include mk/subdir_pre.mk

VERILATOR_MDIR := $(d)obj_dir
JPEG_SRC_V := $(d)../src_v/
JPEG_AXI_RTL := $(JPEG_SRC_V)axi/rtl/
JPEG_AXIS_RTL := $(JPEG_SRC_V)axis/rtl/

ADDITIONAL_CFLAGS ?=
ADDITIONAL_VFLAGS ?=
BASE_CFLAGS := -I$(abspath $(lib_dir)) -std=c++17 $(ADDITIONAL_CFLAGS)
BASE_VFLAGS := -I$(abspath $(d)) -y $(JPEG_SRC_V) -y $(JPEG_AXI_RTL) -y $(JPEG_AXIS_RTL) -Wno-fatal --threads 1 -j `nproc` -O3 --compiler clang -MAKEFLAGS "OPT=-march=native" -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --Mdir $(VERILATOR_MDIR) --cc --build --exe
BASE_LDFLAGS := -fuse-ld=lld-20

NO_TRACE_CFLAGS := $(BASE_CFLAGS) $(ADDITIONAL_CFLAGS) -DTRACE_MODE=0
NO_TRACE_VFLAGS := $(BASE_VFLAGS) $(ADDITIONAL_VFLAGS)
VCD_TRACE_CFLAGS := $(BASE_CFLAGS) $(ADDITIONAL_CFLAGS) -DTRACE_MODE=1
VCD_TRACE_VFLAGS := $(BASE_VFLAGS) $(ADDITIONAL_VFLAGS) --trace-vcd --no-trace-top --trace-depth 3
SAIF_TRACE_CFLAGS := $(BASE_CFLAGS) $(ADDITIONAL_CFLAGS) -DTRACE_MODE=2
SAIF_TRACE_VFLAGS := $(BASE_VFLAGS) $(ADDITIONAL_VFLAGS) --trace-saif --no-trace-top

BIN := $(d)jpeg_rtl_sim_no_trace \
	$(d)jpeg_rtl_sim_vcd_trace \
	$(d)jpeg_rtl_sim_saif_trace

jpeg-all: $(BIN)

$(d)jpeg_rtl_sim_no_trace: CC := clang-20
$(d)jpeg_rtl_sim_no_trace: CXX := clang++-20
$(d)jpeg_rtl_sim_no_trace: private CFLAGS := $(NO_TRACE_CFLAGS)
$(d)jpeg_rtl_sim_no_trace: private LDFLAGS := $(BASE_LDFLAGS)
$(d)jpeg_rtl_sim_no_trace: private VFLAGS := $(NO_TRACE_VFLAGS)
$(d)jpeg_rtl_sim_no_trace: $(d)jpeg_sim_rtl.sv $(d)jpeg_rtl_1.sv $(d)m_axil_adapter.sv $(d)s_axi_adapter.sv $(d)verilator_adapter.cc $(d)verilator_main.cc $(abspath $(lib_simbricks))
	verilator --top-module jpeg_sim -CFLAGS "$(CFLAGS)" -LDFLAGS "$(LDFLAGS)" $(VFLAGS)  -o $(abspath $@) $^

$(d)jpeg_rtl_sim_vcd_trace: CC := clang-20
$(d)jpeg_rtl_sim_vcd_trace: CXX := clang++-20
$(d)jpeg_rtl_sim_vcd_trace: private CFLAGS := $(VCD_TRACE_CFLAGS)
$(d)jpeg_rtl_sim_vcd_trace: private LDFLAGS := $(BASE_LDFLAGS)
$(d)jpeg_rtl_sim_vcd_trace: private VFLAGS := $(VCD_TRACE_VFLAGS)
$(d)jpeg_rtl_sim_vcd_trace: $(d)jpeg_sim_rtl.sv $(d)jpeg_rtl_1.sv $(d)m_axil_adapter.sv $(d)s_axi_adapter.sv $(d)verilator_adapter.cc $(d)verilator_main.cc $(abspath $(lib_simbricks))
	verilator --top-module jpeg_sim -CFLAGS "$(CFLAGS)" -LDFLAGS "$(LDFLAGS)" $(VFLAGS) -o $(abspath $@) $^

$(d)jpeg_rtl_sim_saif_trace: CC := clang-20
$(d)jpeg_rtl_sim_saif_trace: CXX := clang++-20
$(d)jpeg_rtl_sim_saif_trace: private CFLAGS := $(SAIF_TRACE_CFLAGS)
$(d)jpeg_rtl_sim_saif_trace: private LDFLAGS := $(BASE_LDFLAGS)
$(d)jpeg_rtl_sim_saif_trace: private VFLAGS := $(SAIF_TRACE_VFLAGS)
$(d)jpeg_rtl_sim_saif_trace: $(d)jpeg_sim_rtl.sv $(d)jpeg_rtl_1.sv $(d)m_axil_adapter.sv $(d)s_axi_adapter.sv $(d)verilator_adapter.cc $(d)verilator_main.cc $(abspath $(lib_simbricks))
	verilator --top-module jpeg_sim -CFLAGS "$(CFLAGS)" -LDFLAGS "$(LDFLAGS)" $(VFLAGS) -o $(abspath $@) $^

jpeg-clean:
	rm -rf $(BIN) $(VERILATOR_MDIR)

CLEAN := jpeg-clean

.PHONY: jpeg-all $(BIN) jpeg-clean

include mk/subdir_post.mk
