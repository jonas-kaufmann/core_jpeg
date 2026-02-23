#pragma once

#include <simbricks/axi/axi_subordinate.hh>
#include <simbricks/axi/axil_manager.hh>

#define BYTES_DATA 64

// AXI DMA read signals
extern uint64_t s_axi_araddr;
extern uint8_t s_axi_arid;
extern uint8_t s_axi_arready;
extern uint8_t s_axi_arvalid;
extern uint8_t s_axi_arlen;
extern uint8_t s_axi_arsize;
extern uint8_t s_axi_arburst;
extern uint8_t s_axi_rdata[BYTES_DATA];
extern uint8_t s_axi_rid;
extern uint8_t s_axi_rready;
extern uint8_t s_axi_rvalid;
extern uint8_t s_axi_rlast;

// AXI DMA write signals
extern uint64_t s_axi_awaddr;
extern uint8_t s_axi_awid;
extern uint8_t s_axi_awready;
extern uint8_t s_axi_awvalid;
extern uint8_t s_axi_awlen;
extern uint8_t s_axi_awsize;
extern uint8_t s_axi_awburst;
extern uint8_t s_axi_wdata[BYTES_DATA];
extern uint8_t s_axi_wready;
extern uint8_t s_axi_wvalid;
extern uint8_t s_axi_wstrb[BYTES_DATA / 8];
extern uint8_t s_axi_wlast;
extern uint8_t s_axi_bid;
extern uint8_t s_axi_bready;
extern uint8_t s_axi_bvalid;
extern uint8_t s_axi_bresp;

// AXI Lite signals
extern uint32_t m_axil_araddr;
extern uint8_t m_axil_arready;
extern uint8_t m_axil_arvalid;
extern uint64_t m_axil_rdata;
extern uint8_t m_axil_rready;
extern uint8_t m_axil_rvalid;
extern uint8_t m_axil_rresp;
extern uint32_t m_axil_awaddr;
extern uint8_t m_axil_awready;
extern uint8_t m_axil_awvalid;
extern uint64_t m_axil_wdata;
extern uint8_t m_axil_wready;
extern uint8_t m_axil_wvalid;
extern uint8_t m_axil_wstrb;
extern uint8_t m_axil_bready;
extern uint8_t m_axil_bvalid;
extern uint8_t m_axil_bresp;

// handles DMA read requests
using AXISubordinateReadT =
    simbricks::AXISubordinateRead<8, 1, BYTES_DATA,
                                  /*num concurrently pending requests*/ 16>;
class HierVtaAXISubordinateRead : public AXISubordinateReadT {
public:
  explicit HierVtaAXISubordinateRead()
      : AXISubordinateReadT(reinterpret_cast<uint8_t *>(&s_axi_araddr),
                            &s_axi_arid, s_axi_arready, s_axi_arvalid,
                            s_axi_arlen, s_axi_arsize, s_axi_arburst,
                            s_axi_rdata, &s_axi_rid, s_axi_rready, s_axi_rvalid,
                            s_axi_rlast) {}

private:
  void do_read(const simbricks::AXIOperation &axi_op) final;
};

// handles DMA write requests
using AXISubordinateWriteT =
    simbricks::AXISubordinateWrite<8, 1, BYTES_DATA,
                                   /*num concurrently pending requests*/ 16>;
class JpegAXISubordinateWrite : public AXISubordinateWriteT {
public:
  explicit JpegAXISubordinateWrite()
      : AXISubordinateWriteT(
            reinterpret_cast<uint8_t *>(&s_axi_awaddr), &s_axi_awid,
            s_axi_awready, s_axi_awvalid, s_axi_awlen, s_axi_awsize,
            s_axi_awburst, s_axi_wdata, s_axi_wready, s_axi_wvalid, s_axi_wstrb,
            s_axi_wlast, &s_axi_bid, s_axi_bready, s_axi_bvalid, s_axi_bresp) {}

private:
  void do_write(const simbricks::AXIOperation &axi_op) final;
};

// handles host to device register reads / writes
using AXILManagerT = simbricks::AXILManager<4, 8>;
class JpegAXILManager : public AXILManagerT {
public:
  explicit JpegAXILManager()
      : AXILManagerT(
            reinterpret_cast<uint8_t *>(&m_axil_araddr), m_axil_arready,
            m_axil_arvalid, reinterpret_cast<uint8_t *>(&m_axil_rdata),
            m_axil_rready, m_axil_rvalid, m_axil_rresp,
            reinterpret_cast<uint8_t *>(&m_axil_awaddr), m_axil_awready,
            m_axil_awvalid, reinterpret_cast<uint8_t *>(&m_axil_wdata),
            m_axil_wready, m_axil_wvalid, m_axil_wstrb, m_axil_bready,
            m_axil_bvalid, m_axil_bresp) {}

private:
  void read_done(simbricks::AXILOperationR &axi_op) final;
  void write_done(simbricks::AXILOperationW &axi_op) final;
};
