#include "include/jpeg_driver.hh"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

#include "include/jpeg_regs.hh"
#include "include/jpeg_sw.hh"
#include "include/vfio.hh"

namespace jpeg {

// decoding: how long to sleep when no progress can currently be made
constexpr uint32_t kDecodePollSleepUs = 100;
// decoding: how long to sleep when waiting for free descriptors
constexpr uint32_t kDescriptorPollUs = 10;
// decoding: timout for waiting for a free on-device descriptor
constexpr uint32_t kDescriptorSubmitTimeoutMs = 100;

// Barrier for MMIO writes. Makes sure the currently pending MMIO writes are
// flushed, so any write after the barrier cannot be reordered to before.
inline void mmio_write_barrier() {
  asm volatile("dmb oshst" ::: "memory");
}

inline std::chrono::steady_clock::time_point now_ts() {
  return std::chrono::steady_clock::now();
}

std::mutex g_log_mu;

inline void LogLine(const std::string &message) {
  std::lock_guard<std::mutex> lock(g_log_mu);
  std::cout << message << "\n";
}

inline void LogBlock(const std::string &message) {
  std::lock_guard<std::mutex> lock(g_log_mu);
  std::cout << message;
}

void dump_first_bytes(std::ostream &os, const void *data, size_t size) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data);

  std::ios old_state(nullptr);
  old_state.copyfmt(os);

  for (size_t i = 0; i < size; i += 8) {
    os << std::hex << std::setw(8) << std::setfill('0') << i << ": ";
    const size_t line_end = std::min(i + 8, size);
    for (size_t j = i; j < line_end; ++j) {
      os << std::hex << std::setw(2) << std::setfill('0')
         << static_cast<unsigned>(bytes[j]) << " ";
    }
    os << "\n";
  }

  os.copyfmt(old_state);
}

void Scheduler::AssignSwDecodeJobsLocked() {
  while (!free_dst_slots_.empty() && !waiting_sw_decode_.empty()) {
    const uint32_t image_index = waiting_sw_decode_.front();
    waiting_sw_decode_.pop();

    TaskContext &task = tasks_[image_index];
    if (task.stage != TaskStage::kLoadedAwaitingDecode ||
        !task.src_slot.has_value()) {
      continue;
    }

    task.dst_slot = free_dst_slots_.front();
    free_dst_slots_.pop();
    task.stage = TaskStage::kQueuedForSwDecode;
    ready_sw_decode_.push(image_index);
  }
}

std::optional<AcquiredCpuJob> Scheduler::AcquireCpuJob() {
  std::unique_lock<std::mutex> lock(mu_);
  while (true) {
    if (failed_ || AllWorkDoneLocked()) {
      return std::nullopt;
    }

    while (!ready_post_.empty()) {
      const uint32_t image_index = ready_post_.front();
      ready_post_.pop();

      TaskContext &task = tasks_[image_index];
      if (task.stage != TaskStage::kDecoded || !task.dst_slot.has_value()) {
        continue;
      }

      task.stage = TaskStage::kPostProcessing;
      return AcquiredCpuJob{CpuJobKind::kPostProcess, &task};
    }

    if (mode_ == BackendMode::kSoftware) {
      while (!ready_sw_decode_.empty()) {
        const uint32_t image_index = ready_sw_decode_.front();
        ready_sw_decode_.pop();

        TaskContext &task = tasks_[image_index];
        if (task.stage != TaskStage::kQueuedForSwDecode ||
            !task.src_slot.has_value() || !task.dst_slot.has_value()) {
          continue;
        }

        task.stage = TaskStage::kSwDecoding;
        return AcquiredCpuJob{CpuJobKind::kSoftwareDecode, &task};
      }
    }

    if (next_load_index_ < tasks_.size() && !free_src_slots_.empty()) {
      const uint32_t image_index = static_cast<uint32_t>(next_load_index_);
      next_load_index_ += 1;

      TaskContext &task = tasks_[image_index];
      task.src_slot = free_src_slots_.front();
      free_src_slots_.pop();
      task.src_size = 0;
      task.stage = TaskStage::kLoading;

      return AcquiredCpuJob{CpuJobKind::kLoad, &task};
    }

    cv_.wait(lock, [&]() {
      return failed_ || AllWorkDoneLocked() || HasReadyCpuJobLocked();
    });
  }
}

const TaskContext *Scheduler::TryAcquireHardwareSubmitTask() {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_) {
    return nullptr;
  }

  while (!ready_hw_submit_.empty() && !free_dst_slots_.empty()) {
    const uint32_t image_index = ready_hw_submit_.front();
    ready_hw_submit_.pop();

    TaskContext &task = tasks_[image_index];
    if (task.stage != TaskStage::kQueuedForHwSubmit ||
        !task.src_slot.has_value()) {
      continue;
    }

    task.dst_slot = free_dst_slots_.front();
    free_dst_slots_.pop();
    task.stage = TaskStage::kHwSubmitting;

    return &task;
  }

  return nullptr;
}

bool Scheduler::GetTask(uint32_t image_index, TaskContext *out) const {
  if (out == nullptr) {
    return false;
  }

  std::lock_guard<std::mutex> lock(mu_);
  if (image_index >= tasks_.size()) {
    return false;
  }
  *out = tasks_[image_index];
  return true;
}

void Scheduler::CompleteLoad(uint32_t image_index, size_t src_size) {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_ || image_index >= tasks_.size()) {
    return;
  }

  TaskContext &task = tasks_[image_index];
  if (task.stage != TaskStage::kLoading || !task.src_slot.has_value()) {
    failed_ = true;
    failure_message_ = "scheduler: load completed in invalid state";
    cv_.notify_all();
    return;
  }

  task.src_size = src_size;
  if (mode_ == BackendMode::kHardware) {
    task.stage = TaskStage::kQueuedForHwSubmit;
    ready_hw_submit_.push(image_index);
  } else if (!free_dst_slots_.empty()) {
    task.dst_slot = free_dst_slots_.front();
    free_dst_slots_.pop();
    task.stage = TaskStage::kQueuedForSwDecode;
    ready_sw_decode_.push(image_index);
  } else {
    task.stage = TaskStage::kLoadedAwaitingDecode;
    waiting_sw_decode_.push(image_index);
  }

  cv_.notify_all();
}

void Scheduler::CompleteSoftwareDecode(uint32_t image_index,
                                       const jpeg_cpl_entry &cpl) {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_ || image_index >= tasks_.size()) {
    return;
  }

  TaskContext &task = tasks_[image_index];
  if (task.stage != TaskStage::kSwDecoding || !task.src_slot.has_value() ||
      !task.dst_slot.has_value()) {
    failed_ = true;
    failure_message_ = "scheduler: software decode completed in invalid state";
    cv_.notify_all();
    return;
  }

  free_src_slots_.push(*task.src_slot);
  task.src_slot.reset();
  task.src_size = 0;
  task.cpl = cpl;
  task.stage = TaskStage::kDecoded;
  ready_post_.push(image_index);

  cv_.notify_all();
}

void Scheduler::CompleteHardwareSubmit(uint32_t image_index) {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_ || image_index >= tasks_.size()) {
    return;
  }

  TaskContext &task = tasks_[image_index];
  if (task.stage != TaskStage::kHwSubmitting || !task.src_slot.has_value() ||
      !task.dst_slot.has_value()) {
    failed_ = true;
    failure_message_ = "scheduler: hardware submit completed in invalid state";
    cv_.notify_all();
    return;
  }

  task.submit_ts = now_ts();
  task.stage = TaskStage::kHwInflight;
}

void Scheduler::CompleteHardwareDecode(uint32_t image_index,
                                       const jpeg_cpl_entry &cpl) {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_ || image_index >= tasks_.size()) {
    return;
  }

  TaskContext &task = tasks_[image_index];
  if (task.stage != TaskStage::kHwInflight || !task.src_slot.has_value() ||
      !task.dst_slot.has_value()) {
    failed_ = true;
    failure_message_ = "scheduler: hardware decode completed in invalid state";
    cv_.notify_all();
    return;
  }

  free_src_slots_.push(*task.src_slot);
  task.src_slot.reset();
  task.src_size = 0;
  task.cpl = cpl;
  task.stage = TaskStage::kDecoded;
  ready_post_.push(image_index);

  cv_.notify_all();
}

void Scheduler::CompletePostProcess(uint32_t image_index) {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_ || image_index >= tasks_.size()) {
    return;
  }

  TaskContext &task = tasks_[image_index];
  if (task.stage != TaskStage::kPostProcessing || !task.dst_slot.has_value()) {
    failed_ = true;
    failure_message_ = "scheduler: post-process completed in invalid state";
    cv_.notify_all();
    return;
  }

  free_dst_slots_.push(*task.dst_slot);
  task.dst_slot.reset();
  task.stage = TaskStage::kDone;
  num_done_ += 1;

  if (mode_ == BackendMode::kSoftware) {
    AssignSwDecodeJobsLocked();
  }

  cv_.notify_all();
}

void Scheduler::Fail(const std::string &message) {
  std::lock_guard<std::mutex> lock(mu_);
  if (failed_) {
    return;
  }

  failed_ = true;
  failure_message_ = message;
  for (TaskContext &task : tasks_) {
    if (task.stage != TaskStage::kDone) {
      task.stage = TaskStage::kFailed;
    }
  }

  cv_.notify_all();
}

bool Scheduler::HasFailure() const {
  std::lock_guard<std::mutex> lock(mu_);
  return failed_;
}

bool Scheduler::IsFinished() const {
  std::lock_guard<std::mutex> lock(mu_);
  return failed_ || AllWorkDoneLocked();
}

std::string Scheduler::FailureMessage() const {
  std::lock_guard<std::mutex> lock(mu_);
  return failure_message_;
}

size_t Scheduler::TotalImages() const {
  return tasks_.size();
}

bool CpuWorkerThreadMain(const SrcBufferPool &src_pool,
                         const DstBufferPool &dst_pool,
                         uint32_t postprocess_spin_cycles,
                         Scheduler *scheduler) {
  if (scheduler == nullptr) {
    return false;
  }

  while (true) {
    const std::optional<AcquiredCpuJob> job = scheduler->AcquireCpuJob();
    if (!job.has_value()) {
      break;
    }
    if (job->task == nullptr) {
      scheduler->Fail("scheduler returned null CPU task");
      return false;
    }

    const TaskContext &task = *job->task;
    switch (job->kind) {
      case CpuJobKind::kLoad: {
        if (!task.src_slot.has_value()) {
          scheduler->Fail("load job missing source slot");
          return false;
        }

        const DmaBufferRef &src_buf = src_pool.BufferAt(*task.src_slot);
        const auto load_start = now_ts();
        size_t src_size = 0;
        if (!LoadImageToDma(task.image_path.c_str(), src_buf, &src_size)) {
          scheduler->Fail("image load failed for " + task.image_path);
          return false;
        }
        const auto load_end = now_ts();
        const auto load_us =
            std::chrono::duration_cast<std::chrono::microseconds>(load_end -
                                                                  load_start)
                .count();
        std::ostringstream oss;
        oss << "load finished: task_id=" << task.image_index
            << " path=" << task.image_path << " latency_us=" << load_us;
        LogLine(oss.str());
        scheduler->CompleteLoad(task.image_index, src_size);
        break;
      }
      case CpuJobKind::kSoftwareDecode: {
        if (!task.src_slot.has_value() || !task.dst_slot.has_value()) {
          scheduler->Fail("software decode job missing DMA slot");
          return false;
        }

        DmaBufferRef src_buf = src_pool.BufferAt(*task.src_slot);
        src_buf.size = task.src_size;
        const DmaBufferRef &dst_buf = dst_pool.BufferAt(*task.dst_slot);
        if (src_buf.vaddr == nullptr || src_buf.size == 0 ||
            dst_buf.vaddr == nullptr || dst_buf.size == 0) {
          scheduler->Fail("invalid software decode buffers for " +
                          task.image_path);
          return false;
        }

        const auto decode_start = now_ts();
        jpeg_cpl_entry cpl{};
        if (SoftwareDecodeJpeg(src_buf, dst_buf, &cpl) == false) {
          scheduler->Fail("software decode failed for " + task.image_path);
          return false;
        }
        cpl.is_valid = 1;
        cpl.task_id = static_cast<uint16_t>(task.image_index);

        const auto decode_done = now_ts();
        const auto decode_us =
            std::chrono::duration_cast<std::chrono::microseconds>(decode_done -
                                                                  decode_start)
                .count();
        std::ostringstream oss;
        oss << "decode finished: task_id=" << task.image_index
            << " path=" << task.image_path << " latency_us=" << decode_us;
        LogLine(oss.str());
        scheduler->CompleteSoftwareDecode(task.image_index, cpl);
        break;
      }
      case CpuJobKind::kPostProcess: {
        if (!task.dst_slot.has_value()) {
          scheduler->Fail("post-process job missing destination slot");
          return false;
        }

        const DmaBufferRef &dst_buf = dst_pool.BufferAt(*task.dst_slot);
        const size_t decoded_size = static_cast<size_t>(task.cpl.img_width) *
                                    static_cast<size_t>(task.cpl.img_height) *
                                    3;
        const size_t dump_size = std::min(static_cast<size_t>(64),
                                          std::min(dst_buf.size, decoded_size));
        std::ostringstream dump_oss;
        dump_oss << "post: task_id=" << task.image_index << " first "
                 << dump_size << " bytes:\n";
        dump_first_bytes(dump_oss, dst_buf.vaddr, dump_size);
        LogBlock(dump_oss.str());

        const auto post_start = now_ts();
        for (uint32_t i = 0; i < postprocess_spin_cycles; ++i) {
          asm volatile("" ::: "memory");
        }
        const auto post_end = now_ts();
        const auto post_us =
            std::chrono::duration_cast<std::chrono::microseconds>(post_end -
                                                                  post_start)
                .count();
        std::ostringstream oss;
        oss << "post finished: task_id=" << task.image_index
            << " path=" << task.image_path << " latency_us=" << post_us;
        LogLine(oss.str());
        scheduler->CompletePostProcess(task.image_index);
        break;
      }
    }
  }

  return !scheduler->HasFailure();
}

bool HardwareDecoderManagerThreadMain(volatile jpeg_regs *jpeg_dev,
                                      volatile sim_ctrl_regs *sim_ctrl,
                                      const SrcBufferPool &src_pool,
                                      const DstBufferPool &dst_pool,
                                      Scheduler *scheduler) {
  if (scheduler == nullptr || jpeg_dev == nullptr || sim_ctrl == nullptr ||
      src_pool.SlotCount() == 0 || dst_pool.SlotCount() == 0) {
    return false;
  }
  if (scheduler->TotalImages() == 0) {
    return true;
  }

  sim_ctrl->simulation_enabled = 1;
  mmio_write_barrier();

  jpeg_dev->reset = 1;
  mmio_write_barrier();

  {
    std::ostringstream oss;
    oss << __func__
        << "(): number of free descriptors: " << jpeg_dev->desc_num_free;
    LogLine(oss.str());
  }

  while (!scheduler->IsFinished()) {
    bool progressed = false;

    while (true) {
      const std::optional<jpeg_cpl_entry> cpl = TryPopCompletion(jpeg_dev);
      if (!cpl.has_value()) {
        break;
      }

      TaskContext task{};
      if (!scheduler->GetTask(cpl->task_id, &task)) {
        scheduler->Fail("completion for unknown task_id=" +
                        std::to_string(cpl->task_id));
        break;
      }
      if (task.stage != TaskStage::kHwInflight) {
        scheduler->Fail("completion for task not in hardware inflight state");
        break;
      }

      const auto decode_done = now_ts();
      const auto decode_us =
          std::chrono::duration_cast<std::chrono::microseconds>(decode_done -
                                                                task.submit_ts)
              .count();
      std::ostringstream oss;
      oss << "decode finished: task_id=" << task.image_index
          << " path=" << task.image_path << " latency_us=" << decode_us;
      LogLine(oss.str());

      scheduler->CompleteHardwareDecode(cpl->task_id, *cpl);
      progressed = true;
    }
    if (scheduler->HasFailure()) {
      break;
    }

    const TaskContext *task = scheduler->TryAcquireHardwareSubmitTask();
    if (task != nullptr) {
      progressed = true;

      if (!task->src_slot.has_value() || !task->dst_slot.has_value()) {
        scheduler->Fail("hardware submit task missing DMA slot");
        break;
      }

      DmaBufferRef src_buf = src_pool.BufferAt(*task->src_slot);
      src_buf.size = task->src_size;
      const DmaBufferRef &dst_buf = dst_pool.BufferAt(*task->dst_slot);
      if (src_buf.vaddr == nullptr || src_buf.paddr == 0 || src_buf.size == 0 ||
          dst_buf.vaddr == nullptr || dst_buf.paddr == 0 || dst_buf.size == 0) {
        scheduler->Fail("invalid hardware descriptor arguments for " +
                        task->image_path);
        break;
      }

      const auto deadline =
          std::chrono::steady_clock::now() +
          std::chrono::milliseconds(kDescriptorSubmitTimeoutMs);
      while (jpeg_dev->desc_num_free == 0) {
        if (std::chrono::steady_clock::now() >= deadline) {
          scheduler->Fail("timed out waiting for free descriptor");
          break;
        }
        std::this_thread::sleep_for(
            std::chrono::microseconds(kDescriptorPollUs));
      }
      if (scheduler->HasFailure()) {
        break;
      }

      jpeg_dev->src_addr = src_buf.paddr;
      jpeg_dev->src_len = src_buf.size;
      jpeg_dev->dst_addr = dst_buf.paddr;
      jpeg_dev->task_id = task->image_index;
      mmio_write_barrier();
      jpeg_dev->desc_commit = 1;
      mmio_write_barrier();

      scheduler->CompleteHardwareSubmit(task->image_index);
    }

    if (!progressed) {
      std::this_thread::sleep_for(
          std::chrono::microseconds(kDecodePollSleepUs));
    }
  }

  sim_ctrl->simulation_enabled = 0;
  mmio_write_barrier();
  return !scheduler->HasFailure();
}

bool LoadImageToDma(const char *img, const DmaBufferRef &dst_dma,
                    size_t *loaded_size_out) {
  if (dst_dma.vaddr == nullptr || dst_dma.size == 0) {
    std::cerr << __func__ << "(): invalid destination DMA buffer\n";
    return false;
  }
  std::FILE *f = std::fopen(img, "rb");
  if (f == nullptr) {
    std::cerr << __func__ << "(): opening file " << img << " failed\n";
    return false;
  }

  if (fseek(f, 0, SEEK_END) != 0) {
    std::cerr << __func__ << "(): fseek failed for " << img << "\n";
    fclose(f);
    return false;
  }
  const long sz = ftell(f);
  if (sz < 0) {
    std::cerr << __func__ << "(): ftell failed for " << img << "\n";
    fclose(f);
    return false;
  }
  if (static_cast<size_t>(sz) > dst_dma.size) {
    std::cerr << __func__ << "(): image " << img << " (" << sz
              << " bytes) exceeds source DMA slot size (" << dst_dma.size
              << " bytes)\n";
    fclose(f);
    return false;
  }
  rewind(f);

  const size_t read_ok = fread(dst_dma.vaddr, static_cast<size_t>(sz), 1, f);
  fclose(f);
  if (read_ok != 1) {
    std::cerr << __func__ << "(): fread failed for " << img << "\n";
    return false;
  }

  *loaded_size_out = static_cast<size_t>(sz);
  return true;
}

std::optional<jpeg_cpl_entry> TryPopCompletion(volatile jpeg_regs *jpeg_dev) {
  if (jpeg_dev == nullptr) {
    return std::nullopt;
  }

  const uint64_t cpl_entry_v = jpeg_dev->cpl_entry;
  jpeg_cpl_entry cpl{};
  std::memcpy(&cpl, &cpl_entry_v, sizeof(cpl));
  if (cpl.is_valid == 0) {
    return std::nullopt;
  }
  return cpl;
}

}  // namespace jpeg

namespace {

bool init_vfio(const char *device, volatile struct jpeg_regs **jpeg_dev_out,
               volatile struct sim_ctrl_regs **sim_ctrl_out) {
  if (device == nullptr || jpeg_dev_out == nullptr || sim_ctrl_out == nullptr) {
    return false;
  }

  const int vfio_fd = vfio_init(device);
  if (vfio_fd < 0) {
    std::cerr << "vfio init failed\n";
    return false;
  }

  if (vfio_busmaster_enable(vfio_fd)) {
    std::cerr << "vfio busmaster enable failed\n";
    return false;
  }

  size_t reg_len = 0;
  void *bar0 = nullptr;
  if (vfio_map_region(vfio_fd, 0, &bar0, &reg_len)) {
    std::cerr << "vfio map region 0 failed\n";
    return false;
  }
  *jpeg_dev_out = static_cast<volatile struct jpeg_regs *>(bar0);

  void *bar1 = nullptr;
  if (vfio_map_region(vfio_fd, 1, &bar1, &reg_len)) {
    std::cerr << "vfio map region 1 failed\n";
    return false;
  }
  *sim_ctrl_out = static_cast<volatile struct sim_ctrl_regs *>(bar1);

  return true;
}

bool init_devmem(const char *phys_addr_str,
                 volatile struct jpeg_regs **jpeg_dev_out,
                 volatile struct sim_ctrl_regs **sim_ctrl_out) {
  const off_t phys_addr =
      static_cast<off_t>(std::strtoull(phys_addr_str, nullptr, 0));

  const int devmem_fd = open("/dev/mem", O_RDWR | O_SYNC);
  if (devmem_fd < 0) {
    std::cerr << "opening /dev/mem failed: " << std::strerror(errno) << "\n";
    return false;
  }

  void *jpeg_map =
      mmap(nullptr, sizeof(struct jpeg_regs), PROT_READ | PROT_WRITE,
           MAP_SHARED, devmem_fd, phys_addr);
  if (jpeg_map == MAP_FAILED) {
    std::cerr << "mmap /dev/mem failed: " << std::strerror(errno) << "\n";
    close(devmem_fd);
    return false;
  }
  close(devmem_fd);

  *jpeg_dev_out = static_cast<volatile struct jpeg_regs *>(jpeg_map);
  // simulation control doesn't exist outside simulation environment so let's
  // just map a dummy here
  *sim_ctrl_out = new volatile sim_ctrl_regs{};
  return true;
}

}  // namespace

int main(int argc, char *argv[]) {
  if (argc < 5) {
    std::cerr << "usage: jpeg_driver {vfio|devmem|sw} DEVICE-ARG "
                 "POSTPROCESS_SPIN_CYCLES PATH_TO_IMAGE...\n";
    return EXIT_FAILURE;
  }

  volatile struct jpeg_regs *jpeg_dev = nullptr;
  volatile struct sim_ctrl_regs *sim_ctrl = nullptr;
  const uint32_t postprocess_spin_cycles =
      static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 0));
  const std::string backend = argv[1];

  if (backend == "vfio") {
    if (init_vfio(argv[2], &jpeg_dev, &sim_ctrl) == false) {
      return EXIT_FAILURE;
    }
  } else if (backend == "devmem") {
    if (init_devmem(argv[2], &jpeg_dev, &sim_ctrl) == false) {
      return EXIT_FAILURE;
    }
  } else if (backend != "sw") {
    std::cerr << "unknown backend '" << backend
              << "', expected 'vfio', 'devmem', or 'sw'\n";
    return EXIT_FAILURE;
  }

  jpeg::SrcBufferPool src_pool;
  jpeg::DstBufferPool dst_pool;
  if (backend != "sw") {
    if (!jpeg::InitGlobalDma()) {
      std::cerr << "DMA init failed\n";
      return EXIT_FAILURE;
    }
    if (!src_pool.InitDmaBufferPool()) {
      std::cerr << "source DMA pool init failed\n";
      return EXIT_FAILURE;
    }
    if (!dst_pool.InitDmaBufferPool()) {
      std::cerr << "destination DMA pool init failed\n";
      return EXIT_FAILURE;
    }
  } else {
    if (src_pool.InitMallocBufferPool() == false) {
      std::cerr << "source malloc pool init failed\n";
      return EXIT_FAILURE;
    }
    if (dst_pool.InitMallocBufferPool() == false) {
      std::cerr << "destination malloc pool init failed\n";
      return EXIT_FAILURE;
    }
  }

  std::vector<std::string> image_paths;
  for (int i = 4; i < argc; ++i) {
    image_paths.emplace_back(argv[i]);
  }

  if (image_paths.size() >
      static_cast<size_t>(std::numeric_limits<uint16_t>::max()) + 1) {
    std::cerr << "too many images for 16-bit task IDs\n";
    return EXIT_FAILURE;
  }

  const jpeg::BackendMode mode = (backend == "sw")
                                     ? jpeg::BackendMode::kSoftware
                                     : jpeg::BackendMode::kHardware;
  jpeg::Scheduler scheduler(mode, image_paths, src_pool.SlotCount(),
                            dst_pool.SlotCount());

  unsigned int cpu_workers = std::thread::hardware_concurrency();
  if (cpu_workers == 0) {
    cpu_workers = 1;
  }
  if (mode == jpeg::BackendMode::kHardware && cpu_workers > 1) {
    cpu_workers -= 1;
  }

  std::atomic<bool> workers_ok{true};
  std::vector<std::thread> workers;
  workers.reserve(cpu_workers);
  for (unsigned int i = 0; i < cpu_workers; ++i) {
    workers.emplace_back([&]() {
      const bool ok = jpeg::CpuWorkerThreadMain(
          src_pool, dst_pool, postprocess_spin_cycles, &scheduler);
      if (!ok) {
        workers_ok.store(false);
      }
    });
  }

  std::atomic<bool> hw_ok{true};
  std::thread hw_thr;
  if (mode == jpeg::BackendMode::kHardware) {
    hw_thr = std::thread([&]() {
      const bool ok = jpeg::HardwareDecoderManagerThreadMain(
          jpeg_dev, sim_ctrl, src_pool, dst_pool, &scheduler);
      if (!ok) {
        hw_ok.store(false);
      }
    });
  }

  for (std::thread &thr : workers) {
    thr.join();
  }
  if (hw_thr.joinable()) {
    hw_thr.join();
  }

  if (!workers_ok.load() || !hw_ok.load() || scheduler.HasFailure()) {
    const std::string failure_message = scheduler.FailureMessage();
    if (!failure_message.empty()) {
      std::cerr << failure_message << "\n";
    }
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
