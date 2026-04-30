`timescale 1ns / 1ps
`include "jpeg_params.vh"
`default_nettype none
`define JPEG_MARK_DEBUG (* mark_debug = "true" *)

module jpeg_top #(
    parameter unsigned JPEG_SUPPORT_WRITABLE_DHT = `JPEG_SUPPORT_WRITABLE_DHT,
    parameter unsigned JPEG_NUM_DECODERS = 2,
    parameter unsigned DESC_FIFO_DEPTH_LOG2 = 4,
    parameter unsigned INPUT_FIFO_SLOTS = 32,
    parameter unsigned OUTPUT_FIFO_SLOTS = 64,

    parameter unsigned AXI_DMA_ID_WIDTH = `JPEG_DMA_BITS_ID,
    parameter unsigned AXI_DMA_ADDR_WIDTH = `JPEG_DMA_BITS_ADDR,
    parameter unsigned AXI_DMA_DATA_WIDTH = `JPEG_DMA_BITS_DATA,
    parameter unsigned AXI_DMA_STRB_WIDTH = `JPEG_DMA_BITS_DATA / 8,
    parameter unsigned AXI_DMA_MAX_BURST_LEN = `JPEG_DMA_MAX_BURST_LEN,

    parameter unsigned AXIL_MMIO_ADDR_WIDTH = `JPEG_MMIO_BITS_ADDR
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
     * AXI write DMA interface
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
     * AXI read DMA interface
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

  localparam int AxisDataWidth = AXI_DMA_DATA_WIDTH;
  localparam int AxisKeepWidth = AXI_DMA_STRB_WIDTH;
  localparam logic [DESC_FIFO_DEPTH_LOG2:0] DescFifoDepth = (1 << DESC_FIFO_DEPTH_LOG2);
  localparam int InputFifoDepthBytes = INPUT_FIFO_SLOTS * AXI_DMA_STRB_WIDTH;
  localparam int OutputFifoDepthBytes = OUTPUT_FIFO_SLOTS * AXI_DMA_STRB_WIDTH;
  localparam int AxiDmaBytesMax = AXI_DMA_STRB_WIDTH * AXI_DMA_MAX_BURST_LEN;
  localparam int AxiDmaLenMax = InputFifoDepthBytes > OutputFifoDepthBytes ? InputFifoDepthBytes :
      OutputFifoDepthBytes;
  localparam int AxiDmaLenWidth = $clog2(AxiDmaLenMax + 1);
  localparam int DecoderIdxWidth = $clog2(JPEG_NUM_DECODERS);
  localparam int DecoderIdxMask = JPEG_NUM_DECODERS - 1;
  localparam int InputFifoOccWidth = $clog2(InputFifoDepthBytes) + 1;
  localparam int OutputFifoOccWidth = $clog2(OutputFifoDepthBytes) + 1;

  // Verify parameters
  generate
    if ((AXI_DMA_STRB_WIDTH & (AXI_DMA_STRB_WIDTH - 1)) !=
        0) begin : gen_verify_param_axi_dma_strb_width
      initial
        $fatal(1, "Parameter AXI_DMA_STRB_WIDTH (%0d) must be a power of two", AXI_DMA_STRB_WIDTH);
    end
    if (JPEG_NUM_DECODERS <= 1 || (JPEG_NUM_DECODERS & (JPEG_NUM_DECODERS - 1)) != 0) begin
        : gen_verify_param_jpeg_num_decoders
      initial
        $fatal(
            1, "Parameter JPEG_NUM_DECODERS (%0d) must be >1 and power of two", JPEG_NUM_DECODERS
        );
    end
    if (AXI_DMA_ID_WIDTH < DecoderIdxWidth) begin : gen_verify_param_axi_dma_id_width
      initial
        $fatal(
            1,
            "Parameter AXI_DMA_ID_WIDTH (%0d) must be >= %0d to identify %0d decoders",
            AXI_DMA_ID_WIDTH,
            DecoderIdxWidth,
            JPEG_NUM_DECODERS
        );
    end
  endgenerate

  function automatic [$clog2(AxisKeepWidth + 1)-1:0] axis_keep_count;
    input logic [AxisKeepWidth-1:0] keep;
    int i;
    begin
      axis_keep_count = '0;
      for (i = 0; i < AxisKeepWidth; i = i + 1) begin
        axis_keep_count = axis_keep_count + keep[i];
      end
    end
  endfunction

  function automatic [AXI_DMA_ID_WIDTH-1:0] decoder_axi_id;
    input logic [DecoderIdxWidth-1:0] decoder;
    begin
      decoder_axi_id = decoder;
    end
  endfunction

  // --------------------------------------------------------------------------
  // MMIO register map (byte offsets)
  // --------------------------------------------------------------------------
  localparam logic [7:0] RegDescRscAddr = 8'h00;
  localparam logic [7:0] RegDescSrcLen = 8'h08;
  localparam logic [7:0] RegDescDstAddr = 8'h10;
  localparam logic [7:0] RegDescId = 8'h18;
  localparam logic [7:0] RegDescCommit = 8'h20;
  localparam logic [7:0] RegDescFree = 8'h28;
  localparam logic [7:0] RegCplStatus = 8'h30;
  localparam logic [7:0] RegReset = 8'h38;
  localparam logic [7:0] RegClockGateEnable = 8'h40;

  assign s_axil_bresp = 2'b0;
  assign s_axil_rresp = 2'b0;

  logic [63:0] mmio_desc_src_addr_reg;
  logic [63:0] mmio_desc_src_len_reg;
  logic [63:0] mmio_desc_dst_addr_reg;
  logic [15:0] mmio_desc_id_reg;
  logic mmio_clk_gate_enable_reg;
  logic mmio_reset_pulse;

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
  logic [63:0] desc_fifo_src_addr[DescFifoDepth];
  logic [63:0] desc_fifo_src_len[DescFifoDepth];
  logic [63:0] desc_fifo_dst_addr[DescFifoDepth];
  logic [15:0] desc_fifo_id[DescFifoDepth];

  logic [DESC_FIFO_DEPTH_LOG2-1:0] desc_fifo_wr_ptr;
  logic [DESC_FIFO_DEPTH_LOG2-1:0] desc_fifo_rd_ptr;
  `JPEG_MARK_DEBUG
  logic [DESC_FIFO_DEPTH_LOG2:0] desc_fifo_count;

  wire desc_fifo_full = (desc_fifo_count == DescFifoDepth);
  `JPEG_MARK_DEBUG
  wire desc_fifo_empty = (desc_fifo_count == '0);

  logic desc_fifo_push;
  logic desc_fifo_pop;

  // Completion FIFO
  logic [63:0] cpl_fifo_data[DescFifoDepth];
  logic [DESC_FIFO_DEPTH_LOG2-1:0] cpl_fifo_wr_ptr;
  logic [DESC_FIFO_DEPTH_LOG2-1:0] cpl_fifo_rd_ptr;
  logic [DESC_FIFO_DEPTH_LOG2:0] cpl_fifo_count;

  wire cpl_fifo_full = (cpl_fifo_count == DescFifoDepth);
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
      mmio_reset_pulse <= 1'b0;
      mmio_desc_src_addr_reg <= 64'd0;
      mmio_desc_src_len_reg <= 64'd0;
      mmio_desc_dst_addr_reg <= 64'd0;
      mmio_desc_id_reg <= 16'd0;
      mmio_clk_gate_enable_reg <= 1'b0;
      aw_stored <= 1'b0;
      w_stored <= 1'b0;
      awaddr_hold <= '0;
      wdata_hold <= 64'd0;
      wstrb_hold <= 8'd0;
    end else begin
      desc_fifo_push   <= 1'b0;
      mmio_reset_pulse <= 1'b0;

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

          if (aw_stored && w_stored) begin
            s_axil_bvalid <= 1'b1;
            axil_wr_state <= WR_RESP;

            unique case (awaddr_hold[7:0])
              RegDescRscAddr: begin
                if (wstrb_hold[0]) mmio_desc_src_addr_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_src_addr_reg[15:8] <= wdata_hold[15:8];
                if (wstrb_hold[2]) mmio_desc_src_addr_reg[23:16] <= wdata_hold[23:16];
                if (wstrb_hold[3]) mmio_desc_src_addr_reg[31:24] <= wdata_hold[31:24];
                if (wstrb_hold[4]) mmio_desc_src_addr_reg[39:32] <= wdata_hold[39:32];
                if (wstrb_hold[5]) mmio_desc_src_addr_reg[47:40] <= wdata_hold[47:40];
                if (wstrb_hold[6]) mmio_desc_src_addr_reg[55:48] <= wdata_hold[55:48];
                if (wstrb_hold[7]) mmio_desc_src_addr_reg[63:56] <= wdata_hold[63:56];
              end
              RegDescSrcLen: begin
                if (wstrb_hold[0]) mmio_desc_src_len_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_src_len_reg[15:8] <= wdata_hold[15:8];
                if (wstrb_hold[2]) mmio_desc_src_len_reg[23:16] <= wdata_hold[23:16];
                if (wstrb_hold[3]) mmio_desc_src_len_reg[31:24] <= wdata_hold[31:24];
                if (wstrb_hold[4]) mmio_desc_src_len_reg[39:32] <= wdata_hold[39:32];
                if (wstrb_hold[5]) mmio_desc_src_len_reg[47:40] <= wdata_hold[47:40];
                if (wstrb_hold[6]) mmio_desc_src_len_reg[55:48] <= wdata_hold[55:48];
                if (wstrb_hold[7]) mmio_desc_src_len_reg[63:56] <= wdata_hold[63:56];
              end
              RegDescDstAddr: begin
                if (wstrb_hold[0]) mmio_desc_dst_addr_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_dst_addr_reg[15:8] <= wdata_hold[15:8];
                if (wstrb_hold[2]) mmio_desc_dst_addr_reg[23:16] <= wdata_hold[23:16];
                if (wstrb_hold[3]) mmio_desc_dst_addr_reg[31:24] <= wdata_hold[31:24];
                if (wstrb_hold[4]) mmio_desc_dst_addr_reg[39:32] <= wdata_hold[39:32];
                if (wstrb_hold[5]) mmio_desc_dst_addr_reg[47:40] <= wdata_hold[47:40];
                if (wstrb_hold[6]) mmio_desc_dst_addr_reg[55:48] <= wdata_hold[55:48];
                if (wstrb_hold[7]) mmio_desc_dst_addr_reg[63:56] <= wdata_hold[63:56];
              end
              RegDescId: begin
                if (wstrb_hold[0]) mmio_desc_id_reg[7:0] <= wdata_hold[7:0];
                if (wstrb_hold[1]) mmio_desc_id_reg[15:8] <= wdata_hold[15:8];
              end
              RegDescCommit: begin
                if (!desc_fifo_full) begin
                  desc_fifo_push <= 1'b1;
                end
              end
              RegReset: begin
                if (|wdata_hold) begin
                  mmio_reset_pulse <= 1'b1;
                end
              end
              RegClockGateEnable: begin
                if (wstrb_hold[0]) begin
                  mmio_clk_gate_enable_reg <= wdata_hold[0];
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
    if (rst || mmio_reset_pulse) begin
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
              RegDescRscAddr: s_axil_rdata <= mmio_desc_src_addr_reg;
              RegDescSrcLen: s_axil_rdata <= mmio_desc_src_len_reg;
              RegDescDstAddr: s_axil_rdata <= mmio_desc_dst_addr_reg;
              RegDescId: s_axil_rdata <= {{(64 - 16) {1'b0}}, mmio_desc_id_reg};
              RegDescFree: begin
                s_axil_rdata <= DescFifoDepth - desc_fifo_count;
              end
              RegCplStatus: begin
                if (!cpl_fifo_empty) begin
                  s_axil_rdata <= cpl_fifo_data[cpl_fifo_rd_ptr];
                  cpl_fifo_pop <= 1'b1;
                end else begin
                  s_axil_rdata <= 64'd0;
                end
              end
              RegClockGateEnable: s_axil_rdata <= {{63{1'b0}}, mmio_clk_gate_enable_reg};
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
    integer i;
    if (rst || mmio_reset_pulse) begin
      desc_fifo_wr_ptr <= '0;
      desc_fifo_rd_ptr <= '0;
      desc_fifo_count  <= '0;
      cpl_fifo_wr_ptr  <= '0;
      cpl_fifo_rd_ptr  <= '0;
      cpl_fifo_count   <= '0;
      for (i = 0; i < DescFifoDepth; i = i + 1) begin
        desc_fifo_src_addr[i] <= 64'd0;
        desc_fifo_src_len[i]  <= 64'd0;
        desc_fifo_dst_addr[i] <= 64'd0;
        desc_fifo_id[i]       <= 16'd0;
        cpl_fifo_data[i]      <= 64'd0;
      end
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
  // Multi-decoder state and shared DMA connections
  // --------------------------------------------------------------------------

  typedef enum logic [1:0] {
    SLOT_IDLE,
    SLOT_RUN,
    SLOT_RESET_PULSE,
    SLOT_RESET_HOLD
  } decoder_slot_state_t;

  `JPEG_MARK_DEBUG
  decoder_slot_state_t slot_state[JPEG_NUM_DECODERS];

  `JPEG_MARK_DEBUG
  logic write_chunk_data_done;
  logic have_dimensions[JPEG_NUM_DECODERS];
  logic core_reset_pulse[JPEG_NUM_DECODERS];

  logic [AXI_DMA_ADDR_WIDTH-1:0] task_src_addr[JPEG_NUM_DECODERS];
  logic [31:0] task_src_len[JPEG_NUM_DECODERS];
  logic [AXI_DMA_ADDR_WIDTH-1:0] task_dst_addr[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic [31:0] write_bytes_remaining[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic [AxiDmaLenWidth-1:0] write_chunk_bytes_sent;
  logic [15:0] task_id[JPEG_NUM_DECODERS];
  logic [15:0] img_width[JPEG_NUM_DECODERS];
  logic [15:0] img_height[JPEG_NUM_DECODERS];

  `JPEG_MARK_DEBUG
  logic read_service_active;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] read_service_decoder;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] read_rr_ptr;
  `JPEG_MARK_DEBUG
  logic write_service_active;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] write_service_decoder;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] write_rr_ptr;

  `JPEG_MARK_DEBUG
  logic desc_assign_valid;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] desc_assign_decoder;

  // Tracks bytes accepted into each input and output FIFO but not yet consumed
  // by the decoder core. Even though axis_fifo has the signal status_depth,
  // this is not accurate since there is an internal buffering stage before the
  // output AXI-S interface. Data residing in this buffer is not accounted for
  // via status_depth.
  `JPEG_MARK_DEBUG
  logic [InputFifoOccWidth-1:0] input_fifo_occupied_len[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic [OutputFifoOccWidth-1:0] output_fifo_occupied_len[JPEG_NUM_DECODERS];

  logic [AxisDataWidth-1:0] core_in_tdata[JPEG_NUM_DECODERS];
  logic [AxisKeepWidth-1:0] core_in_tkeep[JPEG_NUM_DECODERS];
  logic core_in_tvalid[JPEG_NUM_DECODERS];
  logic core_in_tready[JPEG_NUM_DECODERS];
  logic core_in_tlast[JPEG_NUM_DECODERS];

  logic [AxisDataWidth-1:0] input_fifo_tdata[JPEG_NUM_DECODERS];
  logic [AxisKeepWidth-1:0] input_fifo_tkeep[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic input_fifo_tvalid[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic input_fifo_tready[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic input_fifo_tlast[JPEG_NUM_DECODERS];

  logic [15:0] core_out_width[JPEG_NUM_DECODERS];
  logic [15:0] core_out_height[JPEG_NUM_DECODERS];
  logic core_rst[JPEG_NUM_DECODERS];

  logic [AxisDataWidth-1:0] core_out_tdata[JPEG_NUM_DECODERS];
  logic [AxisKeepWidth-1:0] core_out_tkeep[JPEG_NUM_DECODERS];
  logic core_out_tvalid[JPEG_NUM_DECODERS];
  logic core_out_tready[JPEG_NUM_DECODERS];
  logic core_out_tlast[JPEG_NUM_DECODERS];
  logic core_dims_valid[JPEG_NUM_DECODERS];

  logic [AxisDataWidth-1:0] output_fifo_tdata[JPEG_NUM_DECODERS];
  logic [AxisKeepWidth-1:0] output_fifo_tkeep[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic output_fifo_tvalid[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic output_fifo_tlast[JPEG_NUM_DECODERS];
  `JPEG_MARK_DEBUG
  logic output_fifo_tready[JPEG_NUM_DECODERS];

  logic [AXI_DMA_ADDR_WIDTH-1:0] dma_read_desc_addr;
  `JPEG_MARK_DEBUG
  logic [AxiDmaLenWidth-1:0] dma_read_desc_len;
  `JPEG_MARK_DEBUG
  logic dma_read_desc_valid;
  `JPEG_MARK_DEBUG
  wire dma_read_desc_ready;

  logic [AXI_DMA_ADDR_WIDTH-1:0] dma_write_desc_addr;
  `JPEG_MARK_DEBUG
  logic [AxiDmaLenWidth-1:0] dma_write_desc_len;
  `JPEG_MARK_DEBUG
  logic dma_write_desc_valid;
  `JPEG_MARK_DEBUG
  wire dma_write_desc_ready;

  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] dma_read_decoder;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] dma_write_desc_decoder;

  `JPEG_MARK_DEBUG
  wire dma_read_desc_fire;
  `JPEG_MARK_DEBUG
  wire dma_write_desc_fire;

  wire [AxisDataWidth-1:0] dma_read_data_reg_tdata;
  wire [AxisKeepWidth-1:0] dma_read_data_reg_tkeep;
  wire dma_read_data_reg_tvalid;
  wire dma_read_data_reg_tready;
  wire dma_read_data_reg_tlast;
  wire [DecoderIdxWidth-1:0] dma_read_data_reg_tid;

  wire [AxisDataWidth-1:0] dma_read_data_tdata;
  wire [AxisKeepWidth-1:0] dma_read_data_tkeep;
  `JPEG_MARK_DEBUG
  wire dma_read_data_tvalid;
  `JPEG_MARK_DEBUG
  logic dma_read_data_tready;
  `JPEG_MARK_DEBUG
  wire dma_read_data_tlast;
  `JPEG_MARK_DEBUG
  wire  [DecoderIdxWidth-1:0] dma_read_data_tid;

  logic [  AxisDataWidth-1:0] dma_write_data_tdata;
  logic [  AxisKeepWidth-1:0] dma_write_data_tkeep;
  `JPEG_MARK_DEBUG
  logic dma_write_data_tvalid;
  `JPEG_MARK_DEBUG
  wire dma_write_data_tready;
  `JPEG_MARK_DEBUG
  logic dma_write_data_tlast;
  `JPEG_MARK_DEBUG
  logic [DecoderIdxWidth-1:0] dma_write_data_tid;

  wire [AxisDataWidth-1:0] dma_write_data_reg_tdata;
  wire [AxisKeepWidth-1:0] dma_write_data_reg_tkeep;
  wire dma_write_data_reg_tvalid;
  wire dma_write_data_reg_tready;
  wire dma_write_data_reg_tlast;
  wire [DecoderIdxWidth-1:0] dma_write_data_reg_tid;

  `JPEG_MARK_DEBUG
  wire dma_write_desc_status_valid;

  `JPEG_MARK_DEBUG
  wire [$clog2(
AxisKeepWidth + 1
)-1:0] output_fifo_tkeep_count = axis_keep_count(
      dma_write_data_tkeep
  );
  wire dma_read_data_fire = dma_read_data_tvalid && dma_read_data_tready;
  wire dma_write_data_fire = dma_write_data_tvalid && dma_write_data_tready;
  `JPEG_MARK_DEBUG
  wire write_status_is_final = dma_write_desc_status_valid &&
      (write_bytes_remaining[write_service_decoder] == dma_write_desc_len);

  // Pick the next decoder slot that is ready to accept a fresh descriptor.
  always_ff @(posedge clk) begin
    bit picked_decoder = 0;
    integer i;
    desc_assign_valid   <= 1'b0;
    desc_assign_decoder <= '0;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      if (!picked_decoder && !desc_assign_valid && !desc_fifo_empty &&
          slot_state[i] == SLOT_IDLE) begin
        desc_assign_valid   <= 1'b1;
        desc_assign_decoder <= DecoderIdxWidth'(i);
        picked_decoder = 1;
      end
    end
  end

  assign desc_fifo_pop = desc_assign_valid;

  // DMA read: arbitration and transfer sizing
  always_ff @(posedge clk) begin
    if (rst || mmio_reset_pulse) begin
      dma_read_desc_valid <= 0;
      dma_read_decoder <= 0;
      dma_read_desc_len <= 0;
      dma_read_desc_addr <= 0;
    end else begin
      integer i;
      bit picked_decoder = 0;
      logic [DecoderIdxWidth-1:0] decoder_idx = read_rr_ptr;  // walk decoders in round-robin order
      dma_read_desc_valid <= 0;

      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        logic [InputFifoOccWidth-1:0] input_fifo_free_bytes = 0;
        bit can_issue_read = 0;
        // Compute eligibility and transfer size. Read fill all available input FIFO space.
        if (!picked_decoder && !read_service_active) begin
          input_fifo_free_bytes = (InputFifoDepthBytes - input_fifo_occupied_len[decoder_idx]) & ~(
              AXI_DMA_STRB_WIDTH - 1);
          can_issue_read = (slot_state[decoder_idx] == SLOT_RUN) && task_src_len[decoder_idx] &&
              input_fifo_free_bytes;

          if (can_issue_read) begin
            dma_read_desc_valid <= 1;
            dma_read_decoder <= decoder_idx;
            dma_read_desc_len <= task_src_len[decoder_idx] > input_fifo_free_bytes ?
                input_fifo_free_bytes : task_src_len[decoder_idx];
            dma_read_desc_addr <= task_src_addr[decoder_idx];

            picked_decoder = 1;
          end
        end

        decoder_idx = decoder_idx + 1'b1;
      end
    end
  end

  // DMA write: arbitration and transfer sizing
  always_ff @(posedge clk) begin
    if (rst || mmio_reset_pulse) begin
      dma_write_desc_valid <= 0;
      dma_write_desc_decoder <= 0;
      dma_write_desc_len <= 0;
      dma_write_desc_addr <= 0;
    end else begin
      integer i;
      bit picked_decoder = 0;
      logic [DecoderIdxWidth-1:0] decoder_idx = write_rr_ptr;  // walk decoders in round-robin order
      dma_write_desc_valid <= 0;

      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        bit can_issue_write = 0;
        // Compute eligibility and transfer size. write fill all available input FIFO space.
        if (!picked_decoder && !write_service_active) begin
          can_issue_write = (slot_state[decoder_idx] == SLOT_RUN) && have_dimensions[decoder_idx] &&
              write_bytes_remaining[decoder_idx] && output_fifo_occupied_len[decoder_idx];

          if (can_issue_write) begin
            dma_write_desc_valid <= 1;
            dma_write_desc_decoder <= decoder_idx;
            dma_write_desc_len <=
                write_bytes_remaining[decoder_idx] < output_fifo_occupied_len[decoder_idx] ?
                write_bytes_remaining[decoder_idx] : output_fifo_occupied_len[decoder_idx];
            dma_write_desc_addr <= task_dst_addr[decoder_idx];

            picked_decoder = 1;
          end
        end

        decoder_idx = decoder_idx + 1'b1;
      end
    end
  end

  assign dma_read_desc_fire  = dma_read_desc_valid && dma_read_desc_ready;
  assign dma_write_desc_fire = dma_write_desc_valid && dma_write_desc_ready;

  // Per-slot lifecycle bookkeeping plus shared read/write service ownership.
  always_ff @(posedge clk) begin
    integer i;
    if (rst || mmio_reset_pulse) begin
      read_service_active    <= 1'b0;
      read_service_decoder   <= '0;
      read_rr_ptr            <= '0;
      write_service_active   <= 1'b0;
      write_service_decoder  <= '0;
      write_rr_ptr           <= '0;

      write_chunk_data_done  <= 1'b0;
      write_chunk_bytes_sent <= '0;

      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        slot_state[i] <= SLOT_IDLE;
        have_dimensions[i] <= 1'b0;
        core_reset_pulse[i] <= 1'b0;
        input_fifo_occupied_len[i] <= '0;
        output_fifo_occupied_len[i] <= '0;
        task_src_addr[i] <= 64'd0;
        task_src_len[i] <= 64'd0;
        task_dst_addr[i] <= 64'd0;
        write_bytes_remaining[i] <= 64'd0;
        task_id[i] <= 16'd0;
        img_width[i] <= 16'd0;
        img_height[i] <= 16'd0;
      end
    end else begin
      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        bit input_pushed;
        bit input_popped;
        logic [InputFifoOccWidth-1:0] input_bytes_pushed;
        logic [InputFifoOccWidth-1:0] input_bytes_popped;
        bit output_pushed;
        bit output_popped;
        logic [OutputFifoOccWidth-1:0] output_bytes_pushed;
        logic [OutputFifoOccWidth-1:0] output_bytes_popped;

        core_reset_pulse[i] <= 1'b0;

        input_pushed = input_fifo_tvalid[i] && input_fifo_tready[i];
        input_popped = core_in_tvalid[i] && core_in_tready[i];
        input_bytes_pushed = axis_keep_count(input_fifo_tkeep[i]) &
            {InputFifoOccWidth{input_pushed}};
        input_bytes_popped = axis_keep_count(core_in_tkeep[i]) & {InputFifoOccWidth{input_popped}};
        input_fifo_occupied_len[i] <= input_fifo_occupied_len[i] + input_bytes_pushed -
            input_bytes_popped;

        output_pushed = core_out_tvalid[i] && core_out_tready[i];
        output_popped = output_fifo_tvalid[i] && output_fifo_tready[i];
        output_bytes_pushed = axis_keep_count(core_out_tkeep[i]) &
            {OutputFifoOccWidth{output_pushed}};
        output_bytes_popped = axis_keep_count(output_fifo_tkeep[i]) &
            {OutputFifoOccWidth{output_popped}};
        output_fifo_occupied_len[i] <= output_fifo_occupied_len[i] + output_bytes_pushed -
            output_bytes_popped;

        unique case (slot_state[i])
          SLOT_RESET_PULSE: begin
            core_reset_pulse[i] <= 1'b1;
            slot_state[i] <= SLOT_RESET_HOLD;
          end
          SLOT_RESET_HOLD: begin
            slot_state[i] <= SLOT_IDLE;
          end
          default: begin
          end
        endcase

        if (core_dims_valid[i]) begin
          have_dimensions[i] <= 1'b1;
          img_width[i] <= core_out_width[i];
          img_height[i] <= core_out_height[i];
          write_bytes_remaining[i] <= 32'(core_out_width[i]) * 32'(core_out_height[i]) * 3;
        end

        if (slot_state[i] == SLOT_RUN && have_dimensions[i] && !write_bytes_remaining[i] &&
            !task_src_len[i] && !read_service_active && !write_service_active) begin
          slot_state[i] <= SLOT_RESET_PULSE;
        end
      end

      if (desc_fifo_pop) begin
        slot_state[desc_assign_decoder] <= SLOT_RUN;
        have_dimensions[desc_assign_decoder] <= 1'b0;
        input_fifo_occupied_len[desc_assign_decoder] <= '0;
        output_fifo_occupied_len[desc_assign_decoder] <= '0;
        task_src_addr[desc_assign_decoder] <= desc_fifo_src_addr[desc_fifo_rd_ptr];
        task_src_len[desc_assign_decoder] <= desc_fifo_src_len[desc_fifo_rd_ptr];
        task_dst_addr[desc_assign_decoder] <= desc_fifo_dst_addr[desc_fifo_rd_ptr];
        write_bytes_remaining[desc_assign_decoder] <= 64'd0;
        task_id[desc_assign_decoder] <= desc_fifo_id[desc_fifo_rd_ptr];
        img_width[desc_assign_decoder] <= 16'd0;
        img_height[desc_assign_decoder] <= 16'd0;
      end

      if (dma_read_desc_fire) begin
        read_service_active <= 1'b1;
        read_service_decoder <= dma_read_decoder;
        read_rr_ptr <= dma_read_decoder + 1'b1;
      end

      if (dma_read_data_fire && dma_read_data_tlast) begin
        task_src_addr[read_service_decoder] <= task_src_addr[read_service_decoder] +
            dma_read_desc_len;
        task_src_len[read_service_decoder] <= task_src_len[read_service_decoder] -
            dma_read_desc_len;
        read_service_active <= 1'b0;
      end

      if (dma_write_desc_fire) begin
        write_service_active <= 1'b1;
        write_service_decoder <= dma_write_desc_decoder;
        write_rr_ptr <= dma_write_desc_decoder + 1'b1;
      end

      if (dma_write_data_fire) begin
        write_chunk_bytes_sent <= write_chunk_bytes_sent + output_fifo_tkeep_count;
        if (dma_write_data_tlast) begin
          write_chunk_data_done <= 1'b1;
        end
      end

      if (dma_write_desc_status_valid) begin
        task_dst_addr[write_service_decoder] <= task_dst_addr[write_service_decoder] +
            dma_write_desc_len;
        write_bytes_remaining[write_service_decoder] <=
            write_bytes_remaining[write_service_decoder] - dma_write_desc_len;
        write_chunk_data_done <= 1'b0;
        write_chunk_bytes_sent <= '0;
        write_service_active <= 1'b0;
      end
    end
  end

  // Shared DMA engine. Descriptor tags identify which decoder slot owns each transfer.
  axi_dma #(
      .AXI_DATA_WIDTH(AXI_DMA_DATA_WIDTH),
      .AXI_ADDR_WIDTH(AXI_DMA_ADDR_WIDTH),
      .AXI_STRB_WIDTH(AXI_DMA_STRB_WIDTH),
      .AXI_ID_WIDTH(AXI_DMA_ID_WIDTH),
      .AXI_MAX_BURST_LEN(AXI_DMA_MAX_BURST_LEN),
      .AXIS_DATA_WIDTH(AXI_DMA_DATA_WIDTH),
      .AXIS_KEEP_ENABLE(1),
      .AXIS_KEEP_WIDTH(AXI_DMA_STRB_WIDTH),
      .AXIS_LAST_ENABLE(1),
      .AXIS_ID_ENABLE(1),
      .AXIS_ID_WIDTH(DecoderIdxWidth),
      .AXIS_DEST_ENABLE(0),
      .AXIS_USER_ENABLE(0),
      .LEN_WIDTH(AxiDmaLenWidth),
      .TAG_WIDTH(DecoderIdxWidth),
      .ENABLE_SG(0),
      .ENABLE_UNALIGNED(0)
  ) dma_inst (
      .clk(clk),
      .rst(rst || mmio_reset_pulse),
      .s_axis_read_desc_addr(dma_read_desc_addr),
      .s_axis_read_desc_len(dma_read_desc_len),
      .s_axis_read_desc_tag(dma_read_decoder),
      .s_axis_read_desc_id(dma_read_decoder),
      .s_axis_read_desc_dest(),
      .s_axis_read_desc_user(),
      .s_axis_read_desc_valid(dma_read_desc_valid),
      .s_axis_read_desc_ready(dma_read_desc_ready),
      .m_axis_read_desc_status_tag(),
      .m_axis_read_desc_status_error(),
      .m_axis_read_desc_status_valid(),
      .m_axis_read_data_tdata(dma_read_data_reg_tdata),
      .m_axis_read_data_tkeep(dma_read_data_reg_tkeep),
      .m_axis_read_data_tvalid(dma_read_data_reg_tvalid),
      .m_axis_read_data_tready(dma_read_data_reg_tready),
      .m_axis_read_data_tlast(dma_read_data_reg_tlast),
      .m_axis_read_data_tid(dma_read_data_reg_tid),
      .m_axis_read_data_tdest(),
      .m_axis_read_data_tuser(),
      .s_axis_write_desc_addr(dma_write_desc_addr),
      .s_axis_write_desc_len(dma_write_desc_len),
      .s_axis_write_desc_tag(dma_write_desc_decoder),
      .s_axis_write_desc_valid(dma_write_desc_valid),
      .s_axis_write_desc_ready(dma_write_desc_ready),
      .m_axis_write_desc_status_len(),
      .m_axis_write_desc_status_tag(),
      .m_axis_write_desc_status_id(),
      .m_axis_write_desc_status_dest(),
      .m_axis_write_desc_status_user(),
      .m_axis_write_desc_status_error(),
      .m_axis_write_desc_status_valid(dma_write_desc_status_valid),
      .s_axis_write_data_tdata(dma_write_data_reg_tdata),
      .s_axis_write_data_tkeep(dma_write_data_reg_tkeep),
      .s_axis_write_data_tvalid(dma_write_data_reg_tvalid),
      .s_axis_write_data_tready(dma_write_data_reg_tready),
      .s_axis_write_data_tlast(dma_write_data_reg_tlast),
      .s_axis_write_data_tid(dma_write_data_reg_tid),
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

  axis_register #(
      .DATA_WIDTH(AxisDataWidth),
      .KEEP_ENABLE(1),
      .KEEP_WIDTH(AxisKeepWidth),
      .LAST_ENABLE(1),
      .ID_ENABLE(1),
      .ID_WIDTH(DecoderIdxWidth),
      .DEST_ENABLE(0),
      .USER_ENABLE(0),
      .USER_WIDTH(1),
      .REG_TYPE(2)
  ) dma_read_data_reg (
      .clk(clk),
      .rst(rst || mmio_reset_pulse),
      .s_axis_tdata(dma_read_data_reg_tdata),
      .s_axis_tkeep(dma_read_data_reg_tkeep),
      .s_axis_tvalid(dma_read_data_reg_tvalid),
      .s_axis_tready(dma_read_data_reg_tready),
      .s_axis_tlast(dma_read_data_reg_tlast),
      .s_axis_tid(dma_read_data_reg_tid),
      .s_axis_tdest(),
      .s_axis_tuser(1'b0),
      .m_axis_tdata(dma_read_data_tdata),
      .m_axis_tkeep(dma_read_data_tkeep),
      .m_axis_tvalid(dma_read_data_tvalid),
      .m_axis_tready(dma_read_data_tready),
      .m_axis_tlast(dma_read_data_tlast),
      .m_axis_tid(dma_read_data_tid),
      .m_axis_tdest(),
      .m_axis_tuser()
  );

  axis_register #(
      .DATA_WIDTH(AxisDataWidth),
      .KEEP_ENABLE(1),
      .KEEP_WIDTH(AxisKeepWidth),
      .LAST_ENABLE(1),
      .ID_ENABLE(1),
      .ID_WIDTH(DecoderIdxWidth),
      .DEST_ENABLE(0),
      .USER_ENABLE(0),
      .USER_WIDTH(1),
      .REG_TYPE(2)
  ) dma_write_data_reg (
      .clk(clk),
      .rst(rst || mmio_reset_pulse),
      .s_axis_tdata(dma_write_data_tdata),
      .s_axis_tkeep(dma_write_data_tkeep),
      .s_axis_tvalid(dma_write_data_tvalid),
      .s_axis_tready(dma_write_data_tready),
      .s_axis_tlast(dma_write_data_tlast),
      .s_axis_tid(dma_write_data_tid),
      .s_axis_tdest(),
      .s_axis_tuser(1'b0),
      .m_axis_tdata(dma_write_data_reg_tdata),
      .m_axis_tkeep(dma_write_data_reg_tkeep),
      .m_axis_tvalid(dma_write_data_reg_tvalid),
      .m_axis_tready(dma_write_data_reg_tready),
      .m_axis_tlast(dma_write_data_reg_tlast),
      .m_axis_tid(dma_write_data_reg_tid),
      .m_axis_tdest(),
      .m_axis_tuser()
  );

  // DMA read data routing from DMA engine to input FIFO
  always_comb begin
    integer i;
    dma_read_data_tready = 1'b0;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      input_fifo_tdata[i]  = '0;
      input_fifo_tkeep[i]  = '0;
      input_fifo_tvalid[i] = 1'b0;
      input_fifo_tlast[i]  = 1'b0;
    end

    if (read_service_active) begin
      input_fifo_tdata[read_service_decoder] = dma_read_data_tdata;
      input_fifo_tkeep[read_service_decoder] = dma_read_data_tkeep;
      input_fifo_tvalid[read_service_decoder] = dma_read_data_tvalid;
      input_fifo_tlast[read_service_decoder] = dma_read_data_tlast;
      dma_read_data_tready = input_fifo_tready[read_service_decoder];
    end
  end

  // DMA write data routing from output FIFO to DMA engine
  always_comb begin
    integer i;
    dma_write_data_tdata = '0;
    dma_write_data_tkeep = '0;
    dma_write_data_tvalid = 1'b0;
    dma_write_data_tlast = 1'b0;
    dma_write_data_tid = '0;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      output_fifo_tready[i] = 1'b0;
    end

    if (write_service_active) begin
      dma_write_data_tdata = output_fifo_tdata[write_service_decoder];
      dma_write_data_tkeep = output_fifo_tkeep[write_service_decoder];
      dma_write_data_tvalid = output_fifo_tvalid[write_service_decoder] && !write_chunk_data_done;
      dma_write_data_tlast = !write_chunk_data_done &&
          (write_chunk_bytes_sent + output_fifo_tkeep_count == dma_write_desc_len);
      dma_write_data_tid = write_service_decoder;
      output_fifo_tready[write_service_decoder] = dma_write_data_tready && !write_chunk_data_done;
    end
  end

  genvar g;
  generate
    for (g = 0; g < JPEG_NUM_DECODERS; g = g + 1) begin : gen_decoder
      wire decoder_clk;
      logic decoder_clk_en;
      logic [AxisDataWidth-1:0] input_fifo_reg_tdata;
      logic [AxisKeepWidth-1:0] input_fifo_reg_tkeep;
      logic input_fifo_reg_tvalid;
      logic input_fifo_reg_tready;
      logic input_fifo_reg_tlast;
      logic [AxisDataWidth-1:0] output_fifo_reg_tdata;
      logic [AxisKeepWidth-1:0] output_fifo_reg_tkeep;
      logic output_fifo_reg_tvalid;
      logic output_fifo_reg_tready;
      logic output_fifo_reg_tlast;

      // Each decoder gets private input/output buffering and a dedicated core instance. When MMIO
      // clock gating is enabled, gate this island only while the slot is idle. Force the clock on
      // during resets so the local synchronous reset inputs are observed.
      assign decoder_clk_en = rst || mmio_reset_pulse || !mmio_clk_gate_enable_reg ||
          (slot_state[g] != SLOT_IDLE);
      assign core_rst[g] = rst || mmio_reset_pulse || core_reset_pulse[g];

      BUFGCE decoder_clk_bufgce (
          .I (clk),
          .CE(decoder_clk_en),
          .O (decoder_clk)
      );

      axis_register #(
          .DATA_WIDTH(AxisDataWidth),
          .KEEP_ENABLE(1),
          .KEEP_WIDTH(AxisKeepWidth),
          .LAST_ENABLE(1),
          .ID_ENABLE(0),
          .DEST_ENABLE(0),
          .USER_ENABLE(0),
          .USER_WIDTH(1),
          .REG_TYPE(2)
      ) input_fifo_reg (
          .clk(decoder_clk),
          .rst(core_rst[g]),
          .s_axis_tdata(input_fifo_tdata[g]),
          .s_axis_tkeep(input_fifo_tkeep[g]),
          .s_axis_tvalid(input_fifo_tvalid[g]),
          .s_axis_tready(input_fifo_tready[g]),
          .s_axis_tlast(input_fifo_tlast[g]),
          .s_axis_tid(),
          .s_axis_tdest(),
          .s_axis_tuser(1'b0),
          .m_axis_tdata(input_fifo_reg_tdata),
          .m_axis_tkeep(input_fifo_reg_tkeep),
          .m_axis_tvalid(input_fifo_reg_tvalid),
          .m_axis_tready(input_fifo_reg_tready),
          .m_axis_tlast(input_fifo_reg_tlast),
          .m_axis_tid(),
          .m_axis_tdest(),
          .m_axis_tuser()
      );

      axis_fifo #(
          .DEPTH(InputFifoDepthBytes),
          .DATA_WIDTH(AxisDataWidth),
          .KEEP_ENABLE(1),
          .KEEP_WIDTH(AxisKeepWidth),
          .LAST_ENABLE(1),
          .ID_ENABLE(0),
          .DEST_ENABLE(0),
          .USER_ENABLE(0),
          .USER_WIDTH(1),
          .RAM_PIPELINE(1),
          .OUTPUT_FIFO_ENABLE(0)
      ) input_fifo (
          .clk(decoder_clk),
          .rst(core_rst[g]),
          .s_axis_tdata(input_fifo_reg_tdata),
          .s_axis_tkeep(input_fifo_reg_tkeep),
          .s_axis_tvalid(input_fifo_reg_tvalid),
          .s_axis_tready(input_fifo_reg_tready),
          .s_axis_tlast(input_fifo_reg_tlast),
          .s_axis_tid(),
          .s_axis_tdest(),
          .s_axis_tuser(),
          .m_axis_tdata(core_in_tdata[g]),
          .m_axis_tkeep(core_in_tkeep[g]),
          .m_axis_tvalid(core_in_tvalid[g]),
          .m_axis_tready(core_in_tready[g]),
          .m_axis_tlast(core_in_tlast[g]),
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

      jpeg_core_wrapper #(
          .JPEG_SUPPORT_WRITABLE_DHT(JPEG_SUPPORT_WRITABLE_DHT),
          .AXIS_DATA_WIDTH(AxisDataWidth),
          .AXIS_KEEP_WIDTH(AxisKeepWidth)
      ) jpeg_core_inst (
          .clk(decoder_clk),
          .rst(core_rst[g]),
          .s_axis_tdata(core_in_tdata[g]),
          .s_axis_tkeep(core_in_tkeep[g]),
          .s_axis_tvalid(core_in_tvalid[g]),
          .s_axis_tready(core_in_tready[g]),
          .s_axis_tlast(core_in_tlast[g]),
          .m_axis_tdata(core_out_tdata[g]),
          .m_axis_tkeep(core_out_tkeep[g]),
          .m_axis_tvalid(core_out_tvalid[g]),
          .m_axis_tready(core_out_tready[g]),
          .m_axis_tlast(core_out_tlast[g]),
          .out_dims_valid(core_dims_valid[g]),
          .out_width(core_out_width[g]),
          .out_height(core_out_height[g]),
          .idle()
      );

      axis_fifo #(
          .DEPTH(OutputFifoDepthBytes),
          .DATA_WIDTH(AxisDataWidth),
          .KEEP_ENABLE(1),
          .KEEP_WIDTH(AxisKeepWidth),
          .LAST_ENABLE(1),
          .ID_ENABLE(0),
          .DEST_ENABLE(0),
          .USER_ENABLE(0),
          .USER_WIDTH(1),
          .RAM_PIPELINE(1),
          .OUTPUT_FIFO_ENABLE(1)
      ) output_fifo (
          .clk(decoder_clk),
          .rst(core_rst[g]),
          .s_axis_tdata(core_out_tdata[g]),
          .s_axis_tkeep(core_out_tkeep[g]),
          .s_axis_tvalid(core_out_tvalid[g]),
          .s_axis_tready(core_out_tready[g]),
          .s_axis_tlast(core_out_tlast[g]),
          .s_axis_tid(),
          .s_axis_tdest(),
          .s_axis_tuser(1'b0),
          .m_axis_tdata(output_fifo_reg_tdata),
          .m_axis_tkeep(output_fifo_reg_tkeep),
          .m_axis_tvalid(output_fifo_reg_tvalid),
          .m_axis_tready(output_fifo_reg_tready),
          .m_axis_tlast(output_fifo_reg_tlast),
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

      axis_register #(
          .DATA_WIDTH(AxisDataWidth),
          .KEEP_ENABLE(1),
          .KEEP_WIDTH(AxisKeepWidth),
          .LAST_ENABLE(1),
          .ID_ENABLE(0),
          .DEST_ENABLE(0),
          .USER_ENABLE(0),
          .USER_WIDTH(1),
          .REG_TYPE(2)
      ) output_fifo_reg (
          .clk(decoder_clk),
          .rst(core_rst[g]),
          .s_axis_tdata(output_fifo_reg_tdata),
          .s_axis_tkeep(output_fifo_reg_tkeep),
          .s_axis_tvalid(output_fifo_reg_tvalid),
          .s_axis_tready(output_fifo_reg_tready),
          .s_axis_tlast(output_fifo_reg_tlast),
          .s_axis_tid(),
          .s_axis_tdest(),
          .s_axis_tuser(1'b0),
          .m_axis_tdata(output_fifo_tdata[g]),
          .m_axis_tkeep(output_fifo_tkeep[g]),
          .m_axis_tvalid(output_fifo_tvalid[g]),
          .m_axis_tready(output_fifo_tready[g]),
          .m_axis_tlast(output_fifo_tlast[g]),
          .m_axis_tid(),
          .m_axis_tdest(),
          .m_axis_tuser()
      );
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Completion push
  // --------------------------------------------------------------------------

  always_comb begin
    cpl_fifo_push_data = 64'd0;
    if (write_status_is_final) begin
      cpl_fifo_push_data[15:0]  = 16'd1;
      cpl_fifo_push_data[31:16] = task_id[write_service_decoder];
      cpl_fifo_push_data[47:32] = img_width[write_service_decoder];
      cpl_fifo_push_data[63:48] = img_height[write_service_decoder];
    end
  end

  assign cpl_fifo_push = write_status_is_final;

endmodule

`default_nettype wire
