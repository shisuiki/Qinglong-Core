// RV32I immediate decoder. Selects and sign-extends the immediate for the
// five RV32 immediate formats (I, S, B, U, J).

module imm_gen (
    input  logic [31:0] instr,
    output logic [31:0] imm_i,
    output logic [31:0] imm_s,
    output logic [31:0] imm_b,
    output logic [31:0] imm_u,
    output logic [31:0] imm_j
);

    // I-type: bits [31:20], sign-extended.
    assign imm_i = {{20{instr[31]}}, instr[31:20]};

    // S-type: bits [31:25] | [11:7], sign-extended.
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};

    // B-type: bit31=sign, {7}=bit[10:5]=instr[30:25], [4:1]=instr[11:8], bit[11]=instr[7], LSB=0.
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};

    // U-type: bits [31:12] << 12.
    assign imm_u = {instr[31:12], 12'b0};

    // J-type: sign-ext. 20=instr[31], [10:1]=instr[30:21], [11]=instr[20], [19:12]=instr[19:12], LSB=0.
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

endmodule
