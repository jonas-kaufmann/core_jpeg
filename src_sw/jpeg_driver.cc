#include <fcntl.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <udmabuf/u-dma-buf-ioctl.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <thread>
#include <unordered_map>

#include "include/jpeg_regs.hh"
#include "include/vfio.hh"

#define DEBUG 0

static const size_t DMA_DST_BUF_SIZE = 4096 * 4096 * 3;

static std::unordered_map<void *, std::pair<size_t, uintptr_t>> cma_map{};
static uint8_t *dma_buf = nullptr;
static size_t dma_buf_size = 0;
static size_t dma_buf_off = 0;
static uintptr_t dma_phys_base = 0;
static volatile struct jpeg_regs *jpeg_dev;
static volatile struct sim_ctrl_regs *sim_ctrl;
static uint16_t next_task_id = 0;

// Barrier for MMIO writes. Makes sure the currently pending MMIO writes are
// being flushed, so any write after the barrier cannot be reordered to before.
static inline void mmio_wmb() {
  asm volatile("dmb oshst" ::: "memory");
}

static bool dma_buf_init() {
  // read DMA buffer size
  char attr[1024];
  int fd = open("/sys/class/u-dma-buf/udmabuf0/size", O_RDONLY);
  if (fd == -1) {
    std::cerr << "opening /sys/class/u-dma-buf/udmabuf0/size failed with "
              << std::strerror(errno) << "\n";
    return false;
  }
  read(fd, attr, 1024);
  std::sscanf(attr, "%ld", &dma_buf_size);
  close(fd);

  // read DMA buffer physical address
  fd = open("/sys/class/u-dma-buf/udmabuf0/phys_addr", O_RDONLY);
  if (fd == -1) {
    std::cerr << "opening /sys/class/u-dma-buf/udmabuf0/phys_addr failed with "
              << std::strerror(errno) << "\n";
    return false;
  }
  read(fd, attr, 1024);
  std::sscanf(attr, "%lx", &dma_phys_base);
  close(fd);

  // read DMA coherent flag
  fd = open("/sys/class/u-dma-buf/udmabuf0/dma_coherent", O_RDONLY);
  if (fd == -1) {
    std::cerr
        << "opening /sys/class/u-dma-buf/udmabuf0/dma_coherent failed with "
        << std::strerror(errno) << "\n";
    return false;
  }
  read(fd, attr, 1024);
  uint32_t dma_coherent;
  std::sscanf(attr, "%x", &dma_coherent);
  close(fd);

  // print some info about DMA buffer
  std::cout << "dma_init: size=" << dma_buf_size
            << " dma_coherent=" << dma_coherent << " phys_addr=0x" << std::hex
            << dma_phys_base << std::dec << "\n";

  // TODO(jonas-kaufman): Add explicit cache flush here and O_SYNC
  fd = open("/dev/udmabuf0", O_RDWR | O_SYNC);
  if (fd == -1) {
    std::cerr << "opening /dev/udmabuf0 failed with " << std::strerror(errno)
              << "\n";
    return false;
  }

  // Enable write combining and disable using the cache
  u_dma_buf_ioctl_sync_args sync_args = {0};
  int status = ioctl(fd, U_DMA_BUF_IOCTL_GET_SYNC, &sync_args);
  if (status == -1) {
    std::cerr << "ioctl() get_sync /dev/udmabuf0 failed with "
              << std::strerror(errno) << "\n";
    return false;
  }
  SET_U_DMA_BUF_IOCTL_FLAGS_SYNC_MODE(&sync_args, 2);
  status = ioctl(fd, U_DMA_BUF_IOCTL_SET_SYNC, &sync_args);
  if (status == -1) {
    std::cerr << "ioctl() set_sync /dev/udmabuf0 failed with "
              << std::strerror(errno) << "\n";
    return false;
  }

  // mmap the DMA buffer
  dma_buf = static_cast<uint8_t *>(
      mmap(nullptr, dma_buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0));
  if (dma_buf == nullptr) {
    std::cerr << "mmaping /dev/udmabuf0 failed with " << std::strerror(errno)
              << "\n";
    return false;
  }
  close(fd);

  return true;
}

static bool dma_buf_alloc(size_t size, void **vaddr_out, uintptr_t *paddr_out) {
  std::cout << __func__ << "(size=" << size << ")\n";

  if (dma_buf_off + size > dma_buf_size) {
    return false;
  }

  *vaddr_out = dma_buf + dma_buf_off;
  *paddr_out = dma_phys_base + dma_buf_off;
  dma_buf_off += size;

  return true;
}

static void print_buffer(const void *data, size_t size) {
  auto *bytes = static_cast<const std::uint8_t *>(data);

  std::ios old_state(nullptr);
  old_state.copyfmt(std::cout);  // preserve formatting

  for (std::size_t i = 0; i < size; ++i) {
    if (i % 16 == 0) {
      if (i != 0)
        std::cout << '\n';
    }

    std::cout << std::hex << std::setw(2) << std::setfill('0')
              << static_cast<unsigned>(bytes[i]) << ' ';
  }

  std::cout << '\n';
  std::cout.copyfmt(old_state);  // restore formatting
}

bool load_image(const char *img, size_t *size_out, void **dmabuf_out,
                uintptr_t *dmabuf_paddr_out) {
  std::chrono::time_point start_prepare =
      std::chrono::high_resolution_clock::now();

  std::FILE *f = std::fopen(img, "rb");
  if (f == nullptr) {
    std::cerr << __func__ << "(): opening file " << img << " failed\n";
    return false;
  }

  // Get size
  size_t size;
  fseek(f, 0, SEEK_END);
  size = ftell(f);
  rewind(f);

  // Read file data in
  void *dmabuf;
  uintptr_t dmabuf_paddr;
  if (!dma_buf_alloc(size, &dmabuf, &dmabuf_paddr)) {
    std::cerr << __func__ << "(): dma_buf_alloc failed\n";
    return false;
  }
  fread(dmabuf, size, 1, f);
  fclose(f);

  // Print how long loading took
  std::chrono::duration duration_prepare =
      std::chrono::high_resolution_clock::now() - start_prepare;
  std::cout << __func__ << "() loading image took "
            << std::chrono::duration_cast<std::chrono::nanoseconds>(
                   duration_prepare)
                   .count()
            << "ns\n";

  *size_out = size;
  *dmabuf_out = dmabuf;
  *dmabuf_paddr_out = dmabuf_paddr;

  return true;
}

bool decode_image(size_t src_size, void *dmabuf_src,
                  uintptr_t dmabuf_src_paddr) {
  // Allocate destination DMA buf
  void *dmabuf_dst;
  uintptr_t dmabuf_dst_paddr;
  if (!dma_buf_alloc(DMA_DST_BUF_SIZE, &dmabuf_dst, &dmabuf_dst_paddr)) {
    std::cerr << __func__ << "(): dma_buf_alloc failed\n";
    return false;
  }

  // Wait for space in descriptor queue
  std::chrono::time_point start_wait =
      std::chrono::high_resolution_clock::now();
  while (jpeg_dev->desc_num_free == 0) {
    std::cout << __func__ << "(): waiting for free descriptor\n";
    std::this_thread::sleep_for(std::chrono::microseconds(100));
  }
  std::chrono::duration duration_wait =
      std::chrono::high_resolution_clock::now() - start_wait;
  std::cout << __func__ << "() waiting for free descriptor took "
            << std::chrono::duration_cast<std::chrono::nanoseconds>(
                   duration_wait)
                   .count()
            << "ns\n";

  std::chrono::time_point start_decode =
      std::chrono::high_resolution_clock::now();
  jpeg_dev->src_addr = dmabuf_src_paddr;
  jpeg_dev->src_len = src_size;
  jpeg_dev->dst_addr = dmabuf_dst_paddr;
  uint16_t task_id = next_task_id++;
  jpeg_dev->task_id = task_id;
  mmio_wmb();
  jpeg_dev->desc_commit = 1;

  struct jpeg_cpl_entry cpl_entry;
  auto decode_timeout = std::chrono::milliseconds(100);
  auto decode_deadline =
      std::chrono::high_resolution_clock::now() + decode_timeout;
  while (true) {
    if (std::chrono::high_resolution_clock::now() >= decode_deadline) {
      std::cerr << __func__ << "(): decode timed out after "
                << std::chrono::duration_cast<std::chrono::milliseconds>(
                       decode_timeout)
                       .count()
                << "ms\n";
      return false;
    }

    // Single read required here due to HW implementation, which pops the
    // descriptor once read.
    uint64_t cpl_entry_v = jpeg_dev->cpl_entry;
    std::memcpy(&cpl_entry, &cpl_entry_v, sizeof(cpl_entry));

    if (cpl_entry.is_valid == 0) {
      std::cout << __func__ << "(): waiting for valid cpl_entry\n";
      std::this_thread::sleep_for(std::chrono::microseconds(100));
      continue;
    }

    if (cpl_entry.task_id == task_id) {
      std::cout << __func__ << "(): decode done cpl_entry_v=0x" << std::hex
                << cpl_entry_v << std::dec << " width=" << cpl_entry.img_width
                << " height=" << cpl_entry.img_height << "\n";
      break;
    }
  }

  std::chrono::duration duration_decode =
      std::chrono::high_resolution_clock::now() - start_decode;
  std::cout << __func__ << "() decode took "
            << std::chrono::duration_cast<std::chrono::nanoseconds>(
                   duration_decode)
                   .count()
            << "ns\n";

  std::cout << "First decoded 64 pixels as hex:\n";
  print_buffer(dmabuf_dst, std::min(64 * 3, cpl_entry.img_width *
                                                cpl_entry.img_height * 3));

  // TODO(Jonas) Free dmabuf

  return true;
}

int main(int argc, char *argv[]) {
  if (argc < 3) {
    std::cerr << "usage: jpeg_driver PCI-DEVICE PATH_TO_IMAGE...\n";
    return EXIT_FAILURE;
  }

  char *device = argv[1];
  int vfio_fd;
  if ((vfio_fd = vfio_init(device)) < 0) {
    std::cerr << "vfio init failed" << std::endl;
    return EXIT_FAILURE;
  }

  if (vfio_busmaster_enable(vfio_fd)) {
    std::cerr << "vfio busmaster enable failed" << std::endl;
    return EXIT_FAILURE;
  }

  size_t reg_len = 0;
  void *bar0;
  if (vfio_map_region(vfio_fd, 0, &bar0, &reg_len)) {
    std::cerr << "vfio map region failed" << std::endl;
    return EXIT_FAILURE;
  }
  jpeg_dev = static_cast<volatile struct jpeg_regs *>(bar0);

  void *bar1;
  if (vfio_map_region(vfio_fd, 1, &bar1, &reg_len)) {
    std::cerr << "vfio map region failed" << std::endl;
    return EXIT_FAILURE;
  }
  sim_ctrl = static_cast<volatile struct sim_ctrl_regs *>(bar1);

  if (!dma_buf_init()) {
    return EXIT_FAILURE;
  }

  std::cout << "jpeg_driver: initialization complete, starting decode...\n";
  size_t src_size;
  void *dmabuf_src;
  uintptr_t dmabuf_src_paddr;
  if (!load_image(argv[2], &src_size, &dmabuf_src, &dmabuf_src_paddr)) {
    std::cerr << "Loading img " << argv[2] << " failed\n";
    return EXIT_FAILURE;
  }
  sim_ctrl->simulation_enabled = 1;
  mmio_wmb();
  bool success = decode_image(src_size, dmabuf_src, dmabuf_src_paddr);
  sim_ctrl->simulation_enabled = 0;
  mmio_wmb();
  if (!success) {
    std::cerr << "Decoding img " << argv[2] << " failed\n";
  }

  return success ? EXIT_SUCCESS : EXIT_FAILURE;
}
