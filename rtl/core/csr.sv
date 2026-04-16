// M-mode CSR file for Stage 1. Supports only what riscv-tests (rv32mi-p-*) needs:
//   mstatus, misa, mie, mip (read-only zero for now), mtvec, mepc, mcause, mtval,
//   mscratch, mhartid, mvendorid, marchid, mimpid, mcycle/h, minstret/h.
//
// CSRRW/CSRRS/CSRRC semantics: on CSRR*, rd gets the old value; write-effect uses
// new_val = (op == RW) ? src
//        : (op == RS) ? old | src
//        : (op == RC) ? old & ~src
// with src = rs1 or imm (zero-extended). When rs1/imm is 0 and op is S/C, no write.
//
// CSR traps (illegal): handled here via `illegal` output; the core elevates to trap.

`include "defs.svh"

module csr (
    input  logic        clk,
    input  logic        rst,

    // command from core decode/execute
    input  logic        csr_en,        // a CSR* instruction is executing this cycle
    input  logic [2:0]  csr_op,        // funct3 — CSRRW/S/C/WI/SI/CI
    input  logic [11:0] csr_addr,
    input  logic [4:0]  csr_rs1_or_imm,// for *I variants we pass the 5-bit imm; for non-I we pass rs1 addr (just for zero-check)
    input  logic [31:0] csr_wdata,     // resolved data (rs1 value for non-I, zero-ext imm for I)
    output logic [31:0] csr_rdata,     // value captured this cycle for rd writeback
    output logic        csr_illegal,

    // trap interface (from core)
    input  logic        trap_take,     // asserted when a trap fires; we latch mepc/mcause/mtval
    input  logic [31:0] trap_pc,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_tval,
    input  logic        mret,          // asserted on MRET
    input  logic        retire,        // 1 cycle per successfully-committed insn

    // external interrupt lines (level-sensitive, already debounced by source)
    input  logic        ext_mti,
    input  logic        ext_msi,
    input  logic        ext_mei,

    // outputs visible to the core
    output logic [31:0] mtvec,
    output logic [31:0] mepc_out,      // PC to resume at on MRET
    output logic        mstatus_mie,

    // combinational interrupt-take decision and cause (priority MEI > MSI > MTI)
    output logic        irq_pending,   // asserted while an interrupt can be taken at a boundary
    output logic [31:0] irq_cause
);

    // ------------- CSR storage -------------
    logic [31:0] mstatus_q;
    logic [31:0] mie_q;
    logic [31:0] mtvec_q;
    logic [31:0] mscratch_q;
    logic [31:0] mepc_q;
    logic [31:0] mcause_q;
    logic [31:0] mtval_q;
    logic [63:0] mcycle_q;
    logic [63:0] minstret_q;

    // Read-only CSRs (constants)
    // MISA: MXL=01 (RV32) in [31:30] | bit 8 ("I" extension) = 0x4000_0100.
    localparam logic [31:0] MISA_CONST     = 32'h4000_0100;
    localparam logic [31:0] MHARTID_CONST  = 32'd0;
    localparam logic [31:0] MVENDOR_CONST  = 32'd0;
    localparam logic [31:0] MARCH_CONST    = 32'd0;
    localparam logic [31:0] MIMP_CONST     = 32'd1;

    assign mtvec       = mtvec_q;
    assign mepc_out    = mepc_q;
    assign mstatus_mie = mstatus_q[`MSTATUS_MIE_BIT];

    // ------------- mip / interrupt evaluation -------------
    // Per spec, the MEIP/MTIP/MSIP bits are driven by the external interrupt
    // sources and read-only from software's perspective in this core.
    logic [31:0] mip_live;
    always_comb begin
        mip_live = 32'd0;
        mip_live[`MIP_MSI_BIT] = ext_msi;
        mip_live[`MIP_MTI_BIT] = ext_mti;
        mip_live[`MIP_MEI_BIT] = ext_mei;
    end

    wire [31:0] mip_enabled = mip_live & mie_q;
    // Priority: MEI > MSI > MTI (per privileged spec).
    assign irq_pending = mstatus_q[`MSTATUS_MIE_BIT] && (mip_enabled != 32'd0);
    always_comb begin
        if      (mip_enabled[`MIP_MEI_BIT]) irq_cause = `CAUSE_IRQ_MEI;
        else if (mip_enabled[`MIP_MSI_BIT]) irq_cause = `CAUSE_IRQ_MSI;
        else                                irq_cause = `CAUSE_IRQ_MTI;
    end

    // ------------- CSR read mux -------------
    logic [31:0] read_value;
    logic        addr_valid;

    always_comb begin
        read_value = 32'd0;
        addr_valid = 1'b1;
        unique case (csr_addr)
            `CSR_MSTATUS:   read_value = mstatus_q;
            `CSR_MISA:      read_value = MISA_CONST;
            `CSR_MIE:       read_value = mie_q;
            `CSR_MIP:       read_value = mip_live;
            `CSR_MTVEC:     read_value = mtvec_q;
            `CSR_MSCRATCH:  read_value = mscratch_q;
            `CSR_MEPC:      read_value = mepc_q;
            `CSR_MCAUSE:    read_value = mcause_q;
            `CSR_MTVAL:     read_value = mtval_q;
            `CSR_MCYCLE:    read_value = mcycle_q[31:0];
            `CSR_MCYCLEH:   read_value = mcycle_q[63:32];
            `CSR_MINSTRET:  read_value = minstret_q[31:0];
            `CSR_MINSTRETH: read_value = minstret_q[63:32];
            `CSR_MHARTID:   read_value = MHARTID_CONST;
            `CSR_MVENDORID: read_value = MVENDOR_CONST;
            `CSR_MARCHID:   read_value = MARCH_CONST;
            `CSR_MIMPID:    read_value = MIMP_CONST;
            default: begin
                read_value = 32'd0;
                addr_valid = 1'b0;
            end
        endcase
    end

    assign csr_rdata = read_value;

    // Does this CSR op actually perform a write?
    // For CSRRS/CSRRC (and their imm forms) a zero source does not write.
    logic does_write;
    always_comb begin
        unique case (csr_op)
            `F3_CSRRW, `F3_CSRRWI: does_write = 1'b1;
            `F3_CSRRS, `F3_CSRRC:  does_write = (csr_rs1_or_imm != 5'd0);
            `F3_CSRRSI, `F3_CSRRCI: does_write = (csr_rs1_or_imm != 5'd0);
            default:               does_write = 1'b0;
        endcase
    end

    // Compute the would-be new value of the CSR.
    logic [31:0] new_val;
    always_comb begin
        unique case (csr_op)
            `F3_CSRRW, `F3_CSRRWI: new_val = csr_wdata;
            `F3_CSRRS, `F3_CSRRSI: new_val = read_value |  csr_wdata;
            `F3_CSRRC, `F3_CSRRCI: new_val = read_value & ~csr_wdata;
            default:               new_val = read_value;
        endcase
    end

    // Read-only CSRs (top 2 bits of addr == 11) trap if written.
    logic is_read_only_space;
    assign is_read_only_space = (csr_addr[11:10] == 2'b11);

    // Pure function of (csr_op, csr_addr) — the core decides separately whether
    // to actually commit this instruction.  Breaks a combinational cycle between
    // csr_en and trap composition in the core.
    assign csr_illegal = !addr_valid || (does_write && is_read_only_space);

    // ------------- write logic -------------
    wire do_write = csr_en && does_write && !csr_illegal;

    always_ff @(posedge clk) begin
        if (rst) begin
            // Stage 1 reset state.  M-mode only, interrupts disabled.
            mstatus_q  <= 32'd0;
            mie_q      <= 32'd0;
            mtvec_q    <= 32'd0;
            mscratch_q <= 32'd0;
            mepc_q     <= 32'd0;
            mcause_q   <= 32'd0;
            mtval_q    <= 32'd0;
            mcycle_q   <= 64'd0;
            minstret_q <= 64'd0;
        end else begin
            // Free-running counters, but if a CSR write to the same counter
            // is happening this cycle we must not let the increment clobber
            // the written bits — the software write takes precedence.
            if (!(do_write && (csr_addr == `CSR_MCYCLE   || csr_addr == `CSR_MCYCLEH)))
                mcycle_q <= mcycle_q + 64'd1;
            if (retire &&
                !(do_write && (csr_addr == `CSR_MINSTRET || csr_addr == `CSR_MINSTRETH)))
                minstret_q <= minstret_q + 64'd1;

            // Trap entry wins over an instruction's CSR write this cycle.
            if (trap_take) begin
                mepc_q   <= trap_pc;
                mcause_q <= trap_cause;
                mtval_q  <= trap_tval;
                // Push MIE to MPIE, clear MIE, set MPP=11 (M-mode).
                mstatus_q[`MSTATUS_MPIE_BIT]            <= mstatus_q[`MSTATUS_MIE_BIT];
                mstatus_q[`MSTATUS_MIE_BIT]             <= 1'b0;
                mstatus_q[`MSTATUS_MPP_HI:`MSTATUS_MPP_LO] <= 2'b11;
            end else if (mret) begin
                // Pop: MIE ← MPIE, MPIE ← 1.
                mstatus_q[`MSTATUS_MIE_BIT]  <= mstatus_q[`MSTATUS_MPIE_BIT];
                mstatus_q[`MSTATUS_MPIE_BIT] <= 1'b1;
            end else if (do_write) begin
                unique case (csr_addr)
                    `CSR_MSTATUS:   mstatus_q  <= new_val & 32'h0000_1888; // MIE, MPIE, MPP bits writable
                    `CSR_MIE:       mie_q      <= new_val;
                    `CSR_MTVEC:     mtvec_q    <= {new_val[31:2], 1'b0, new_val[0]}; // mode bit[0], base aligned
                    `CSR_MSCRATCH:  mscratch_q <= new_val;
                    `CSR_MEPC:      mepc_q     <= {new_val[31:2], 2'b00};            // 4-byte aligned
                    `CSR_MCAUSE:    mcause_q   <= new_val;
                    `CSR_MTVAL:     mtval_q    <= new_val;
                    `CSR_MCYCLE:    mcycle_q[31:0]   <= new_val;
                    `CSR_MCYCLEH:   mcycle_q[63:32]  <= new_val;
                    `CSR_MINSTRET:  minstret_q[31:0] <= new_val;
                    `CSR_MINSTRETH: minstret_q[63:32]<= new_val;
                    default: /* no write */ ;
                endcase
            end
        end
    end

    // Instruction retirement tick. Rather than gating with commit, we let the
    // core increment this via a dedicated input. For Stage 1 simplicity we'll
    // approximate by counting on every cycle the core signals commit; but the
    // core doesn't wire that yet, so leave minstret static for now. TODO.

endmodule
