`timescale 1ns / 1ps
`default_nettype none

module jpeg_core_wrapper #(
    parameter unsigned JPEG_SUPPORT_WRITABLE_DHT = 1,
    parameter unsigned AXIS_DATA_WIDTH = 512,
    parameter unsigned AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH / 8
) (
    input wire clk,
    input wire rst,

    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0] s_axis_tkeep,
    input  wire                       s_axis_tvalid,
    output wire                       s_axis_tready,
    input  wire                       s_axis_tlast,

    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0] m_axis_tkeep,
    output wire                       m_axis_tvalid,
    input  wire                       m_axis_tready,
    output wire                       m_axis_tlast,

    output logic        out_dims_valid,
    output wire  [15:0] out_width,
    output wire  [15:0] out_height,
    output wire         idle
);

  wire [31:0] core_in_data;
  wire [3:0] core_in_strb;
  wire core_in_valid;
  wire core_in_ready;
  wire core_in_last;

  wire core_out_valid;
  wire [15:0] core_out_width;
  wire [15:0] core_out_height;
  wire [15:0] core_out_x;
  wire [15:0] core_out_y;
  wire [7:0] core_out_r;
  wire [7:0] core_out_g;
  wire [7:0] core_out_b;
  wire core_out_accept;
  wire core_out_last = (core_out_x == core_out_width - 1'b1) && (core_out_y == core_out_height - 1'b1);

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
      .s_axis_tdata(s_axis_tdata),
      .s_axis_tkeep(s_axis_tkeep),
      .s_axis_tvalid(s_axis_tvalid),
      .s_axis_tready(s_axis_tready),
      .s_axis_tlast(s_axis_tlast),
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
      .idle_o(idle)
  );

  jpeg_rgb_repacker #(
      .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
      .AXIS_KEEP_WIDTH(AXIS_KEEP_WIDTH)
  ) out_repacker (
      .clk(clk),
      .rst(rst),
      .s_axis_tdata({core_out_b, core_out_g, core_out_r}),
      .s_axis_tvalid(core_out_valid),
      .s_axis_tready(core_out_accept),
      .s_axis_tlast(core_out_last),
      .m_axis_tdata(m_axis_tdata),
      .m_axis_tkeep(m_axis_tkeep),
      .m_axis_tvalid(m_axis_tvalid),
      .m_axis_tready(m_axis_tready),
      .m_axis_tlast(m_axis_tlast)
  );

  assign out_width  = core_out_width;
  assign out_height = core_out_height;

  always_ff @(posedge clk) begin
    if (rst) begin
      out_dims_valid <= 1'b0;
    end else begin
      out_dims_valid <= core_out_valid && core_out_accept && (core_out_x == 16'd0) && (core_out_y == 16'd0);
    end
  end

endmodule

`default_nettype wire
