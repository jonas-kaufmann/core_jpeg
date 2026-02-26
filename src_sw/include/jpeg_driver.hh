#pragma once

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <chrono>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <utility>
#include <vector>

#include "include/jpeg_dma.hh"
#include "include/jpeg_regs.hh"

namespace jpeg {

struct ImageLoadedEvent {
  uint16_t task_id = 0;
  std::string image_path;
  uint32_t src_slot = 0;
  DmaBufferRef src;
};

struct ImageDecodedEvent {
  uint16_t task_id = 0;
  std::string image_path;
  DmaBufferRef dst;
  uint32_t dst_slot = 0;
  jpeg_cpl_entry cpl{};
};

struct DecodeInflightTask {
  uint16_t task_id = 0;
  uint32_t dst_slot = 0;
  std::chrono::steady_clock::time_point submit_ts;
  ImageLoadedEvent src_task;
};

template <typename T>
class BlockingFifo {
 public:
  void Push(T value);
  void WaitForEntry();
  void Pop(T *out);

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  std::queue<T> q_;
};

struct PipelineQueues {
  BlockingFifo<ImageLoadedEvent> load_to_decode;
  BlockingFifo<ImageDecodedEvent> decode_to_post;

  // Feedback path: post-processing returns destination slot IDs to decoder.
  BlockingFifo<uint32_t> released_dst_slots;

  // Feedback path: decoder returns source slot IDs to loader.
  BlockingFifo<uint32_t> released_src_slots;
};

bool LoadImageToDma(const char *img, const DmaBufferRef &dst_dma,
                    size_t *loaded_size_out);

// Per-thread entry points.
bool ImageLoaderThread(const std::vector<std::string> &image_paths,
                       const SrcBufferPool &src_pool, PipelineQueues *queues);

bool DecoderManagerThreadMain(volatile jpeg_regs *jpeg_dev,
                              volatile sim_ctrl_regs *sim_ctrl,
                              const DstBufferPool &dst_pool,
                              size_t total_images, PipelineQueues *queues);

bool PostProcessThreadMain(size_t total_images, PipelineQueues *queues);

// Decoder thread helpers.
std::optional<jpeg_cpl_entry> TryPopCompletion(volatile jpeg_regs *jpeg_dev);

template <typename T>
void BlockingFifo<T>::Push(T value) {
  std::lock_guard<std::mutex> lock(mu_);
  q_.push(std::move(value));
  cv_.notify_one();
}

template <typename T>
void BlockingFifo<T>::WaitForEntry() {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait(lock, [this]() { return !q_.empty(); });
}

template <typename T>
void BlockingFifo<T>::Pop(T *out) {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait(lock, [this]() { return !q_.empty(); });
  *out = std::move(q_.front());
  q_.pop();
}

}  // namespace jpeg
