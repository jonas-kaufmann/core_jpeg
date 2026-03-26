`timescale 1ns / 1ps
`default_nettype none

module jpeg_rgb_repacker #(
    parameter unsigned AXIS_DATA_WIDTH = 512,
    parameter unsigned AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH / 8
) (
    input wire clk,
    input wire rst,

    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0] m_axis_tkeep,
    output wire                       m_axis_tvalid,
    input  wire                       m_axis_tready,
    output wire                       m_axis_tlast
);

  localparam int QUEUE_DATA_WIDTH = AXIS_DATA_WIDTH + 24;
  localparam int COUNT_WIDTH = $clog2(AXIS_KEEP_WIDTH + 4);

  function automatic [AXIS_KEEP_WIDTH-1:0] keep_mask(input int unsigned count);
    int i;
    begin
      keep_mask = '0;
      for (i = 0; i < AXIS_KEEP_WIDTH; i = i + 1) begin
        keep_mask[i] = i < count;
      end
    end
  endfunction

  logic [QUEUE_DATA_WIDTH-1:0] queue_data_reg = '0;
  logic [COUNT_WIDTH-1:0] byte_count_reg = '0;
  logic frame_last_reg = 1'b0;

  logic [QUEUE_DATA_WIDTH-1:0] queue_data_next;
  logic [COUNT_WIDTH-1:0] byte_count_next;
  logic frame_last_next;

  wire have_output = (byte_count_reg >= AXIS_KEEP_WIDTH) || (frame_last_reg && (byte_count_reg != 0));
  wire [$clog2(
AXIS_KEEP_WIDTH + 1
)-1:0] output_byte_count = byte_count_reg >= AXIS_KEEP_WIDTH ? AXIS_KEEP_WIDTH :
      byte_count_reg[$clog2(
      AXIS_KEEP_WIDTH+1
  )-1:0];
  wire output_fire = have_output && m_axis_tready;

  assign s_axis_tready = !frame_last_reg &&
      ((byte_count_reg <= AXIS_KEEP_WIDTH-1) || output_fire);

  assign m_axis_tdata = queue_data_reg[AXIS_DATA_WIDTH-1:0];
  assign m_axis_tkeep = keep_mask(output_byte_count);
  assign m_axis_tvalid = have_output;
  assign m_axis_tlast = frame_last_reg && (byte_count_reg <= AXIS_KEEP_WIDTH);

  always_comb begin
    int unsigned emitted_bytes;

    emitted_bytes   = 0;
    queue_data_next = queue_data_reg;
    byte_count_next = byte_count_reg;
    frame_last_next = frame_last_reg;

    if (output_fire) begin
      emitted_bytes   = byte_count_reg >= AXIS_KEEP_WIDTH ? AXIS_KEEP_WIDTH : byte_count_reg;
      queue_data_next = queue_data_reg >> (emitted_bytes * 8);
      byte_count_next = byte_count_reg - emitted_bytes;
      if (frame_last_reg && (byte_count_reg <= AXIS_KEEP_WIDTH)) begin
        frame_last_next = 1'b0;
      end
    end

    if (s_axis_tvalid && s_axis_tready) begin
      queue_data_next[byte_count_next*8+:24] = s_axis_tdata;
      byte_count_next = byte_count_next + 3;
      if (s_axis_tlast) begin
        frame_last_next = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      queue_data_reg <= '0;
      byte_count_reg <= '0;
      frame_last_reg <= 1'b0;
    end else begin
      queue_data_reg <= queue_data_next;
      byte_count_reg <= byte_count_next;
      frame_last_reg <= frame_last_next;
    end
  end

endmodule

`default_nettype wire
