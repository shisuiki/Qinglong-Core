// Minimal UART transmitter (8N1, LSB first).
//
// Handshake:
//   tx_valid : 1-cycle pulse accepted only when tx_ready == 1.
//   tx_data  : byte to send, sampled on the accepting edge.
//   tx_ready : high while idle, low while shifting out a frame.
//
// The core stalls on console writes when this goes low (via mmio.req_ready),
// so we get back-pressure for free and never drop a byte.
//
// Frame timing is driven by a divider counter that produces one `bit_tick` per
// UART bit.  For 50 MHz / 115_200 baud that's ~434 cycles/bit.  Ten bit-ticks
// per frame (start + 8 data + stop).

module uart_tx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
)(
    input  logic       clk,
    input  logic       rst,

    input  logic       tx_valid,
    input  logic [7:0] tx_data,
    output logic       tx_ready,

    output logic       tx          // idle-high serial line
);

    localparam int DIV_MAX = CLK_HZ / BAUD;   // clock cycles per UART bit

    // Shift register holds {stop, data[7:0], start} = 10 bits, shifted LSB out.
    logic [9:0]                    sreg;
    logic [$clog2(DIV_MAX+1)-1:0]  div_cnt;
    logic [3:0]                    bit_cnt;   // counts 0..10
    logic                          busy;

    assign tx_ready = !busy;
    assign tx       = busy ? sreg[0] : 1'b1;  // idle high

    always_ff @(posedge clk) begin
        if (rst) begin
            sreg    <= 10'h3FF;
            div_cnt <= '0;
            bit_cnt <= 4'd0;
            busy    <= 1'b0;
        end else begin
            if (!busy) begin
                if (tx_valid) begin
                    sreg    <= {1'b1, tx_data, 1'b0};   // stop, 8 data (lsb first), start
                    div_cnt <= '0;
                    bit_cnt <= 4'd0;
                    busy    <= 1'b1;
                end
            end else begin
                if (div_cnt == DIV_MAX - 1) begin
                    div_cnt <= '0;
                    sreg    <= {1'b1, sreg[9:1]};        // shift LSB out, shift 1 in from top
                    if (bit_cnt == 4'd9) begin           // stop bit just shifted out
                        busy    <= 1'b0;
                        bit_cnt <= 4'd0;
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end

endmodule
