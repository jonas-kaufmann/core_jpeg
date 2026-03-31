#!/usr/bin/env bash
set -euo pipefail

g++ -std=c++17 -O2 -g -I. -I../c_model/ -I../../ -pthread jpeg_driver.cc jpeg_sw.cc jpeg_dma.cc vfio.cc -o jpeg_driver_native
