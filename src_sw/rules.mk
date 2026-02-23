include mk/subdir_pre.mk

# TODO(jonas-kaufmann): Compile two version of binary; one for x86 and one for ARM64

jpeg_driver := $(d)jpeg_driver

$(jpeg_driver): CXX := aarch64-linux-gnu-g++
$(jpeg_driver): $(d)vfio.o

OBJS := $(d)jpeg_driver.o $(d)vfio.o
CLEAN := $(OBJS) $(jpeg_driver)
ALL := $(jpeg_driver)

include mk/subdir_post.mk
