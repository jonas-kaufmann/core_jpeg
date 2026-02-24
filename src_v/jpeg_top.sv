`timescale 1ns / 1ps
`default_nettype none

module jpeg_top #(
    parameter unsigned JPEG_SUPPORT_WRITABLE_DHT = 0,
    parameter unsigned JPEG_NUM_DECODERS = 1,
    parameter unsigned DESC_FIFO_DEPTH_LOG2 = 4,

    parameter unsigned AXI_DMA_ID_WIDTH   = 8,
    parameter unsigned AXI_DMA_ADDR_WIDTH = 64,
    parameter unsigned AXI_DMA_DATA_WIDTH = 512,
    parameter unsigned AXI_DMA_STRB_WIDTH = AXI_DMA_DATA_WIDTH / 8,

    parameter unsigned AXIL_MMIO_ADDR_WIDTH = 32
) (
    input wire clk,
    input wire rst,

    /*
     * AXI lite MMIO interface
     */
    input  wire  [AXIL_MMIO_ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire  [                     2:0] s_axil_awprot,
    input  wire                             s_axil_awvalid,
    output logic                            s_axil_awready,
    input  wire  [                    63:0] s_axil_wdata,
    input  wire  [                     7:0] s_axil_wstrb,
    input  wire                             s_axil_wvalid,
    output logic                            s_axil_wready,
    output reg   [                     1:0] s_axil_bresp,
    output reg                              s_axil_bvalid,
    input  wire                             s_axil_bready,
    input  wire  [AXIL_MMIO_ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire  [                     2:0] s_axil_arprot,
    input  wire                             s_axil_arvalid,
    output reg                              s_axil_arready,
    output reg   [                    63:0] s_axil_rdata,
    output reg   [                     1:0] s_axil_rresp,
    output reg                              s_axil_rvalid,
    input  wire                             s_axil_rready,

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

  localparam int AXIS_DATA_WIDTH = AXI_DMA_DATA_WIDTH;
  localparam int AXIS_KEEP_WIDTH = AXI_DMA_STRB_WIDTH;
  localparam logic [DESC_FIFO_DEPTH_LOG2:0] DESC_FIFO_DEPTH = (1 << DESC_FIFO_DEPTH_LOG2);

  // --------------------------------------------------------------------------
  // MMIO register map (byte offsets)
  // --------------------------------------------------------------------------
  localparam logic [7:0] REG_DESC_SRC_ADDR = 8'h00;
  localparam logic [7:0] REG_DESC_SRC_LEN = 8'h08;
  localparam logic [7:0] REG_DESC_DST_ADDR = 8'h10;
  localparam logic [7:0] REG_DESC_ID = 8'h18;
  localparam logic [7:0] REG_DESC_COMMIT = 8'h20;
  localparam logic [7:0] REG_DESC_FREE = 8'h28;
  localparam logic [7:0] REG_CPL_STATUS = 8'h30;

  assign s_axil_bresp = 2'b0;
  assign s_axil_rresp = 2'b0;

  logic [63:0] mmio_desc_src_addr_reg;
  logic [63:0] mmio_desc_src_len_reg;
  logic [63:0] mmio_desc_dst_addr_reg;
  logic [15:0] mmio_desc_id_reg;

  typedef enum logic {
    WR_IDLE,
    WR_RESP
  } axil_wr_state_t;
  typedef enum logic {
    RD_IDLE,
    RD_RESP
  } axil_rd_state_t;

  axil_wr_state_t axil_wr_state;
  axil_rd_state_t axil_rd_state;
  logic aw_stored;
  logic w_stored;
  logic [AXIL_MMIO_ADDR_WIDTH-1:0] awaddr_hold;
  logic [63:0] wdata_hold;
  logic [7:0] wstrb_hold;

  // Descriptor FIFO
  logic [63:0] desc_fifo_src_addr[0:DESC_FIFO_DEPTH-1];
  logic [63:0] desc_fifo_src_len[0:DESC_FIFO_DEPTH-1];
  logic [63:0] desc_fifo_dst_addr[0:DESC_FIFO_DEPTH-1];
  logic [15:0] desc_fifo_id[0:DESC_FIFO_DEPTH-1];

  logic [DESC_FIFO_DEPTH_LOG2-1:0] desc_fifo_wr_ptr;
  logic [DESC_FIFO_DEPTH_LOG2-1:0] desc_fifo_rd_ptr;
  logic [DESC_FIFO_DEPTH_LOG2:0] desc_fifo_count;

  wire desc_fifo_full = (desc_fifo_count == DESC_FIFO_DEPTH);
  wire desc_fifo_empty = (desc_fifo_count == '0);

  logic desc_fifo_push;
  logic desc_fifo_pop;

  // Completion FIFO
  logic [63:0] cpl_fifo_data[0:DESC_FIFO_DEPTH-1];
  logic [DESC_FIFO_DEPTH_LOG2-1:0] cpl_fifo_wr_ptr;
  logic [DESC_FIFO_DEPTH_LOG2-1:0] cpl_fifo_rd_ptr;
  logic [DESC_FIFO_DEPTH_LOG2:0] cpl_fifo_count;

  wire cpl_fifo_full = (cpl_fifo_count == DESC_FIFO_DEPTH);
  wire cpl_fifo_empty = (cpl_fifo_count == '0);

  wire cpl_fifo_push;
  logic cpl_fifo_pop;
  logic [63:0] cpl_fifo_push_data;

  // MMIO write path
  assign s_axil_awready = !rst && (axil_wr_state == WR_IDLE) && !aw_stored;
  assign s_axil_wready  = !rst && (axil_wr_state == WR_IDLE) && !w_stored;
  always_ff @(posedge clk) begin
    if (rst) begin
      s_axil_bvalid <= 1'b0;
      axil_wr_state <= WR_IDLE;
      desc_fifo_push <= 1'b0;
      mmio_desc_src_addr_reg <= 64'd0;
      mmio_desc_src_len_reg <= 64'd0;
      mmio_desc_dst_addr_reg <= 64'd0;
      mmio_desc_id_reg <= 16'd0;
      aw_stored <= 1'b0;
      w_stored <= 1'b0;
      awaddr_hold <= '0;
      wdata_hold <= 64'd0;
      wstrb_hold <= 8'd0;
    end else begin
      desc_fifo_push <= 1'b0;

      unique case (axil_wr_state)
        WR_IDLE: begin
          s_axil_bvalid <= 1'b0;
          if (s_axil_awvalid && s_axil_awready) begin
            awaddr_hold <= s_axil_awaddr;
            aw_stored   <= 1'b1;
          end
          if (s_axil_wvalid && s_axil_wready) begin
            wdata_hold <= s_axil_wdata;
            wstrb_hold <= s_axil_wstrb;
            w_stored   <= 1'b1;
          end

          // TODO(Jonas): This adds additional cycle
          if (aw_stored && w_stored) begin
            s_axil_bvalid <= 1'b1;
            axil_wr_state <= WR_RESP;

            unique case (awaddr_hold[7:0])
              REG_DESC_SRC_ADDR: begin
                if (wstrb_hold[0]) mmio_desc_src_addr_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_src_addr_reg[15:8] <= wdata_hold[15:8];
                if (wstrb_hold[2]) mmio_desc_src_addr_reg[23:16] <= wdata_hold[23:16];
                if (wstrb_hold[3]) mmio_desc_src_addr_reg[31:24] <= wdata_hold[31:24];
                if (wstrb_hold[4]) mmio_desc_src_addr_reg[39:32] <= wdata_hold[39:32];
                if (wstrb_hold[5]) mmio_desc_src_addr_reg[47:40] <= wdata_hold[47:40];
                if (wstrb_hold[6]) mmio_desc_src_addr_reg[55:48] <= wdata_hold[55:48];
                if (wstrb_hold[7]) mmio_desc_src_addr_reg[63:56] <= wdata_hold[63:56];
              end
              REG_DESC_SRC_LEN: begin
                if (wstrb_hold[0]) mmio_desc_src_len_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_src_len_reg[15:8] <= wdata_hold[15:8];
                if (wstrb_hold[2]) mmio_desc_src_len_reg[23:16] <= wdata_hold[23:16];
                if (wstrb_hold[3]) mmio_desc_src_len_reg[31:24] <= wdata_hold[31:24];
                if (wstrb_hold[4]) mmio_desc_src_len_reg[39:32] <= wdata_hold[39:32];
                if (wstrb_hold[5]) mmio_desc_src_len_reg[47:40] <= wdata_hold[47:40];
                if (wstrb_hold[6]) mmio_desc_src_len_reg[55:48] <= wdata_hold[55:48];
                if (wstrb_hold[7]) mmio_desc_src_len_reg[63:56] <= wdata_hold[63:56];
              end
              REG_DESC_DST_ADDR: begin
                if (wstrb_hold[0]) mmio_desc_dst_addr_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_dst_addr_reg[15:8] <= wdata_hold[15:8];
                if (wstrb_hold[2]) mmio_desc_dst_addr_reg[23:16] <= wdata_hold[23:16];
                if (wstrb_hold[3]) mmio_desc_dst_addr_reg[31:24] <= wdata_hold[31:24];
                if (wstrb_hold[4]) mmio_desc_dst_addr_reg[39:32] <= wdata_hold[39:32];
                if (wstrb_hold[5]) mmio_desc_dst_addr_reg[47:40] <= wdata_hold[47:40];
                if (wstrb_hold[6]) mmio_desc_dst_addr_reg[55:48] <= wdata_hold[55:48];
                if (wstrb_hold[7]) mmio_desc_dst_addr_reg[63:56] <= wdata_hold[63:56];
              end
              REG_DESC_ID: begin
                if (wstrb_hold[0]) mmio_desc_id_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_id_reg[15:8] <= wdata_hold[15:8];
              end
              REG_DESC_COMMIT: begin
                if (!desc_fifo_full) begin
                  desc_fifo_push <= 1'b1;
                end
              end
              default: begin
              end
            endcase
          end
        end
        WR_RESP: begin
          if (s_axil_bready) begin
            s_axil_bvalid <= 1'b0;
            axil_wr_state <= WR_IDLE;
            aw_stored <= 1'b0;
            w_stored <= 1'b0;
          end
        end
      endcase
    end
  end

  // MMIO read path
  always_ff @(posedge clk) begin
    if (rst) begin
      s_axil_arready <= 1'b0;
      s_axil_rdata   <= 64'd0;
      s_axil_rvalid  <= 1'b0;
      axil_rd_state  <= RD_IDLE;
      cpl_fifo_pop   <= 1'b0;
    end else begin
      cpl_fifo_pop <= 1'b0;

      case (axil_rd_state)
        RD_IDLE: begin
          s_axil_arready <= 1'b1;
          s_axil_rvalid  <= 1'b0;
          if (s_axil_arvalid) begin
            s_axil_rvalid <= 1'b1;
            axil_rd_state <= RD_RESP;
            unique case (s_axil_araddr[7:0])
              REG_DESC_SRC_ADDR: s_axil_rdata <= mmio_desc_src_addr_reg;
              REG_DESC_SRC_LEN: s_axil_rdata <= mmio_desc_src_len_reg;
              REG_DESC_DST_ADDR: s_axil_rdata <= mmio_desc_dst_addr_reg;
              REG_DESC_ID: s_axil_rdata <= {{(64 - 16) {1'b0}}, mmio_desc_id_reg};
              REG_DESC_FREE: begin
                s_axil_rdata <= DESC_FIFO_DEPTH - desc_fifo_count;
              end
              REG_CPL_STATUS: begin
                if (!cpl_fifo_empty) begin
                  s_axil_rdata <= cpl_fifo_data[cpl_fifo_rd_ptr];
                  cpl_fifo_pop <= 1'b1;
                end else begin
                  s_axil_rdata <= 64'd0;
                end
              end
              default: s_axil_rdata <= 64'd0;
            endcase
          end
        end
        RD_RESP: begin
          s_axil_arready <= 1'b0;
          if (s_axil_rready) begin
            s_axil_rvalid <= 1'b0;
            axil_rd_state <= RD_IDLE;
          end
        end
        default: axil_rd_state <= RD_IDLE;
      endcase
    end
  end

  // MMIO FIFO updates
  always_ff @(posedge clk) begin
    if (rst) begin
      desc_fifo_wr_ptr <= '0;
      desc_fifo_rd_ptr <= '0;
      desc_fifo_count  <= '0;
      cpl_fifo_wr_ptr  <= '0;
      cpl_fifo_rd_ptr  <= '0;
      cpl_fifo_count   <= '0;
    end else begin
      if (desc_fifo_push && !desc_fifo_full) begin
        desc_fifo_src_addr[desc_fifo_wr_ptr] <= mmio_desc_src_addr_reg;
        desc_fifo_src_len[desc_fifo_wr_ptr] <= mmio_desc_src_len_reg;
        desc_fifo_dst_addr[desc_fifo_wr_ptr] <= mmio_desc_dst_addr_reg;
        desc_fifo_id[desc_fifo_wr_ptr] <= mmio_desc_id_reg;
        desc_fifo_wr_ptr <= desc_fifo_wr_ptr + 1'b1;
      end

      if (desc_fifo_pop && !desc_fifo_empty) begin
        desc_fifo_rd_ptr <= desc_fifo_rd_ptr + 1'b1;
      end

      case ({
        (desc_fifo_push && !desc_fifo_full), (desc_fifo_pop && !desc_fifo_empty)
      })
        2'b10:   desc_fifo_count <= desc_fifo_count + 1'b1;
        2'b01:   desc_fifo_count <= desc_fifo_count - 1'b1;
        default: desc_fifo_count <= desc_fifo_count;
      endcase

      if (cpl_fifo_push && !cpl_fifo_full) begin
        cpl_fifo_data[cpl_fifo_wr_ptr] <= cpl_fifo_push_data;
        cpl_fifo_wr_ptr <= cpl_fifo_wr_ptr + 1'b1;
      end

      if (cpl_fifo_pop && !cpl_fifo_empty) begin
        cpl_fifo_rd_ptr <= cpl_fifo_rd_ptr + 1'b1;
      end

      case ({
        (cpl_fifo_push && !cpl_fifo_full), (cpl_fifo_pop && !cpl_fifo_empty)
      })
        2'b10:   cpl_fifo_count <= cpl_fifo_count + 1'b1;
        2'b01:   cpl_fifo_count <= cpl_fifo_count - 1'b1;
        default: cpl_fifo_count <= cpl_fifo_count;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // Single-decoder state and DMA connections
  // --------------------------------------------------------------------------

  logic task_active;
  logic read_desc_issued;
  logic write_desc_issued;
  logic have_dimensions;

  logic [63:0] task_src_addr;
  logic [63:0] task_src_len;
  logic [63:0] task_dst_addr;
  logic [15:0] task_id;

  logic [15:0] img_width;
  logic [15:0] img_height;

  always_ff @(posedge clk) begin
    if (rst) begin
      task_active <= 1'b0;
      read_desc_issued <= 1'b0;
      write_desc_issued <= 1'b0;
      have_dimensions <= 1'b0;
      task_src_addr <= 64'd0;
      task_src_len <= 64'd0;
      task_dst_addr <= 64'd0;
      task_id <= 16'd0;
      img_width <= 16'd0;
      img_height <= 16'd0;
    end else begin
      if (!task_active && !desc_fifo_empty) begin
        task_active <= 1'b1;
        task_src_addr <= desc_fifo_src_addr[desc_fifo_rd_ptr];
        task_src_len <= desc_fifo_src_len[desc_fifo_rd_ptr];
        task_dst_addr <= desc_fifo_dst_addr[desc_fifo_rd_ptr];
        task_id <= desc_fifo_id[desc_fifo_rd_ptr];
        read_desc_issued <= 1'b0;
        write_desc_issued <= 1'b0;
        have_dimensions <= 1'b0;
      end

      if (read_desc_fire) begin
        read_desc_issued <= 1'b1;
      end

      if (write_desc_fire) begin
        write_desc_issued <= 1'b1;
      end

      if (capture_dimensions) begin
        have_dimensions <= 1'b1;
        img_width <= core_out_width;
        img_height <= core_out_height;
      end

      if (task_done) begin
        task_active <= 1'b0;
      end
    end
  end

  assign desc_fifo_pop = (!task_active && !desc_fifo_empty);

  // --------------------------------------------------------------------------
  // DMA core
  // --------------------------------------------------------------------------

  wire read_desc_fire;
  wire write_desc_fire;

  wire [AXI_DMA_ADDR_WIDTH-1:0] dma_read_desc_addr = task_src_addr[AXI_DMA_ADDR_WIDTH-1:0];
  wire [19:0] dma_read_desc_len = task_src_len[19:0];
  wire dma_read_desc_valid = task_active && !read_desc_issued;
  wire dma_read_desc_ready;

  wire [AXI_DMA_ADDR_WIDTH-1:0] dma_write_desc_addr = task_dst_addr[AXI_DMA_ADDR_WIDTH-1:0];
  wire [31:0] pixel_count = {16'd0, img_width} * {16'd0, img_height};
  wire [31:0] byte_count = pixel_count * 3;
  wire [19:0] dma_write_desc_len = byte_count[19:0];
  wire dma_write_desc_valid = task_active && have_dimensions && !write_desc_issued;
  wire dma_write_desc_ready;

  assign read_desc_fire  = dma_read_desc_valid && dma_read_desc_ready;
  assign write_desc_fire = dma_write_desc_valid && dma_write_desc_ready;

  wire [AXIS_DATA_WIDTH-1:0] dma_read_data_tdata;
  wire [AXIS_KEEP_WIDTH-1:0] dma_read_data_tkeep;
  wire dma_read_data_tvalid;
  wire dma_read_data_tready;
  wire dma_read_data_tlast;

  wire [AXIS_DATA_WIDTH-1:0] dma_write_data_tdata;
  wire [AXIS_KEEP_WIDTH-1:0] dma_write_data_tkeep;
  wire dma_write_data_tvalid;
  wire dma_write_data_tready;
  wire dma_write_data_tlast;

  axi_dma #(
      .AXI_DATA_WIDTH(AXI_DMA_DATA_WIDTH),
      .AXI_ADDR_WIDTH(AXI_DMA_ADDR_WIDTH),
      .AXI_STRB_WIDTH(AXI_DMA_STRB_WIDTH),
      .AXI_ID_WIDTH(AXI_DMA_ID_WIDTH),
      .AXI_MAX_BURST_LEN(16),
      .AXIS_DATA_WIDTH(AXI_DMA_DATA_WIDTH),
      .AXIS_KEEP_ENABLE(1),
      .AXIS_KEEP_WIDTH(AXI_DMA_STRB_WIDTH),
      .AXIS_LAST_ENABLE(1),
      .AXIS_ID_ENABLE(0),
      .AXIS_ID_WIDTH(AXI_DMA_ID_WIDTH),
      .AXIS_DEST_ENABLE(0),
      .AXIS_USER_ENABLE(0),
      .LEN_WIDTH(20),
      .TAG_WIDTH(8),
      .ENABLE_SG(0),
      .ENABLE_UNALIGNED(1)
  ) dma_inst (
      .clk(clk),
      .rst(rst),
      .s_axis_read_desc_addr(dma_read_desc_addr),
      .s_axis_read_desc_len(dma_read_desc_len),
      .s_axis_read_desc_tag(8'd0),
      .s_axis_read_desc_id({AXI_DMA_ID_WIDTH{1'b0}}),
      .s_axis_read_desc_dest(),
      .s_axis_read_desc_user(),
      .s_axis_read_desc_valid(dma_read_desc_valid),
      .s_axis_read_desc_ready(dma_read_desc_ready),
      .m_axis_read_desc_status_tag(),
      .m_axis_read_desc_status_error(),
      .m_axis_read_desc_status_valid(),
      .m_axis_read_data_tdata(dma_read_data_tdata),
      .m_axis_read_data_tkeep(dma_read_data_tkeep),
      .m_axis_read_data_tvalid(dma_read_data_tvalid),
      .m_axis_read_data_tready(dma_read_data_tready),
      .m_axis_read_data_tlast(dma_read_data_tlast),
      .m_axis_read_data_tid(),
      .m_axis_read_data_tdest(),
      .m_axis_read_data_tuser(),
      .s_axis_write_desc_addr(dma_write_desc_addr),
      .s_axis_write_desc_len(dma_write_desc_len),
      .s_axis_write_desc_tag(8'd0),
      .s_axis_write_desc_valid(dma_write_desc_valid),
      .s_axis_write_desc_ready(dma_write_desc_ready),
      .m_axis_write_desc_status_len(),
      .m_axis_write_desc_status_tag(),
      .m_axis_write_desc_status_id(),
      .m_axis_write_desc_status_dest(),
      .m_axis_write_desc_status_user(),
      .m_axis_write_desc_status_error(),
      .m_axis_write_desc_status_valid(),
      .s_axis_write_data_tdata(dma_write_data_tdata),
      .s_axis_write_data_tkeep(dma_write_data_tkeep),
      .s_axis_write_data_tvalid(dma_write_data_tvalid),
      .s_axis_write_data_tready(dma_write_data_tready),
      .s_axis_write_data_tlast(dma_write_data_tlast),
      .s_axis_write_data_tid({AXI_DMA_ID_WIDTH{1'b0}}),
      .s_axis_write_data_tdest(),
      .s_axis_write_data_tuser(),
      .m_axi_awid(m_axi_awid),
      .m_axi_awaddr(m_axi_awaddr),
      .m_axi_awlen(m_axi_awlen),
      .m_axi_awsize(m_axi_awsize),
      .m_axi_awburst(m_axi_awburst),
      .m_axi_awlock(m_axi_awlock),
      .m_axi_awcache(m_axi_awcache),
      .m_axi_awprot(m_axi_awprot),
      .m_axi_awvalid(m_axi_awvalid),
      .m_axi_awready(m_axi_awready),
      .m_axi_wdata(m_axi_wdata),
      .m_axi_wstrb(m_axi_wstrb),
      .m_axi_wlast(m_axi_wlast),
      .m_axi_wvalid(m_axi_wvalid),
      .m_axi_wready(m_axi_wready),
      .m_axi_bid(m_axi_bid),
      .m_axi_bresp(m_axi_bresp),
      .m_axi_bvalid(m_axi_bvalid),
      .m_axi_bready(m_axi_bready),
      .m_axi_arid(m_axi_arid),
      .m_axi_araddr(m_axi_araddr),
      .m_axi_arlen(m_axi_arlen),
      .m_axi_arsize(m_axi_arsize),
      .m_axi_arburst(m_axi_arburst),
      .m_axi_arlock(m_axi_arlock),
      .m_axi_arcache(m_axi_arcache),
      .m_axi_arprot(m_axi_arprot),
      .m_axi_arvalid(m_axi_arvalid),
      .m_axi_arready(m_axi_arready),
      .m_axi_rid(m_axi_rid),
      .m_axi_rdata(m_axi_rdata),
      .m_axi_rresp(m_axi_rresp),
      .m_axi_rlast(m_axi_rlast),
      .m_axi_rvalid(m_axi_rvalid),
      .m_axi_rready(m_axi_rready),
      .read_enable(1'b1),
      .write_enable(1'b1),
      .write_abort(1'b0)
  );

  // --------------------------------------------------------------------------
  // Input buffering and decoder
  // --------------------------------------------------------------------------

  wire [AXIS_DATA_WIDTH-1:0] in_fifo_tdata;
  wire [AXIS_KEEP_WIDTH-1:0] in_fifo_tkeep;
  wire in_fifo_tvalid;
  wire in_fifo_tready;
  wire in_fifo_tlast;

  axis_fifo #(
      .DEPTH(1024),
      .DATA_WIDTH(AXIS_DATA_WIDTH),
      .KEEP_ENABLE(1),
      .KEEP_WIDTH(AXIS_KEEP_WIDTH),
      .LAST_ENABLE(1),
      .ID_ENABLE(0),
      .DEST_ENABLE(0),
      .USER_ENABLE(0),
      .USER_WIDTH(1),
      .RAM_PIPELINE(1),
      .OUTPUT_FIFO_ENABLE(0)
  ) input_fifo (
      .clk(clk),
      .rst(rst),
      .s_axis_tdata(dma_read_data_tdata),
      .s_axis_tkeep(dma_read_data_tkeep),
      .s_axis_tvalid(dma_read_data_tvalid),
      .s_axis_tready(dma_read_data_tready),
      .s_axis_tlast(dma_read_data_tlast),
      .s_axis_tid(),
      .s_axis_tdest(),
      .s_axis_tuser(),
      .m_axis_tdata(in_fifo_tdata),
      .m_axis_tkeep(in_fifo_tkeep),
      .m_axis_tvalid(in_fifo_tvalid),
      .m_axis_tready(in_fifo_tready),
      .m_axis_tlast(in_fifo_tlast),
      .m_axis_tid(),
      .m_axis_tdest(),
      .m_axis_tuser(),
      .pause_req(1'b0),
      .pause_ack(),
      .status_depth(),
      .status_depth_commit(),
      .status_overflow(),
      .status_bad_frame(),
      .status_good_frame()
  );

  wire [31:0] core_in_data;
  wire [3:0] core_in_strb;
  wire core_in_valid;
  wire core_in_ready;
  wire core_in_last;

  axis_adapter #(
      .S_DATA_WIDTH(AXIS_DATA_WIDTH),
      .S_KEEP_ENABLE(1),
      .S_KEEP_WIDTH(AXIS_KEEP_WIDTH),
      .M_DATA_WIDTH(32),
      .M_KEEP_ENABLE(1),
      .M_KEEP_WIDTH(4),
      .ID_ENABLE(0),
      .DEST_ENABLE(0),
      .USER_ENABLE(0),
      .USER_WIDTH(1)
  ) in_adapter (
      .clk(clk),
      .rst(rst),
      .s_axis_tdata(in_fifo_tdata),
      .s_axis_tkeep(in_fifo_tkeep),
      .s_axis_tvalid(in_fifo_tvalid),
      .s_axis_tready(in_fifo_tready),
      .s_axis_tlast(in_fifo_tlast),
      .s_axis_tid(),
      .s_axis_tdest(),
      .s_axis_tuser(),
      .m_axis_tdata(core_in_data),
      .m_axis_tkeep(core_in_strb),
      .m_axis_tvalid(core_in_valid),
      .m_axis_tready(core_in_ready),
      .m_axis_tlast(core_in_last),
      .m_axis_tid(),
      .m_axis_tdest(),
      .m_axis_tuser()
  );

  wire core_out_valid;
  wire [15:0] core_out_width;
  wire [15:0] core_out_height;
  wire [15:0] core_out_x;
  wire [15:0] core_out_y;
  wire [7:0] core_out_r;
  wire [7:0] core_out_g;
  wire [7:0] core_out_b;
  wire core_idle;
  wire core_out_accept = out_fifo_tready;

  jpeg_core #(
      .SUPPORT_WRITABLE_DHT(JPEG_SUPPORT_WRITABLE_DHT)
  ) u_core (
      .clk_i(clk),
      .rst_i(rst),
      .inport_valid_i(core_in_valid),
      .inport_data_i(core_in_data),
      .inport_strb_i(core_in_strb),
      .inport_last_i(1'b0),
      .outport_accept_i(core_out_accept),
      .inport_accept_o(core_in_ready),
      .outport_valid_o(core_out_valid),
      .outport_width_o(core_out_width),
      .outport_height_o(core_out_height),
      .outport_pixel_x_o(core_out_x),
      .outport_pixel_y_o(core_out_y),
      .outport_pixel_r_o(core_out_r),
      .outport_pixel_g_o(core_out_g),
      .outport_pixel_b_o(core_out_b),
      .idle_o(core_idle)
  );

  // --------------------------------------------------------------------------
  // Output buffering and DMA write
  // --------------------------------------------------------------------------

  wire [23:0] out_fifo_tdata;
  wire [2:0] out_fifo_tkeep;
  wire out_fifo_tvalid;
  wire out_fifo_tready;
  wire out_fifo_tlast;
  wire out_fifo_tready_dma;
  wire out_adapter_ready;

  wire out_fifo_s_last = (core_out_x == core_out_width - 1'b1) && (core_out_y == core_out_height - 1'b1);

  axis_fifo #(
      .DEPTH(2048),
      .DATA_WIDTH(24),
      .KEEP_ENABLE(1),
      .KEEP_WIDTH(3),
      .LAST_ENABLE(1),
      .ID_ENABLE(0),
      .DEST_ENABLE(0),
      .USER_ENABLE(0),
      .USER_WIDTH(1),
      .RAM_PIPELINE(1),
      .OUTPUT_FIFO_ENABLE(0)
  ) output_fifo (
      .clk(clk),
      .rst(rst),
      .s_axis_tdata({core_out_b, core_out_g, core_out_r}),
      .s_axis_tkeep(3'b111),
      .s_axis_tvalid(core_out_valid),
      .s_axis_tready(out_fifo_tready),
      .s_axis_tlast(out_fifo_s_last),
      .s_axis_tid(),
      .s_axis_tdest(),
      .s_axis_tuser(1'b0),
      .m_axis_tdata(out_fifo_tdata),
      .m_axis_tkeep(out_fifo_tkeep),
      .m_axis_tvalid(out_fifo_tvalid),
      .m_axis_tready(out_fifo_tready_dma),
      .m_axis_tlast(out_fifo_tlast),
      .m_axis_tid(),
      .m_axis_tdest(),
      .m_axis_tuser(),
      .pause_req(1'b0),
      .pause_ack(),
      .status_depth(),
      .status_depth_commit(),
      .status_overflow(),
      .status_bad_frame(),
      .status_good_frame()
  );

  axis_adapter #(
      .S_DATA_WIDTH(24),
      .S_KEEP_ENABLE(1),
      .S_KEEP_WIDTH(3),
      .M_DATA_WIDTH(AXIS_DATA_WIDTH),
      .M_KEEP_ENABLE(1),
      .M_KEEP_WIDTH(AXIS_KEEP_WIDTH),
      .ID_ENABLE(0),
      .DEST_ENABLE(0),
      .USER_ENABLE(0),
      .USER_WIDTH(1)
  ) out_adapter (
      .clk(clk),
      .rst(rst),
      .s_axis_tdata(out_fifo_tdata),
      .s_axis_tkeep(out_fifo_tkeep),
      .s_axis_tvalid(out_fifo_tvalid),
      .s_axis_tready(out_adapter_ready),
      .s_axis_tlast(out_fifo_tlast),
      .s_axis_tid(),
      .s_axis_tdest(),
      .s_axis_tuser(),
      .m_axis_tdata(dma_write_data_tdata),
      .m_axis_tkeep(dma_write_data_tkeep),
      .m_axis_tvalid(dma_write_data_tvalid),
      .m_axis_tready(dma_write_data_tready),
      .m_axis_tlast(dma_write_data_tlast),
      .m_axis_tid(),
      .m_axis_tdest(),
      .m_axis_tuser()
  );

  assign out_fifo_tready_dma = write_desc_issued ? out_adapter_ready : 1'b0;

  wire capture_dimensions = core_out_valid && core_out_accept && !have_dimensions;
  wire task_done = dma_write_data_tvalid && dma_write_data_tready && dma_write_data_tlast;

  // --------------------------------------------------------------------------
  // Completion push
  // --------------------------------------------------------------------------

  always_comb begin
    cpl_fifo_push_data = 64'd0;
    if (task_done) begin
      cpl_fifo_push_data[15:0]  = 16'd1;
      cpl_fifo_push_data[31:16] = task_id;
      cpl_fifo_push_data[47:32] = img_width;
      cpl_fifo_push_data[63:48] = img_height;
    end
  end

  assign cpl_fifo_push = task_done;

endmodule

`default_nettype wire
