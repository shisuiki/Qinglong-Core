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

// ---------- privilege levels (used in core and mstatus.MPP/SPP) ----------
`define PRV_U 2'b00
`define PRV_S 2'b01
`define PRV_M 2'b11

// ---------- CSR addresses we implement (M-mode) ----------
`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MEDELEG   12'h302
`define CSR_MIDELEG   12'h303
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
// Unprivileged read-only aliases (Zicntr).
`define CSR_CYCLE     12'hC00
`define CSR_INSTRET   12'hC02
`define CSR_CYCLEH    12'hC80
`define CSR_INSTRETH  12'hC82
`define CSR_MHARTID   12'hF14
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13

// ---------- CSR addresses we implement (PMP, M-mode) ----------
// We back pmpcfg0..3 and pmpaddr0..15 with plain 32-bit R/W storage —
// no enforcement yet (Stage 6C-3a). Enough to pass rv32mi-p-pmpaddr,
// which is a register-behavior probe (no real access checks).
`define CSR_PMPCFG0   12'h3A0
`define CSR_PMPCFG1   12'h3A1
`define CSR_PMPCFG2   12'h3A2
`define CSR_PMPCFG3   12'h3A3
`define CSR_PMPADDR0  12'h3B0
`define CSR_PMPADDR1  12'h3B1
`define CSR_PMPADDR2  12'h3B2
`define CSR_PMPADDR3  12'h3B3
`define CSR_PMPADDR4  12'h3B4
`define CSR_PMPADDR5  12'h3B5
`define CSR_PMPADDR6  12'h3B6
`define CSR_PMPADDR7  12'h3B7
`define CSR_PMPADDR8  12'h3B8
`define CSR_PMPADDR9  12'h3B9
`define CSR_PMPADDR10 12'h3BA
`define CSR_PMPADDR11 12'h3BB
`define CSR_PMPADDR12 12'h3BC
`define CSR_PMPADDR13 12'h3BD
`define CSR_PMPADDR14 12'h3BE
`define CSR_PMPADDR15 12'h3BF

// ---------- CSR addresses we implement (S-mode) ----------
`define CSR_SSTATUS   12'h100
`define CSR_SIE       12'h104
`define CSR_STVEC     12'h105
`define CSR_SCOUNTEREN 12'h106
`define CSR_SSCRATCH  12'h140
`define CSR_SEPC      12'h141
`define CSR_SCAUSE    12'h142
`define CSR_STVAL     12'h143
`define CSR_SIP       12'h144
`define CSR_SATP      12'h180

// ---------- mcause values (M-mode, high bit=0 → exception, 1 → interrupt) ----------
`define CAUSE_INSN_ADDR_MISALIGNED  32'd0
`define CAUSE_INSN_ACCESS_FAULT     32'd1
`define CAUSE_ILLEGAL_INSN          32'd2
`define CAUSE_BREAKPOINT            32'd3
`define CAUSE_LOAD_ADDR_MISALIGNED  32'd4
`define CAUSE_LOAD_ACCESS_FAULT     32'd5
`define CAUSE_STORE_ADDR_MISALIGNED 32'd6
`define CAUSE_STORE_ACCESS_FAULT    32'd7
`define CAUSE_ECALL_FROM_U          32'd8
`define CAUSE_ECALL_FROM_S          32'd9
`define CAUSE_ECALL_FROM_M          32'd11
`define CAUSE_INSN_PAGE_FAULT       32'd12
`define CAUSE_LOAD_PAGE_FAULT       32'd13
`define CAUSE_STORE_PAGE_FAULT      32'd15

// ---------- interrupt causes (mcause MSB=1) ----------
`define CAUSE_IRQ_SSI               32'h8000_0001
`define CAUSE_IRQ_MSI               32'h8000_0003
`define CAUSE_IRQ_STI               32'h8000_0005
`define CAUSE_IRQ_MTI               32'h8000_0007
`define CAUSE_IRQ_SEI               32'h8000_0009
`define CAUSE_IRQ_MEI               32'h8000_000B

// ---------- mip/mie bit positions ----------
`define MIP_SSI_BIT  1
`define MIP_MSI_BIT  3
`define MIP_STI_BIT  5
`define MIP_MTI_BIT  7
`define MIP_SEI_BIT  9
`define MIP_MEI_BIT  11

// ---------- mstatus bit layout (RV32 M/S subset) ----------
// bit 1 SIE, bit 3 MIE, bit 5 SPIE, bit 7 MPIE, bit 8 SPP, bits 12:11 MPP,
// bit 17 MPRV, bit 18 SUM, bit 19 MXR, bit 22 TVM, bit 23 TW, bit 24 TSR.
`define MSTATUS_SIE_BIT   1
`define MSTATUS_MIE_BIT   3
`define MSTATUS_SPIE_BIT  5
`define MSTATUS_MPIE_BIT  7
`define MSTATUS_SPP_BIT   8
`define MSTATUS_MPP_LO    11
`define MSTATUS_MPP_HI    12
`define MSTATUS_MPRV_BIT  17
`define MSTATUS_SUM_BIT   18
`define MSTATUS_MXR_BIT   19
`define MSTATUS_TVM_BIT   20
`define MSTATUS_TW_BIT    21
`define MSTATUS_TSR_BIT   22

// ---------- sstatus is a subset-view of mstatus — these bits are visible ----------
// SIE(1), SPIE(5), SPP(8), SUM(18), MXR(19). (Also SUM/MXR matter once MMU lands.)
`define SSTATUS_MASK 32'h000C_0122

// ---------- misc ----------
`define RESET_PC     32'h8000_0000

`endif
