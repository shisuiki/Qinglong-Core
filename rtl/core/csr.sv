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
// Exception delegation via medeleg, interrupt delegation via mideleg. An
// interrupt routes to S-mode when the current priv is < M and mideleg[cause]
// is set; otherwise M-mode takes it. Within each path, priority follows the
// priv spec: MEI > MSI > MTI > SEI > SSI > STI.

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
    input  logic        ext_sei,   // hardware S-mode external (e.g. PLIC ctx1)

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
    output logic        mstatus_tvm,   // trap SFENCE.VMA / satp from S-mode
    output logic        mstatus_tsr,   // trap SRET from S-mode

    // combinational interrupt-take decision and cause (priority MEI > MSI > MTI)
    output logic        irq_pending,   // asserted while an M-mode interrupt can be taken
    output logic [31:0] irq_cause,

    // PMP state — 16 entries. cfg bytes come from pmpcfg0..3 (4 bytes per
    // CSR), addrs from pmpaddr0..15. Exposed flat for easy wiring into
    // the MMU's access-check path.
    // Packed 2D so Yosys/SBY accept the port list (unpacked port arrays
    // aren't supported by the Verilog frontend). Indexable as pmp_cfg_out[i]
    // / pmp_addr_out[i] the same way an unpacked array would be.
    output logic [15:0][7:0]  pmp_cfg_out,
    output logic [15:0][31:0] pmp_addr_out
`ifdef RISCV_FORMAL
    ,
    // Live CSR storage taps for RVFI. Pre-edge values; the tap captures
    // them at WB time when the CSR insn fires, then computes wdata from
    // the writable mask defined in this module.
    output logic [31:0] mstatus_now,
    output logic        csr_active_write
`endif
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
    assign mstatus_tvm  = mstatus_q[`MSTATUS_TVM_BIT];
    assign mstatus_tsr  = mstatus_q[`MSTATUS_TSR_BIT];

    // Per-entry lock / A-mode derived from pmpcfg_q. Used for WARL masking
    // on pmpaddr and pmpcfg writes (priv-spec: L=1 makes that cfg byte and
    // its pmpaddr read-only, and locks pmpaddr[i-1] whenever entry i is TOR).
    logic [15:0] pmp_L;
    logic [15:0] pmp_A_is_tor;
    logic [15:0] pmpaddr_locked;
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            pmp_L[i]        = pmpcfg_q[i/4][(i%4)*8 + 7];
            pmp_A_is_tor[i] = (pmpcfg_q[i/4][(i%4)*8 + 3 +: 2] == 2'b01);
        end
        for (int i = 0; i < 16; i++) begin
            if (i == 15)
                pmpaddr_locked[i] = pmp_L[i];
            else
                pmpaddr_locked[i] = pmp_L[i]
                                  | (pmp_L[i+1] & pmp_A_is_tor[i+1]);
        end
    end

    // Per-byte merge for pmpcfg writes: keep byte if its L=1, else take
    // the new byte. `wb_new` is the word being written, `old_w` is the
    // current value of pmpcfgN.
    function automatic [31:0] pmpcfg_write_mask(input [31:0] old_w,
                                                input [31:0] wb_new);
        begin
            pmpcfg_write_mask = 32'd0;
            for (int b = 0; b < 4; b++) begin
                if (old_w[b*8 + 7])
                    pmpcfg_write_mask[b*8 +: 8] = old_w[b*8  +: 8];
                else
                    pmpcfg_write_mask[b*8 +: 8] = wb_new[b*8 +: 8];
            end
        end
    endfunction

    // Fan out PMP storage. Byte-unpack pmpcfg0..3 and pass pmpaddr through.
    generate
        for (genvar pi = 0; pi < 16; pi = pi + 1) begin : g_pmp_fanout
            assign pmp_cfg_out[pi]  = pmpcfg_q[pi / 4][(pi % 4) * 8 +: 8];
            assign pmp_addr_out[pi] = pmpaddr_q[pi];
        end
    endgenerate

    // ------------- mip composition -------------
    // External bits (MSIP/MTIP/MEIP) come from the interrupt controllers.
    // Software-writable S-level bits (SSIP/STIP/SEIP) live in mip_sw_q.
    logic [31:0] mip_live;
    always_comb begin
        mip_live = mip_sw_q;
        mip_live[`MIP_MSI_BIT] = ext_msi;
        mip_live[`MIP_MTI_BIT] = ext_mti;
        mip_live[`MIP_MEI_BIT] = ext_mei;
        // SEIP is the OR of software-set (via mip write) and hardware ext_sei.
        // Reading sip observes the combined value; clearing software-set side
        // via sip write cannot clear the hardware-driven half until PLIC claim.
        mip_live[`MIP_SEI_BIT] = mip_sw_q[`MIP_SEI_BIT] | ext_sei;
    end

    // ------------- interrupt evaluation -------------
    // Two parallel paths per the priv spec:
    //   M-path: bits NOT delegated via mideleg. M can take these whenever it's
    //           in a lower priv, or in M with MIE set.
    //   S-path: bits delegated via mideleg. Only S/U can take these (never M);
    //           if in S we additionally gate on SIE.
    // M always wins if both paths are live, then priority is MEI>MSI>MTI>
    // SEI>SSI>STI within the winning path.
    wire [31:0] mip_m_enabled = mip_live & mie_q & ~mideleg_q;
    wire [31:0] mip_s_enabled = mip_live & mie_q &  mideleg_q;
    wire m_irq_enabled = (priv_mode_q != `PRV_M) ||
                         (priv_mode_q == `PRV_M && mstatus_q[`MSTATUS_MIE_BIT]);
    wire s_irq_enabled = (priv_mode_q == `PRV_U) ||
                         (priv_mode_q == `PRV_S && mstatus_q[`MSTATUS_SIE_BIT]);
    wire m_irq_live = m_irq_enabled && (mip_m_enabled != 32'd0);
    wire s_irq_live = s_irq_enabled && (mip_s_enabled != 32'd0);
    assign irq_pending = m_irq_live || s_irq_live;
    always_comb begin
        // M wins over S; within a path, follow spec priority MEI>MSI>MTI then
        // SEI>SSI>STI. Since mideleg-writable bits are only SSI/STI/SEI, an
        // M-path chosen this cycle will always land on MEI/MSI/MTI (the
        // else-branches below are dead but kept for defense).
        if (m_irq_live) begin
            if      (mip_m_enabled[`MIP_MEI_BIT]) irq_cause = `CAUSE_IRQ_MEI;
            else if (mip_m_enabled[`MIP_MSI_BIT]) irq_cause = `CAUSE_IRQ_MSI;
            else if (mip_m_enabled[`MIP_MTI_BIT]) irq_cause = `CAUSE_IRQ_MTI;
            else if (mip_m_enabled[`MIP_SEI_BIT]) irq_cause = `CAUSE_IRQ_SEI;
            else if (mip_m_enabled[`MIP_SSI_BIT]) irq_cause = `CAUSE_IRQ_SSI;
            else                                  irq_cause = `CAUSE_IRQ_STI;
        end else begin
            if      (mip_s_enabled[`MIP_SEI_BIT]) irq_cause = `CAUSE_IRQ_SEI;
            else if (mip_s_enabled[`MIP_SSI_BIT]) irq_cause = `CAUSE_IRQ_SSI;
            else                                  irq_cause = `CAUSE_IRQ_STI;
        end
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
    // TVM=1 traps any S-mode access to satp as illegal.
    wire tvm_blocks_satp = (csr_addr == `CSR_SATP)
                           && (priv_mode_q == `PRV_S)
                           && mstatus_q[`MSTATUS_TVM_BIT];
    assign csr_illegal = !addr_valid
                         || !priv_ok
                         || (does_write && is_read_only_space)
                         || tvm_blocks_satp;

    // ------------- write logic -------------
    wire do_write = csr_en && does_write && !csr_illegal;

`ifdef RISCV_FORMAL
    // Live taps for the core's RVFI tap. These avoid having the tap
    // duplicate WARL/illegal logic that's the source of truth here.
    assign mstatus_now      = mstatus_q;
    assign csr_active_write = do_write;
`endif

    // Writable bit masks.
    // mstatus: MIE(3) MPIE(7) MPP(12:11) | SIE(1) SPIE(5) SPP(8) | SUM(18)
    //          MXR(19) MPRV(17) | TVM(20) TSR(22). TW(21) and SD stay read-only zero.
    localparam logic [31:0] MSTATUS_WRITABLE = 32'h005E_19AA;
    // SSTATUS_MASK (see defs.svh) — subset of MSTATUS_WRITABLE.
    // mie / mip writable bit masks. mip: only SSIP is writable (software
    // interrupt pending at S-level).
    localparam logic [31:0] MIE_WRITABLE = 32'h0000_0AAA;
    // mip: M-mode can software-set SSIP (bit 1), STIP (bit 5), SEIP (bit 9) —
    // OpenSBI's timer-trap fwd uses `csrrs mip, STIP` to raise the S-mode
    // timer IRQ after catching MTIP. SSIP is also the S-mode write side.
    // MTIP/MSIP/MEIP stay read-only (driven by ext_* from CLINT/PLIC).
    localparam logic [31:0] MIP_M_WRITABLE = 32'h0000_0222;
    // sip (S-mode view): only SSIP is truly software-writable at S-level.
    // STIP/SEIP appear RO to S-mode.
    localparam logic [31:0] MIP_S_WRITABLE = 32'h0000_0002;

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
`ifdef VERILATOR
                if (trace_dbg_en)
                    $display("[TRAP] t=%0t cause=%08x pc=%08x tval=%08x from_priv=%0d to_s=%0d mip=%08x mie=%08x mstatus=%08x mtvec=%08x mepc=%08x",
                        $time, trap_cause, trap_pc, trap_tval, priv_mode_q, trap_to_s,
                        mip_live, mie_q, mstatus_q, mtvec_q, mepc_q);
`endif
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
                    `CSR_MIP:       mip_sw_q   <= (mip_sw_q  & ~MIP_M_WRITABLE) |
                                                  (new_val   &  MIP_M_WRITABLE);
                    `CSR_MTVEC:     mtvec_q    <= {new_val[31:2], 1'b0, new_val[0]};
                    `CSR_MSCRATCH:  begin
                                    mscratch_q <= new_val;
`ifdef VERILATOR
                                    if (trace_dbg_en)
                                        $display("[MSCRATCH] t=%0t old=%08x new=%08x priv=%0d csr_addr=%03x",
                                            $time, mscratch_q, new_val, priv_mode_q, csr_addr);
`endif
                                    end
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
                    `CSR_SIP:       mip_sw_q   <= (mip_sw_q  & ~MIP_S_WRITABLE) |
                                                  (new_val   &  MIP_S_WRITABLE & mideleg_q);
                    `CSR_STVEC:     stvec_q    <= {new_val[31:2], 1'b0, new_val[0]};
                    `CSR_SSCRATCH:  begin
                                    sscratch_q <= new_val;
`ifdef VERILATOR
                                    if (trace_dbg_en)
                                        $display("[SSCRATCH] t=%0t old=%08x new=%08x priv=%0d csr_addr=%03x",
                                            $time, sscratch_q, new_val, priv_mode_q, csr_addr);
`endif
                                    end
                    `CSR_SEPC:      sepc_q     <= {new_val[31:2], 2'b00};
                    `CSR_SCAUSE:    scause_q   <= new_val;
                    `CSR_STVAL:     stval_q    <= new_val;
                    `CSR_SATP:      satp_q     <= new_val;
                    // PMP WARL: lock bit (L) makes the cfg byte + pmpaddr
                    // read-only; TOR on entry i locks pmpaddr[i-1] as well.
                    `CSR_PMPCFG0:   pmpcfg_q[0] <= pmpcfg_write_mask(pmpcfg_q[0], new_val);
                    `CSR_PMPCFG1:   pmpcfg_q[1] <= pmpcfg_write_mask(pmpcfg_q[1], new_val);
                    `CSR_PMPCFG2:   pmpcfg_q[2] <= pmpcfg_write_mask(pmpcfg_q[2], new_val);
                    `CSR_PMPCFG3:   pmpcfg_q[3] <= pmpcfg_write_mask(pmpcfg_q[3], new_val);
                    `CSR_PMPADDR0:  if (!pmpaddr_locked[0])  pmpaddr_q[0]  <= new_val;
                    `CSR_PMPADDR1:  if (!pmpaddr_locked[1])  pmpaddr_q[1]  <= new_val;
                    `CSR_PMPADDR2:  if (!pmpaddr_locked[2])  pmpaddr_q[2]  <= new_val;
                    `CSR_PMPADDR3:  if (!pmpaddr_locked[3])  pmpaddr_q[3]  <= new_val;
                    `CSR_PMPADDR4:  if (!pmpaddr_locked[4])  pmpaddr_q[4]  <= new_val;
                    `CSR_PMPADDR5:  if (!pmpaddr_locked[5])  pmpaddr_q[5]  <= new_val;
                    `CSR_PMPADDR6:  if (!pmpaddr_locked[6])  pmpaddr_q[6]  <= new_val;
                    `CSR_PMPADDR7:  if (!pmpaddr_locked[7])  pmpaddr_q[7]  <= new_val;
                    `CSR_PMPADDR8:  if (!pmpaddr_locked[8])  pmpaddr_q[8]  <= new_val;
                    `CSR_PMPADDR9:  if (!pmpaddr_locked[9])  pmpaddr_q[9]  <= new_val;
                    `CSR_PMPADDR10: if (!pmpaddr_locked[10]) pmpaddr_q[10] <= new_val;
                    `CSR_PMPADDR11: if (!pmpaddr_locked[11]) pmpaddr_q[11] <= new_val;
                    `CSR_PMPADDR12: if (!pmpaddr_locked[12]) pmpaddr_q[12] <= new_val;
                    `CSR_PMPADDR13: if (!pmpaddr_locked[13]) pmpaddr_q[13] <= new_val;
                    `CSR_PMPADDR14: if (!pmpaddr_locked[14]) pmpaddr_q[14] <= new_val;
                    `CSR_PMPADDR15: if (!pmpaddr_locked[15]) pmpaddr_q[15] <= new_val;
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

`ifdef VERILATOR
    // Debug $display traces ([TRAP]/[MSCRATCH]/[SSCRATCH]) are off by default.
    // Enable with `+trace_dbg` on the sim command line.
    bit trace_dbg_en = 1'b0;
    initial begin
        if ($test$plusargs("trace_dbg")) trace_dbg_en = 1'b1;
    end
`endif

endmodule
