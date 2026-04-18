// M- and S-mode CSR file.
//
// CSR storage: M-mode (mstatus, mie, mip-writable-bits, mtvec, mepc, mcause,
// mtval, mscratch, medeleg, mideleg, mcycle, minstret) + S-mode shadows
// (stvec, sepc, scause, stval, sscratch, satp). sstatus / sie / sip are
// subset-views of mstatus / mie / mip with masked read/write.
//
// Privilege: `priv_mode_q` tracks current mode (M/S/U). Trap entry routes to
// mtvec (M-mode) or stvec (S-mode) based on medeleg/mideleg, updates the
// matching trap CSRs, pushes the old priv into MPP/SPP, and drops to the
// target priv. MRET pops from MPP. SRET pops from SPP. CSR access is blocked
// (csr_illegal) if priv_mode_q lies below the CSR's required privilege
// (csr_addr[9:8] encodes the minimum priv per the RISC-V spec).
//
// Stage 6C-1 scope: exception delegation only. Interrupt delegation is still
// a no-op (mideleg is writable but ignored by the take-interrupt path); irq
// is always taken in M-mode. Tightens to full mideleg semantics with S-mode
// interrupts once there's S-mode software to exercise them.

`include "defs.svh"

module csr (
    input  logic        clk,
    input  logic        rst,

    // command from core decode/execute
    input  logic        csr_en,        // a CSR* instruction is executing this cycle
    input  logic [2:0]  csr_op,        // funct3 — CSRRW/S/C/WI/SI/CI
    input  logic [11:0] csr_addr,
    input  logic [4:0]  csr_rs1_or_imm,// for *I: zero-ext imm; otherwise rs1 addr (for zero-check)
    input  logic [31:0] csr_wdata,     // resolved data (rs1 value for non-I, zero-ext imm for I)
    output logic [31:0] csr_rdata,     // value captured this cycle for rd writeback
    output logic        csr_illegal,

    // trap interface (from core)
    input  logic        trap_take,     // asserted when a trap fires; we latch epc/cause/tval
    input  logic [31:0] trap_pc,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_tval,
    input  logic        mret,          // MRET
    input  logic        sret,          // SRET
    input  logic        retire,        // 1 cycle per successfully-committed insn

    // external interrupt lines (level-sensitive, already debounced by source)
    input  logic        ext_mti,
    input  logic        ext_msi,
    input  logic        ext_mei,

    // outputs visible to the core
    output logic [31:0] mtvec,
    output logic [31:0] stvec,
    output logic [31:0] mepc_out,
    output logic [31:0] sepc_out,
    output logic [1:0]  priv_mode,     // current hart privilege
    output logic        trap_to_s,     // if trap_take is high, it's being delegated to S-mode
    output logic [31:0] satp_out,      // for the MMU (Stage 6C-2)
    output logic        sstatus_sum,   // U-access from S-mode (for MMU)
    output logic        mstatus_mxr,   // make-executable-readable (for MMU)
    output logic        mstatus_mprv,  // load/store uses MPP's priv (for MMU)
    output logic [1:0]  mstatus_mpp,

    // combinational interrupt-take decision and cause (priority MEI > MSI > MTI)
    output logic        irq_pending,   // asserted while an M-mode interrupt can be taken
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
    logic [31:0] medeleg_q;
    logic [31:0] mideleg_q;
    logic [31:0] mip_sw_q;    // SW-writable bits of mip (SSIP etc.); MIP's external bits come from ext_*.
    logic [31:0] stvec_q;
    logic [31:0] sscratch_q;
    logic [31:0] sepc_q;
    logic [31:0] scause_q;
    logic [31:0] stval_q;
    logic [31:0] satp_q;
    logic [63:0] mcycle_q;
    logic [63:0] minstret_q;
    logic [1:0]  priv_mode_q;

    // PMP registers: 4 pmpcfg and 16 pmpaddr. Storage-only for now (Stage 6C-3a);
    // no access-fault path yet. Sized/named for easy expansion to enforcement.
    logic [31:0] pmpcfg_q  [0:3];
    logic [31:0] pmpaddr_q [0:15];

    // Read-only CSRs (constants)
    // MISA: MXL=01 (RV32) | S (18) | I (8). No A/M bits advertised (kept as before).
    localparam logic [31:0] MISA_CONST     = 32'h4004_0100;
    localparam logic [31:0] MHARTID_CONST  = 32'd0;
    localparam logic [31:0] MVENDOR_CONST  = 32'd0;
    localparam logic [31:0] MARCH_CONST    = 32'd0;
    localparam logic [31:0] MIMP_CONST     = 32'd1;

    assign mtvec        = mtvec_q;
    assign stvec        = stvec_q;
    assign mepc_out     = mepc_q;
    assign sepc_out     = sepc_q;
    assign priv_mode    = priv_mode_q;
    assign satp_out     = satp_q;
    assign sstatus_sum  = mstatus_q[`MSTATUS_SUM_BIT];
    assign mstatus_mxr  = mstatus_q[`MSTATUS_MXR_BIT];
    assign mstatus_mprv = mstatus_q[`MSTATUS_MPRV_BIT];
    assign mstatus_mpp  = mstatus_q[`MSTATUS_MPP_HI:`MSTATUS_MPP_LO];

    // ------------- mip composition -------------
    // External bits (MSIP/MTIP/MEIP) come from the interrupt controllers.
    // Software-writable S-level bits (SSIP/STIP/SEIP) live in mip_sw_q.
    logic [31:0] mip_live;
    always_comb begin
        mip_live = mip_sw_q;
        mip_live[`MIP_MSI_BIT] = ext_msi;
        mip_live[`MIP_MTI_BIT] = ext_mti;
        mip_live[`MIP_MEI_BIT] = ext_mei;
    end

    // ------------- interrupt evaluation -------------
    // For Stage 6C-1 we still only take interrupts in M-mode (mideleg unused
    // by the take path). Once S-mode software exists we'll extend with a
    // second irq path + delegation logic.
    wire [31:0] mip_enabled = mip_live & mie_q & ~mideleg_q;
    // Interrupt takeable at M when priv < M, or (priv == M && MIE).
    wire m_irq_enabled = (priv_mode_q != `PRV_M) ||
                          (priv_mode_q == `PRV_M && mstatus_q[`MSTATUS_MIE_BIT]);
    assign irq_pending = m_irq_enabled && (mip_enabled != 32'd0);
    always_comb begin
        if      (mip_enabled[`MIP_MEI_BIT]) irq_cause = `CAUSE_IRQ_MEI;
        else if (mip_enabled[`MIP_MSI_BIT]) irq_cause = `CAUSE_IRQ_MSI;
        else                                irq_cause = `CAUSE_IRQ_MTI;
    end

    // ------------- sstatus / sie / sip views -------------
    // Masked reads/writes of the parent M-CSRs.
    wire [31:0] sstatus_read = mstatus_q & `SSTATUS_MASK;
    wire [31:0] sie_read     = mie_q     & mideleg_q;
    wire [31:0] sip_read     = mip_live  & mideleg_q;

    // ------------- CSR read mux -------------
    logic [31:0] read_value;
    logic        addr_valid;

    always_comb begin
        read_value = 32'd0;
        addr_valid = 1'b1;
        unique case (csr_addr)
            // M-mode
            `CSR_MSTATUS:   read_value = mstatus_q;
            `CSR_MISA:      read_value = MISA_CONST;
            `CSR_MEDELEG:   read_value = medeleg_q;
            `CSR_MIDELEG:   read_value = mideleg_q;
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
            `CSR_CYCLE:     read_value = mcycle_q[31:0];
            `CSR_CYCLEH:    read_value = mcycle_q[63:32];
            `CSR_INSTRET:   read_value = minstret_q[31:0];
            `CSR_INSTRETH:  read_value = minstret_q[63:32];
            `CSR_MHARTID:   read_value = MHARTID_CONST;
            `CSR_MVENDORID: read_value = MVENDOR_CONST;
            `CSR_MARCHID:   read_value = MARCH_CONST;
            `CSR_MIMPID:    read_value = MIMP_CONST;
            // S-mode
            `CSR_SSTATUS:   read_value = sstatus_read;
            `CSR_SIE:       read_value = sie_read;
            `CSR_SIP:       read_value = sip_read;
            `CSR_STVEC:     read_value = stvec_q;
            `CSR_SCOUNTEREN:read_value = 32'd0;   // not implemented; RAZ
            `CSR_SSCRATCH:  read_value = sscratch_q;
            `CSR_SEPC:      read_value = sepc_q;
            `CSR_SCAUSE:    read_value = scause_q;
            `CSR_STVAL:     read_value = stval_q;
            `CSR_SATP:      read_value = satp_q;
            // PMP
            `CSR_PMPCFG0:   read_value = pmpcfg_q[0];
            `CSR_PMPCFG1:   read_value = pmpcfg_q[1];
            `CSR_PMPCFG2:   read_value = pmpcfg_q[2];
            `CSR_PMPCFG3:   read_value = pmpcfg_q[3];
            `CSR_PMPADDR0:  read_value = pmpaddr_q[0];
            `CSR_PMPADDR1:  read_value = pmpaddr_q[1];
            `CSR_PMPADDR2:  read_value = pmpaddr_q[2];
            `CSR_PMPADDR3:  read_value = pmpaddr_q[3];
            `CSR_PMPADDR4:  read_value = pmpaddr_q[4];
            `CSR_PMPADDR5:  read_value = pmpaddr_q[5];
            `CSR_PMPADDR6:  read_value = pmpaddr_q[6];
            `CSR_PMPADDR7:  read_value = pmpaddr_q[7];
            `CSR_PMPADDR8:  read_value = pmpaddr_q[8];
            `CSR_PMPADDR9:  read_value = pmpaddr_q[9];
            `CSR_PMPADDR10: read_value = pmpaddr_q[10];
            `CSR_PMPADDR11: read_value = pmpaddr_q[11];
            `CSR_PMPADDR12: read_value = pmpaddr_q[12];
            `CSR_PMPADDR13: read_value = pmpaddr_q[13];
            `CSR_PMPADDR14: read_value = pmpaddr_q[14];
            `CSR_PMPADDR15: read_value = pmpaddr_q[15];
            default: begin
                read_value = 32'd0;
                addr_valid = 1'b0;
            end
        endcase
    end

    assign csr_rdata = read_value;

    // Does this CSR op actually perform a write? CSRR{S,C}[I] with zero src
    // does NOT write.
    logic does_write;
    always_comb begin
        unique case (csr_op)
            `F3_CSRRW, `F3_CSRRWI:  does_write = 1'b1;
            `F3_CSRRS, `F3_CSRRC:   does_write = (csr_rs1_or_imm != 5'd0);
            `F3_CSRRSI, `F3_CSRRCI: does_write = (csr_rs1_or_imm != 5'd0);
            default:                does_write = 1'b0;
        endcase
    end

    // Compute the would-be new CSR value.
    logic [31:0] new_val;
    always_comb begin
        unique case (csr_op)
            `F3_CSRRW, `F3_CSRRWI:   new_val = csr_wdata;
            `F3_CSRRS, `F3_CSRRSI:   new_val = read_value |  csr_wdata;
            `F3_CSRRC, `F3_CSRRCI:   new_val = read_value & ~csr_wdata;
            default:                 new_val = read_value;
        endcase
    end

    // Read-only CSRs (top 2 bits of addr == 11) trap if written.
    wire is_read_only_space = (csr_addr[11:10] == 2'b11);
    // Priv check: csr_addr[9:8] is the minimum privilege required to access
    // this CSR. priv_mode_q must be >= that field.
    wire [1:0] csr_min_priv = csr_addr[9:8];
    wire priv_ok = (priv_mode_q >= csr_min_priv);

    // Pure function of (csr_op, csr_addr, priv_mode_q) — breaks a
    // combinational cycle between csr_en and trap composition in the core.
    assign csr_illegal = !addr_valid
                         || !priv_ok
                         || (does_write && is_read_only_space);

    // ------------- write logic -------------
    wire do_write = csr_en && does_write && !csr_illegal;

    // Writable bit masks.
    // mstatus: MIE(3) MPIE(7) MPP(12:11) | SIE(1) SPIE(5) SPP(8) | SUM(18)
    //          MXR(19) MPRV(17). Leaves TVM/TW/TSR and SD read-only zero.
    localparam logic [31:0] MSTATUS_WRITABLE = 32'h000E_19AA;
    // SSTATUS_MASK (see defs.svh) — subset of MSTATUS_WRITABLE.
    // mie / mip writable bit masks. mip: only SSIP is writable (software
    // interrupt pending at S-level).
    localparam logic [31:0] MIE_WRITABLE = 32'h0000_0AAA;
    localparam logic [31:0] MIP_WRITABLE = 32'h0000_0002; // SSIP only

    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_q   <= 32'd0;
            mie_q       <= 32'd0;
            mtvec_q     <= 32'd0;
            mscratch_q  <= 32'd0;
            mepc_q      <= 32'd0;
            mcause_q    <= 32'd0;
            mtval_q     <= 32'd0;
            medeleg_q   <= 32'd0;
            mideleg_q   <= 32'd0;
            mip_sw_q    <= 32'd0;
            stvec_q     <= 32'd0;
            sscratch_q  <= 32'd0;
            sepc_q      <= 32'd0;
            scause_q    <= 32'd0;
            stval_q     <= 32'd0;
            satp_q      <= 32'd0;
            mcycle_q    <= 64'd0;
            minstret_q  <= 64'd0;
            priv_mode_q <= `PRV_M;
            for (int i = 0; i < 4;  i++) pmpcfg_q[i]  <= 32'd0;
            for (int i = 0; i < 16; i++) pmpaddr_q[i] <= 32'd0;
        end else begin
            // Free-running counters (but SW writes win against the tick).
            if (!(do_write && (csr_addr == `CSR_MCYCLE   || csr_addr == `CSR_MCYCLEH)))
                mcycle_q <= mcycle_q + 64'd1;
            if (retire &&
                !(do_write && (csr_addr == `CSR_MINSTRET || csr_addr == `CSR_MINSTRETH)))
                minstret_q <= minstret_q + 64'd1;

            // Trap entry beats an instruction's CSR write this cycle.
            if (trap_take) begin
                // Decide delegation target. `trap_to_s` is visible to the
                // core so wb_redirect_pc picks the right vector. We consider
                // delegation only when coming from S or U (never delegate to
                // S from M).
                if (trap_to_s) begin
                    sepc_q   <= trap_pc;
                    scause_q <= trap_cause;
                    stval_q  <= trap_tval;
                    mstatus_q[`MSTATUS_SPIE_BIT] <= mstatus_q[`MSTATUS_SIE_BIT];
                    mstatus_q[`MSTATUS_SIE_BIT]  <= 1'b0;
                    // SPP: 1 iff coming from S-mode.
                    mstatus_q[`MSTATUS_SPP_BIT]  <= (priv_mode_q == `PRV_S);
                    priv_mode_q                  <= `PRV_S;
                end else begin
                    mepc_q   <= trap_pc;
                    mcause_q <= trap_cause;
                    mtval_q  <= trap_tval;
                    mstatus_q[`MSTATUS_MPIE_BIT] <= mstatus_q[`MSTATUS_MIE_BIT];
                    mstatus_q[`MSTATUS_MIE_BIT]  <= 1'b0;
                    mstatus_q[`MSTATUS_MPP_HI:`MSTATUS_MPP_LO] <= priv_mode_q;
                    priv_mode_q                  <= `PRV_M;
                end
            end else if (mret) begin
                mstatus_q[`MSTATUS_MIE_BIT]  <= mstatus_q[`MSTATUS_MPIE_BIT];
                mstatus_q[`MSTATUS_MPIE_BIT] <= 1'b1;
                priv_mode_q                  <= mstatus_q[`MSTATUS_MPP_HI:`MSTATUS_MPP_LO];
                // MPP is set to U (the least-privileged supported mode).
                mstatus_q[`MSTATUS_MPP_HI:`MSTATUS_MPP_LO] <= `PRV_U;
                // If MPP was not M, clear MPRV.
                if (mstatus_q[`MSTATUS_MPP_HI:`MSTATUS_MPP_LO] != `PRV_M)
                    mstatus_q[`MSTATUS_MPRV_BIT] <= 1'b0;
            end else if (sret) begin
                mstatus_q[`MSTATUS_SIE_BIT]  <= mstatus_q[`MSTATUS_SPIE_BIT];
                mstatus_q[`MSTATUS_SPIE_BIT] <= 1'b1;
                priv_mode_q                  <= {1'b0, mstatus_q[`MSTATUS_SPP_BIT]};
                mstatus_q[`MSTATUS_SPP_BIT]  <= 1'b0;
                // SPP going to not-M => clear MPRV per spec.
                if (mstatus_q[`MSTATUS_SPP_BIT] == 1'b0)
                    mstatus_q[`MSTATUS_MPRV_BIT] <= 1'b0;
            end else if (do_write) begin
                unique case (csr_addr)
                    // M-mode writes
                    `CSR_MSTATUS:   mstatus_q  <= (mstatus_q & ~MSTATUS_WRITABLE) |
                                                  (new_val   &  MSTATUS_WRITABLE);
                    `CSR_MEDELEG:   medeleg_q  <= new_val & 32'h0000_B3FF; // exc bits [15:0], skip M-only
                    `CSR_MIDELEG:   mideleg_q  <= new_val & 32'h0000_0222; // SSI/STI/SEI
                    `CSR_MIE:       mie_q      <= (mie_q     & ~MIE_WRITABLE) |
                                                  (new_val   &  MIE_WRITABLE);
                    `CSR_MIP:       mip_sw_q   <= (mip_sw_q  & ~MIP_WRITABLE) |
                                                  (new_val   &  MIP_WRITABLE);
                    `CSR_MTVEC:     mtvec_q    <= {new_val[31:2], 1'b0, new_val[0]};
                    `CSR_MSCRATCH:  mscratch_q <= new_val;
                    `CSR_MEPC:      mepc_q     <= {new_val[31:2], 2'b00};
                    `CSR_MCAUSE:    mcause_q   <= new_val;
                    `CSR_MTVAL:     mtval_q    <= new_val;
                    `CSR_MCYCLE:    mcycle_q[31:0]   <= new_val;
                    `CSR_MCYCLEH:   mcycle_q[63:32]  <= new_val;
                    `CSR_MINSTRET:  minstret_q[31:0] <= new_val;
                    `CSR_MINSTRETH: minstret_q[63:32]<= new_val;
                    // S-mode writes: sstatus / sie / sip are subset-views
                    `CSR_SSTATUS:   mstatus_q  <= (mstatus_q & ~`SSTATUS_MASK) |
                                                  (new_val   &  `SSTATUS_MASK);
                    `CSR_SIE:       mie_q      <= (mie_q     & ~mideleg_q) |
                                                  (new_val   &  mideleg_q & MIE_WRITABLE);
                    `CSR_SIP:       mip_sw_q   <= (mip_sw_q  & ~MIP_WRITABLE) |
                                                  (new_val   &  MIP_WRITABLE & mideleg_q);
                    `CSR_STVEC:     stvec_q    <= {new_val[31:2], 1'b0, new_val[0]};
                    `CSR_SSCRATCH:  sscratch_q <= new_val;
                    `CSR_SEPC:      sepc_q     <= {new_val[31:2], 2'b00};
                    `CSR_SCAUSE:    scause_q   <= new_val;
                    `CSR_STVAL:     stval_q    <= new_val;
                    `CSR_SATP:      satp_q     <= new_val;
                    // PMP storage — no lock enforcement yet.
                    `CSR_PMPCFG0:   pmpcfg_q[0]  <= new_val;
                    `CSR_PMPCFG1:   pmpcfg_q[1]  <= new_val;
                    `CSR_PMPCFG2:   pmpcfg_q[2]  <= new_val;
                    `CSR_PMPCFG3:   pmpcfg_q[3]  <= new_val;
                    `CSR_PMPADDR0:  pmpaddr_q[0]  <= new_val;
                    `CSR_PMPADDR1:  pmpaddr_q[1]  <= new_val;
                    `CSR_PMPADDR2:  pmpaddr_q[2]  <= new_val;
                    `CSR_PMPADDR3:  pmpaddr_q[3]  <= new_val;
                    `CSR_PMPADDR4:  pmpaddr_q[4]  <= new_val;
                    `CSR_PMPADDR5:  pmpaddr_q[5]  <= new_val;
                    `CSR_PMPADDR6:  pmpaddr_q[6]  <= new_val;
                    `CSR_PMPADDR7:  pmpaddr_q[7]  <= new_val;
                    `CSR_PMPADDR8:  pmpaddr_q[8]  <= new_val;
                    `CSR_PMPADDR9:  pmpaddr_q[9]  <= new_val;
                    `CSR_PMPADDR10: pmpaddr_q[10] <= new_val;
                    `CSR_PMPADDR11: pmpaddr_q[11] <= new_val;
                    `CSR_PMPADDR12: pmpaddr_q[12] <= new_val;
                    `CSR_PMPADDR13: pmpaddr_q[13] <= new_val;
                    `CSR_PMPADDR14: pmpaddr_q[14] <= new_val;
                    `CSR_PMPADDR15: pmpaddr_q[15] <= new_val;
                    default: /* no write */ ;
                endcase
            end
        end
    end

    // ------------- delegation decision -------------
    // A trap delegates to S only if priv_mode_q is S or U AND the corresponding
    // delegation bit is set. For exceptions, medeleg[cause[4:0]] gates it;
    // for interrupts, mideleg[cause[4:0]] (cause MSB==1 is interrupt).
    wire is_interrupt_w = trap_cause[31];
    wire [4:0] cause_idx_w = trap_cause[4:0];
    wire delegated_w = is_interrupt_w ? mideleg_q[cause_idx_w]
                                      : medeleg_q[cause_idx_w];
    assign trap_to_s = trap_take
                       && (priv_mode_q != `PRV_M)
                       && delegated_w;

endmodule
