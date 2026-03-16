#define TRACE_MODE_NONE 0
#define TRACE_MODE_VCD 1
#define TRACE_MODE_SAIF 2

#ifndef TRACE_MODE
#define TRACE_MODE TRACE_MODE_VCD
#endif

#define TRACE_ENABLED \
  TRACE_MODE == TRACE_MODE_VCD || TRACE_MODE == TRACE_MODE_SAIF

#if TRACE_MODE == TRACE_MODE_VCD
#include <verilated_vcd_c.h>
#elif TRACE_MODE == TRACE_MODE_SAIF
#include <verilated_saif_c.h>
#endif

#include <Vjpeg_sim.h>
#include <sys/stat.h>
#include <verilated.h>
#include <verilated_vcd_c.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <ostream>
#include <sstream>
#include <string>

static std::unique_ptr<Vjpeg_sim> topp;

static uint32_t trace_idx_next = 0;
#if TRACE_MODE == TRACE_MODE_VCD
static std::unique_ptr<VerilatedVcdC> tracer;
#elif TRACE_MODE == TRACE_MODE_SAIF
static std::unique_ptr<VerilatedSaifC> tracer;
#endif

#if TRACE_ENABLED
void create_next_trace_file(char *base_filename) {
#if TRACE_MODE == TRACE_MODE_VCD
  if (!tracer->isOpen()) {
    std::ostringstream trace_file;
    trace_file << base_filename;
    trace_file << ".vcd";
    tracer->open(trace_file.str().c_str());
    return;
  }
  tracer->openNext(true);
#elif TRACE_MODE == TRACE_MODE_SAIF
  tracer->close();
  // produce trace file name with incrementing suffix
  std::ostringstream trace_file;
  trace_file << base_filename << "_" << trace_idx_next++;
  trace_file << ".saif";
  tracer->open(trace_file.str().c_str());
#endif
}
#endif

int main(int argc, char **argv, char **) {
  if (argc < 5) {
    std::cerr << "usage: jpeg_sim <clock frequency in MHz> <path to trace file "
                 "without suffix> <nanoseconds after which to write to next "
                 "waveform file> <number of nanoseconds per waveform file> "
                 "[plusargs...]"
              << std::endl;
    return 1;
  }
  uint64_t clk_freq = std::stoull(argv[1]);
  uint64_t clk_period_ps = 1000000 / clk_freq;
  uint64_t sampling_period_ps = std::stoull(argv[3]) * 1000;
  uint64_t sample_length_ps = std::stoull(argv[4]) * 1000;
  uint64_t next_trace_file_at_ps = sampling_period_ps;
  uint64_t trace_until = sample_length_ps;

  std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);
  topp = std::unique_ptr<Vjpeg_sim>(new Vjpeg_sim(contextp.get(), ""));

  // Reset design
  topp->rst = 1;
  for (int i = 0; i < 10; ++i) {
    topp->clk = 0;
    topp->eval();
    topp->clk = 1;
    topp->eval();
  }
  topp->rst = 0;

// Set up tracing
#if TRACE_ENABLED
  Verilated::traceEverOn(true);
#if TRACE_MODE == TRACE_MODE_VCD
  tracer = std::unique_ptr<VerilatedVcdC>(new VerilatedVcdC());
#elif TRACE_MODE == TRACE_MODE_SAIF
  tracer = std::unique_ptr<VerilatedSaifC>(new VerilatedSaifC());
#endif
  topp->trace(tracer.get(), 0);
  create_next_trace_file(argv[2]);
#endif

  // Simulate until $finish
  while (!contextp->gotFinish()) {
    // Evaluate model
    topp->clk = !topp->clk;
    topp->eval();
#if TRACE_ENABLED
    if (contextp->time() >= next_trace_file_at_ps) {
      next_trace_file_at_ps = contextp->time() + sampling_period_ps;
      trace_until = contextp->time() + sample_length_ps;
      create_next_trace_file(argv[2]);
    }
    if (contextp->time() < trace_until) {
      tracer->dump(contextp->time());
    }
#endif
    // Advance time
    contextp->timeInc(clk_period_ps / 2);
  }

#if TRACE_ENABLED
  tracer = nullptr;
#endif

  // Execute 'final' processes
  topp->final();
  // Print statistical summary report
  contextp->statsPrintSummary();
  
  // Need to explicitly call destructors, otherwise get heap-use-after-free
  topp = nullptr;
  contextp = nullptr;

  return 0;
}
