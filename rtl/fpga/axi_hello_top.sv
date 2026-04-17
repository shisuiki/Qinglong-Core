// -----------------------------------------------------------------------------
// axi_hello_top.sv
// RealDigital Urbana (xc7s50csga324-1) Stage 5 AXI bringup top.
//
// Same core/MMCM/reset as hello_top, but the SoC's AXI-Lite master port is
// wired out to a real AMD `axi_uartlite` IP instead of the sim BRAM. The
// legacy MMIO console (0xD058_0000) is left in place but not pinned out —
// software drives the TX line exclusively through the UartLite @ 0xC0000000.
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
    // Async assert when BTN0 pressed or MMCM unlocked; async deassert would be
    // unsafe, so we use a 2-FF synchronizer that releases in-domain.
    // AMD `proc_sys_reset` does essentially the same thing; keeping this
    // hand-built keeps the project self-contained (no extra IP for the reset).
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
    wire rstn_sync = !rst_sync;   // UartLite IP expects active-low resetn

    // ---------- AXI-Lite master (from soc_top) ----------
    wire        m_axil_awvalid, m_axil_awready;
    wire [31:0] m_axil_awaddr;
    wire [2:0]  m_axil_awprot;
    wire        m_axil_wvalid,  m_axil_wready;
    wire [31:0] m_axil_wdata;
    wire [3:0]  m_axil_wstrb;
    wire        m_axil_bvalid,  m_axil_bready;
    wire [1:0]  m_axil_bresp;
    wire        m_axil_arvalid, m_axil_arready;
    wire [31:0] m_axil_araddr;
    wire [2:0]  m_axil_arprot;
    wire        m_axil_rvalid,  m_axil_rready;
    wire [31:0] m_axil_rdata;
    wire [1:0]  m_axil_rresp;

    // ---------- SoC ----------
    wire        console_valid;   // legacy MMIO console byte (unused on pin — left for debug/ILA)
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

        .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),
        .m_axil_awaddr(m_axil_awaddr),   .m_axil_awprot(m_axil_awprot),
        .m_axil_wvalid(m_axil_wvalid),   .m_axil_wready(m_axil_wready),
        .m_axil_wdata(m_axil_wdata),     .m_axil_wstrb(m_axil_wstrb),
        .m_axil_bvalid(m_axil_bvalid),   .m_axil_bready(m_axil_bready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_arvalid(m_axil_arvalid), .m_axil_arready(m_axil_arready),
        .m_axil_araddr(m_axil_araddr),   .m_axil_arprot(m_axil_arprot),
        .m_axil_rvalid(m_axil_rvalid),   .m_axil_rready(m_axil_rready),
        .m_axil_rdata(m_axil_rdata),     .m_axil_rresp(m_axil_rresp),

        .ext_mei(1'b0),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr),
        .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );

    // ---------- AMD AXI UartLite ----------
    // Created from Vivado's IP catalog by the build TCL (module: axi_uartlite_0).
    // Clock 50 MHz, baud 115200, 8N1, no parity, FIFOs on.
    wire uartlite_irq;

    axi_uartlite_0 u_uartlite (
        .s_axi_aclk   (core_clk),
        .s_axi_aresetn(rstn_sync),

        .s_axi_awaddr (m_axil_awaddr[3:0]),
        .s_axi_awvalid(m_axil_awvalid),
        .s_axi_awready(m_axil_awready),

        .s_axi_wdata  (m_axil_wdata),
        .s_axi_wstrb  (m_axil_wstrb),
        .s_axi_wvalid (m_axil_wvalid),
        .s_axi_wready (m_axil_wready),

        .s_axi_bresp  (m_axil_bresp),
        .s_axi_bvalid (m_axil_bvalid),
        .s_axi_bready (m_axil_bready),

        .s_axi_araddr (m_axil_araddr[3:0]),
        .s_axi_arvalid(m_axil_arvalid),
        .s_axi_arready(m_axil_arready),

        .s_axi_rdata  (m_axil_rdata),
        .s_axi_rresp  (m_axil_rresp),
        .s_axi_rvalid (m_axil_rvalid),
        .s_axi_rready (m_axil_rready),

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
