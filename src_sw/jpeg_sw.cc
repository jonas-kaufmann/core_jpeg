#include "include/jpeg_sw.hh"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>

#include "jpeg_bit_buffer.h"
#include "jpeg_dht.h"
#include "jpeg_dqt.h"
#include "jpeg_idct.h"
#include "jpeg_mcu_block.h"

namespace jpeg {
namespace {

enum class JpegMode {
  kMonochrome,
  kYcbcr444,
  kYcbcr420,
  kUnsupported,
};

class SoftwareJpegDecoder {
 public:
  SoftwareJpegDecoder() : mcu_dec_(&bit_buffer_, &dht_) {
  }

  bool Decode(const DmaBufferRef &src, const DmaBufferRef &dst,
              jpeg_cpl_entry *cpl_out) {
    if (src.vaddr == nullptr || src.size == 0 || dst.vaddr == nullptr ||
        dst.size == 0 || cpl_out == nullptr) {
      std::cerr << __func__
                << "(): invalid buffers passed to software decode\n";
      return false;
    }

    src_bytes_ = static_cast<const uint8_t *>(src.vaddr);
    src_len_ = src.size;
    dst_bytes_ = static_cast<uint8_t *>(dst.vaddr);
    dst_capacity_ = dst.size;
    width_ = 0;
    height_ = 0;
    mode_ = JpegMode::kUnsupported;
    std::memset(dqt_table_, 0, sizeof(dqt_table_));
    dqt_.reset();
    dht_.reset();
    idct_.reset();

    bool decode_done = false;
    uint8_t last_b = 0;
    for (size_t i = 0; i < src_len_;) {
      uint8_t b = src_bytes_[i++];

      if (last_b == 0xFF && b == 0xD8) {
        last_b = b;
        continue;
      }

      if (last_b == 0xFF && b == 0xC0) {
        if (ParseSof0(&i) == false) {
          return false;
        }
      } else if (last_b == 0xFF && b == 0xDB) {
        if (ParseDqt(&i) == false) {
          return false;
        }
      } else if (last_b == 0xFF && b == 0xC4) {
        if (ParseDht(&i) == false) {
          return false;
        }
      } else if (last_b == 0xFF && b == 0xDA) {
        if (ParseSos(&i) == false) {
          return false;
        }
        decode_done = DecodeImage();
        if (decode_done == false) {
          return false;
        }
      } else if (last_b == 0xFF && b == 0xD9) {
        break;
      } else if (last_b == 0xFF && b == 0xC2) {
        std::cerr << __func__ << "(): progressive JPEG not supported\n";
        return false;
      } else if (last_b == 0xFF && (b == 0xDD || (b >= 0xD0 && b <= 0xD7) ||
                                    (b >= 0xE0 && b <= 0xEF) || b == 0xFE)) {
        if (SkipSegment(&i) == false) {
          return false;
        }
      }

      last_b = b;
    }

    if (decode_done == false) {
      std::cerr << __func__ << "(): JPEG decode did not complete\n";
      return false;
    }

    cpl_out->is_valid = 1;
    cpl_out->img_width = width_;
    cpl_out->img_height = height_;
    return true;
  }

 private:
  static uint8_t GetByte(const uint8_t *buf, size_t *idx) {
    const uint8_t value = buf[*idx];
    *idx += 1;
    return value;
  }

  static uint16_t GetWord(const uint8_t *buf, size_t *idx) {
    const uint16_t hi = GetByte(buf, idx);
    const uint16_t lo = GetByte(buf, idx);
    return static_cast<uint16_t>((hi << 8) | lo);
  }

  bool RequireAvailable(size_t offset, size_t needed) const {
    if (offset + needed > src_len_) {
      std::cerr << __func__ << "(): truncated JPEG stream\n";
      return false;
    }
    return true;
  }

  bool EnsureDstCapacity() const {
    const size_t required =
        static_cast<size_t>(width_) * static_cast<size_t>(height_) * 3;
    if (required > dst_capacity_) {
      std::cerr << __func__ << "(): decoded image exceeds destination buffer\n";
      return false;
    }
    return true;
  }

  bool SkipSegment(size_t *idx) {
    if (RequireAvailable(*idx, 2) == false) {
      return false;
    }
    const size_t seg_start = *idx;
    const uint16_t seg_len = GetWord(src_bytes_, idx);
    if (seg_len < 2) {
      std::cerr << __func__ << "(): malformed segment length\n";
      return false;
    }
    if (seg_start + seg_len > src_len_) {
      std::cerr << __func__ << "(): segment exceeds JPEG input\n";
      return false;
    }
    *idx = seg_start + seg_len;
    return true;
  }

  bool ParseSof0(size_t *idx) {
    if (RequireAvailable(*idx, 2) == false) {
      return false;
    }
    const size_t seg_start = *idx;
    const uint16_t seg_len = GetWord(src_bytes_, idx);
    if (seg_len < 8 || seg_start + seg_len > src_len_) {
      std::cerr << __func__ << "(): invalid SOF0 segment\n";
      return false;
    }

    if (RequireAvailable(*idx, static_cast<size_t>(seg_len) - 2) == false) {
      return false;
    }

    const uint8_t precision = GetByte(src_bytes_, idx);
    (void)precision;
    height_ = GetWord(src_bytes_, idx);
    width_ = GetWord(src_bytes_, idx);
    const uint8_t num_comps = GetByte(src_bytes_, idx);
    if (num_comps > 3) {
      std::cerr << __func__ << "(): unsupported component count\n";
      return false;
    }
    if (EnsureDstCapacity() == false) {
      return false;
    }

    uint8_t comp_id[3] = {0, 0, 0};
    uint8_t horiz_factor[3] = {0, 0, 0};
    uint8_t vert_factor[3] = {0, 0, 0};
    for (uint8_t x = 0; x < num_comps; ++x) {
      comp_id[x] = GetByte(src_bytes_, idx);
      const uint8_t sample_factor = GetByte(src_bytes_, idx);
      horiz_factor[x] = static_cast<uint8_t>(sample_factor >> 4);
      vert_factor[x] = static_cast<uint8_t>(sample_factor & 0xF);
      dqt_table_[x] = GetByte(src_bytes_, idx);
    }

    mode_ = JpegMode::kUnsupported;
    if (num_comps == 1) {
      mode_ = JpegMode::kMonochrome;
    } else if (num_comps == 3 && comp_id[0] == 1 && comp_id[1] == 2 &&
               comp_id[2] == 3) {
      if (horiz_factor[0] == 1 && vert_factor[0] == 1 && horiz_factor[1] == 1 &&
          vert_factor[1] == 1 && horiz_factor[2] == 1 && vert_factor[2] == 1) {
        mode_ = JpegMode::kYcbcr444;
      } else if (horiz_factor[0] == 2 && vert_factor[0] == 2 &&
                 horiz_factor[1] == 1 && vert_factor[1] == 1 &&
                 horiz_factor[2] == 1 && vert_factor[2] == 1) {
        mode_ = JpegMode::kYcbcr420;
      }
    }

    *idx = seg_start + seg_len;
    return true;
  }

  bool ParseDqt(size_t *idx) {
    if (RequireAvailable(*idx, 2) == false) {
      return false;
    }
    const size_t seg_start = *idx;
    const uint16_t seg_len = GetWord(src_bytes_, idx);
    if (seg_len < 2 || seg_start + seg_len > src_len_) {
      std::cerr << __func__ << "(): invalid DQT segment\n";
      return false;
    }
    dqt_.process(const_cast<uint8_t *>(&src_bytes_[*idx]), seg_len - 2);
    *idx = seg_start + seg_len;
    return true;
  }

  bool ParseDht(size_t *idx) {
    if (RequireAvailable(*idx, 2) == false) {
      return false;
    }
    const size_t seg_start = *idx;
    const uint16_t seg_len = GetWord(src_bytes_, idx);
    if (seg_len < 2 || seg_start + seg_len > src_len_) {
      std::cerr << __func__ << "(): invalid DHT segment\n";
      return false;
    }
    dht_.process(const_cast<uint8_t *>(&src_bytes_[*idx]), seg_len - 2);
    *idx = seg_start + seg_len;
    return true;
  }

  bool ParseSos(size_t *idx) {
    if (mode_ == JpegMode::kUnsupported) {
      std::cerr << __func__ << "(): unsupported JPEG mode\n";
      return false;
    }
    if (RequireAvailable(*idx, 2) == false) {
      return false;
    }
    const size_t seg_start = *idx;
    const uint16_t seg_len = GetWord(src_bytes_, idx);
    if (seg_len < 2 || seg_start + seg_len > src_len_) {
      std::cerr << __func__ << "(): invalid SOS segment\n";
      return false;
    }

    if (RequireAvailable(*idx, static_cast<size_t>(seg_len) - 2) == false) {
      return false;
    }

    const uint8_t comp_count = GetByte(src_bytes_, idx);
    for (uint8_t x = 0; x < comp_count; ++x) {
      (void)GetByte(src_bytes_, idx);
      (void)GetByte(src_bytes_, idx);
    }
    (void)GetByte(src_bytes_, idx);
    (void)GetByte(src_bytes_, idx);
    (void)GetByte(src_bytes_, idx);

    *idx = seg_start + seg_len;
    bit_buffer_.reset(static_cast<int>(src_len_));
    while (*idx < src_len_) {
      const uint8_t b = src_bytes_[*idx];
      if (bit_buffer_.push(b)) {
        *idx += 1;
      } else {
        if (*idx > 0) {
          *idx -= 1;
        }
        break;
      }
    }
    return true;
  }

  bool WriteRgbPixel(int x, int y, int r, int g, int b) {
    if (x < 0 || y < 0 || x >= width_ || y >= height_) {
      return true;
    }

    r = std::clamp(r, 0, 255);
    g = std::clamp(g, 0, 255);
    b = std::clamp(b, 0, 255);

    const size_t offset =
        (static_cast<size_t>(y) * static_cast<size_t>(width_) +
         static_cast<size_t>(x)) *
        3;
    if (offset + 2 >= dst_capacity_) {
      std::cerr << __func__ << "(): destination write exceeded buffer\n";
      return false;
    }

    dst_bytes_[offset + 0] = static_cast<uint8_t>(r);
    dst_bytes_[offset + 1] = static_cast<uint8_t>(g);
    dst_bytes_[offset + 2] = static_cast<uint8_t>(b);
    return true;
  }

  bool ConvertBlock(int block_num, int *y, int *cb, int *cr) {
    int x_blocks = width_ / 8;
    if ((width_ % 8) != 0) {
      x_blocks += 1;
    }

    const int x_start = (block_num % x_blocks) * 8;
    const int y_start = (block_num / x_blocks) * 8;

    for (int i = 0; i < 64; ++i) {
      int r = 128 + y[i];
      int g = 128 + y[i];
      int b = 128 + y[i];
      if (mode_ != JpegMode::kMonochrome) {
        r = static_cast<int>(128 + y[i] + (cr[i] * 1.402));
        g = static_cast<int>(128 + y[i] - (cb[i] * 0.34414) -
                             (cr[i] * 0.71414));
        b = static_cast<int>(128 + y[i] + (cb[i] * 1.772));
      }

      const int px = x_start + (i % 8);
      const int py = y_start + (i / 8);
      if (WriteRgbPixel(px, py, r, g, b) == false) {
        return false;
      }
    }
    return true;
  }

  bool DecodeImage() {
    int16_t dc_coeff_y = 0;
    int16_t dc_coeff_cb = 0;
    int16_t dc_coeff_cr = 0;
    int32_t sample_out[64];
    int block_out[64];
    int y_dct_out[4 * 64];
    int cb_dct_out[64];
    int cr_dct_out[64];
    int count = 0;
    int loop = 0;
    int block_num = 0;

    while (bit_buffer_.eof() == false) {
      if (mode_ == JpegMode::kYcbcr420) {
        count = mcu_dec_.decode(DHT_TABLE_Y_DC_IDX, dc_coeff_y, sample_out);
        dqt_.process_samples(dqt_table_[0], sample_out, block_out, count);
        idct_.process(block_out, &y_dct_out[0]);

        count = mcu_dec_.decode(DHT_TABLE_Y_DC_IDX, dc_coeff_y, sample_out);
        dqt_.process_samples(dqt_table_[0], sample_out, block_out, count);
        idct_.process(block_out, &y_dct_out[64]);

        count = mcu_dec_.decode(DHT_TABLE_Y_DC_IDX, dc_coeff_y, sample_out);
        dqt_.process_samples(dqt_table_[0], sample_out, block_out, count);
        idct_.process(block_out, &y_dct_out[128]);

        count = mcu_dec_.decode(DHT_TABLE_Y_DC_IDX, dc_coeff_y, sample_out);
        dqt_.process_samples(dqt_table_[0], sample_out, block_out, count);
        idct_.process(block_out, &y_dct_out[192]);

        count = mcu_dec_.decode(DHT_TABLE_CX_DC_IDX, dc_coeff_cb, sample_out);
        dqt_.process_samples(dqt_table_[1], sample_out, block_out, count);
        idct_.process(block_out, &cb_dct_out[0]);

        count = mcu_dec_.decode(DHT_TABLE_CX_DC_IDX, dc_coeff_cr, sample_out);
        dqt_.process_samples(dqt_table_[2], sample_out, block_out, count);
        idct_.process(block_out, &cr_dct_out[0]);

        int cb_dct_out_x2[256];
        int cr_dct_out_x2[256];
        for (int i = 0; i < 64; ++i) {
          int x = i % 8;
          int y = i / 16;
          int sub_idx = (y * 8) + (x / 2);
          cb_dct_out_x2[i] = cb_dct_out[sub_idx];
          cr_dct_out_x2[i] = cr_dct_out[sub_idx];
        }
        for (int i = 0; i < 64; ++i) {
          int x = i % 8;
          int y = i / 16;
          int sub_idx = (y * 8) + 4 + (x / 2);
          cb_dct_out_x2[64 + i] = cb_dct_out[sub_idx];
          cr_dct_out_x2[64 + i] = cr_dct_out[sub_idx];
        }
        for (int i = 0; i < 64; ++i) {
          int x = i % 8;
          int y = i / 16;
          int sub_idx = 32 + (y * 8) + (x / 2);
          cb_dct_out_x2[128 + i] = cb_dct_out[sub_idx];
          cr_dct_out_x2[128 + i] = cr_dct_out[sub_idx];
        }
        for (int i = 0; i < 64; ++i) {
          int x = i % 8;
          int y = i / 16;
          int sub_idx = 32 + (y * 8) + 4 + (x / 2);
          cb_dct_out_x2[192 + i] = cb_dct_out[sub_idx];
          cr_dct_out_x2[192 + i] = cr_dct_out[sub_idx];
        }

        int mcu_width = width_ / 8;
        if ((width_ % 8) != 0) {
          mcu_width += 1;
        }

        if (ConvertBlock((block_num / 2) + 0, &y_dct_out[0], &cb_dct_out_x2[0],
                         &cr_dct_out_x2[0]) == false ||
            ConvertBlock((block_num / 2) + 1, &y_dct_out[64],
                         &cb_dct_out_x2[64], &cr_dct_out_x2[64]) == false ||
            ConvertBlock((block_num / 2) + mcu_width + 0, &y_dct_out[128],
                         &cb_dct_out_x2[128], &cr_dct_out_x2[128]) == false ||
            ConvertBlock((block_num / 2) + mcu_width + 1, &y_dct_out[192],
                         &cb_dct_out_x2[192], &cr_dct_out_x2[192]) == false) {
          return false;
        }

        block_num += 4;
        loop += 1;
        if (loop == (mcu_width / 2)) {
          block_num += (mcu_width * 2);
          loop = 0;
        }
      } else if (mode_ == JpegMode::kYcbcr444) {
        count = mcu_dec_.decode(DHT_TABLE_Y_DC_IDX, dc_coeff_y, sample_out);
        dqt_.process_samples(dqt_table_[0], sample_out, block_out, count);
        idct_.process(block_out, &y_dct_out[0]);

        count = mcu_dec_.decode(DHT_TABLE_CX_DC_IDX, dc_coeff_cb, sample_out);
        dqt_.process_samples(dqt_table_[1], sample_out, block_out, count);
        idct_.process(block_out, &cb_dct_out[0]);

        count = mcu_dec_.decode(DHT_TABLE_CX_DC_IDX, dc_coeff_cr, sample_out);
        dqt_.process_samples(dqt_table_[2], sample_out, block_out, count);
        idct_.process(block_out, &cr_dct_out[0]);

        if (ConvertBlock(block_num, y_dct_out, cb_dct_out, cr_dct_out) ==
            false) {
          return false;
        }
        block_num += 1;
      } else if (mode_ == JpegMode::kMonochrome) {
        count = mcu_dec_.decode(DHT_TABLE_Y_DC_IDX, dc_coeff_y, sample_out);
        dqt_.process_samples(dqt_table_[0], sample_out, block_out, count);
        idct_.process(block_out, &y_dct_out[0]);

        if (ConvertBlock(block_num, y_dct_out, cb_dct_out, cr_dct_out) ==
            false) {
          return false;
        }
        block_num += 1;
      } else {
        return false;
      }
    }

    return true;
  }

  jpeg_dqt dqt_;
  jpeg_dht dht_;
  jpeg_idct idct_;
  jpeg_bit_buffer bit_buffer_;
  jpeg_mcu_block mcu_dec_;

  const uint8_t *src_bytes_ = nullptr;
  size_t src_len_ = 0;
  uint8_t *dst_bytes_ = nullptr;
  size_t dst_capacity_ = 0;
  uint16_t width_ = 0;
  uint16_t height_ = 0;
  JpegMode mode_ = JpegMode::kUnsupported;
  uint8_t dqt_table_[3] = {0, 0, 0};
};

}  // namespace

bool SoftwareDecodeJpeg(const DmaBufferRef &src, const DmaBufferRef &dst,
                        jpeg_cpl_entry *cpl_out) {
  SoftwareJpegDecoder decoder;
  return decoder.Decode(src, dst, cpl_out);
}

}  // namespace jpeg
