## TODOs
- Decoded image is in 8x8 row-major order. Implementing proper reordering in HW
  is somewhat expensive as this requires enough memory to hold
  `max_supported_img_width x 8` pixels.
