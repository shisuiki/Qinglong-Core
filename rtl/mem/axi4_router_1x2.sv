// Sim-only behavioral 1×2 AXI4 router.
//
// On synth this slot is replaced by Vivado axi_crossbar IP plus per-Lite-slave
// axi_protocol_converter wrappers. This module exists so the sim build can
// exercise the upstream AXI4-full master (axi4_master.sv) end-to-end without
// pulling Vivado IP simulation models into Verilator.
//
// Master port: AXI4-full (single-beat, single-outstanding — matches what
// axi4_master emits today; len/burst tracking is intentionally not
// implemented — when 7c adds D-cache bursts, this module gets revisited).
// Slave ports: AXI4-Lite. The router drops master-side ID/LEN/LAST/etc and
// presents pure Lite to each slave.
//
// Address decode uses bit [12] within the 0xC000_xxxx window:
//   Slave 0 — 0xC000_0000 .. 0xC000_0FFF
//   Slave 1 — 0xC000_1000 .. 0xC000_1FFF
//
// Anything outside (or addr[15:13] != 0) returns DECERR via the internal stub.

module axi4_router_1x2 #(
    parameter int unsigned ID_W = 4
) (
    input  logic clk,
    input  logic rst,

    // ---- AXI4-full master port (from axi4_master) ----
    input  logic              m_axi_awvalid,
    output logic              m_axi_awready,
    input  logic [31:0]       m_axi_awaddr,
    input  logic [ID_W-1:0]   m_axi_awid,
    input  logic [7:0]        m_axi_awlen,
    input  logic [2:0]        m_axi_awsize,
    input  logic [1:0]        m_axi_awburst,
    input  logic              m_axi_awlock,
    input  logic [3:0]        m_axi_awcache,
    input  logic [2:0]        m_axi_awprot,
    input  logic [3:0]        m_axi_awqos,

    input  logic              m_axi_wvalid,
    output logic              m_axi_wready,
    input  logic [31:0]       m_axi_wdata,
    input  logic [3:0]        m_axi_wstrb,
    input  logic              m_axi_wlast,

    output logic              m_axi_bvalid,
    input  logic              m_axi_bready,
    output logic [ID_W-1:0]   m_axi_bid,
    output logic [1:0]        m_axi_bresp,

    input  logic              m_axi_arvalid,
    output logic              m_axi_arready,
    input  logic [31:0]       m_axi_araddr,
    input  logic [ID_W-1:0]   m_axi_arid,
    input  logic [7:0]        m_axi_arlen,
    input  logic [2:0]        m_axi_arsize,
    input  logic [1:0]        m_axi_arburst,
    input  logic              m_axi_arlock,
    input  logic [3:0]        m_axi_arcache,
    input  logic [2:0]        m_axi_arprot,
    input  logic [3:0]        m_axi_arqos,

    output logic              m_axi_rvalid,
    input  logic              m_axi_rready,
    output logic [ID_W-1:0]   m_axi_rid,
    output logic [31:0]       m_axi_rdata,
    output logic [1:0]        m_axi_rresp,
    output logic              m_axi_rlast,

    // ---- 2× AXI4-Lite slave ports ----
    output logic              s0_axil_awvalid, s1_axil_awvalid,
    input  logic              s0_axil_awready, s1_axil_awready,
    output logic [31:0]       s0_axil_awaddr,  s1_axil_awaddr,
    output logic [2:0]        s0_axil_awprot,  s1_axil_awprot,

    output logic              s0_axil_wvalid,  s1_axil_wvalid,
    input  logic              s0_axil_wready,  s1_axil_wready,
    output logic [31:0]       s0_axil_wdata,   s1_axil_wdata,
    output logic [3:0]        s0_axil_wstrb,   s1_axil_wstrb,

    input  logic              s0_axil_bvalid,  s1_axil_bvalid,
    output logic              s0_axil_bready,  s1_axil_bready,
    input  logic [1:0]        s0_axil_bresp,   s1_axil_bresp,

    output logic              s0_axil_arvalid, s1_axil_arvalid,
    input  logic              s0_axil_arready, s1_axil_arready,
    output logic [31:0]       s0_axil_araddr,  s1_axil_araddr,
    output logic [2:0]        s0_axil_arprot,  s1_axil_arprot,

    input  logic              s0_axil_rvalid,  s1_axil_rvalid,
    output logic              s0_axil_rready,  s1_axil_rready,
    input  logic [31:0]       s0_axil_rdata,   s1_axil_rdata,
    input  logic [1:0]        s0_axil_rresp,   s1_axil_rresp
);

    // 0/1 → mapped slave index; 2 → DECERR (unmapped).
    function automatic logic [1:0] decode (input logic [31:0] addr);
        if (addr[31:16] != 16'hC000) return 2'd2;
        if (addr[15:13] != 3'd0)     return 2'd2;
        return {1'b0, addr[12]};
    endfunction

    logic [1:0] sel_w_q, sel_r_q;
    logic       sel_w_valid_q, sel_r_valid_q;

    wire [1:0] sel_w_now = decode(m_axi_awaddr);
    wire [1:0] sel_r_now = decode(m_axi_araddr);
    wire [1:0] sel_w_eff = sel_w_valid_q ? sel_w_q : sel_w_now;

    // -------- Internal DECERR stub --------
    logic d_aw_q, d_w_q, d_b_q;
    logic d_ar_q, d_r_q;
    wire  d_awready = !d_aw_q;
    wire  d_wready  = !d_w_q;
    wire  d_arready = !d_ar_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            d_aw_q <= 1'b0; d_w_q <= 1'b0; d_b_q <= 1'b0;
            d_ar_q <= 1'b0; d_r_q <= 1'b0;
        end else begin
            if (m_axi_awvalid && d_awready && (sel_w_now == 2'd2)) d_aw_q <= 1'b1;
            if (m_axi_wvalid  && d_wready  && (sel_w_eff == 2'd2)) d_w_q  <= 1'b1;
            if (d_aw_q && d_w_q && !d_b_q) d_b_q <= 1'b1;
            if (d_b_q && m_axi_bready && (sel_w_q == 2'd2)) begin
                d_b_q <= 1'b0; d_aw_q <= 1'b0; d_w_q <= 1'b0;
            end
            if (m_axi_arvalid && d_arready && (sel_r_now == 2'd2)) d_ar_q <= 1'b1;
            if (d_ar_q && !d_r_q) d_r_q <= 1'b1;
            if (d_r_q && m_axi_rready && (sel_r_q == 2'd2)) begin
                d_r_q <= 1'b0; d_ar_q <= 1'b0;
            end
        end
    end

    // -------- AW fan-out --------
    assign s0_axil_awvalid = m_axi_awvalid && (sel_w_now == 2'd0);
    assign s1_axil_awvalid = m_axi_awvalid && (sel_w_now == 2'd1);
    assign s0_axil_awaddr  = m_axi_awaddr; assign s0_axil_awprot = m_axi_awprot;
    assign s1_axil_awaddr  = m_axi_awaddr; assign s1_axil_awprot = m_axi_awprot;

    assign m_axi_awready =
        (sel_w_now == 2'd0) ? s0_axil_awready :
        (sel_w_now == 2'd1) ? s1_axil_awready :
                              d_awready;

    // -------- W fan-out --------
    assign s0_axil_wvalid = m_axi_wvalid && (sel_w_eff == 2'd0);
    assign s1_axil_wvalid = m_axi_wvalid && (sel_w_eff == 2'd1);
    assign s0_axil_wdata  = m_axi_wdata; assign s0_axil_wstrb = m_axi_wstrb;
    assign s1_axil_wdata  = m_axi_wdata; assign s1_axil_wstrb = m_axi_wstrb;

    assign m_axi_wready =
        (sel_w_eff == 2'd0) ? s0_axil_wready :
        (sel_w_eff == 2'd1) ? s1_axil_wready :
                              d_wready;

    // -------- B funnel --------
    always_ff @(posedge clk) begin
        if (rst) begin
            sel_w_q       <= 2'd0;
            sel_w_valid_q <= 1'b0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                sel_w_q       <= sel_w_now;
                sel_w_valid_q <= 1'b1;
            end else if (m_axi_bvalid && m_axi_bready) begin
                sel_w_valid_q <= 1'b0;
            end
        end
    end

    wire b_real_valid =
        (sel_w_q == 2'd0) ? s0_axil_bvalid :
        (sel_w_q == 2'd1) ? s1_axil_bvalid :
                            d_b_q;
    wire [1:0] b_real_resp =
        (sel_w_q == 2'd0) ? s0_axil_bresp :
        (sel_w_q == 2'd1) ? s1_axil_bresp :
                            2'b11;          // DECERR
    assign m_axi_bvalid = sel_w_valid_q ? b_real_valid : 1'b0;
    assign m_axi_bresp  = sel_w_valid_q ? b_real_resp  : 2'b00;
    assign m_axi_bid    = '0;

    assign s0_axil_bready = sel_w_valid_q && (sel_w_q == 2'd0) && m_axi_bready;
    assign s1_axil_bready = sel_w_valid_q && (sel_w_q == 2'd1) && m_axi_bready;

    // -------- AR fan-out --------
    assign s0_axil_arvalid = m_axi_arvalid && (sel_r_now == 2'd0);
    assign s1_axil_arvalid = m_axi_arvalid && (sel_r_now == 2'd1);
    assign s0_axil_araddr  = m_axi_araddr; assign s0_axil_arprot = m_axi_arprot;
    assign s1_axil_araddr  = m_axi_araddr; assign s1_axil_arprot = m_axi_arprot;

    assign m_axi_arready =
        (sel_r_now == 2'd0) ? s0_axil_arready :
        (sel_r_now == 2'd1) ? s1_axil_arready :
                              d_arready;

    // -------- R funnel --------
    always_ff @(posedge clk) begin
        if (rst) begin
            sel_r_q       <= 2'd0;
            sel_r_valid_q <= 1'b0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                sel_r_q       <= sel_r_now;
                sel_r_valid_q <= 1'b1;
            end else if (m_axi_rvalid && m_axi_rready) begin
                sel_r_valid_q <= 1'b0;
            end
        end
    end

    wire r_real_valid =
        (sel_r_q == 2'd0) ? s0_axil_rvalid :
        (sel_r_q == 2'd1) ? s1_axil_rvalid :
                            d_r_q;
    wire [31:0] r_real_data =
        (sel_r_q == 2'd0) ? s0_axil_rdata :
        (sel_r_q == 2'd1) ? s1_axil_rdata :
                            32'd0;
    wire [1:0] r_real_resp =
        (sel_r_q == 2'd0) ? s0_axil_rresp :
        (sel_r_q == 2'd1) ? s1_axil_rresp :
                            2'b11;          // DECERR
    assign m_axi_rvalid = sel_r_valid_q ? r_real_valid : 1'b0;
    assign m_axi_rdata  = sel_r_valid_q ? r_real_data  : 32'd0;
    assign m_axi_rresp  = sel_r_valid_q ? r_real_resp  : 2'b00;
    assign m_axi_rid    = '0;
    assign m_axi_rlast  = m_axi_rvalid;

    assign s0_axil_rready = sel_r_valid_q && (sel_r_q == 2'd0) && m_axi_rready;
    assign s1_axil_rready = sel_r_valid_q && (sel_r_q == 2'd1) && m_axi_rready;

endmodule
