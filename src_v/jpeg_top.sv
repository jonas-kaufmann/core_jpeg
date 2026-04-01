`timescale 1ns / 1ps
`include "jpeg_params.vh"
`default_nettype none

module jpeg_top #(
    parameter unsigned JPEG_SUPPORT_WRITABLE_DHT = `JPEG_SUPPORT_WRITABLE_DHT,
    parameter unsigned JPEG_NUM_DECODERS = 1,
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
  localparam int INPUT_FIFO_DEPTH_BYTES = INPUT_FIFO_SLOTS * AXI_DMA_STRB_WIDTH;
  localparam int OUTPUT_FIFO_DEPTH_BYTES = OUTPUT_FIFO_SLOTS * AXI_DMA_STRB_WIDTH;
  localparam int AXI_DMA_BYTES_MAX = AXI_DMA_STRB_WIDTH * AXI_DMA_MAX_BURST_LEN;
  localparam int AXI_DMA_LEN_WIDTH = $clog2(AXI_DMA_BYTES_MAX + 1);
  localparam int DECODER_IDX_WIDTH = JPEG_NUM_DECODERS > 1 ? $clog2(JPEG_NUM_DECODERS) : 1;
  localparam int INPUT_FIFO_OCC_WIDTH = $clog2(INPUT_FIFO_DEPTH_BYTES) + 1;
  localparam int OUTPUT_FIFO_OCC_WIDTH = $clog2(OUTPUT_FIFO_DEPTH_BYTES) + 1;

  // Verify parameters
  generate
    if ((AXI_DMA_STRB_WIDTH & (AXI_DMA_STRB_WIDTH - 1)) != 0) begin : gen_verify_param_axi_dma_strb_width
      initial
        $fatal(1, "Parameter AXI_DMA_STRB_WIDTH (%0d) must be a power of two", AXI_DMA_STRB_WIDTH);
    end
    if (AXI_DMA_ID_WIDTH < DECODER_IDX_WIDTH) begin : gen_verify_param_axi_dma_id_width
      initial
        $fatal(1, "Parameter AXI_DMA_ID_WIDTH (%0d) must be >= %0d to identify %0d decoders",
               AXI_DMA_ID_WIDTH, DECODER_IDX_WIDTH, JPEG_NUM_DECODERS);
    end
  endgenerate

  function automatic [$clog2(AXIS_KEEP_WIDTH + 1)-1:0] axis_keep_count(input logic [AXIS_KEEP_WIDTH-1:0] keep);
    int i;
    begin
      axis_keep_count = '0;
      for (i = 0; i < AXIS_KEEP_WIDTH; i = i + 1) begin
        axis_keep_count = axis_keep_count + keep[i];
      end
    end
  endfunction

  function automatic [AXI_DMA_ID_WIDTH-1:0] decoder_axi_id(input logic [DECODER_IDX_WIDTH-1:0] decoder);
    begin
      decoder_axi_id = decoder;
    end
  endfunction

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
  localparam logic [7:0] REG_RESET = 8'h38;

  assign s_axil_bresp = 2'b0;
  assign s_axil_rresp = 2'b0;

  logic [63:0] mmio_desc_src_addr_reg;
  logic [63:0] mmio_desc_src_len_reg;
  logic [63:0] mmio_desc_dst_addr_reg;
  logic [15:0] mmio_desc_id_reg;
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
      mmio_reset_pulse <= 1'b0;
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
              REG_RESET: begin
                if (|wdata_hold) begin
                  mmio_reset_pulse <= 1'b1;
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
    if (rst || mmio_reset_pulse) begin
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
  // Multi-decoder state and shared DMA connections
  // --------------------------------------------------------------------------

  typedef enum logic [1:0] {
    SLOT_IDLE,
    SLOT_RUN,
    SLOT_RESET_PULSE,
    SLOT_RESET_HOLD
  } decoder_slot_state_t;

  decoder_slot_state_t slot_state[0:JPEG_NUM_DECODERS-1];

  logic read_chunk_active[0:JPEG_NUM_DECODERS-1];
  logic write_chunk_active[0:JPEG_NUM_DECODERS-1];
  logic write_chunk_data_done[0:JPEG_NUM_DECODERS-1];
  logic have_dimensions[0:JPEG_NUM_DECODERS-1];
  logic core_reset_pulse[0:JPEG_NUM_DECODERS-1];

  logic [63:0] task_src_addr[0:JPEG_NUM_DECODERS-1];
  logic [63:0] task_src_len[0:JPEG_NUM_DECODERS-1];
  logic [63:0] task_dst_addr[0:JPEG_NUM_DECODERS-1];
  logic [63:0] read_chunk_len[0:JPEG_NUM_DECODERS-1];
  logic [63:0] write_bytes_remaining[0:JPEG_NUM_DECODERS-1];
  logic [63:0] write_chunk_len[0:JPEG_NUM_DECODERS-1];
  logic [$clog2(AXIS_KEEP_WIDTH + 1)+AXI_DMA_LEN_WIDTH-1:0]
      write_chunk_bytes_sent[0:JPEG_NUM_DECODERS-1];
  logic [15:0] task_id[0:JPEG_NUM_DECODERS-1];
  logic [15:0] img_width[0:JPEG_NUM_DECODERS-1];
  logic [15:0] img_height[0:JPEG_NUM_DECODERS-1];
  logic read_stream_done[0:JPEG_NUM_DECODERS-1];
  logic write_stream_done[0:JPEG_NUM_DECODERS-1];

  logic read_service_active;
  logic [DECODER_IDX_WIDTH-1:0] read_service_decoder;
  logic write_service_active;
  logic [DECODER_IDX_WIDTH-1:0] write_service_decoder;

  logic desc_assign_valid;
  logic [DECODER_IDX_WIDTH-1:0] desc_assign_decoder;

  logic [INPUT_FIFO_OCC_WIDTH-1:0] input_fifo_occupied_len[0:JPEG_NUM_DECODERS-1];
  logic [INPUT_FIFO_OCC_WIDTH-1:0] input_fifo_free_bytes[0:JPEG_NUM_DECODERS-1];
  logic [OUTPUT_FIFO_OCC_WIDTH-1:0] output_fifo_occupied_len[0:JPEG_NUM_DECODERS-1];

  logic [AXIS_DATA_WIDTH-1:0] in_fifo_tdata[0:JPEG_NUM_DECODERS-1];
  logic [AXIS_KEEP_WIDTH-1:0] in_fifo_tkeep[0:JPEG_NUM_DECODERS-1];
  logic in_fifo_tvalid[0:JPEG_NUM_DECODERS-1];
  logic in_fifo_tready[0:JPEG_NUM_DECODERS-1];
  logic in_fifo_tlast[0:JPEG_NUM_DECODERS-1];
  logic in_fifo_dma_tready[0:JPEG_NUM_DECODERS-1];

  logic [15:0] core_out_width[0:JPEG_NUM_DECODERS-1];
  logic [15:0] core_out_height[0:JPEG_NUM_DECODERS-1];
  logic core_rst[0:JPEG_NUM_DECODERS-1];

  logic [AXIS_DATA_WIDTH-1:0] core_out_tdata[0:JPEG_NUM_DECODERS-1];
  logic [AXIS_KEEP_WIDTH-1:0] core_out_tkeep[0:JPEG_NUM_DECODERS-1];
  logic core_out_tvalid[0:JPEG_NUM_DECODERS-1];
  logic core_out_tready[0:JPEG_NUM_DECODERS-1];
  logic core_out_tlast[0:JPEG_NUM_DECODERS-1];
  logic core_dims_valid[0:JPEG_NUM_DECODERS-1];

  logic [AXIS_DATA_WIDTH-1:0] out_fifo_tdata[0:JPEG_NUM_DECODERS-1];
  logic [AXIS_KEEP_WIDTH-1:0] out_fifo_tkeep[0:JPEG_NUM_DECODERS-1];
  logic out_fifo_tvalid[0:JPEG_NUM_DECODERS-1];
  logic out_fifo_tready[0:JPEG_NUM_DECODERS-1];
  logic out_fifo_tlast[0:JPEG_NUM_DECODERS-1];
  logic out_fifo_tready_dma[0:JPEG_NUM_DECODERS-1];

  logic can_issue_read_desc[0:JPEG_NUM_DECODERS-1];
  logic can_issue_write_desc[0:JPEG_NUM_DECODERS-1];
  logic [63:0] next_read_desc_len[0:JPEG_NUM_DECODERS-1];
  logic [63:0] next_write_desc_len[0:JPEG_NUM_DECODERS-1];
  logic [31:0] capture_pixel_count[0:JPEG_NUM_DECODERS-1];
  logic [31:0] capture_byte_count[0:JPEG_NUM_DECODERS-1];

  logic read_issue_valid;
  logic [DECODER_IDX_WIDTH-1:0] read_issue_decoder;
  logic write_issue_valid;
  logic [DECODER_IDX_WIDTH-1:0] write_issue_decoder;

  wire read_desc_fire;
  wire write_desc_fire;

  wire [AXI_DMA_ADDR_WIDTH-1:0] dma_read_desc_addr = task_src_addr[read_issue_decoder][AXI_DMA_ADDR_WIDTH-1:0];
  wire [AXI_DMA_LEN_WIDTH-1:0] dma_read_desc_len = next_read_desc_len[read_issue_decoder][AXI_DMA_LEN_WIDTH-1:0];
  wire dma_read_desc_valid = read_issue_valid;
  wire dma_read_desc_ready;

  wire [AXI_DMA_ADDR_WIDTH-1:0] dma_write_desc_addr = task_dst_addr[write_issue_decoder][AXI_DMA_ADDR_WIDTH-1:0];
  wire [AXI_DMA_LEN_WIDTH-1:0] dma_write_desc_len =
      next_write_desc_len[write_issue_decoder][AXI_DMA_LEN_WIDTH-1:0];
  wire dma_write_desc_valid = write_issue_valid;
  wire dma_write_desc_ready;

  wire [AXIS_DATA_WIDTH-1:0] dma_read_data_tdata;
  wire [AXIS_KEEP_WIDTH-1:0] dma_read_data_tkeep;
  wire dma_read_data_tvalid;
  logic dma_read_data_tready;
  wire dma_read_data_tlast;
  wire [AXI_DMA_ID_WIDTH-1:0] dma_read_data_tid;

  logic [AXIS_DATA_WIDTH-1:0] dma_write_data_tdata;
  logic [AXIS_KEEP_WIDTH-1:0] dma_write_data_tkeep;
  logic dma_write_data_tvalid;
  wire dma_write_data_tready;
  logic dma_write_data_tlast;
  logic [AXI_DMA_ID_WIDTH-1:0] dma_write_data_tid;

  wire [DECODER_IDX_WIDTH-1:0] dma_read_desc_status_tag;
  wire [3:0] dma_read_desc_status_error;
  wire dma_read_desc_status_valid;
  wire [AXI_DMA_LEN_WIDTH-1:0] dma_write_desc_status_len;
  wire [DECODER_IDX_WIDTH-1:0] dma_write_desc_status_tag;
  wire [AXI_DMA_ID_WIDTH-1:0] dma_write_desc_status_id;
  wire [3:0] dma_write_desc_status_error;
  wire dma_write_desc_status_valid;

  logic [$clog2(AXIS_KEEP_WIDTH + 1)-1:0] active_out_fifo_tkeep_count;
  wire dma_read_data_fire = dma_read_data_tvalid && dma_read_data_tready;
  wire dma_write_data_fire = dma_write_data_tvalid && dma_write_data_tready;
  wire [DECODER_IDX_WIDTH-1:0] dma_write_status_decoder = dma_write_desc_status_tag[DECODER_IDX_WIDTH-1:0];
  wire write_status_is_final = dma_write_desc_status_valid
      && (write_bytes_remaining[dma_write_status_decoder] == write_chunk_len[dma_write_status_decoder]);

  // Pick the next decoder slot that is ready to accept a fresh descriptor.
  always_comb begin
    integer i;
    desc_assign_valid = 1'b0;
    desc_assign_decoder = '0;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      if (!desc_assign_valid && slot_state[i] == SLOT_IDLE) begin
        desc_assign_valid = 1'b1;
        desc_assign_decoder = DECODER_IDX_WIDTH'(i);
      end
    end
  end

  assign desc_fifo_pop = desc_assign_valid && !desc_fifo_empty;

  // Read arbitration favors the decoder that will stall first due to input starvation.
  always_comb begin
    integer i;
    read_issue_valid = 1'b0;
    read_issue_decoder = '0;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      if (can_issue_read_desc[i]
          && (!read_issue_valid
              || input_fifo_occupied_len[i] < input_fifo_occupied_len[read_issue_decoder])) begin
        read_issue_valid = 1'b1;
        read_issue_decoder = DECODER_IDX_WIDTH'(i);
      end
    end
  end

  // Write arbitration favors the decoder that is closest to blocking on output backpressure.
  always_comb begin
    integer i;
    write_issue_valid = 1'b0;
    write_issue_decoder = '0;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      if (can_issue_write_desc[i]
          && (!write_issue_valid
              || output_fifo_occupied_len[i] > output_fifo_occupied_len[write_issue_decoder])) begin
        write_issue_valid = 1'b1;
        write_issue_decoder = DECODER_IDX_WIDTH'(i);
      end
    end
  end

  assign read_desc_fire  = dma_read_desc_valid && dma_read_desc_ready;
  assign write_desc_fire = dma_write_desc_valid && dma_write_desc_ready;

  // Per-decoder DMA eligibility and transfer sizing derived from local FIFO pressure. Except for
  // the last transfer, we always want them to have full size, i.e. all strb bits 1.
  always_comb begin
    integer i;
    for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
      input_fifo_free_bytes[i] = (INPUT_FIFO_DEPTH_BYTES - input_fifo_occupied_len[i])
          & ~(AXI_DMA_STRB_WIDTH - 1);
      can_issue_read_desc[i] = !read_service_active && (slot_state[i] == SLOT_RUN) && !read_stream_done[i]
          && !read_chunk_active[i] && (task_src_len[i] != 0) && (input_fifo_free_bytes[i] != 0);
      next_read_desc_len[i] = task_src_len[i] > AXI_DMA_BYTES_MAX ? AXI_DMA_BYTES_MAX
          : task_src_len[i] < input_fifo_free_bytes[i] ? task_src_len[i] : input_fifo_free_bytes[i];

      capture_pixel_count[i] = {16'd0, core_out_width[i]} * {16'd0, core_out_height[i]};
      capture_byte_count[i] = capture_pixel_count[i] * 3;
      can_issue_write_desc[i] = !write_service_active && (slot_state[i] == SLOT_RUN) && have_dimensions[i]
          && !write_stream_done[i] && !write_chunk_active[i] && (write_bytes_remaining[i] != 0)
          && (output_fifo_occupied_len[i] >= AXI_DMA_STRB_WIDTH);
      next_write_desc_len[i] = write_bytes_remaining[i] > AXI_DMA_BYTES_MAX ? AXI_DMA_BYTES_MAX
          : (write_bytes_remaining[i] & ~(AXI_DMA_STRB_WIDTH - 1)) != 0
              ? (write_bytes_remaining[i] & ~(AXI_DMA_STRB_WIDTH - 1))
              : write_bytes_remaining[i];
    end
  end

  // Route the shared DMA read stream into the input FIFO that owns the active read transaction.
  always_comb begin
    integer i;
    dma_read_data_tready = 1'b0;
    if (dma_read_data_tvalid) begin
      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        if (dma_read_data_tid == decoder_axi_id(DECODER_IDX_WIDTH'(i))) begin
          dma_read_data_tready = in_fifo_dma_tready[i];
        end
      end
    end
  end

  // Route the selected decoder's output FIFO into the shared DMA write-data channel.
  always_comb begin
    active_out_fifo_tkeep_count = '0;
    dma_write_data_tdata = '0;
    dma_write_data_tkeep = '0;
    dma_write_data_tvalid = 1'b0;
    dma_write_data_tlast = 1'b0;
    dma_write_data_tid = '0;

    if (write_service_active) begin
      active_out_fifo_tkeep_count = axis_keep_count(out_fifo_tkeep[write_service_decoder]);
      dma_write_data_tdata = out_fifo_tdata[write_service_decoder];
      dma_write_data_tkeep = out_fifo_tkeep[write_service_decoder];
      dma_write_data_tvalid = out_fifo_tvalid[write_service_decoder]
          && write_chunk_active[write_service_decoder]
          && !write_chunk_data_done[write_service_decoder];
      dma_write_data_tlast = write_chunk_active[write_service_decoder]
          && !write_chunk_data_done[write_service_decoder]
          && (write_chunk_bytes_sent[write_service_decoder] + active_out_fifo_tkeep_count
              == write_chunk_len[write_service_decoder]);
      dma_write_data_tid = decoder_axi_id(write_service_decoder);
    end
  end

  // Per-slot lifecycle bookkeeping plus shared read/write service ownership.
  always_ff @(posedge clk) begin
    integer i;
    if (rst || mmio_reset_pulse) begin
      read_service_active <= 1'b0;
      read_service_decoder <= '0;
      write_service_active <= 1'b0;
      write_service_decoder <= '0;

      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        slot_state[i] <= SLOT_IDLE;
        read_chunk_active[i] <= 1'b0;
        write_chunk_active[i] <= 1'b0;
        write_chunk_data_done[i] <= 1'b0;
        have_dimensions[i] <= 1'b0;
        core_reset_pulse[i] <= 1'b0;
        task_src_addr[i] <= 64'd0;
        task_src_len[i] <= 64'd0;
        task_dst_addr[i] <= 64'd0;
        read_chunk_len[i] <= 64'd0;
        write_bytes_remaining[i] <= 64'd0;
        write_chunk_len[i] <= 64'd0;
        write_chunk_bytes_sent[i] <= '0;
        task_id[i] <= 16'd0;
        img_width[i] <= 16'd0;
        img_height[i] <= 16'd0;
        read_stream_done[i] <= 1'b0;
        write_stream_done[i] <= 1'b0;
      end
    end else begin
      for (i = 0; i < JPEG_NUM_DECODERS; i = i + 1) begin
        core_reset_pulse[i] <= 1'b0;

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
          write_bytes_remaining[i] <= capture_byte_count[i];
        end

        if (slot_state[i] == SLOT_RUN && read_stream_done[i] && write_stream_done[i]
            && !read_chunk_active[i] && !write_chunk_active[i]) begin
          slot_state[i] <= SLOT_RESET_PULSE;
        end
      end

      if (desc_fifo_pop) begin
        slot_state[desc_assign_decoder] <= SLOT_RUN;
        read_chunk_active[desc_assign_decoder] <= 1'b0;
        write_chunk_active[desc_assign_decoder] <= 1'b0;
        write_chunk_data_done[desc_assign_decoder] <= 1'b0;
        have_dimensions[desc_assign_decoder] <= 1'b0;
        task_src_addr[desc_assign_decoder] <= desc_fifo_src_addr[desc_fifo_rd_ptr];
        task_src_len[desc_assign_decoder] <= desc_fifo_src_len[desc_fifo_rd_ptr];
        task_dst_addr[desc_assign_decoder] <= desc_fifo_dst_addr[desc_fifo_rd_ptr];
        read_chunk_len[desc_assign_decoder] <= 64'd0;
        write_bytes_remaining[desc_assign_decoder] <= 64'd0;
        write_chunk_len[desc_assign_decoder] <= 64'd0;
        write_chunk_bytes_sent[desc_assign_decoder] <= '0;
        task_id[desc_assign_decoder] <= desc_fifo_id[desc_fifo_rd_ptr];
        img_width[desc_assign_decoder] <= 16'd0;
        img_height[desc_assign_decoder] <= 16'd0;
        read_stream_done[desc_assign_decoder] <= (desc_fifo_src_len[desc_fifo_rd_ptr] == 64'd0);
        write_stream_done[desc_assign_decoder] <= 1'b0;
      end

      if (read_desc_fire) begin
        read_chunk_active[read_issue_decoder] <= 1'b1;
        read_chunk_len[read_issue_decoder] <= next_read_desc_len[read_issue_decoder];
        read_service_active <= 1'b1;
        read_service_decoder <= read_issue_decoder;
      end

      if (dma_read_data_fire && dma_read_data_tlast) begin
        task_src_addr[read_service_decoder] <= task_src_addr[read_service_decoder]
            + read_chunk_len[read_service_decoder];
        task_src_len[read_service_decoder] <= task_src_len[read_service_decoder]
            - read_chunk_len[read_service_decoder];
        read_chunk_active[read_service_decoder] <= 1'b0;
        read_stream_done[read_service_decoder] <=
            (task_src_len[read_service_decoder] == read_chunk_len[read_service_decoder]);
        read_service_active <= 1'b0;
      end

      if (write_desc_fire) begin
        write_chunk_active[write_issue_decoder] <= 1'b1;
        write_chunk_data_done[write_issue_decoder] <= 1'b0;
        write_chunk_len[write_issue_decoder] <= next_write_desc_len[write_issue_decoder];
        write_chunk_bytes_sent[write_issue_decoder] <= '0;
        write_service_active <= 1'b1;
        write_service_decoder <= write_issue_decoder;
      end

      if (dma_write_data_fire) begin
        write_chunk_bytes_sent[write_service_decoder] <=
            write_chunk_bytes_sent[write_service_decoder] + active_out_fifo_tkeep_count;
        if (dma_write_data_tlast) begin
          write_chunk_data_done[write_service_decoder] <= 1'b1;
        end
      end

      if (dma_write_desc_status_valid) begin
        task_dst_addr[dma_write_status_decoder] <= task_dst_addr[dma_write_status_decoder]
            + write_chunk_len[dma_write_status_decoder];
        write_bytes_remaining[dma_write_status_decoder] <=
            write_bytes_remaining[dma_write_status_decoder] - write_chunk_len[dma_write_status_decoder];
        write_chunk_active[dma_write_status_decoder] <= 1'b0;
        write_chunk_data_done[dma_write_status_decoder] <= 1'b0;
        write_chunk_len[dma_write_status_decoder] <= 64'd0;
        write_chunk_bytes_sent[dma_write_status_decoder] <= '0;
        write_stream_done[dma_write_status_decoder] <=
            (write_bytes_remaining[dma_write_status_decoder] == write_chunk_len[dma_write_status_decoder]);
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
      .AXIS_ID_WIDTH(AXI_DMA_ID_WIDTH),
      .AXIS_DEST_ENABLE(0),
      .AXIS_USER_ENABLE(0),
      .LEN_WIDTH(AXI_DMA_LEN_WIDTH),
      .TAG_WIDTH(DECODER_IDX_WIDTH),
      .ENABLE_SG(0),
      .ENABLE_UNALIGNED(0)
  ) dma_inst (
      .clk(clk),
      .rst(rst),
      .s_axis_read_desc_addr(dma_read_desc_addr),
      .s_axis_read_desc_len(dma_read_desc_len),
      .s_axis_read_desc_tag(read_issue_decoder),
      .s_axis_read_desc_id(decoder_axi_id(read_issue_decoder)),
      .s_axis_read_desc_dest(),
      .s_axis_read_desc_user(),
      .s_axis_read_desc_valid(dma_read_desc_valid),
      .s_axis_read_desc_ready(dma_read_desc_ready),
      .m_axis_read_desc_status_tag(dma_read_desc_status_tag),
      .m_axis_read_desc_status_error(dma_read_desc_status_error),
      .m_axis_read_desc_status_valid(dma_read_desc_status_valid),
      .m_axis_read_data_tdata(dma_read_data_tdata),
      .m_axis_read_data_tkeep(dma_read_data_tkeep),
      .m_axis_read_data_tvalid(dma_read_data_tvalid),
      .m_axis_read_data_tready(dma_read_data_tready),
      .m_axis_read_data_tlast(dma_read_data_tlast),
      .m_axis_read_data_tid(dma_read_data_tid),
      .m_axis_read_data_tdest(),
      .m_axis_read_data_tuser(),
      .s_axis_write_desc_addr(dma_write_desc_addr),
      .s_axis_write_desc_len(dma_write_desc_len),
      .s_axis_write_desc_tag(write_issue_decoder),
      .s_axis_write_desc_valid(dma_write_desc_valid),
      .s_axis_write_desc_ready(dma_write_desc_ready),
      .m_axis_write_desc_status_len(dma_write_desc_status_len),
      .m_axis_write_desc_status_tag(dma_write_desc_status_tag),
      .m_axis_write_desc_status_id(dma_write_desc_status_id),
      .m_axis_write_desc_status_dest(),
      .m_axis_write_desc_status_user(),
      .m_axis_write_desc_status_error(dma_write_desc_status_error),
      .m_axis_write_desc_status_valid(dma_write_desc_status_valid),
      .s_axis_write_data_tdata(dma_write_data_tdata),
      .s_axis_write_data_tkeep(dma_write_data_tkeep),
      .s_axis_write_data_tvalid(dma_write_data_tvalid),
      .s_axis_write_data_tready(dma_write_data_tready),
      .s_axis_write_data_tlast(dma_write_data_tlast),
      .s_axis_write_data_tid(dma_write_data_tid),
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

  genvar g;
  generate
    for (g = 0; g < JPEG_NUM_DECODERS; g = g + 1) begin : gen_decoder
      // Each decoder gets private input/output buffering and a dedicated core instance.
      assign core_rst[g] = rst || mmio_reset_pulse || core_reset_pulse[g];

      axis_fifo #(
          .DEPTH(INPUT_FIFO_DEPTH_BYTES),
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
          .rst(core_rst[g]),
          .s_axis_tdata(dma_read_data_tdata),
          .s_axis_tkeep(dma_read_data_tkeep),
          .s_axis_tvalid(dma_read_data_tvalid && (dma_read_data_tid == decoder_axi_id(DECODER_IDX_WIDTH'(g)))),
          .s_axis_tready(in_fifo_dma_tready[g]),
          .s_axis_tlast(dma_read_data_tlast),
          .s_axis_tid(),
          .s_axis_tdest(),
          .s_axis_tuser(),
          .m_axis_tdata(in_fifo_tdata[g]),
          .m_axis_tkeep(in_fifo_tkeep[g]),
          .m_axis_tvalid(in_fifo_tvalid[g]),
          .m_axis_tready(in_fifo_tready[g]),
          .m_axis_tlast(in_fifo_tlast[g]),
          .m_axis_tid(),
          .m_axis_tdest(),
          .m_axis_tuser(),
          .pause_req(1'b0),
          .pause_ack(),
          .status_depth(input_fifo_occupied_len[g]),
          .status_depth_commit(),
          .status_overflow(),
          .status_bad_frame(),
          .status_good_frame()
      );

      jpeg_core_wrapper #(
          .JPEG_SUPPORT_WRITABLE_DHT(JPEG_SUPPORT_WRITABLE_DHT),
          .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
          .AXIS_KEEP_WIDTH(AXIS_KEEP_WIDTH)
      ) jpeg_core_inst (
          .clk(clk),
          .rst(core_rst[g]),
          .s_axis_tdata(in_fifo_tdata[g]),
          .s_axis_tkeep(in_fifo_tkeep[g]),
          .s_axis_tvalid(in_fifo_tvalid[g]),
          .s_axis_tready(in_fifo_tready[g]),
          .s_axis_tlast(in_fifo_tlast[g]),
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

      assign core_out_tready[g] = out_fifo_tready[g];

      axis_fifo #(
          .DEPTH(OUTPUT_FIFO_DEPTH_BYTES),
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
      ) output_fifo (
          .clk(clk),
          .rst(core_rst[g]),
          .s_axis_tdata(core_out_tdata[g]),
          .s_axis_tkeep(core_out_tkeep[g]),
          .s_axis_tvalid(core_out_tvalid[g]),
          .s_axis_tready(out_fifo_tready[g]),
          .s_axis_tlast(core_out_tlast[g]),
          .s_axis_tid(),
          .s_axis_tdest(),
          .s_axis_tuser(1'b0),
          .m_axis_tdata(out_fifo_tdata[g]),
          .m_axis_tkeep(out_fifo_tkeep[g]),
          .m_axis_tvalid(out_fifo_tvalid[g]),
          .m_axis_tready(out_fifo_tready_dma[g]),
          .m_axis_tlast(out_fifo_tlast[g]),
          .m_axis_tid(),
          .m_axis_tdest(),
          .m_axis_tuser(),
          .pause_req(1'b0),
          .pause_ack(),
          .status_depth(output_fifo_occupied_len[g]),
          .status_depth_commit(),
          .status_overflow(),
          .status_bad_frame(),
          .status_good_frame()
      );

      assign out_fifo_tready_dma[g] = write_service_active && (write_service_decoder == DECODER_IDX_WIDTH'(g))
          && write_chunk_active[g] && !write_chunk_data_done[g] && dma_write_data_tready;
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Completion push
  // --------------------------------------------------------------------------

  always_comb begin
    cpl_fifo_push_data = 64'd0;
    if (write_status_is_final) begin
      cpl_fifo_push_data[15:0]  = 16'd1;
      cpl_fifo_push_data[31:16] = task_id[dma_write_status_decoder];
      cpl_fifo_push_data[47:32] = img_width[dma_write_status_decoder];
      cpl_fifo_push_data[63:48] = img_height[dma_write_status_decoder];
    end
  end

  assign cpl_fifo_push = write_status_is_final;

endmodule

`default_nettype wire
