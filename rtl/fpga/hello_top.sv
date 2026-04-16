// -----------------------------------------------------------------------------
// hello_top.sv
// RealDigital Urbana (xc7s50csga324-1) first real-CPU bringup.
//
//   100 MHz single-ended oscillator on N15
//   MMCM: 100 MHz → 50 MHz core_clk  (VCO = 1000 MHz)
//   rst_n (BTN0, active-low, J2) → 2-FF sync in core_clk domain
//   soc_top on core_clk, SRAM pre-loaded from $readmemh image
//   soc_top.console_byte → uart_tx → B16 (to on-board USB bridge) @ 115200-8N1
//   led[0] = core_clk heartbeat
//   led[1] = exit_valid
//   led[2] = stretched commit pulse (instruction retire indicator)
//   led[7:3] = exit_code[4:0]
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module hello_top #(
    parameter SRAM_INIT_FILE = ""
)(
    input  wire        clk,            // 100 MHz (N15)
    input  wire        rst_n,          // BTN0, active-low (J2)
    output wire        uart_tx_pin,    // B16 (to USB bridge RX)
    output wire [7:0]  led
);

    // -------------------------------------------------------------------------
    // MMCM: 100 MHz in → 50 MHz out
    //   VCO = 100 * CLKFBOUT_MULT_F / DIVCLK_DIVIDE = 100 * 10 / 1 = 1000 MHz
    //   core_clk = VCO / CLKOUT0_DIVIDE_F = 1000 / 20 = 50 MHz
    // -------------------------------------------------------------------------
    wire core_clk;
    wire mmcm_clkfb;
    wire mmcm_locked;
    wire mmcm_clkout0;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKIN1_PERIOD     (10.000),     // 100 MHz
        .DIVCLK_DIVIDE     (1),
        .CLKFBOUT_MULT_F   (10.000),     // VCO = 1000 MHz
        .CLKOUT0_DIVIDE_F  (20.000),     // 50 MHz
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

    // -------------------------------------------------------------------------
    // Reset: held while either BTN0 is pressed (rst_n low) or MMCM unlocked.
    // Two-FF sync into core_clk.
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // SoC + UART
    // -------------------------------------------------------------------------
    logic        console_valid;
    logic [7:0]  console_byte;
    logic        console_ready;
    logic        exit_valid;
    logic [31:0] exit_code;

    logic        commit_valid;
    logic [31:0] commit_pc, commit_insn, commit_rd_data, commit_cause;
    logic        commit_rd_wen, commit_trap;
    logic [4:0]  commit_rd_addr;

    soc_top #(
        .SRAM_WORDS     (16384),
        .RESET_PC       (32'h8000_0000),
        .SRAM_INIT_FILE (SRAM_INIT_FILE)
    ) u_soc (
        .clk           (core_clk),
        .rst           (rst_sync),
        .console_valid (console_valid),
        .console_byte  (console_byte),
        .console_ready (console_ready),
        .exit_valid    (exit_valid),
        .exit_code     (exit_code),
        .commit_valid  (commit_valid),
        .commit_pc     (commit_pc),
        .commit_insn   (commit_insn),
        .commit_rd_wen (commit_rd_wen),
        .commit_rd_addr(commit_rd_addr),
        .commit_rd_data(commit_rd_data),
        .commit_trap   (commit_trap),
        .commit_cause  (commit_cause)
    );

    uart_tx #(
        .CLK_HZ (50_000_000),
        .BAUD   (115_200)
    ) u_uart_tx (
        .clk      (core_clk),
        .rst      (rst_sync),
        .tx_valid (console_valid),
        .tx_data  (console_byte),
        .tx_ready (console_ready),
        .tx       (uart_tx_pin)
    );

    // -------------------------------------------------------------------------
    // LED indicators
    // -------------------------------------------------------------------------
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

    // Diagnostic LEDs to help us see the board without a UART:
    //   led[0] = heartbeat off core_clk  (~1.5 Hz) — MMCM + BUFG alive
    //   led[1] = mmcm_locked             — MMCM actually locked
    //   led[2] = rst_n                   — button state read (should be 1 idle)
    //   led[3] = !rst_sync               — core out of reset
    //   led[4] = commit stretched pulse  — CPU retiring instructions
    //   led[5] = exit_valid              — SW reached mmio_exit
    //   led[6] = console_valid (latched OR trace) — CPU issued a console putc
    //   led[7] = uart_tx_pin level       — serial output line (idle=high)
    reg console_seen = 1'b0;
    always_ff @(posedge core_clk) begin
        if (rst_sync)            console_seen <= 1'b0;
        else if (console_valid)  console_seen <= 1'b1;
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
