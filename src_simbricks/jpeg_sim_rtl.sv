`timescale 1ps / 1ps
`include "jpeg_params.vh"


module jpeg_sim (
    input clk,
    input rst
);
  string  pci_socket_str;
  string  shm_path_str;
  longint sync_period;
  longint pci_latency;
  longint clk_freq_mhz;
  longint clk_period_ps;

  import "DPI-C" function void simbricks_init(
    input string  pci_socket,
    input string  shm_path,
    input longint sync_period,
    input longint pci_latency,
    input longint clk_freq_mhz
  );

  import "DPI-C" function bit simbricks_is_exit();

  // M AXI Lite for Control
  wire [`JPEG_MMIO_BITS_ADDR-1:0] s_axil_awaddr;
  wire [2:0] s_axil_awprot;
  wire s_axil_awvalid;
  wire s_axil_awready;
  wire [63:0] s_axil_wdata;
  wire [7:0] s_axil_wstrb;
  wire s_axil_wvalid;
  wire s_axil_wready;
  wire [1:0] s_axil_bresp;
  wire s_axil_bvalid;
  wire s_axil_bready;
  wire [`JPEG_MMIO_BITS_ADDR-1:0] s_axil_araddr;
  wire [2:0] s_axil_arprot;
  wire s_axil_arvalid;
  wire s_axil_arready;
  wire [63:0] s_axil_rdata;
  wire [1:0] s_axil_rresp;
  wire s_axil_rvalid;
  wire s_axil_rready;

  m_axil_adapter m_axil_ctrl (
      .clk(clk),
      .m_axil_awaddr(s_axil_awaddr),
      .m_axil_awprot(s_axil_awprot),
      .m_axil_awvalid(s_axil_awvalid),
      .m_axil_awready(s_axil_awready),
      .m_axil_wdata(s_axil_wdata),
      .m_axil_wstrb(s_axil_wstrb),
      .m_axil_wvalid(s_axil_wvalid),
      .m_axil_wready(s_axil_wready),
      .m_axil_bresp(s_axil_bresp),
      .m_axil_bvalid(s_axil_bvalid),
      .m_axil_bready(s_axil_bready),
      .m_axil_araddr(s_axil_araddr),
      .m_axil_arprot(s_axil_arprot),
      .m_axil_arvalid(s_axil_arvalid),
      .m_axil_arready(s_axil_arready),
      .m_axil_rdata(s_axil_rdata),
      .m_axil_rresp(s_axil_rresp),
      .m_axil_rvalid(s_axil_rvalid),
      .m_axil_rready(s_axil_rready)
  );

  // S AXI for DMAs
  wire [`JPEG_DMA_BITS_ID-1:0] m_axi_awid;
  wire [`JPEG_DMA_BITS_ADDR-1:0] m_axi_awaddr;
  wire [`JPEG_DMA_BITS_LEN-1:0] m_axi_awlen;
  wire [2:0] m_axi_awsize;
  wire [1:0] m_axi_awburst;
  wire m_axi_awvalid;
  wire m_axi_awready;
  wire [`JPEG_DMA_BITS_DATA-1:0] m_axi_wdata;
  wire [`JPEG_DMA_BYTES_DATA-1:0] m_axi_wstrb;
  wire m_axi_wlast;
  wire m_axi_wvalid;
  wire m_axi_wready;
  wire [`JPEG_DMA_BITS_ID-1:0] m_axi_bid;
  wire [1:0] m_axi_bresp;
  wire m_axi_bvalid;
  wire m_axi_bready;
  wire [7:0] m_axi_arid;
  wire [`JPEG_DMA_BITS_ADDR-1:0] m_axi_araddr;
  wire [`JPEG_DMA_BITS_LEN-1:0] m_axi_arlen;
  wire [2:0] m_axi_arsize;
  wire [1:0] m_axi_arburst;
  wire m_axi_arvalid;
  wire m_axi_arready;
  wire [`JPEG_DMA_BITS_ID-1:0] m_axi_rid;
  wire [`JPEG_DMA_BITS_DATA-1:0] m_axi_rdata;
  wire [1:0] m_axi_rresp;
  wire m_axi_rlast;
  wire m_axi_rvalid;
  wire m_axi_rready;
  // unused

  s_axi_adapter s_axi_dma (
      .clk(clk),
      .s_axi_awid(m_axi_awid),
      .s_axi_awaddr(m_axi_awaddr),
      .s_axi_awlen(m_axi_awlen),
      .s_axi_awsize(m_axi_awsize),
      .s_axi_awburst(m_axi_awburst),
      .s_axi_awvalid(m_axi_awvalid),
      .s_axi_awready(m_axi_awready),
      .s_axi_wdata(m_axi_wdata),
      .s_axi_wstrb(m_axi_wstrb),
      .s_axi_wlast(m_axi_wlast),
      .s_axi_wvalid(m_axi_wvalid),
      .s_axi_wready(m_axi_wready),
      .s_axi_bid(m_axi_bid),
      .s_axi_bresp(m_axi_bresp),
      .s_axi_bvalid(m_axi_bvalid),
      .s_axi_bready(m_axi_bready),
      .s_axi_arid(m_axi_arid),
      .s_axi_araddr(m_axi_araddr),
      .s_axi_arlen(m_axi_arlen),
      .s_axi_arsize(m_axi_arsize),
      .s_axi_arburst(m_axi_arburst),
      .s_axi_arvalid(m_axi_arvalid),
      .s_axi_arready(m_axi_arready),
      .s_axi_rid(m_axi_rid),
      .s_axi_rdata(m_axi_rdata),
      .s_axi_rresp(m_axi_rresp),
      .s_axi_rlast(m_axi_rlast),
      .s_axi_rvalid(m_axi_rvalid),
      .s_axi_rready(m_axi_rready)
  );

  // instantiate main module
  jpeg_top_bd jpeg_top_bd_inst (
      .*,
      // unused
      .m_axi_awlock(),
      .m_axi_awcache(),
      .m_axi_awprot(),
      .m_axi_arlock(),
      .m_axi_arcache(),
      .m_axi_arprot()
  );

  initial begin
    if (!$value$plusargs("PCI_SOCKET=%s", pci_socket_str)) begin
      $fatal(1, "Missing required +PCI_SOCKET=<value> argument");
    end
    if (!$value$plusargs("SHM_PATH=%s", shm_path_str)) begin
      $fatal(1, "Missing required +SHM_PATH=<value> argument");
    end
    if (!$value$plusargs("SYNC_PERIOD=%d", sync_period)) begin
      $fatal(1, "Missing required +SYNC_PERIOD=<value> argument");
    end
    if (!$value$plusargs("PCI_LATENCY=%d", pci_latency)) begin
      $fatal(1, "Missing required +PCI_LATENCY=<value> argument");
    end
    if (!$value$plusargs("CLK_FREQ_MHZ=%d", clk_freq_mhz)) begin
      $fatal(1, "Missing required +CLK_FREQ_MHZ=<value> argument");
    end

    clk_period_ps = 1000000 / clk_freq_mhz;

    simbricks_init(pci_socket_str, shm_path_str, sync_period, pci_latency, clk_freq_mhz);
  end

  always @(posedge clk) begin
    if (simbricks_is_exit()) begin
      $display("Got exit signal from SimBricks adapter.");
      $finish();
    end
  end

endmodule
