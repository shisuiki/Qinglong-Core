// -----------------------------------------------------------------------------
// blinky_top.sv
// SP701 (Spartan-7 xc7s100fgga676-2) Vivado-flow smoke test.
//
// Purpose: validate XDC, non-project TCL build flow and JTAG programming chain
// end-to-end. Drives the 8 on-board LEDs in a Knight-Rider-ish pattern from a
// free-running 28-bit counter clocked off the 200 MHz differential sysclk.
//
// No MMCM, no IP, no clocking wizard. Just IBUFDS + a counter.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module blinky_top (
    input  wire       sysclk_p,
    input  wire       sysclk_n,
    input  wire       cpu_reset,   // active-high push button
    output wire [7:0] led
);

    // -------------------------------------------------------------------------
    // Differential -> single-ended 200 MHz clock
    // -------------------------------------------------------------------------
    wire sysclk;

    IBUFDS #(
        .DIFF_TERM    ("FALSE"),
        .IBUF_LOW_PWR ("FALSE"),
        .IOSTANDARD   ("LVDS_25")
    ) u_ibufds_sysclk (
        .O  (sysclk),
        .I  (sysclk_p),
        .IB (sysclk_n)
    );

    // -------------------------------------------------------------------------
    // Two-FF synchronizer for cpu_reset (active-high)
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg rst_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg rst_sync = 1'b0;

    always_ff @(posedge sysclk) begin
        rst_meta <= cpu_reset;
        rst_sync <= rst_meta;
    end

    // -------------------------------------------------------------------------
    // 28-bit free-running counter
    //   bit 27 toggles at 200e6 / 2^28 ~= 0.745 Hz -> visible blink on led[0]
    //   bits [26:20] drive led[7:1] so each LED toggles at a different rate,
    //   producing a ladder/knight-rider-ish animation that's clearly not
    //   all-on / all-off.
    // -------------------------------------------------------------------------
    reg [27:0] count = 28'd0;

    always_ff @(posedge sysclk) begin
        if (rst_sync) begin
            count <= 28'd0;
        end else begin
            count <= count + 28'd1;
        end
    end

    assign led[0]   = count[27];
    assign led[7:1] = count[26:20];

endmodule

`default_nettype wire
