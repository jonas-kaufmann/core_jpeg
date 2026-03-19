#include "include/jpeg_driver.hh"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>
#include <unordered_map>
#include <vector>

#include "include/jpeg_regs.hh"
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

void dump_first_bytes(const void *data, size_t size) {
  const uint8_t *bytes = static_cast<const uint8_t *>(data);

  std::ios old_state(nullptr);
  old_state.copyfmt(std::cout);

  for (size_t i = 0; i < size; i += 8) {
    std::cout << std::hex << std::setw(8) << std::setfill('0') << i << ": ";
    const size_t line_end = std::min(i + 8, size);
    for (size_t j = i; j < line_end; ++j) {
      std::cout << std::hex << std::setw(2) << std::setfill('0')
                << static_cast<unsigned>(bytes[j]) << " ";
    }
    std::cout << "\n";
  }

  std::cout.copyfmt(old_state);
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
  long sz = ftell(f);
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

  size_t read_ok = fread(dst_dma.vaddr, static_cast<size_t>(sz), 1, f);
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

  uint64_t cpl_entry_v = jpeg_dev->cpl_entry;
  jpeg_cpl_entry cpl{};
  std::memcpy(&cpl, &cpl_entry_v, sizeof(cpl));
  if (cpl.is_valid == 0) {
    return std::nullopt;
  }
  return cpl;
}

bool ImageLoaderThread(const std::vector<std::string> &image_paths,
                       const SrcBufferPool &src_pool, PipelineQueues *queues) {
  if (queues == nullptr || src_pool.SlotCount() == 0) {
    return false;
  }

  uint16_t task_id = 0;
  std::queue<uint32_t> free_src_slots;
  for (uint32_t i = 0; i < src_pool.SlotCount(); ++i) {
    free_src_slots.push(i);
  }

  for (const std::string &path : image_paths) {
    if (free_src_slots.empty()) {
      uint32_t released_src_slot = 0;
      queues->released_src_slots.Pop(&released_src_slot);
      if (released_src_slot >= src_pool.SlotCount()) {
        std::cerr << __func__
                  << "(): invalid released src slot=" << released_src_slot
                  << "\n";
        return false;
      }
      free_src_slots.push(released_src_slot);
    }

    const uint32_t src_slot = free_src_slots.front();
    free_src_slots.pop();
    const DmaBufferRef &src_buf = src_pool.BufferAt(src_slot);

    const auto load_start = now_ts();
    size_t src_size = 0;
    if (!LoadImageToDma(path.c_str(), src_buf, &src_size)) {
      return false;
    }
    const auto load_end = now_ts();
    const auto load_us = std::chrono::duration_cast<std::chrono::microseconds>(
                             load_end - load_start)
                             .count();
    std::cout << "load finished: task_id=" << task_id << " path=" << path
              << " latency_us=" << load_us << "\n";

    ImageLoadedEvent event{};
    event.task_id = task_id;
    event.image_path = path;
    event.src_slot = src_slot;
    event.src = src_buf;
    event.src.size = src_size;

    queues->load_to_decode.Push(std::move(event));
    ++task_id;
  }
  return true;
}

bool DecoderManagerThreadMain(volatile jpeg_regs *jpeg_dev,
                              volatile sim_ctrl_regs *sim_ctrl,
                              const DstBufferPool &dst_pool,
                              size_t total_images, PipelineQueues *queues) {
  if (queues == nullptr || jpeg_dev == nullptr || sim_ctrl == nullptr ||
      dst_pool.SlotCount() == 0) {
    return false;
  }

  std::queue<uint32_t> free_slots;
  for (uint32_t i = 0; i < dst_pool.SlotCount(); ++i) {
    free_slots.push(i);
  }

  size_t num_submitted = 0;
  size_t num_completed = 0;
  std::unordered_map<uint16_t, DecodeInflightTask> inflight;

  queues->load_to_decode.WaitForEntry();

  // enable simulation of JPEG decoder
  sim_ctrl->simulation_enabled = 1;
  mmio_write_barrier();

  while (num_completed < total_images) {
    bool progressed = false;

    // process all available completion entries
    while (true) {
      std::optional<jpeg_cpl_entry> cpl = TryPopCompletion(jpeg_dev);
      if (!cpl.has_value()) {
        break;
      }

      auto it = inflight.find(cpl->task_id);
      if (it == inflight.end()) {
        std::cerr << __func__
                  << "(): completion for unknown task_id=" << cpl->task_id
                  << "\n";
        return false;
      }

      const DecodeInflightTask &inflight_task = it->second;
      if (inflight_task.dst_slot >= dst_pool.SlotCount()) {
        std::cerr << __func__ << "(): invalid dst slot in inflight state\n";
        return false;
      }
      const auto decode_done = now_ts();
      const auto decode_us =
          std::chrono::duration_cast<std::chrono::microseconds>(
              decode_done - inflight_task.submit_ts)
              .count();
      std::cout << "decode finished: task_id=" << inflight_task.task_id
                << " path=" << inflight_task.src_task.image_path
                << " latency_us=" << decode_us << "\n";

      ImageDecodedEvent event{};
      event.task_id = inflight_task.task_id;
      event.image_path = inflight_task.src_task.image_path;
      event.dst_slot = inflight_task.dst_slot;
      event.dst = dst_pool.BufferAt(inflight_task.dst_slot);
      event.cpl = *cpl;
      queues->decode_to_post.Push(std::move(event));
      queues->released_src_slots.Push(inflight_task.src_task.src_slot);

      inflight.erase(it);
      ++num_completed;
      progressed = true;
    }

    // push task descriptor for new image to decode
    if (num_submitted < total_images && !free_slots.empty()) {
      ImageLoadedEvent src_task{};
      queues->load_to_decode.Pop(&src_task);
      ++num_submitted;
      uint32_t slot = free_slots.front();
      free_slots.pop();

      const DmaBufferRef &dst_buf = dst_pool.BufferAt(slot);
      if (src_task.src.vaddr == nullptr || src_task.src.paddr == 0 ||
          src_task.src.size == 0 || dst_buf.vaddr == nullptr ||
          dst_buf.paddr == 0 || dst_buf.size == 0) {
        std::cerr << __func__ << "(): invalid descriptor arguments\n";
        return false;
      }

      // wait for free descriptor
      auto deadline = std::chrono::steady_clock::now() +
                      std::chrono::milliseconds(kDescriptorSubmitTimeoutMs);
      while (jpeg_dev->desc_num_free == 0) {
        if (std::chrono::steady_clock::now() >= deadline) {
          std::cerr << __func__
                    << "(): timed out waiting for free descriptor\n";
          return false;
        }
        std::this_thread::sleep_for(
            std::chrono::microseconds(kDescriptorPollUs));
      }

      jpeg_dev->src_addr = src_task.src.paddr;
      jpeg_dev->src_len = src_task.src.size;
      jpeg_dev->dst_addr = dst_buf.paddr;
      jpeg_dev->task_id = src_task.task_id;
      mmio_write_barrier();
      jpeg_dev->desc_commit = 1;
      mmio_write_barrier();

      DecodeInflightTask inflight_task{};
      inflight_task.task_id = src_task.task_id;
      inflight_task.dst_slot = slot;
      inflight_task.submit_ts = now_ts();
      inflight_task.src_task = std::move(src_task);

      auto inserted =
          inflight.emplace(inflight_task.task_id, std::move(inflight_task));
      if (!inserted.second) {
        std::cerr << __func__
                  << "(): duplicate task_id=" << inserted.first->first
                  << " in flight\n";
        return false;
      }

      progressed = true;
    }

    // release slots in DMA dst buffer pool
    if (free_slots.empty()) {
      uint32_t released_slot = 0;
      queues->released_dst_slots.Pop(&released_slot);
      if (released_slot >= dst_pool.SlotCount()) {
        std::cerr << __func__
                  << "(): invalid released dst slot=" << released_slot << "\n";
        return false;
      }
      free_slots.push(released_slot);
      progressed = true;
    }

    if (!progressed) {
      std::this_thread::sleep_for(
          std::chrono::microseconds(kDecodePollSleepUs));
    }
  }

  // disable simulation of JPEG decoder
  sim_ctrl->simulation_enabled = 0;
  mmio_write_barrier();

  return true;
}

bool PostProcessThreadMain(size_t total_images,
                           uint32_t postprocess_spin_cycles,
                           PipelineQueues *queues) {
  if (queues == nullptr) {
    return false;
  }

  for (size_t i = 0; i < total_images; ++i) {
    ImageDecodedEvent task{};
    queues->decode_to_post.Pop(&task);

    const size_t decoded_size = static_cast<size_t>(task.cpl.img_width) *
                                static_cast<size_t>(task.cpl.img_height) * 3;
    const size_t dump_size = std::min(static_cast<size_t>(64),
                                      std::min(task.dst.size, decoded_size));
    std::cout << "post: task_id=" << task.task_id << " first " << dump_size
              << " bytes:\n";
    dump_first_bytes(task.dst.vaddr, dump_size);

    const auto post_start = now_ts();
    for (uint32_t i = 0; i < postprocess_spin_cycles; ++i) {
      asm volatile("" ::: "memory");
    }
    const auto post_end = now_ts();
    const auto post_us = std::chrono::duration_cast<std::chrono::microseconds>(
                             post_end - post_start)
                             .count();
    std::cout << "post finished: task_id=" << task.task_id
              << " path=" << task.image_path << " latency_us=" << post_us
              << "\n";
    queues->released_dst_slots.Push(task.dst_slot);
  }
  return true;
}

}  // namespace jpeg

namespace {

bool init_vfio(const char *device, volatile struct jpeg_regs **jpeg_dev_out,
               volatile struct sim_ctrl_regs **sim_ctrl_out) {
  if (device == nullptr || jpeg_dev_out == nullptr || sim_ctrl_out == nullptr) {
    return false;
  }

  int vfio_fd = vfio_init(device);
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
    std::cerr << "usage: jpeg_driver_revamped {vfio|devmem} DEVICE-ARG "
                 "POSTPROCESS_SPIN_CYCLES PATH_TO_IMAGE...\n";
    return EXIT_FAILURE;
  }

  volatile struct jpeg_regs *jpeg_dev = nullptr;
  volatile struct sim_ctrl_regs *sim_ctrl = nullptr;
  const std::string backend = argv[1];
  if (backend == "vfio") {
    if (!init_vfio(argv[2], &jpeg_dev, &sim_ctrl)) {
      return EXIT_FAILURE;
    }
  } else if (backend == "devmem") {
    if (!init_devmem(argv[2], &jpeg_dev, &sim_ctrl)) {
      return EXIT_FAILURE;
    }
  } else {
    std::cerr << "unknown backend '" << backend
              << "', expected 'vfio' or 'devmem'\n";
    return EXIT_FAILURE;
  }

  const uint32_t postprocess_spin_cycles =
      static_cast<uint32_t>(std::strtoul(argv[3], nullptr, 0));

  if (!jpeg::InitGlobalDma()) {
    std::cerr << "DMA init failed\n";
    return EXIT_FAILURE;
  }

  jpeg::SrcBufferPool src_pool;
  if (!src_pool.InitDmaBufferPool()) {
    std::cerr << "source DMA pool init failed\n";
    return EXIT_FAILURE;
  }

  jpeg::DstBufferPool dst_pool;
  if (!dst_pool.InitDmaBufferPool()) {
    std::cerr << "destination DMA pool init failed\n";
    return EXIT_FAILURE;
  }

  std::vector<std::string> image_paths;
  for (int i = 4; i < argc; ++i) {
    image_paths.emplace_back(argv[i]);
  }
  const size_t total_images = image_paths.size();

  jpeg::PipelineQueues queues;
  std::mutex status_mu;
  std::condition_variable status_cv;
  bool loader_done = false;
  bool decoder_done = false;
  bool post_done = false;
  bool loader_ok = false;
  bool decoder_ok = false;
  bool post_ok = false;

  // start worker threads
  std::thread loader_thr([&]() {
    const bool ok = jpeg::ImageLoaderThread(image_paths, src_pool, &queues);
    {
      std::lock_guard<std::mutex> lock(status_mu);
      loader_ok = ok;
      loader_done = true;
    }
    status_cv.notify_one();
  });
  std::thread decoder_thr([&]() {
    const bool ok = jpeg::DecoderManagerThreadMain(jpeg_dev, sim_ctrl, dst_pool,
                                                   total_images, &queues);
    {
      std::lock_guard<std::mutex> lock(status_mu);
      decoder_ok = ok;
      decoder_done = true;
    }
    status_cv.notify_one();
  });
  std::thread post_thr([&]() {
    const bool ok = jpeg::PostProcessThreadMain(
        total_images, postprocess_spin_cycles, &queues);
    {
      std::lock_guard<std::mutex> lock(status_mu);
      post_ok = ok;
      post_done = true;
    }
    status_cv.notify_one();
  });

  // wait for worker threads to finish
  std::unique_lock<std::mutex> lock(status_mu);
  while (!(loader_done && decoder_done && post_done)) {
    status_cv.wait(lock, [&]() {
      return (loader_done && decoder_done && post_done) ||
             (loader_done && !loader_ok) || (decoder_done && !decoder_ok) ||
             (post_done && !post_ok);
    });
    if (loader_done && !loader_ok) {
      std::cerr << "jpeg_driver_revamped: loader thread failed\n";
      return EXIT_FAILURE;
    }
    if (decoder_done && !decoder_ok) {
      std::cerr << "jpeg_driver_revamped: decoder thread failed\n";
      return EXIT_FAILURE;
    }
    if (post_done && !post_ok) {
      std::cerr << "jpeg_driver_revamped: post thread failed\n";
      return EXIT_FAILURE;
    }
  }

  loader_thr.join();
  decoder_thr.join();
  post_thr.join();

  return EXIT_SUCCESS;
}
