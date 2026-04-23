#include <chrono>
#include <cstdint>
#include <cstring>
#include <exception>
#include <stdexcept>
// #define AXI_R_DEBUG
// #define AXI_W_DEBUG
// #define AXIL_R_DEBUG
// #define AXIL_W_DEBUG

#define NUM_ADAPTERS 2

#include <signal.h>

#include <simbricks/base/cxxatomicfix.h>

#include "verilator_adapter.hh"
extern "C" {
#include <simbricks/pcie/if.h>
}

// AXI DMA read signals
uint64_t s_axi_araddr;
uint8_t s_axi_arid;
uint8_t s_axi_arready;
uint8_t s_axi_arvalid;
uint8_t s_axi_arlen;
uint8_t s_axi_arsize;
uint8_t s_axi_arburst;
uint8_t s_axi_rdata[BYTES_DATA];
uint8_t s_axi_rid;
uint8_t s_axi_rready;
uint8_t s_axi_rvalid;
uint8_t s_axi_rlast;

// AXI DMA write signals
uint64_t s_axi_awaddr;
uint8_t s_axi_awid;
uint8_t s_axi_awready;
uint8_t s_axi_awvalid;
uint8_t s_axi_awlen;
uint8_t s_axi_awsize;
uint8_t s_axi_awburst;
uint8_t s_axi_wdata[BYTES_DATA];
uint8_t s_axi_wready;
uint8_t s_axi_wvalid;
uint8_t s_axi_wstrb[BYTES_DATA / 8];
uint8_t s_axi_wlast;
uint8_t s_axi_bid;
uint8_t s_axi_bready;
uint8_t s_axi_bvalid;
uint8_t s_axi_bresp;

// AXI Lite signals
uint32_t m_axil_araddr;
uint8_t m_axil_arready;
uint8_t m_axil_arvalid;
uint64_t m_axil_rdata;
uint8_t m_axil_rready;
uint8_t m_axil_rvalid;
uint8_t m_axil_rresp;
uint32_t m_axil_awaddr;
uint8_t m_axil_awready;
uint8_t m_axil_awvalid;
uint64_t m_axil_wdata;
uint8_t m_axil_wready;
uint8_t m_axil_wvalid;
uint8_t m_axil_wstrb;
uint8_t m_axil_bready;
uint8_t m_axil_bvalid;
uint8_t m_axil_bresp;

HierVtaAXISubordinateRead dma_read{};
JpegAXISubordinateWrite dma_write{};
JpegAXILManager reg_read_write{};
uint64_t clock_period = 1'000'000 / 150ULL;  // 150 MHz
uint64_t simbricks_time = 0;
uint64_t hardware_time = 0;
volatile bool exiting = 0;
struct SimbricksPcieIf pcieif;
bool synchronized = false;
uint8_t num_adapters_ticked = 0;
bool pseudo_synchronized = true;
uint64_t sim_start_ts;
std::chrono::time_point<std::chrono::steady_clock> sim_start_real;

volatile union SimbricksProtoPcieD2H *d2h_alloc(uint64_t cur_ts) {
  volatile union SimbricksProtoPcieD2H *msg;
  while (!(msg = SimbricksPcieIfD2HOutAlloc(&pcieif, cur_ts))) {
  }
  return msg;
}

void HierVtaAXISubordinateRead::do_read(const simbricks::AXIOperation &axi_op) {
#if JPGD_DEBUG
  std::cout << "JpegDecoderMemReader::doRead() ts=" << simbricks_time
            << " id=" << axi_op.id << " addr=" << axi_op.addr
            << " len=" << axi_op.len << "\n";
#endif

  volatile union SimbricksProtoPcieD2H *msg = d2h_alloc(simbricks_time);
  if (!msg) {
    throw std::runtime_error(
        "HierVtaAXISubordinateRead::doRead() dma read alloc failed");
  }

  unsigned int max_size = SimbricksPcieIfH2DOutMsgLen(&pcieif) -
                          sizeof(SimbricksProtoPcieH2DReadcomp);
  if (axi_op.len > max_size) {
    std::cerr << "error: read data of length " << axi_op.len
              << " doesn't fit into a SimBricks message\n";
    std::terminate();
  }

  volatile struct SimbricksProtoPcieD2HRead *read = &msg->read;
  read->req_id = axi_op.id;
  read->offset = axi_op.addr;
  read->len = axi_op.len;
  SimbricksPcieIfD2HOutSend(&pcieif, msg, SIMBRICKS_PROTO_PCIE_D2H_MSG_READ);
}

void JpegAXISubordinateWrite::do_write(const simbricks::AXIOperation &axi_op) {
#if JPGD_DEBUG
  std::cout << "JpegDecoderMemWriter::doWrite() ts=" << simbricks_time
            << " id=" << axi_op.id << " addr=" << axi_op.addr
            << " len=" << axi_op.len << "\n";
#endif

  volatile union SimbricksProtoPcieD2H *msg = d2h_alloc(simbricks_time);
  if (!msg) {
    throw std::runtime_error(
        "JpegDecoderMemWriter::doWrite() dma read alloc failed");
  }

  volatile struct SimbricksProtoPcieD2HWrite *write = &msg->write;
  unsigned int max_size = SimbricksPcieIfH2DOutMsgLen(&pcieif) - sizeof(*write);
  if (axi_op.len > max_size) {
    std::cerr << "error: write data of length " << axi_op.len
              << " doesn't fit into a SimBricks message\n";
    std::terminate();
  }

  write->req_id = axi_op.id;
  write->offset = axi_op.addr;
  write->len = axi_op.len;
  std::memcpy(const_cast<uint8_t *>(write->data), axi_op.buf.get(), axi_op.len);
  SimbricksPcieIfD2HOutSend(&pcieif, msg, SIMBRICKS_PROTO_PCIE_D2H_MSG_WRITE);
}

void JpegAXILManager::read_done(simbricks::AXILOperationR &axi_op) {
#if JPGD_DEBUG
  std::cout << "HierVtaAXILManager::read_done() ts=" << simbricks_time
            << " id=" << axi_op.req_id << " addr=" << axi_op.addr << "\n";
#endif

  volatile union SimbricksProtoPcieD2H *msg = d2h_alloc(simbricks_time);
  if (!msg) {
    throw std::runtime_error(
        "HierVtaAXILManager::read_done() completion alloc failed");
  }

  volatile struct SimbricksProtoPcieD2HReadcomp *readcomp = &msg->readcomp;
  std::memcpy(const_cast<uint8_t *>(readcomp->data), &axi_op.data,
              sizeof(axi_op.data));
  readcomp->req_id = axi_op.req_id;
  SimbricksPcieIfD2HOutSend(&pcieif, msg,
                            SIMBRICKS_PROTO_PCIE_D2H_MSG_READCOMP);
}

void JpegAXILManager::write_done(simbricks::AXILOperationW &axi_op) {
#if JPGD_DEBUG
  std::cout << "HierVtaAXILManager::write_done ts=" << simbricks_time
            << " id=" << axi_op.req_id << " addr=" << axi_op.addr << "\n";
#endif

  if (axi_op.posted) {
    return;
  }

  volatile union SimbricksProtoPcieD2H *msg = d2h_alloc(simbricks_time);
  if (!msg) {
    throw std::runtime_error(
        "HierVtaAXILManager::write_done completion alloc failed");
  }

  volatile struct SimbricksProtoPcieD2HWritecomp *writecomp = &msg->writecomp;
  writecomp->req_id = axi_op.req_id;
  SimbricksPcieIfD2HOutSend(&pcieif, msg,
                            SIMBRICKS_PROTO_PCIE_D2H_MSG_WRITECOMP);
}

bool PciIfInit(const char *shm_path,
               struct SimbricksBaseIfParams &baseif_params) {
  struct SimbricksBaseIfSHMPool pool;
  struct SimBricksBaseIfEstablishData ests;
  struct SimbricksProtoPcieDevIntro d_intro;
  struct SimbricksProtoPcieHostIntro h_intro;

  std::memset(&pool, 0, sizeof(pool));
  std::memset(&ests, 0, sizeof(ests));
  std::memset(&d_intro, 0, sizeof(d_intro));

  d_intro.pci_vendor_id = 0xdead;
  d_intro.pci_device_id = 0xbeef;
  d_intro.pci_class = 0x40;
  d_intro.pci_subclass = 0x00;
  d_intro.pci_revision = 0x00;

  // First BAR passes through to RTL
  d_intro.bars[0].len = 4096;
  d_intro.bars[0].flags = 0;

  // Second BAR for simulation control
  d_intro.bars[1].len = 4096;
  d_intro.bars[1].flags = 0;

  ests.base_if = &pcieif.base;
  ests.tx_intro = &d_intro;
  ests.tx_intro_len = sizeof(d_intro);
  ests.rx_intro = &h_intro;
  ests.rx_intro_len = sizeof(h_intro);

  if (SimbricksBaseIfInit(&pcieif.base, &baseif_params)) {
    std::cerr << "PciIfInit: SimbricksBaseIfInit failed\n";
    return false;
  }

  if (SimbricksBaseIfSHMPoolCreate(
          &pool, shm_path, SimbricksBaseIfSHMSize(&pcieif.base.params)) != 0) {
    std::cerr << "PciIfInit: SimbricksBaseIfSHMPoolCreate failed\n";
    return false;
  }

  if (SimbricksBaseIfListen(&pcieif.base, &pool) != 0) {
    std::cerr << "PciIfInit: SimbricksBaseIfListen failed\n";
    return false;
  }

  if (SimBricksBaseIfEstablish(&ests, 1)) {
    std::cerr << "PciIfInit: SimBricksBaseIfEstablish failed\n";
    return false;
  }

  return true;
}

bool h2d_read(volatile struct SimbricksProtoPcieH2DRead &read) {
#if JPGD_DEBUG
  std::cout << "h2d_read ts=" << simbricks_time
            << " bar=" << static_cast<int>(read.bar)
            << " offset=" << read.offset << " len=" << read.len << "\n";
#endif

  switch (read.bar) {
    case 0: {
      if (synchronized && pseudo_synchronized) {
        throw std::runtime_error(
            "h2d_read() cannot handle incoming read request while doing "
            "pseudo-synchronization");
      }
      reg_read_write.issue_read(read.req_id, read.offset);
      break;
    }
    default: {
      std::cerr << "error: read from unexpected bar " << read.bar << "\n";
      return false;
    }
  }
  return true;
}

bool h2d_write(volatile struct SimbricksProtoPcieH2DWrite &write, bool posted) {
#if JPGD_DEBUG
  std::cout << "h2d_write ts=" << simbricks_time
            << " bar=" << static_cast<int>(write.bar)
            << " offset=" << write.offset << " len=" << write.len << "\n";
#endif

  switch (write.bar) {
    case 0: {
      uint64_t data;
      if (synchronized && pseudo_synchronized) {
        throw std::runtime_error(
            "h2d_write() cannot handle incoming request while doing "
            "pseudo-synchronization");
      }
      std::memcpy(&data, const_cast<uint8_t *>(write.data), write.len);
      reg_read_write.issue_write(write.req_id, write.offset, data, posted);
      break;
    }
    case 1: {
      if (write.offset != 0 || write.len != 4) {
        throw std::runtime_error(
            "h2d_write() write to simulation control BAR only supports offset "
            "0 and length 4");
      }
      uint32_t data;
      std::memcpy(&data, const_cast<uint8_t *>(write.data), sizeof(data));
      if (pseudo_synchronized && data == 1) {
        std::cout << "Disabling pseudo-synchronization at simbricks_time="
                  << simbricks_time << " hardware_time=" << hardware_time
                  << std::endl;
        pseudo_synchronized = false;
        sim_start_ts = hardware_time;
        sim_start_real = std::chrono::steady_clock::now();
      } else if (!pseudo_synchronized && data == 0) {
        auto sim_ps = hardware_time - sim_start_ts;
        auto sim_real_seconds =
            std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - sim_start_real)
                .count();
        std::cout << "Enabling pseudo-synchronization at simbricks_time="
                  << simbricks_time << " hardware_time=" << hardware_time
                  << " sim_ps=" << sim_ps
                  << " sim_real_seconds=" << sim_real_seconds << std::endl;
        pseudo_synchronized = true;
      }
      break;
    }
    default: {
      std::cerr << "error: write to unexpected bar " << write.bar << "\n";
      return false;
    }
  }

  if (!posted) {
    volatile union SimbricksProtoPcieD2H *msg = d2h_alloc(simbricks_time);
    volatile struct SimbricksProtoPcieD2HWritecomp &writecomp = msg->writecomp;
    writecomp.req_id = write.req_id;

    SimbricksPcieIfD2HOutSend(&pcieif, msg,
                              SIMBRICKS_PROTO_PCIE_D2H_MSG_WRITECOMP);
  }
  return true;
}

bool h2d_readcomp(volatile struct SimbricksProtoPcieH2DReadcomp &readcomp) {
  if (synchronized && pseudo_synchronized) {
    throw std::runtime_error(
        "h2d_readcomp() cannot handle incoming response while doing "
        "pseudo-synchronization");
  }
  dma_read.read_done(readcomp.req_id, const_cast<uint8_t *>(readcomp.data));
  return true;
}

bool h2d_writecomp(volatile struct SimbricksProtoPcieH2DWritecomp &writecomp) {
  if (synchronized && pseudo_synchronized) {
    throw std::runtime_error(
        "h2d_writecomp() cannot handle incoming response while doing "
        "pseudo-synchronization");
  }
  dma_write.write_done(writecomp.req_id);
  return true;
}

bool poll_h2d() {
  volatile union SimbricksProtoPcieH2D *msg =
      SimbricksPcieIfH2DInPoll(&pcieif, simbricks_time);

  // no msg available
  if (msg == nullptr)
    return true;

  uint8_t type = SimbricksPcieIfH2DInType(&pcieif, msg);

  switch (type) {
    case SIMBRICKS_PROTO_PCIE_H2D_MSG_READ:
      if (!h2d_read(msg->read)) {
        return false;
      }
      break;
    case SIMBRICKS_PROTO_PCIE_H2D_MSG_WRITE:
      if (!h2d_write(msg->write, false)) {
        return false;
      }
      break;
    case SIMBRICKS_PROTO_PCIE_H2D_MSG_WRITE_POSTED:
      if (!h2d_write(msg->write, true)) {
        return false;
      }
      break;
    case SIMBRICKS_PROTO_PCIE_H2D_MSG_READCOMP:
      if (!h2d_readcomp(msg->readcomp)) {
        return false;
      }
      break;
    case SIMBRICKS_PROTO_PCIE_H2D_MSG_WRITECOMP:
      if (!h2d_writecomp(msg->writecomp)) {
        return false;
      }
      break;
    case SIMBRICKS_PROTO_PCIE_H2D_MSG_DEVCTRL:
    case SIMBRICKS_PROTO_MSG_TYPE_SYNC:
      break; /* noop */
    case SIMBRICKS_PROTO_MSG_TYPE_TERMINATE:
      std::cerr << "poll_h2d: peer terminated\n";
      exiting = true;
      break;
    default:
      std::cerr << "warn: poll_h2d: unsupported type=" << type << "\n";
  }

  SimbricksPcieIfH2DInDone(&pcieif, msg);
  return true;
}

extern "C" void sigint_handler(int dummy) {
  exiting = 1;
}

extern "C" void sigusr1_handler(int dummy) {
  std::cerr << "simbricks_time=" << simbricks_time
            << " hardware_time=" << hardware_time << std::endl;
}

extern "C" void simbricks_init(const char *pci_socket, const char *shm_path,
                               uint64_t sync_period, uint64_t pci_latency,
                               uint64_t clk_freq_mhz) {
  std::cout << "simbricks_init(): pci_socket=" << pci_socket
            << " shm_path=" << shm_path << " sync_period=" << sync_period
            << " pci_latency=" << pci_latency
            << " clk_freq_mhz=" << clk_freq_mhz << std::endl;
  struct SimbricksBaseIfParams if_params;
  std::memset(&if_params, 0, sizeof(if_params));
  SimbricksPcieIfDefaultParams(&if_params);

  if_params.sync_interval = sync_period * 1000ULL;
  if_params.link_latency = pci_latency * 1000ULL;
  clock_period = 1000000ULL / clk_freq_mhz;

  if_params.sock_path = pci_socket;
  if (!PciIfInit(shm_path, if_params)) {
    throw std::runtime_error("PciIfInit failed");
  }

  synchronized = SimbricksBaseIfSyncEnabled(&pcieif.base);
  signal(SIGINT, sigint_handler);
  signal(SIGUSR1, sigusr1_handler);
}

void simbricks_sync_poll() {
  if (num_adapters_ticked > 0) {
    return;
  }

  // Pseudo-synchronization: Loop here, always fast-forwarding own timestamp to
  // timestamp of next message.
  //
  // This feature is meant to speed up simulation while the software doesn't
  // touch the accelerator.
  do {
    if (synchronized && pseudo_synchronized) {
      simbricks_time = SimbricksPcieIfH2DInTimestamp(&pcieif);
    }

    // send required sync messages
    while (SimbricksPcieIfD2HOutSync(&pcieif, simbricks_time) < 0) {
      std::cerr << "warn: SimbricksPcieIfD2HOutSync failed simbricks_time="
                << simbricks_time << "\n";
    }

    // process available incoming messages for current timestamp
    do {
      poll_h2d();
    } while (!exiting && ((synchronized && SimbricksPcieIfH2DInTimestamp(
                                               &pcieif) <= simbricks_time)));
  } while (!exiting && synchronized && pseudo_synchronized);
}

void simbricks_tick() {
  num_adapters_ticked++;
  if (num_adapters_ticked == NUM_ADAPTERS) {
    num_adapters_ticked = 0;
    simbricks_time += clock_period;
    hardware_time += clock_period;
  }
}

extern "C" unsigned char simbricks_is_exit() {
  return exiting ? 1 : 0;
}

extern "C" void s_axi_adapter_step(
    const uint8_t dpi_awid, const uint64_t dpi_awaddr, const uint8_t dpi_awlen,
    const uint8_t dpi_awsize, const uint8_t dpi_awburst,
    const uint8_t dpi_awvalid, uint8_t *const dpi_awready,
    const uint8_t *dpi_wdata, const uint8_t *dpi_wstrb, const uint8_t dpi_wlast,
    const uint8_t dpi_wvalid, uint8_t *const dpi_wready, uint8_t *const dpi_bid,
    uint8_t *const dpi_bresp, uint8_t *const dpi_bvalid,
    const uint8_t dpi_bready, const uint8_t dpi_arid, const uint64_t dpi_araddr,
    const uint8_t dpi_arlen, const uint8_t dpi_arsize,
    const uint8_t dpi_arburst, const uint8_t dpi_arvalid,
    uint8_t *const dpi_arready, uint8_t *const dpi_rid,
    uint8_t *const dpi_rdata, uint8_t *const dpi_rresp,
    uint8_t *const dpi_rlast, uint8_t *const dpi_rvalid,
    const uint8_t dpi_rready) {
  simbricks_sync_poll();

  // copy over input signals
  s_axi_awid = dpi_awid;
  s_axi_awaddr = dpi_awaddr;
  s_axi_awlen = dpi_awlen;
  s_axi_awsize = dpi_awsize;
  s_axi_awburst = dpi_awburst;
  s_axi_awvalid = dpi_awvalid;
  std::memcpy(s_axi_wdata, dpi_wdata, sizeof(s_axi_wdata));
  std::memcpy(s_axi_wstrb, dpi_wstrb, sizeof(s_axi_wstrb));
  s_axi_wlast = dpi_wlast;
  s_axi_wvalid = dpi_wvalid;
  s_axi_bready = dpi_bready;
  s_axi_arid = dpi_arid;
  s_axi_araddr = dpi_araddr;
  s_axi_arlen = dpi_arlen;
  s_axi_arsize = dpi_arsize;
  s_axi_arburst = dpi_arburst;
  s_axi_arvalid = dpi_arvalid;
  s_axi_rready = dpi_rready;

  dma_read.step(simbricks_time);
  dma_write.step(simbricks_time);
  dma_read.step_apply();
  dma_write.step_apply();

  // write output signals
  *dpi_awready = s_axi_awready;
  *dpi_wready = s_axi_wready;
  *dpi_bid = s_axi_bid;
  *dpi_bresp = s_axi_bresp;
  *dpi_bvalid = s_axi_bvalid;
  *dpi_arready = s_axi_arready;
  *dpi_rid = s_axi_rid;
  *dpi_rresp = 0;
  *dpi_rlast = s_axi_rlast;
  *dpi_rvalid = s_axi_rvalid;
  std::memcpy(dpi_rdata, s_axi_rdata, BYTES_DATA);

  simbricks_tick();
}

extern "C" void m_axil_adapter_step(
    uint32_t *const dpi_awaddr, uint8_t *const dpi_awprot,
    uint8_t *const dpi_awvalid, const uint8_t dpi_awready,
    uint64_t *const dpi_wdata, uint8_t *const dpi_wstrb,
    uint8_t *const dpi_wvalid, const uint8_t dpi_wready,
    const uint8_t dpi_bresp, const uint8_t dpi_bvalid,
    uint8_t *const dpi_bready, uint32_t *const dpi_araddr,
    uint8_t *const dpi_arprot, uint8_t *const dpi_arvalid,
    const uint8_t dpi_arready, const uint64_t dpi_rdata,
    const uint8_t dpi_rresp, const uint8_t dpi_rvalid,
    uint8_t *const dpi_rready) {
  simbricks_sync_poll();

  // copy over input signals
  m_axil_awready = dpi_awready;
  m_axil_wready = dpi_wready;
  m_axil_bresp = dpi_bresp;
  m_axil_bvalid = dpi_bvalid;
  m_axil_arready = dpi_arready;
  m_axil_rdata = dpi_rdata;
  m_axil_rresp = dpi_rresp;
  m_axil_rvalid = dpi_rvalid;

  reg_read_write.step(simbricks_time);
  reg_read_write.step_apply();

  // write output signals
  *dpi_awaddr = m_axil_awaddr;
  *dpi_awprot = 0;
  *dpi_awvalid = m_axil_awvalid;
  *dpi_wdata = m_axil_wdata;
  *dpi_wstrb = m_axil_wstrb;
  *dpi_wvalid = m_axil_wvalid;
  *dpi_bready = m_axil_bready;
  *dpi_araddr = m_axil_araddr;
  *dpi_arprot = 0;
  *dpi_arvalid = m_axil_arvalid;
  *dpi_rready = m_axil_rready;

  simbricks_tick();
}
