#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <vector>

#include "include/jpeg_dma.hh"
#include "include/jpeg_regs.hh"

namespace jpeg {

enum class BackendMode { kHardware, kSoftware };

enum class TaskStage {
  kPendingLoad,
  kLoading,
  kLoadedAwaitingDecode,
  kQueuedForHwSubmit,
  kHwSubmitting,
  kHwInflight,
  kQueuedForSwDecode,
  kSwDecoding,
  kDecoded,
  kPostProcessing,
  kDone,
  kFailed,
};

struct TaskContext;

enum class CpuJobKind { kLoad, kSoftwareDecode, kPostProcess };

struct AcquiredCpuJob {
  CpuJobKind kind{};
  const TaskContext *task = nullptr;
};

struct TaskContext {
  uint32_t image_index = 0;
  std::string image_path;
  TaskStage stage = TaskStage::kPendingLoad;
  std::optional<uint32_t> src_slot;
  std::optional<uint32_t> dst_slot;
  size_t src_size = 0;
  jpeg_cpl_entry cpl{};
  std::chrono::steady_clock::time_point submit_ts{};
};

class Scheduler {
 public:
  Scheduler(BackendMode mode, const std::vector<std::string> &image_paths,
            size_t src_slot_count, size_t dst_slot_count)
      : mode_(mode) {
    tasks_.reserve(image_paths.size());
    for (size_t i = 0; i < image_paths.size(); ++i) {
      TaskContext task{};
      task.image_index = static_cast<uint32_t>(i);
      task.image_path = image_paths[i];
      tasks_.push_back(std::move(task));
    }

    for (uint32_t i = 0; i < src_slot_count; ++i) {
      free_src_slots_.push(i);
    }
    for (uint32_t i = 0; i < dst_slot_count; ++i) {
      free_dst_slots_.push(i);
    }
  }

  std::optional<AcquiredCpuJob> AcquireCpuJob();
  const TaskContext *TryAcquireHardwareSubmitTask();

  bool GetTask(uint32_t image_index, TaskContext *out) const;

  void CompleteLoad(uint32_t image_index, size_t src_size);
  void CompleteSoftwareDecode(uint32_t image_index, const jpeg_cpl_entry &cpl);
  void CompleteHardwareSubmit(uint32_t image_index);
  void CompleteHardwareDecode(uint32_t image_index, const jpeg_cpl_entry &cpl);
  void CompletePostProcess(uint32_t image_index);

  void Fail(const std::string &message);

  bool HasFailure() const;
  bool IsFinished() const;
  std::string FailureMessage() const;
  size_t TotalImages() const;

 private:
  bool HasReadyCpuJobLocked() const {
    if (!ready_post_.empty()) {
      return true;
    }
    if (mode_ == BackendMode::kSoftware && !ready_sw_decode_.empty()) {
      return true;
    }
    return next_load_index_ < tasks_.size() && !free_src_slots_.empty();
  }

  bool AllWorkDoneLocked() const {
    return num_done_ == tasks_.size();
  }

  void AssignSwDecodeJobsLocked();

  BackendMode mode_;
  std::vector<TaskContext> tasks_;
  size_t next_load_index_ = 0;
  size_t num_done_ = 0;
  std::queue<uint32_t> free_src_slots_;
  std::queue<uint32_t> free_dst_slots_;
  std::queue<uint32_t> ready_post_;
  std::queue<uint32_t> waiting_sw_decode_;
  std::queue<uint32_t> ready_sw_decode_;
  std::queue<uint32_t> ready_hw_submit_;
  bool failed_ = false;
  std::string failure_message_;
  mutable std::mutex mu_;
  std::condition_variable cv_;
};

bool CpuWorkerThreadMain(const SrcBufferPool &src_pool,
                         const DstBufferPool &dst_pool,
                         uint32_t postprocess_spin_cycles,
                         Scheduler *scheduler);

bool HardwareDecoderManagerThreadMain(volatile jpeg_regs *jpeg_dev,
                                      volatile sim_ctrl_regs *sim_ctrl,
                                      const SrcBufferPool &src_pool,
                                      const DstBufferPool &dst_pool,
                                      Scheduler *scheduler);

bool LoadImageToDma(const char *img, const DmaBufferRef &dst_dma,
                    size_t *loaded_size_out);

std::optional<jpeg_cpl_entry> TryPopCompletion(volatile jpeg_regs *jpeg_dev);

}  // namespace jpeg
