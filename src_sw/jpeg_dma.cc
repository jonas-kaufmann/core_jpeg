#include "include/jpeg_dma.hh"

#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <udmabuf/u-dma-buf-ioctl.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <iostream>

namespace jpeg {
namespace {

constexpr size_t kDefaultDmaAlignment = 1;

uint8_t *g_dma_buf = nullptr;
size_t g_dma_buf_size = 0;
size_t g_dma_buf_off = 0;
uintptr_t g_dma_phys_base = 0;

size_t AlignUp(size_t value, size_t alignment) {
  return (value + alignment - 1) & ~(alignment - 1);
}

bool DmaBufInit() {
  char attr[1024] = {0};

  int fd = open("/sys/class/u-dma-buf/udmabuf0/size", O_RDONLY);
  if (fd == -1) {
    std::cerr << "opening /sys/class/u-dma-buf/udmabuf0/size failed with "
              << std::strerror(errno) << "\n";
    return false;
  }
  read(fd, attr, sizeof(attr));
  std::sscanf(attr, "%ld", &g_dma_buf_size);
  close(fd);

  fd = open("/sys/class/u-dma-buf/udmabuf0/phys_addr", O_RDONLY);
  if (fd == -1) {
    std::cerr << "opening /sys/class/u-dma-buf/udmabuf0/phys_addr failed with "
              << std::strerror(errno) << "\n";
    return false;
  }
  std::memset(attr, 0, sizeof(attr));
  read(fd, attr, sizeof(attr));
  std::sscanf(attr, "%lx", &g_dma_phys_base);
  close(fd);

  fd = open("/sys/class/u-dma-buf/udmabuf0/dma_coherent", O_RDONLY);
  if (fd == -1) {
    std::cerr
        << "opening /sys/class/u-dma-buf/udmabuf0/dma_coherent failed with "
        << std::strerror(errno) << "\n";
    return false;
  }
  std::memset(attr, 0, sizeof(attr));
  read(fd, attr, sizeof(attr));
  uint32_t dma_coherent = 0;
  std::sscanf(attr, "%x", &dma_coherent);
  close(fd);

  std::cout << "dma_init: size=" << g_dma_buf_size
            << " dma_coherent=" << dma_coherent << " phys_addr=0x" << std::hex
            << g_dma_phys_base << std::dec << "\n";

  fd = open("/dev/udmabuf0", O_RDWR | O_SYNC);
  if (fd == -1) {
    std::cerr << "opening /dev/udmabuf0 failed with " << std::strerror(errno)
              << "\n";
    return false;
  }

  u_dma_buf_ioctl_sync_args sync_args = {0};
  int status = ioctl(fd, U_DMA_BUF_IOCTL_GET_SYNC, &sync_args);
  if (status == -1) {
    std::cerr << "ioctl() get_sync /dev/udmabuf0 failed with "
              << std::strerror(errno) << "\n";
    close(fd);
    return false;
  }
  SET_U_DMA_BUF_IOCTL_FLAGS_SYNC_MODE(&sync_args, 2);
  status = ioctl(fd, U_DMA_BUF_IOCTL_SET_SYNC, &sync_args);
  if (status == -1) {
    std::cerr << "ioctl() set_sync /dev/udmabuf0 failed with "
              << std::strerror(errno) << "\n";
    close(fd);
    return false;
  }

  g_dma_buf = static_cast<uint8_t *>(
      mmap(nullptr, g_dma_buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
  close(fd);

  if (g_dma_buf == nullptr || g_dma_buf == MAP_FAILED) {
    std::cerr << "mmaping /dev/udmabuf0 failed with " << std::strerror(errno)
              << "\n";
    g_dma_buf = nullptr;
    return false;
  }

  return true;
}

}  // namespace

bool InitGlobalDma() {
  if (g_dma_buf != nullptr) {
    return true;
  }
  return DmaBufInit();
}

bool DmaBufAllocAligned(size_t size, size_t alignment, DmaBufferRef *out) {
  if (g_dma_buf == nullptr || out == nullptr) {
    return false;
  }
  if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
    std::cerr << __func__ << "(): invalid alignment " << alignment << "\n";
    return false;
  }
  if ((g_dma_phys_base & (alignment - 1)) != 0) {
    std::cerr << __func__ << "(): DMA base physical address 0x" << std::hex
              << g_dma_phys_base << std::dec << " is not aligned to "
              << alignment << " bytes\n";
    return false;
  }

  const size_t aligned_off = AlignUp(g_dma_buf_off, alignment);
  if (aligned_off + size > g_dma_buf_size) {
    return false;
  }

  out->vaddr = g_dma_buf + aligned_off;
  out->paddr = g_dma_phys_base + aligned_off;
  out->size = size;
  g_dma_buf_off = aligned_off + size;
  return true;
}

bool DmaBufAlloc(size_t size, DmaBufferRef *out) {
  return DmaBufAllocAligned(size, kDefaultDmaAlignment, out);
}

}  // namespace jpeg
