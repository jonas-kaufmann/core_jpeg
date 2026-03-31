#pragma once

#include "include/jpeg_dma.hh"
#include "include/jpeg_regs.hh"

namespace jpeg {

bool SoftwareDecodeJpeg(const DmaBufferRef &src, const DmaBufferRef &dst,
                        jpeg_cpl_entry *cpl_out);

}  // namespace jpeg
