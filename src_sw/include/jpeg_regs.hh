#pragma once

#include <stdint.h>

struct __attribute__((__packed__)) jpeg_regs {
  uint64_t src_addr;
  uint64_t src_len;
  uint64_t dst_addr;
  uint64_t task_id;  // actually uint16_t but this forces full-width write
  uint64_t desc_commit;
  uint64_t desc_num_free;
  uint64_t cpl_entry;
  uint64_t reset;
};

struct __attribute__((__packed__)) jpeg_cpl_entry {
  uint16_t is_valid;
  uint16_t task_id;
  uint16_t img_width;
  uint16_t img_height;
};

// make sure `struct jpeg_cpl_entry` maps cleanly to `cpl_entry`
static_assert(sizeof(static_cast<struct jpeg_regs *>(nullptr)->cpl_entry) ==
              sizeof(struct jpeg_cpl_entry));

struct __attribute__((__packed__)) sim_ctrl_regs {
  uint32_t simulation_enabled;
};
