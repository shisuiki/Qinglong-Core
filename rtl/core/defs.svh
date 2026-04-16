// RV32I opcode / funct3 / funct7 / CSR addresses / trap causes.
// Single-file include, no package — avoids Verilator package-scope quirks at this stage.

`ifndef RV_DEFS_SVH
`define RV_DEFS_SVH

// ---------- opcodes (bits [6:0], always 2'b11 in the low two bits for non-C) ----------
`define OP_LUI      7'b0110111
`define OP_AUIPC    7'b0010111
`define OP_JAL      7'b1101111
`define OP_JALR     7'b1100111
`define OP_BRANCH   7'b1100011
`define OP_LOAD     7'b0000011
`define OP_STORE    7'b0100011
`define OP_OP_IMM   7'b0010011
`define OP_OP       7'b0110011
`define OP_AMO      7'b0101111  // A-extension atomics
`define OP_MISC_MEM 7'b0001111  // FENCE
`define OP_SYSTEM   7'b1110011  // ECALL/EBREAK/CSR*/MRET

// ---------- funct3 for OP / OP-IMM ----------
`define F3_ADD_SUB  3'b000
`define F3_SLL      3'b001
`define F3_SLT      3'b010
`define F3_SLTU     3'b011
`define F3_XOR      3'b100
`define F3_SRL_SRA  3'b101
`define F3_OR       3'b110
`define F3_AND      3'b111

// ---------- funct3 for BRANCH ----------
`define F3_BEQ      3'b000
`define F3_BNE      3'b001
`define F3_BLT      3'b100
`define F3_BGE      3'b101
`define F3_BLTU     3'b110
`define F3_BGEU     3'b111

// ---------- funct3 for LOAD ----------
`define F3_LB       3'b000
`define F3_LH       3'b001
`define F3_LW       3'b010
`define F3_LBU      3'b100
`define F3_LHU      3'b101

// ---------- funct3 for STORE ----------
`define F3_SB       3'b000
`define F3_SH       3'b001
`define F3_SW       3'b010

// ---------- A extension: funct3 = 010 with OP_AMO, funct5 = instr[31:27] ----------
`define F3_AMO_W    3'b010
`define AMO_ADD     5'b00000
`define AMO_SWAP    5'b00001
`define AMO_LR      5'b00010
`define AMO_SC      5'b00011
`define AMO_XOR     5'b00100
`define AMO_OR      5'b01000
`define AMO_AND     5'b01100
`define AMO_MIN     5'b10000
`define AMO_MAX     5'b10100
`define AMO_MINU    5'b11000
`define AMO_MAXU    5'b11100

// ---------- M extension (funct7 = 0000001 with OP) ----------
`define F7_MULDIV   7'b0000001
`define F3_MUL      3'b000
`define F3_MULH     3'b001
`define F3_MULHSU   3'b010
`define F3_MULHU    3'b011
`define F3_DIV      3'b100
`define F3_DIVU     3'b101
`define F3_REM      3'b110
`define F3_REMU     3'b111

// ---------- funct3 for SYSTEM ----------
`define F3_PRIV     3'b000
`define F3_CSRRW    3'b001
`define F3_CSRRS    3'b010
`define F3_CSRRC    3'b011
`define F3_CSRRWI   3'b101
`define F3_CSRRSI   3'b110
`define F3_CSRRCI   3'b111

// ---------- CSR addresses we implement (M-mode) ----------
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MCYCLEH   12'hB80
`define CSR_MINSTRETH 12'hB82
`define CSR_MHARTID   12'hF14
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13

// ---------- mcause values (M-mode, high bit=0 → exception, 1 → interrupt) ----------
`define CAUSE_INSN_ADDR_MISALIGNED  32'd0
`define CAUSE_INSN_ACCESS_FAULT     32'd1
`define CAUSE_ILLEGAL_INSN          32'd2
`define CAUSE_BREAKPOINT            32'd3
`define CAUSE_LOAD_ADDR_MISALIGNED  32'd4
`define CAUSE_LOAD_ACCESS_FAULT     32'd5
`define CAUSE_STORE_ADDR_MISALIGNED 32'd6
`define CAUSE_STORE_ACCESS_FAULT    32'd7
`define CAUSE_ECALL_FROM_M          32'd11

// ---------- mstatus bit layout (RV32 M-mode subset) ----------
// bit 3 MIE, bit 7 MPIE, bits 12:11 MPP.
`define MSTATUS_MIE_BIT   3
`define MSTATUS_MPIE_BIT  7
`define MSTATUS_MPP_LO    11
`define MSTATUS_MPP_HI    12

// ---------- misc ----------
`define RESET_PC     32'h8000_0000

`endif
