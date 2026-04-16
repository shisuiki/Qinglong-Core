// Combinational RV32I ALU.
// op_sel encoding chosen for compactness (not matching funct3 directly so
// shift/arith selection is explicit).

module alu (
    input  logic [3:0]  op,       // see localparams below
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y,
    output logic        eq,       // a == b
    output logic        lt,       // signed a < b
    output logic        ltu       // unsigned a < b
);

    // Compact opcodes; core decoder maps from funct3/funct7 to these.
    localparam logic [3:0] ALU_ADD  = 4'd0;
    localparam logic [3:0] ALU_SUB  = 4'd1;
    localparam logic [3:0] ALU_AND  = 4'd2;
    localparam logic [3:0] ALU_OR   = 4'd3;
    localparam logic [3:0] ALU_XOR  = 4'd4;
    localparam logic [3:0] ALU_SLL  = 4'd5;
    localparam logic [3:0] ALU_SRL  = 4'd6;
    localparam logic [3:0] ALU_SRA  = 4'd7;
    localparam logic [3:0] ALU_SLT  = 4'd8;
    localparam logic [3:0] ALU_SLTU = 4'd9;
    localparam logic [3:0] ALU_COPY_B = 4'd10; // pass-through for LUI etc.

    // Comparison results (also exported for branch unit)
    assign eq  = (a == b);
    assign lt  = ($signed(a) <  $signed(b));
    assign ltu = (a < b);

    logic [4:0] shamt;
    assign shamt = b[4:0];

    always_comb begin
        unique case (op)
            ALU_ADD:    y = a + b;
            ALU_SUB:    y = a - b;
            ALU_AND:    y = a & b;
            ALU_OR:     y = a | b;
            ALU_XOR:    y = a ^ b;
            ALU_SLL:    y = a << shamt;
            ALU_SRL:    y = a >> shamt;
            ALU_SRA:    y = $signed(a) >>> shamt;
            ALU_SLT:    y = {31'd0, lt};
            ALU_SLTU:   y = {31'd0, ltu};
            ALU_COPY_B: y = b;
            default:    y = 32'd0;
        endcase
    end

endmodule
