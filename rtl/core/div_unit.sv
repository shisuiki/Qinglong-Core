// RV32M integer divider.  Iterative restoring divide, 32 cycles.
//
// Encoding (funct3):
//   DIV  (100) signed   / signed
//   DIVU (101) unsigned / unsigned
//   REM  (110) signed   % signed
//   REMU (111) unsigned % unsigned
//
// RISC-V M-ext required semantics:
//   divide-by-zero:         DIV/DIVU → -1 (all ones);  REM/REMU → dividend
//   signed overflow (MIN/-1): DIV → MIN(=dividend);    REM → 0
//
// Handshake:  hold `start` for one cycle with the operands presented; `busy`
// rises immediately and falls when `done` pulses.  `result` is valid on and
// after the cycle `done` is asserted.

module div_unit (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        is_signed,  // funct3[0] == 0 means signed variant
    input  logic        want_rem,   // 1 = REM/REMU, 0 = DIV/DIVU
    input  logic [31:0] dividend,
    input  logic [31:0] divisor,
    output logic        busy,
    output logic        done,       // 1 cycle pulse when `result` becomes valid
    output logic [31:0] result
);

    typedef enum logic [1:0] {S_IDLE, S_INIT, S_COMPUTE, S_FIXUP} state_t;
    state_t state_q;

    // Latched operands + configuration
    logic        sign_q;    // captured is_signed
    logic        rem_q;     // captured want_rem
    logic        neg_q_q;   // "quotient should be negated"
    logic        neg_r_q;   // "remainder should be negated"
    logic        div_by_zero_q;
    logic        overflow_q;

    // Datapath state
    logic [31:0] remainder_q;
    logic [31:0] quotient_q;
    logic [31:0] divisor_abs_q;
    logic [31:0] dividend_abs_q;
    logic [5:0]  iter_q;    // counts 0..31 then 32 to trigger fixup

    // ---- top-level outputs ----
    assign busy = (state_q != S_IDLE);

    // ---- helpers ----
    wire dividend_neg = is_signed && dividend[31];
    wire divisor_neg  = is_signed && divisor[31];
    wire [31:0] dividend_abs = dividend_neg ? (~dividend + 32'd1) : dividend;
    wire [31:0] divisor_abs  = divisor_neg  ? (~divisor  + 32'd1) : divisor;

    wire div_by_zero_w = (divisor == 32'd0);
    // Signed overflow: INT_MIN / -1 = INT_MIN (undefined in C, defined in RISC-V M).
    wire overflow_w = is_signed && (dividend == 32'h8000_0000) && (divisor == 32'hFFFF_FFFF);

    // ---- restoring divide step ----
    // Shift (R, Q) left by 1 (R takes MSB of remaining dividend); if R >= D, subtract and set Q[0].
    logic [32:0] r_shift;    // one extra bit for compare
    logic [32:0] r_sub;
    logic        r_ge;
    always_comb begin
        r_shift = {remainder_q, dividend_abs_q[31]};     // shift-in MSB of remaining dividend
        r_sub   = r_shift - {1'b0, divisor_abs_q};
        r_ge    = !r_sub[32];                             // no borrow → r_shift >= divisor
    end

    // ---- FSM ----
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q        <= S_IDLE;
            done           <= 1'b0;
            result         <= 32'd0;
            sign_q         <= 1'b0;
            rem_q          <= 1'b0;
            neg_q_q        <= 1'b0;
            neg_r_q        <= 1'b0;
            div_by_zero_q  <= 1'b0;
            overflow_q     <= 1'b0;
            remainder_q    <= 32'd0;
            quotient_q     <= 32'd0;
            divisor_abs_q  <= 32'd0;
            dividend_abs_q <= 32'd0;
            iter_q         <= 6'd0;
        end else begin
            done <= 1'b0; // default: deassert unless we pulse it below

            unique case (state_q)
                S_IDLE: begin
                    if (start) begin
                        sign_q         <= is_signed;
                        rem_q          <= want_rem;
                        div_by_zero_q  <= div_by_zero_w;
                        overflow_q     <= overflow_w;
                        // sign of quotient: XOR of operand signs (unless div-by-zero / overflow path)
                        neg_q_q        <= dividend_neg ^ divisor_neg;
                        // sign of remainder: same as dividend
                        neg_r_q        <= dividend_neg;
                        divisor_abs_q  <= divisor_abs;
                        dividend_abs_q <= dividend_abs;
                        remainder_q    <= 32'd0;
                        quotient_q     <= 32'd0;
                        iter_q         <= 6'd0;
                        state_q        <= S_INIT;
                    end
                end

                S_INIT: begin
                    // Short-circuit for divide-by-zero / overflow.
                    if (div_by_zero_q) begin
                        if (rem_q) begin
                            // REM/REMU: remainder = original dividend (not abs)
                            // We need the original signed dividend value. Re-derive from abs+sign.
                            result  <= neg_r_q ? (~dividend_abs_q + 32'd1) : dividend_abs_q;
                        end else begin
                            // DIV/DIVU: quotient = -1 (all ones)
                            result  <= 32'hFFFF_FFFF;
                        end
                        done    <= 1'b1;
                        state_q <= S_IDLE;
                    end else if (overflow_q) begin
                        if (rem_q) begin
                            result <= 32'd0;                 // REM INT_MIN / -1 = 0
                        end else begin
                            result <= 32'h8000_0000;         // DIV INT_MIN / -1 = INT_MIN
                        end
                        done    <= 1'b1;
                        state_q <= S_IDLE;
                    end else begin
                        state_q <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    // Shift dividend left by 1, feed into the R register.
                    if (r_ge) begin
                        remainder_q <= r_sub[31:0];
                        quotient_q  <= {quotient_q[30:0], 1'b1};
                    end else begin
                        remainder_q <= r_shift[31:0];
                        quotient_q  <= {quotient_q[30:0], 1'b0};
                    end
                    dividend_abs_q <= {dividend_abs_q[30:0], 1'b0};
                    iter_q         <= iter_q + 6'd1;

                    if (iter_q == 6'd31) begin
                        state_q <= S_FIXUP;
                    end
                end

                S_FIXUP: begin
                    if (rem_q) begin
                        result <= neg_r_q ? (~remainder_q + 32'd1) : remainder_q;
                    end else begin
                        result <= neg_q_q ? (~quotient_q + 32'd1) : quotient_q;
                    end
                    done    <= 1'b1;
                    state_q <= S_IDLE;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
