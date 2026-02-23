`timescale 1ns / 1ps
`include "jpeg_params.svh"

module m_axil_adapter(
    input clk,
    output reg [`JPEG_MMIO_BITS_ADDR-1:0] m_axil_awaddr,
    output reg [2:0] m_axil_awprot,
    output reg m_axil_awvalid,
    input m_axil_awready,
    output reg [63:0] m_axil_wdata,
    output reg [7:0] m_axil_wstrb,
    output reg m_axil_wvalid,
    input m_axil_wready,
    input [1:0] m_axil_bresp,
    input m_axil_bvalid,
    output reg m_axil_bready,
    output reg [`JPEG_MMIO_BITS_ADDR-1:0] m_axil_araddr,
    output reg [2:0] m_axil_arprot,
    output reg m_axil_arvalid,
    input m_axil_arready,
    input [63:0] m_axil_rdata,
    input [1:0] m_axil_rresp,
    input m_axil_rvalid,
    output reg m_axil_rready
);
    typedef logic [2:0] dpi3_t;
    typedef logic [7:0] dpi8_t;

    import "DPI-C" function void m_axil_adapter_step(
        output int dpi_awaddr,
        output byte dpi_awprot,
        output bit dpi_awvalid,
        input bit dpi_awready,
        output longint dpi_wdata,
        output byte dpi_wstrb,
        output bit dpi_wvalid,
        input bit dpi_wready,
        input byte dpi_bresp,
        input bit dpi_bvalid,
        output bit dpi_bready,
        output int dpi_araddr,
        output byte dpi_arprot,
        output bit dpi_arvalid,
        input bit dpi_arready,
        input longint dpi_rdata,
        input byte dpi_rresp,
        input bit dpi_rvalid,
        output bit dpi_rready
    );

    always @(posedge clk) begin
        int dpi_awaddr;
        byte dpi_awprot;
        bit dpi_awvalid;
        longint dpi_wdata;
        byte dpi_wstrb;
        bit dpi_wvalid;
        bit dpi_bready;
        int dpi_araddr;
        byte dpi_arprot;
        bit dpi_arvalid;
        bit dpi_rready;

        m_axil_adapter_step(
            dpi_awaddr,
            dpi_awprot,
            dpi_awvalid,
            m_axil_awready,
            dpi_wdata,
            dpi_wstrb,
            dpi_wvalid,
            m_axil_wready,
            byte'(m_axil_bresp),
            m_axil_bvalid,
            dpi_bready,
            dpi_araddr,
            dpi_arprot,
            dpi_arvalid,
            m_axil_arready,
            m_axil_rdata,
            byte'(m_axil_rresp),
            m_axil_rvalid,
            dpi_rready
        );

        m_axil_awaddr <= dpi_awaddr;
        m_axil_awprot <= dpi3_t'(dpi_awprot);
        m_axil_awvalid <= dpi_awvalid;
        m_axil_wdata <= dpi_wdata;
        m_axil_wstrb <= dpi8_t'(dpi_wstrb);
        m_axil_wvalid <= dpi_wvalid;
        m_axil_bready <= dpi_bready;
        m_axil_araddr <= dpi_araddr;
        m_axil_arprot <= dpi3_t'(dpi_arprot);
        m_axil_arvalid <= dpi_arvalid;
        m_axil_rready <= dpi_rready;
    end

endmodule
