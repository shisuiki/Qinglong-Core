// -----------------------------------------------------------------------------
// blinky_top.sv
// RealDigital Urbana (xc7s50csga324-1) Vivado-flow smoke test.
//
// 100 MHz single-ended oscillator on N15 → free-running 27-bit counter drives
// eight LEDs.  `rst_n` is the active-low BTN0 push button.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module blinky_top (
    input  wire       clk,          // 100 MHz single-ended (N15)
    input  wire       rst_n,        // BTN0, active-low (J2)
    output wire [7:0] led
);

    wire rst = ~rst_n;

    (* ASYNC_REG = "TRUE" *) reg rst_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst_sync = 1'b1;

    always_ff @(posedge clk) begin
        rst_meta <= rst;
        rst_sync <= rst_meta;
    end

    // 27-bit counter.  At 100 MHz, bit 26 toggles at ~0.745 Hz (visible blink).
    reg [26:0] count = 27'd0;

    always_ff @(posedge clk) begin
        if (rst_sync) count <= 27'd0;
        else          count <= count + 27'd1;
    end

    assign led[0]   = count[26];
    assign led[7:1] = count[25:19];

endmodule

`default_nettype wire
