`timescale 1ns / 1ps
`include "jpeg_params.vh"

module s_axi_adapter(
    input clk,
    input [7:0] s_axi_awid,
    input [63:0] s_axi_awaddr,
    input [7:0] s_axi_awlen,
    input [2:0] s_axi_awsize,
    input [1:0] s_axi_awburst,
    input s_axi_awvalid,
    output reg s_axi_awready,
    input [`JPEG_DMA_BITS_DATA-1:0] s_axi_wdata,
    input [`JPEG_DMA_BYTES_DATA-1:0] s_axi_wstrb,
    input s_axi_wlast,
    input s_axi_wvalid,
    output reg s_axi_wready,
    output reg [7:0] s_axi_bid,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input s_axi_bready,
    input [7:0] s_axi_arid,
    input [63:0] s_axi_araddr,
    input [7:0] s_axi_arlen,
    input [2:0] s_axi_arsize,
    input [1:0] s_axi_arburst,
    input s_axi_arvalid,
    output reg s_axi_arready,
    output reg [7:0] s_axi_rid,
    output reg [`JPEG_DMA_BITS_DATA-1:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rlast,
    output reg s_axi_rvalid,
    input s_axi_rready
);

    typedef logic [1:0] dpi2_t;

    byte dpi_wdata[`JPEG_DMA_BYTES_DATA];
    for (genvar i = 0; i < `JPEG_DMA_BYTES_DATA; i = i + 1) begin: gen_wdata_assign
        assign dpi_wdata[i] = s_axi_wdata[i * 8 +: 8];
    end

    byte dpi_wstrb[`JPEG_DMA_BYTES_DATA/8];
    for (genvar i = 0; i < `JPEG_DMA_BYTES_DATA/8; i = i + 1) begin : gen_wstrb_assign
        assign dpi_wstrb[i] = s_axi_wstrb[i * 8 +: 8];
    end

    import "DPI-C" function void s_axi_adapter_step(
        input byte dpi_awid,
        input longint dpi_awaddr,
        input byte dpi_awlen,
        input byte dpi_awsize,
        input byte dpi_awburst,
        input bit dpi_awvalid,
        output bit dpi_awready,
        input byte dpi_wdata[`JPEG_DMA_BYTES_DATA],
        input byte dpi_wstrb[`JPEG_DMA_BYTES_DATA/8],
        input bit dpi_wlast,
        input bit dpi_wvalid,
        output bit dpi_wready,
        output byte dpi_bid,
        output byte dpi_bresp,
        output bit dpi_bvalid,
        input bit dpi_bready,
        input byte dpi_arid,
        input longint dpi_araddr,
        input byte dpi_arlen,
        input byte dpi_arsize,
        input byte dpi_arburst,
        input bit dpi_arvalid,
        output bit dpi_arready,
        output byte dpi_rid,
        output byte dpi_rdata[`JPEG_DMA_BYTES_DATA],
        output byte dpi_rresp,
        output bit dpi_rlast,
        output bit dpi_rvalid,
        input bit dpi_rready
    );

    always @(posedge clk) begin
        bit dpi_awready;
        bit dpi_wready;
        byte dpi_bid;
        byte dpi_bresp;
        bit dpi_bvalid;
        bit dpi_arready;
        byte dpi_rid;
        byte dpi_rdata[`JPEG_DMA_BYTES_DATA];
        byte dpi_rresp;
        bit dpi_rlast;
        bit dpi_rvalid;

        s_axi_adapter_step(
            s_axi_awid,
            s_axi_awaddr,
            s_axi_awlen,
            byte'(s_axi_awsize),
            byte'(s_axi_awburst),
            s_axi_awvalid,
            dpi_awready,
            dpi_wdata,
            dpi_wstrb,
            s_axi_wlast,
            s_axi_wvalid,
            dpi_wready,
            dpi_bid,
            dpi_bresp,
            dpi_bvalid,
            s_axi_bready,
            s_axi_arid,
            s_axi_araddr,
            s_axi_arlen,
            byte'(s_axi_arsize),
            byte'(s_axi_arburst),
            s_axi_arvalid,
            dpi_arready,
            dpi_rid,
            dpi_rdata,
            dpi_rresp,
            dpi_rlast,
            dpi_rvalid,
            s_axi_rready
        );

        s_axi_awready <= dpi_awready;
        s_axi_wready <= dpi_wready;
        s_axi_bid <= dpi_bid;
        s_axi_bresp <= dpi2_t'(dpi_bresp);
        s_axi_bvalid <= dpi_bvalid;
        s_axi_arready <= dpi_arready;
        s_axi_rid <= dpi_rid;
        for (integer i = 0; i < `JPEG_DMA_BYTES_DATA; i = i + 1) begin
            s_axi_rdata[8 * i +: 8] <= dpi_rdata[i];
        end
        s_axi_rresp <= dpi2_t'(dpi_rresp);
        s_axi_rlast <= dpi_rlast;
        s_axi_rvalid <= dpi_rvalid;
    end

endmodule
