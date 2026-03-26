`include "jpeg_params.vh"

module jpeg_shell #(
    parameter int JPEG_SUPPORT_WRITABLE_DHT = 1,
    parameter int JPEG_NUM_DECODERS = 1,
    parameter int DESC_FIFO_DEPTH_LOG2 = 3,

    /*
     * The in- and output pins are just copied over from the definition of
     * module `jpeg_top` along with the parameters they use. The following
     * parameter definitions just allow us to reuse the copied over parameters.
     */
    parameter int AXI_DMA_ID_WIDTH   = `JPEG_DMA_BITS_ID,
    parameter int AXI_DMA_ADDR_WIDTH = `JPEG_DMA_BITS_ADDR,
    parameter int AXI_DMA_DATA_WIDTH = `JPEG_DMA_BITS_DATA,
    parameter int AXI_DMA_STRB_WIDTH = `JPEG_DMA_BITS_DATA / 8,

    parameter int AXIL_MMIO_ADDR_WIDTH = `JPEG_MMIO_BITS_ADDR
) (
    input wire clk,
    input wire rst,

    /*
     * AXI lite MMIO interface
     */
    input  wire [AXIL_MMIO_ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire [                     2:0] s_axil_awprot,
    input  wire                            s_axil_awvalid,
    output wire                            s_axil_awready,
    input  wire [                    63:0] s_axil_wdata,
    input  wire [                     7:0] s_axil_wstrb,
    input  wire                            s_axil_wvalid,
    output wire                            s_axil_wready,
    output wire [                     1:0] s_axil_bresp,
    output wire                            s_axil_bvalid,
    input  wire                            s_axil_bready,
    input  wire [AXIL_MMIO_ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire [                     2:0] s_axil_arprot,
    input  wire                            s_axil_arvalid,
    output wire                            s_axil_arready,
    output wire [                    63:0] s_axil_rdata,
    output wire [                     1:0] s_axil_rresp,
    output wire                            s_axil_rvalid,
    input  wire                            s_axil_rready,

    /*
     * AXI read DMA interface
     */
    output wire [  AXI_DMA_ID_WIDTH-1:0] m_axi_awid,
    output wire [AXI_DMA_ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [                   7:0] m_axi_awlen,
    output wire [                   2:0] m_axi_awsize,
    output wire [                   1:0] m_axi_awburst,
    output wire                          m_axi_awlock,
    output wire [                   3:0] m_axi_awcache,
    output wire [                   2:0] m_axi_awprot,
    output wire                          m_axi_awvalid,
    input  wire                          m_axi_awready,
    output wire [AXI_DMA_DATA_WIDTH-1:0] m_axi_wdata,
    output wire [AXI_DMA_STRB_WIDTH-1:0] m_axi_wstrb,
    output wire                          m_axi_wlast,
    output wire                          m_axi_wvalid,
    input  wire                          m_axi_wready,
    input  wire [  AXI_DMA_ID_WIDTH-1:0] m_axi_bid,
    input  wire [                   1:0] m_axi_bresp,
    input  wire                          m_axi_bvalid,
    output wire                          m_axi_bready,

    /*
     * AXI write DMA interface
     */
    output wire [  AXI_DMA_ID_WIDTH-1:0] m_axi_arid,
    output wire [AXI_DMA_ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [                   7:0] m_axi_arlen,
    output wire [                   2:0] m_axi_arsize,
    output wire [                   1:0] m_axi_arburst,
    output wire                          m_axi_arlock,
    output wire [                   3:0] m_axi_arcache,
    output wire [                   2:0] m_axi_arprot,
    output wire                          m_axi_arvalid,
    input  wire                          m_axi_arready,
    input  wire [  AXI_DMA_ID_WIDTH-1:0] m_axi_rid,
    input  wire [AXI_DMA_DATA_WIDTH-1:0] m_axi_rdata,
    input  wire [                   1:0] m_axi_rresp,
    input  wire                          m_axi_rlast,
    input  wire                          m_axi_rvalid,
    output wire                          m_axi_rready
);

  jpeg_top #(
      .JPEG_SUPPORT_WRITABLE_DHT(JPEG_SUPPORT_WRITABLE_DHT),
      .JPEG_NUM_DECODERS(JPEG_NUM_DECODERS),
      .DESC_FIFO_DEPTH_LOG2(DESC_FIFO_DEPTH_LOG2),
      .AXI_DMA_ID_WIDTH(AXI_DMA_ID_WIDTH),
      .AXI_DMA_ADDR_WIDTH(AXI_DMA_ADDR_WIDTH),
      .AXI_DMA_DATA_WIDTH(AXI_DMA_DATA_WIDTH),
      .AXI_DMA_STRB_WIDTH(AXI_DMA_STRB_WIDTH),
      .AXIL_MMIO_ADDR_WIDTH(AXIL_MMIO_ADDR_WIDTH)
  ) jpeg_top_inst (
      .*
  );

endmodule
