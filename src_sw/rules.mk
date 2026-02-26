include mk/subdir_pre.mk

# TODO(jonas-kaufmann): Compile two version of binary; one for x86 and one for ARM64

JPEG_CPPFLAGS_EXTRA := -I$(d)
jpeg_driver := $(d)jpeg_driver

$(jpeg_driver): CPPFLAGS += $(JPEG_CPPFLAGS_EXTRA)
$(jpeg_driver): CXX := aarch64-linux-gnu-g++
$(jpeg_driver): $(d)vfio.o $(d)jpeg_dma.o

OBJS := $(d)jpeg_driver.o $(d)jpeg_dma.o $(d)vfio.o
CLEAN := $(OBJS) $(jpeg_driver)
ALL := $(jpeg_driver)

include mk/subdir_post.mk
