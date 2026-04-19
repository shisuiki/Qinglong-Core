// -----------------------------------------------------------------------------
// axi_hello_top.sv
// RealDigital Urbana (xc7s50csga324-1) Stage 5 AXI bringup top.
//
// soc_top exports an AXI4-full master (Stage 7a refactor — single-beat for
// now). Vivado's free axi_protocol_converter IP downgrades it to AXI4-Lite
// before feeding axi_uartlite_0. The legacy MMIO console (0xD058_0000) is
// left in place but not pinned out — software drives the TX line through
// UartLite @ 0xC000_0000.
//
// On-board serial bridge:
//   uart_tx_pin → A16 = host RX (FPGA OUTPUT)
//   uart_rx_pin ← B16 = host TX (FPGA INPUT)
//
// LEDs keep the same hello_top semantics (heartbeat, lock, reset, commit,
// exit, console-seen, tx line).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module axi_hello_top #(
    parameter SRAM_INIT_FILE = ""
)(
    input  wire        clk,            // 100 MHz (N15)
    input  wire        rst_n,          // BTN0, active-low (J2)
    output wire        uart_tx_pin,    // A16 → host RX
    input  wire        uart_rx_pin,    // B16 ← host TX
    output wire [7:0]  led
);

    // ---------- MMCM 100 → 50 MHz ----------
    wire core_clk;
    wire mmcm_clkfb;
    wire mmcm_locked;
    wire mmcm_clkout0;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKIN1_PERIOD     (10.000),
        .DIVCLK_DIVIDE     (1),
        .CLKFBOUT_MULT_F   (10.000),
        .CLKOUT0_DIVIDE_F  (20.000),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE     (0.000),
        .STARTUP_WAIT      ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk),
        .CLKFBIN  (mmcm_clkfb),
        .CLKFBOUT (mmcm_clkfb),
        .CLKOUT0  (mmcm_clkout0),
        .LOCKED   (mmcm_locked),
        .RST      (1'b0),
        .PWRDWN   (1'b0)
    );

    BUFG u_bufg_core (.I(mmcm_clkout0), .O(core_clk));

    // ---------- PSR-style reset sync ----------
    wire rst_async = !rst_n || !mmcm_locked;

    (* ASYNC_REG = "TRUE" *) reg rst_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_sync = 1'b1;

    always_ff @(posedge core_clk or posedge rst_async) begin
        if (rst_async) begin
            rst_meta <= 1'b1;
            rst_sync <= 1'b1;
        end else begin
            rst_meta <= 1'b0;
            rst_sync <= rst_meta;
        end
    end
    wire rstn_sync = !rst_sync;   // IP cores expect active-low resetn

    // ---------- AXI4-full master (from soc_top) ----------
    wire        m_axi_awvalid, m_axi_awready;
    wire [31:0] m_axi_awaddr;
    wire [3:0]  m_axi_awid;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awlock;
    wire [3:0]  m_axi_awcache;
    wire [2:0]  m_axi_awprot;
    wire [3:0]  m_axi_awqos;
    wire        m_axi_wvalid, m_axi_wready;
    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_bvalid, m_axi_bready;
    wire [3:0]  m_axi_bid;
    wire [1:0]  m_axi_bresp;
    wire        m_axi_arvalid, m_axi_arready;
    wire [31:0] m_axi_araddr;
    wire [3:0]  m_axi_arid;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arlock;
    wire [3:0]  m_axi_arcache;
    wire [2:0]  m_axi_arprot;
    wire [3:0]  m_axi_arqos;
    wire        m_axi_rvalid, m_axi_rready;
    wire [3:0]  m_axi_rid;
    wire [31:0] m_axi_rdata;
    wire [1:0]  m_axi_rresp;
    wire        m_axi_rlast;

    // ---------- SoC ----------
    wire        console_valid;   // legacy MMIO console byte (debug/ILA)
    wire [7:0]  console_byte;
    wire        console_ready = 1'b1;
    wire        exit_valid;
    wire [31:0] exit_code;

    wire        commit_valid;
    wire [31:0] commit_pc, commit_insn, commit_rd_data, commit_cause;
    wire        commit_rd_wen, commit_trap;
    wire [4:0]  commit_rd_addr;

    soc_top #(
        .SRAM_WORDS     (16384),
        .RESET_PC       (32'h8000_0000),
        .SRAM_INIT_FILE (SRAM_INIT_FILE)
    ) u_soc (
        .clk(core_clk), .rst(rst_sync),

        .console_valid(console_valid), .console_byte(console_byte),
        .console_ready(console_ready),
        .exit_valid(exit_valid), .exit_code(exit_code),

        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awaddr(m_axi_awaddr),   .m_axi_awid(m_axi_awid),
        .m_axi_awlen(m_axi_awlen),     .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_wvalid(m_axi_wvalid),   .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata),     .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid),   .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid),         .m_axi_bresp(m_axi_bresp),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_araddr(m_axi_araddr),   .m_axi_arid(m_axi_arid),
        .m_axi_arlen(m_axi_arlen),     .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_rvalid(m_axi_rvalid),   .m_axi_rready(m_axi_rready),
        .m_axi_rid(m_axi_rid),         .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),     .m_axi_rlast(m_axi_rlast),

        .ext_mei(1'b0),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr),
        .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );

    // ---------- AXI4 → AXI4-Lite protocol converter ----------
    // Vivado free IP. SI = AXI4 (full), MI = AXI4-Lite. Connects soc_top's
    // master to axi_uartlite_0 (Lite-only slave).
    wire        ul_awvalid, ul_awready;
    wire [31:0] ul_awaddr;
    wire [2:0]  ul_awprot;
    wire        ul_wvalid,  ul_wready;
    wire [31:0] ul_wdata;
    wire [3:0]  ul_wstrb;
    wire        ul_bvalid,  ul_bready;
    wire [1:0]  ul_bresp;
    wire        ul_arvalid, ul_arready;
    wire [31:0] ul_araddr;
    wire [2:0]  ul_arprot;
    wire        ul_rvalid,  ul_rready;
    wire [31:0] ul_rdata;
    wire [1:0]  ul_rresp;

    axi_protocol_converter_0 u_proto_conv (
        .aclk    (core_clk),
        .aresetn (rstn_sync),

        // Slave (AXI4-full) — from soc_top
        .s_axi_awid    (m_axi_awid),
        .s_axi_awaddr  (m_axi_awaddr),
        .s_axi_awlen   (m_axi_awlen),
        .s_axi_awsize  (m_axi_awsize),
        .s_axi_awburst (m_axi_awburst),
        .s_axi_awlock  (m_axi_awlock),
        .s_axi_awcache (m_axi_awcache),
        .s_axi_awprot  (m_axi_awprot),
        .s_axi_awqos   (m_axi_awqos),
        .s_axi_awvalid (m_axi_awvalid),
        .s_axi_awready (m_axi_awready),

        .s_axi_wdata   (m_axi_wdata),
        .s_axi_wstrb   (m_axi_wstrb),
        .s_axi_wlast   (m_axi_wlast),
        .s_axi_wvalid  (m_axi_wvalid),
        .s_axi_wready  (m_axi_wready),

        .s_axi_bid     (m_axi_bid),
        .s_axi_bresp   (m_axi_bresp),
        .s_axi_bvalid  (m_axi_bvalid),
        .s_axi_bready  (m_axi_bready),

        .s_axi_arid    (m_axi_arid),
        .s_axi_araddr  (m_axi_araddr),
        .s_axi_arlen   (m_axi_arlen),
        .s_axi_arsize  (m_axi_arsize),
        .s_axi_arburst (m_axi_arburst),
        .s_axi_arlock  (m_axi_arlock),
        .s_axi_arcache (m_axi_arcache),
        .s_axi_arprot  (m_axi_arprot),
        .s_axi_arqos   (m_axi_arqos),
        .s_axi_arvalid (m_axi_arvalid),
        .s_axi_arready (m_axi_arready),

        .s_axi_rid     (m_axi_rid),
        .s_axi_rdata   (m_axi_rdata),
        .s_axi_rresp   (m_axi_rresp),
        .s_axi_rlast   (m_axi_rlast),
        .s_axi_rvalid  (m_axi_rvalid),
        .s_axi_rready  (m_axi_rready),

        // Master (AXI4-Lite) — to axi_uartlite_0
        .m_axi_awaddr  (ul_awaddr),
        .m_axi_awprot  (ul_awprot),
        .m_axi_awvalid (ul_awvalid),
        .m_axi_awready (ul_awready),
        .m_axi_wdata   (ul_wdata),
        .m_axi_wstrb   (ul_wstrb),
        .m_axi_wvalid  (ul_wvalid),
        .m_axi_wready  (ul_wready),
        .m_axi_bresp   (ul_bresp),
        .m_axi_bvalid  (ul_bvalid),
        .m_axi_bready  (ul_bready),
        .m_axi_araddr  (ul_araddr),
        .m_axi_arprot  (ul_arprot),
        .m_axi_arvalid (ul_arvalid),
        .m_axi_arready (ul_arready),
        .m_axi_rdata   (ul_rdata),
        .m_axi_rresp   (ul_rresp),
        .m_axi_rvalid  (ul_rvalid),
        .m_axi_rready  (ul_rready)
    );

    // ---------- AMD AXI UartLite ----------
    wire uartlite_irq;

    axi_uartlite_0 u_uartlite (
        .s_axi_aclk   (core_clk),
        .s_axi_aresetn(rstn_sync),

        .s_axi_awaddr (ul_awaddr[3:0]),
        .s_axi_awvalid(ul_awvalid),
        .s_axi_awready(ul_awready),

        .s_axi_wdata  (ul_wdata),
        .s_axi_wstrb  (ul_wstrb),
        .s_axi_wvalid (ul_wvalid),
        .s_axi_wready (ul_wready),

        .s_axi_bresp  (ul_bresp),
        .s_axi_bvalid (ul_bvalid),
        .s_axi_bready (ul_bready),

        .s_axi_araddr (ul_araddr[3:0]),
        .s_axi_arvalid(ul_arvalid),
        .s_axi_arready(ul_arready),

        .s_axi_rdata  (ul_rdata),
        .s_axi_rresp  (ul_rresp),
        .s_axi_rvalid (ul_rvalid),
        .s_axi_rready (ul_rready),

        .rx           (uart_rx_pin),
        .tx           (uart_tx_pin),
        .interrupt    (uartlite_irq)
    );

    // ---------- LED indicators ----------
    reg [24:0] hb = 25'd0;
    always_ff @(posedge core_clk) begin
        if (rst_sync) hb <= 25'd0;
        else          hb <= hb + 25'd1;
    end

    reg [19:0] commit_stretch = 20'd0;
    always_ff @(posedge core_clk) begin
        if (rst_sync) begin
            commit_stretch <= 20'd0;
        end else if (commit_valid) begin
            commit_stretch <= 20'hFFFFF;
        end else if (commit_stretch != 20'd0) begin
            commit_stretch <= commit_stretch - 20'd1;
        end
    end

    reg console_seen = 1'b0;
    always_ff @(posedge core_clk) begin
        if (rst_sync)           console_seen <= 1'b0;
        else if (console_valid) console_seen <= 1'b1;
    end

    assign led[0] = hb[24];
    assign led[1] = mmcm_locked;
    assign led[2] = rst_n;
    assign led[3] = !rst_sync;
    assign led[4] = commit_stretch[19];
    assign led[5] = exit_valid;
    assign led[6] = console_seen;
    assign led[7] = uart_tx_pin;

endmodule

`default_nettype wire
