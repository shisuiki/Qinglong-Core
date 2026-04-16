// RV32M multiplier.  Combinational 32x32 -> 64 signed multiply covering all
// four variants via operand sign extension to 33 bits.  Vivado will infer
// DSP48E1 slices; Verilator evaluates it natively.  In the multi-cycle core
// this fits in a single EX cycle — the S_EXEC state already absorbs it.
//
// Encoding (funct3):
//   MUL    (000)  lo(  signed a *   signed b)
//   MULH   (001)  hi(  signed a *   signed b)
//   MULHSU (010)  hi(  signed a * unsigned b)
//   MULHU  (011)  hi(unsigned a * unsigned b)

module mul_unit (
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic        a_signed,   // 1 = treat a as signed
    input  logic        b_signed,   // 1 = treat b as signed
    input  logic        hi,         // 1 = return upper 32 bits; 0 = lower
    output logic [31:0] result
);
    // Sign-extend to 33 bits so that $signed(*) covers all four combinations.
    logic signed [32:0] a_ext, b_ext;
    assign a_ext = a_signed ? {{1{a[31]}}, a} : {1'b0, a};
    assign b_ext = b_signed ? {{1{b[31]}}, b} : {1'b0, b};

    // 33x33 -> 66 bit signed product.  We only ever use the low 64 bits.
    logic signed [65:0] prod;
    assign prod = a_ext * b_ext;

    assign result = hi ? prod[63:32] : prod[31:0];

endmodule
