#pragma once

#include <array>
#include <bitset>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>

namespace jpeg {

struct DmaBufferRef {
  void *vaddr = nullptr;
  uintptr_t paddr = 0;
  size_t size = 0;
};

bool DmaBufAllocAligned(size_t size, size_t alignment, DmaBufferRef *out);
bool DmaBufAlloc(size_t size, DmaBufferRef *out);

template <size_t kNumSlots, size_t kSlotSizeBytes>
class BufferPool {
 public:
  static constexpr size_t kAlignmentBytes = 128;

  bool InitDmaBufferPool() {
    std::lock_guard<std::mutex> lock(mu_);
    for (size_t i = 0; i < kNumSlots; ++i) {
      DmaBufferRef buf{};
      if (!DmaBufAllocAligned(kSlotSizeBytes, kAlignmentBytes, &buf)) {
        std::cerr << __func__ << "(): DMA pool allocation failed at slot " << i
                  << "\n";
        return false;
      }
      buffers_[i] = buf;
    }
    slot_in_use_.reset();
    return true;
  }

  bool InitMallocBufferPool() {
    std::lock_guard<std::mutex> lock(mu_);
    for (size_t i = 0; i < kNumSlots; ++i) {
      DmaBufferRef buf{};
      void *ptr = nullptr;
      if (posix_memalign(&ptr, kAlignmentBytes, kSlotSizeBytes) != 0) {
        std::cerr << __func__ << "(): malloc pool allocation failed at slot "
                  << i << "\n";
        return false;
      }
      buf.vaddr = ptr;
      buf.size = kSlotSizeBytes;
      buffers_[i] = buf;
    }
    slot_in_use_.reset();
    uses_malloc_ = true;
    return true;
  }

  bool GetBufferFromPool(uint32_t *slot_out, DmaBufferRef *buffer_out) {
    if (slot_out == nullptr || buffer_out == nullptr) {
      return false;
    }

    std::lock_guard<std::mutex> lock(mu_);
    for (uint32_t i = 0; i < kNumSlots; ++i) {
      if (slot_in_use_.test(i)) {
        continue;
      }
      slot_in_use_.set(i);
      *slot_out = i;
      *buffer_out = buffers_[i];
      return true;
    }
    return false;
  }

  bool ReleaseBufferSlot(uint32_t slot) {
    std::lock_guard<std::mutex> lock(mu_);
    if (slot >= kNumSlots) {
      return false;
    }
    if (!slot_in_use_.test(slot)) {
      return false;
    }
    slot_in_use_.reset(slot);
    return true;
  }

  size_t SlotCount() const {
    return kNumSlots;
  }
  size_t SlotSize() const {
    return kSlotSizeBytes;
  }
  const DmaBufferRef &BufferAt(uint32_t slot) const {
    return buffers_[slot];
  }

 private:
  std::array<DmaBufferRef, kNumSlots> buffers_{};
  std::bitset<kNumSlots> slot_in_use_{};
  bool uses_malloc_ = false;
  std::mutex mu_;
};

// support decoding images up to 4096x4096 pixels
using DstBufferPool = BufferPool<4, 4096 * 4096 * 3>;
// assume images are at least half 50% compressed
using SrcBufferPool = BufferPool<4, 4096 * 4096 * 3 / 2>;

bool InitGlobalDma();

}  // namespace jpeg
