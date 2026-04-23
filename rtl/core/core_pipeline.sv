// Stage 5 RV32IM pipelined core. Drop-in replacement for core_multicycle.
//
// 5 stages: IF / ID / EX / MEM / WB.
//
//   IF : issue ifetch_req for pc_q; latch rsp into IF/ID pipeline register.
//        One in-flight fetch; squash-on-redirect for in-flight responses.
//   ID : decode, regfile async-read with WB→ID bypass, hazard/serialize detect.
//   EX : operand forwarding from EX/MEM and MEM/WB stages, ALU, branch
//        resolution (static NT; taken branches redirect w/ 2-bubble flush),
//        M-ext MUL (1-cycle) / DIV (stall EX ~33 cycles), exception detect
//        (illegal/ecall/ebreak/misaligned), L/S address compute.
//   MEM: drive dmem_req; wait for dmem_rsp_valid; align/sign-ext loads; bus
//        faults become traps.
//   WB : write regfile, drive CSR read/write + trap/mret, emit commit trace.
//        Traps commit here (flush-to-retirement) → program-order trace.
//
// CSR / MRET / ECALL / EBREAK / WFI / FENCE* are "serializing": ID stalls
// them until the pipe drains, then dispatches them alone. CSR state is
// read AND written at WB — no EX-time CSR read needed.
//
// Interrupts: injected as a trap-carrying bubble at IF when the pipe is
// idle (ex/mem/wb valid all 0). It flows through to WB and commits.
//
// A-extension (LR/SC/AMO) stubbed as illegal for now — see task 5E.

`include "defs.svh"
`ifdef RISCV_FORMAL
`include "rvfi_macros.vh"
`endif

module core_pipeline #(
    parameter logic [31:0] RESET_PC = `RESET_PC
) (
    input  logic        clk,
    input  logic        rst,

    // ---- ifetch bus ----
    output logic        ifetch_req_valid,
    output logic [31:0] ifetch_req_addr,
    input  logic        ifetch_req_ready,
    input  logic        ifetch_rsp_valid,
    input  logic [31:0] ifetch_rsp_data,
    input  logic        ifetch_rsp_fault,
    input  logic        ifetch_rsp_pagefault,
    output logic        ifetch_rsp_ready,

    // ---- dmem bus ----
    output logic        dmem_req_valid,
    output logic [31:0] dmem_req_addr,
    output logic        dmem_req_wen,
    output logic [31:0] dmem_req_wdata,
    output logic [3:0]  dmem_req_wmask,
    output logic [1:0]  dmem_req_size,
    input  logic        dmem_req_ready,
    input  logic        dmem_rsp_valid,
    input  logic [31:0] dmem_rsp_rdata,
    input  logic        dmem_rsp_fault,
    input  logic        dmem_rsp_pagefault,
    output logic        dmem_rsp_ready,

    // ---- ext interrupt lines ----
    input  logic        ext_mti,
    input  logic        ext_msi,
    input  logic        ext_mei,
    input  logic        ext_sei,

    // ---- commit trace ----
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic        commit_rd_wen,
    output logic [4:0]  commit_rd_addr,
    output logic [31:0] commit_rd_data,
    output logic        commit_trap,
    output logic [31:0] commit_cause,

    // ---- icache invalidate on FENCE.I (1-cycle pulse at retirement) ----
    output logic        icache_invalidate,

    // ---- TLB flush on SFENCE.VMA (1-cycle pulse at retirement) ----
    // rs1_nz / rs2_nz are the ISA "is x0?" booleans; rs1_va is the raw
    // register value (low 12 bits ignored by the MMU), rs2_asid is the low
    // 9 bits of rs2. See mmu.sv port comment for exact semantics.
    output logic        mmu_sfence_vma,
    output logic        mmu_sfence_rs1_nz,
    output logic [31:0] mmu_sfence_rs1_va,
    output logic        mmu_sfence_rs2_nz,
    output logic [8:0]  mmu_sfence_rs2_asid,

    // ---- CSR state visible to the MMU (Stage 6C-2) ----
    output logic [31:0] mmu_satp,
    output logic [1:0]  mmu_priv,
    output logic        mmu_mprv,
    output logic [1:0]  mmu_mpp,
    output logic        mmu_sum,
    output logic        mmu_mxr,
    output logic [15:0][7:0]  mmu_pmp_cfg,
    output logic [15:0][31:0] mmu_pmp_addr
`ifdef RISCV_FORMAL
    ,`RVFI_OUTPUTS
`endif
);

    assign mmu_satp = satp_v;
    assign mmu_priv = priv_mode_v;
    assign mmu_mprv = mstatus_mprv_v;
    assign mmu_mpp  = mstatus_mpp_v;
    assign mmu_sum  = sstatus_sum_v;
    assign mmu_mxr  = mstatus_mxr_v;

    // ========================================================================
    // Signal declarations (all at top for clarity)
    // ========================================================================
    // PC + fetch tracker
    logic [31:0] pc_q, pc_d;
    logic        fetch_inflight_q, fetch_inflight_d;
    logic [31:0] fetch_inflight_pc_q, fetch_inflight_pc_d;
    logic        fetch_squash_q, fetch_squash_d;

    // IF/ID
    logic        id_valid_q, id_valid_d;
    logic [31:0] id_pc_q, id_pc_d;
    logic [31:0] id_instr_q, id_instr_d;
    logic        id_fault_q, id_fault_d;
    logic        id_pagefault_q, id_pagefault_d;
    logic        id_irq_q, id_irq_d;
    logic [31:0] id_irq_cause_q, id_irq_cause_d;

    // ID/EX — operand & control
    logic        ex_valid_q, ex_valid_d;
    logic [31:0] ex_pc_q, ex_pc_d;
    logic [31:0] ex_instr_q, ex_instr_d;
    logic [31:0] ex_rs1_q_data, ex_rs1_d_data;   // named to avoid clash
    logic [31:0] ex_rs2_q_data, ex_rs2_d_data;
    logic [31:0] ex_imm_q, ex_imm_d;
    logic [3:0]  ex_alu_op_q, ex_alu_op_d;
    logic [1:0]  ex_alu_a_sel_q, ex_alu_a_sel_d;
    logic [1:0]  ex_alu_b_sel_q, ex_alu_b_sel_d;
    logic [4:0]  ex_rd_q, ex_rd_d;
    logic [4:0]  ex_rs1_q, ex_rs1_d;
    logic [4:0]  ex_rs2_q, ex_rs2_d;
    logic [2:0]  ex_funct3_q, ex_funct3_d;
    logic [11:0] ex_csr_addr_q, ex_csr_addr_d;
    logic        ex_rd_wen_q, ex_rd_wen_d;
    logic        ex_rs1_used_q, ex_rs1_used_d;
    logic        ex_rs2_used_q, ex_rs2_used_d;
    logic        ex_is_lui_q, ex_is_lui_d;
    logic        ex_is_auipc_q, ex_is_auipc_d;
    logic        ex_is_jal_q, ex_is_jal_d;
    logic        ex_is_jalr_q, ex_is_jalr_d;
    logic        ex_is_branch_q, ex_is_branch_d;
    logic        ex_is_load_q, ex_is_load_d;
    logic        ex_is_store_q, ex_is_store_d;
    logic        ex_is_csr_q, ex_is_csr_d;
    logic        ex_is_ecall_q, ex_is_ecall_d;
    logic        ex_is_ebreak_q, ex_is_ebreak_d;
    logic        ex_is_mret_q, ex_is_mret_d;
    logic        ex_is_sret_q, ex_is_sret_d;
    logic        ex_is_wfi_q, ex_is_wfi_d;
    logic        ex_is_mul_q, ex_is_mul_d;
    logic        ex_is_div_q, ex_is_div_d;
    logic        ex_is_lr_q, ex_is_lr_d;
    logic        ex_is_sc_q, ex_is_sc_d;
    logic        ex_is_amo_rmw_q, ex_is_amo_rmw_d;
    logic [4:0]  ex_amo_funct5_q, ex_amo_funct5_d;
    logic        ex_is_serial_q, ex_is_serial_d;
    logic        ex_fetch_fault_q, ex_fetch_fault_d;
    logic        ex_fetch_pagefault_q, ex_fetch_pagefault_d;
    logic        ex_illegal_q, ex_illegal_d;
    logic        ex_irq_q, ex_irq_d;
    logic [31:0] ex_irq_cause_q, ex_irq_cause_d;

    // EX/MEM
    logic        mem_valid_q, mem_valid_d;
    logic [31:0] mem_pc_q, mem_pc_d;
    logic [31:0] mem_instr_q, mem_instr_d;
    logic [31:0] mem_alu_y_q, mem_alu_y_d;     // load/store address OR arith result
    logic        mem_has_result_q, mem_has_result_d;  // forward-viable arith
    logic [31:0] mem_result_q, mem_result_d;          // arith value (forward)
    logic [31:0] mem_store_wdata_q, mem_store_wdata_d;
    logic [3:0]  mem_store_wmask_q, mem_store_wmask_d;
    logic [2:0]  mem_funct3_q, mem_funct3_d;
    logic [4:0]  mem_rd_q, mem_rd_d;
    logic        mem_rd_wen_q, mem_rd_wen_d;
    logic        mem_is_load_q, mem_is_load_d;
    logic        mem_is_store_q, mem_is_store_d;
    logic        mem_is_csr_q, mem_is_csr_d;
    logic        mem_is_mret_q, mem_is_mret_d;
    logic        mem_is_sret_q, mem_is_sret_d;
    logic        mem_is_serial_q, mem_is_serial_d;
    logic        mem_is_lr_q, mem_is_lr_d;
    logic        mem_is_sc_q, mem_is_sc_d;
    logic        mem_is_amo_rmw_q, mem_is_amo_rmw_d;
    logic [4:0]  mem_amo_funct5_q, mem_amo_funct5_d;
    logic [31:0] mem_amo_rs2_q, mem_amo_rs2_d;
    logic        mem_amo_phase_q, mem_amo_phase_d;   // 0 = load beat, 1 = store beat
    logic [31:0] mem_amo_old_q;                       // latched on AMO load rsp
    logic [11:0] mem_csr_addr_q, mem_csr_addr_d;
    logic [31:0] mem_csr_wdata_q, mem_csr_wdata_d;
    logic [2:0]  mem_csr_op_q, mem_csr_op_d;
    logic [4:0]  mem_csr_rs1imm_q, mem_csr_rs1imm_d;
    // SFENCE.VMA needs the live rs1/rs2 register values at retire to drive
    // the MMU's per-VA/per-ASID flush. They are captured at EX and carried
    // through MEM/WB — meaningless for non-SFENCE retirements, but cheap.
    logic [31:0] mem_sfence_rs1_q, mem_sfence_rs1_d;
    logic [31:0] mem_sfence_rs2_q, mem_sfence_rs2_d;
    logic        mem_trap_q, mem_trap_d;
    logic [31:0] mem_cause_q, mem_cause_d;
    logic [31:0] mem_tval_q, mem_tval_d;
    logic        mem_ls_pending_q, mem_ls_pending_d;
    logic        mem_req_fired_q; // 1 once dmem_req was accepted; prevents re-issue
    logic        mem_bus_fault_q; // latched from dmem_rsp when it arrives
    logic        mem_bus_pagefault_q; // latched: mmu-reported page fault (mutex w/ bus_fault)
    logic [31:0] mem_load_data_q; // latched from load rsp (aligned/ext)

    // MEM/WB
    logic        wb_valid_q, wb_valid_d;
    logic [31:0] wb_pc_q, wb_pc_d;
    logic [31:0] wb_instr_q, wb_instr_d;
    logic [4:0]  wb_rd_q, wb_rd_d;
    logic        wb_rd_wen_q, wb_rd_wen_d;
    logic [31:0] wb_result_q, wb_result_d;
    logic        wb_trap_q, wb_trap_d;
    logic [31:0] wb_cause_q, wb_cause_d;
    logic [31:0] wb_tval_q, wb_tval_d;
    logic        wb_is_mret_q, wb_is_mret_d;
    logic        wb_is_sret_q, wb_is_sret_d;
    logic        wb_is_csr_q, wb_is_csr_d;
    logic        wb_is_serial_q, wb_is_serial_d;
    logic [11:0] wb_csr_addr_q, wb_csr_addr_d;
    logic [31:0] wb_csr_wdata_q, wb_csr_wdata_d;
    logic [2:0]  wb_csr_op_q, wb_csr_op_d;
    logic [4:0]  wb_csr_rs1imm_q, wb_csr_rs1imm_d;
    logic [31:0] wb_sfence_rs1_q, wb_sfence_rs1_d;
    logic [31:0] wb_sfence_rs2_q, wb_sfence_rs2_d;

    // Control / hazards / flush
    logic stall_id, stall_ex, stall_mem;
    logic flush_if, flush_id, flush_ex;
    logic branch_redirect;
    logic [31:0] branch_redirect_pc;
    logic wb_redirect;
    logic [31:0] wb_redirect_pc;
    logic trap_pending_q, trap_pending_d;  // latch from EX detect → WB clear

    // LR/SC reservation state
    logic        resv_valid_q;
    logic [29:0] resv_addr_q;   // word-aligned reservation addr (bits [31:2])

    // CSR-visible
    logic [31:0] mtvec_v, mepc_v;
    logic [31:0] stvec_v, sepc_v, satp_v;
    logic [1:0]  priv_mode_v, mstatus_mpp_v;
    logic        trap_to_s_v;
    logic        sstatus_sum_v, mstatus_mxr_v, mstatus_mprv_v;
    logic        mstatus_tvm_v, mstatus_tsr_v;
    logic        irq_pending_v;
    logic [31:0] irq_cause_v;

    // CSR interface
    logic        csr_en_wb;
    logic        trap_take_wb;
    logic        mret_wb;
    logic        sret_wb;
    logic        retire_wb;
    logic [31:0] csr_rdata_w;
    logic        csr_illegal_w;

    // Regfile interface
    logic        rf_wen;
    logic [4:0]  rf_rd_addr;
    logic [31:0] rf_rd_data;
    logic [31:0] rf_rs1_data, rf_rs2_data;

    // ========================================================================
    // Regfile (ID reads, WB writes)
    // ========================================================================
    regfile u_rf (
        .clk(clk),
        .rs1_addr(id_instr_q[19:15]), .rs1_data(rf_rs1_data),
        .rs2_addr(id_instr_q[24:20]), .rs2_data(rf_rs2_data),
        .wen(rf_wen), .rd_addr(rf_rd_addr), .rd_data(rf_rd_data)
    );

    // ========================================================================
    // IF stage
    // ========================================================================
    wire if_id_slot_free_next = !id_valid_q || !stall_id;
    // IRQ inject: fire when nothing is in EX/MEM/WB, no fetch is in flight,
    // and no IRQ bubble is already in ID. id_valid_q can be 1 (a real instr
    // currently sitting in ID) — we'll kick that instr out via id_will_bubble
    // and capture its PC as mepc (so kernel re-executes it on return).
    wire allow_irq_inject =  irq_pending_v && !ex_valid_q && !mem_valid_q && !wb_valid_q &&
                             !fetch_inflight_q && !trap_pending_q && !id_irq_q;
    wire if_can_issue = !fetch_inflight_q && if_id_slot_free_next &&
                        !branch_redirect && !wb_redirect &&
                        !trap_pending_q && !allow_irq_inject;

    assign ifetch_req_valid = if_can_issue && !rst;
    assign ifetch_req_addr  = pc_q;
    // Only assert rsp_ready when a fetch is in-flight. If the MMU delivers
    // a same-cycle rsp (e.g. walk-result pagefault fires req_ready=1 and
    // rsp_valid=1 simultaneously), the MMU's if_fault_rsp_done sees our
    // rsp_ready and clears if_xlate_valid_q next cycle — but we only sample
    // rsp_arriving on the cycle *after* the handshake (fetch_inflight_q=1),
    // so the rsp would be silently dropped. Gating rsp_ready keeps the MMU
    // holding the rsp/valid_q through the cycle we actually latch it.
    assign ifetch_rsp_ready = fetch_inflight_q;

    wire rsp_arriving   = fetch_inflight_q && ifetch_rsp_valid;
    wire rsp_consumable = rsp_arriving && !fetch_squash_q;

    // PC update
    always_comb begin
        pc_d = pc_q;
        if (wb_redirect) begin
            pc_d = wb_redirect_pc;
        end else if (branch_redirect) begin
            pc_d = branch_redirect_pc;
        end else if (ifetch_req_valid && ifetch_req_ready) begin
            pc_d = pc_q + 32'd4;
        end
    end

    // Fetch in-flight tracker
    always_comb begin
        fetch_inflight_d    = fetch_inflight_q;
        fetch_inflight_pc_d = fetch_inflight_pc_q;
        fetch_squash_d      = fetch_squash_q;

        if (rsp_arriving) begin
            fetch_inflight_d = 1'b0;
            fetch_squash_d   = 1'b0;
        end
        if (ifetch_req_valid && ifetch_req_ready) begin
            fetch_inflight_d    = 1'b1;
            fetch_inflight_pc_d = pc_q;
            fetch_squash_d      = 1'b0;
        end
        if ((branch_redirect || wb_redirect) && fetch_inflight_d && !rsp_arriving) begin
            fetch_squash_d = 1'b1;
        end
    end

    // IF/ID update
    always_comb begin
        id_valid_d     = id_valid_q;
        id_pc_d        = id_pc_q;
        id_instr_d     = id_instr_q;
        id_fault_d     = id_fault_q;
        id_pagefault_d = id_pagefault_q;
        id_irq_d       = id_irq_q;
        id_irq_cause_d = id_irq_cause_q;

        if (flush_id) begin
            id_valid_d = 1'b0;
            id_irq_d   = 1'b0;
        end else if (!id_valid_q || !stall_id) begin
            // ID slot is accepting: either empty, or current instr is advancing
            // to EX this cycle. If stall_id is high because of a *downstream*
            // hazard (e.g. DIV in EX), an empty ID can still absorb an arriving
            // rsp — the stall only forbids ID→EX advance, not IF→ID fill.
            if (allow_irq_inject) begin
                id_valid_d     = 1'b1;
                // Capture the PC of the instruction the IRQ pre-empts. If ID
                // already holds a real instr (id_valid_q=1), use its PC — that
                // instr is being kicked out (id_will_bubble forces a bubble
                // into EX), so kernel must re-execute it on mret return. If ID
                // is empty, use pc_q (next-to-fetch PC).
                id_pc_d        = id_valid_q ? id_pc_q : pc_q;
                // Use all-zero encoding (not 0x13/NOP): 0 has opcode=0 which
                // doesn't match any legal insn, so riscv-formal's insn checks
                // see spec_valid=0 and skip the retirement — as they should,
                // since this is a trap retirement, not a real insn commit.
                // 0x13 = ADDI x0,x0,0 used to leak into the insn_addi check.
                id_instr_d     = 32'h0000_0000;
                id_fault_d     = 1'b0;
                id_pagefault_d = 1'b0;
                id_irq_d       = 1'b1;
                id_irq_cause_d = irq_cause_v;
            end else if (rsp_consumable) begin
                id_valid_d     = 1'b1;
                id_pc_d        = fetch_inflight_pc_q;
                id_instr_d     = ifetch_rsp_data;
                id_fault_d     = ifetch_rsp_fault;
                id_pagefault_d = ifetch_rsp_pagefault;
                id_irq_d       = 1'b0;
                id_irq_cause_d = 32'd0;
            end else begin
                id_valid_d = 1'b0;
                id_irq_d   = 1'b0;
            end
        end
    end

    // ========================================================================
    // ID stage — decode
    // ========================================================================
    wire [6:0]  id_opcode = id_instr_q[6:0];
    wire [2:0]  id_funct3 = id_instr_q[14:12];
    wire [6:0]  id_funct7 = id_instr_q[31:25];
    wire [4:0]  id_rd     = id_instr_q[11:7];
    wire [4:0]  id_rs1    = id_instr_q[19:15];
    wire [4:0]  id_rs2    = id_instr_q[24:20];
    wire [11:0] id_csr_addr = id_instr_q[31:20];

    wire id_is_lui     = (id_opcode == `OP_LUI);
    wire id_is_auipc   = (id_opcode == `OP_AUIPC);
    wire id_is_jal     = (id_opcode == `OP_JAL);
    wire id_is_jalr    = (id_opcode == `OP_JALR);
    wire id_is_branch  = (id_opcode == `OP_BRANCH);
    wire id_is_load    = (id_opcode == `OP_LOAD);
    wire id_is_store   = (id_opcode == `OP_STORE);
    wire id_is_op_imm  = (id_opcode == `OP_OP_IMM);
    wire id_is_op      = (id_opcode == `OP_OP);
    wire id_is_misc    = (id_opcode == `OP_MISC_MEM);
    wire id_is_system  = (id_opcode == `OP_SYSTEM);
    wire id_is_amo     = (id_opcode == `OP_AMO);
    wire id_is_ecall   = id_is_system && (id_funct3 == `F3_PRIV) && (id_instr_q[31:20] == 12'h000);
    wire id_is_ebreak  = id_is_system && (id_funct3 == `F3_PRIV) && (id_instr_q[31:20] == 12'h001);
    wire id_is_mret    = id_is_system && (id_funct3 == `F3_PRIV) && (id_instr_q[31:20] == 12'h302);
    wire id_is_sret    = id_is_system && (id_funct3 == `F3_PRIV) && (id_instr_q[31:20] == 12'h102);
    wire id_is_wfi     = id_is_system && (id_funct3 == `F3_PRIV) && (id_instr_q[31:20] == 12'h105);
    // SFENCE.VMA: funct7=0001001, rs2/rs1 are operands (we ignore both — flush-all)
    wire id_is_sfence  = id_is_system && (id_funct3 == `F3_PRIV) && (id_instr_q[31:25] == 7'b0001001);
    wire id_is_csr     = id_is_system && (id_funct3 != `F3_PRIV);
    wire id_is_muldiv  = id_is_op && (id_funct7 == `F7_MULDIV);
    wire id_is_mul     = id_is_muldiv && !id_funct3[2];
    wire id_is_div     = id_is_muldiv &&  id_funct3[2];

    // A-extension decode (funct3 must be 010 = word; funct5 in bits [31:27])
    wire        id_is_amo_w  = id_is_amo && (id_funct3 == `F3_AMO_W);
    wire [4:0]  id_amo_funct5 = id_instr_q[31:27];
    wire id_is_lr      = id_is_amo_w && (id_amo_funct5 == `AMO_LR) && (id_rs2 == 5'd0);
    wire id_is_sc      = id_is_amo_w && (id_amo_funct5 == `AMO_SC);
    wire id_is_amo_rmw = id_is_amo_w && !id_is_lr && !id_is_sc &&
                         ((id_amo_funct5 == `AMO_SWAP) || (id_amo_funct5 == `AMO_ADD) ||
                          (id_amo_funct5 == `AMO_XOR)  || (id_amo_funct5 == `AMO_AND) ||
                          (id_amo_funct5 == `AMO_OR)   || (id_amo_funct5 == `AMO_MIN) ||
                          (id_amo_funct5 == `AMO_MAX)  || (id_amo_funct5 == `AMO_MINU) ||
                          (id_amo_funct5 == `AMO_MAXU));
    wire id_is_atomic  = id_is_lr || id_is_sc || id_is_amo_rmw;

    wire id_is_serial  = id_is_csr || id_is_mret || id_is_sret || id_is_ecall ||
                         id_is_ebreak || id_is_wfi || id_is_misc || id_is_atomic ||
                         id_is_sfence;

    wire id_rs1_used = id_is_jalr || id_is_branch || id_is_load || id_is_store ||
                       id_is_op_imm || id_is_op || id_is_atomic ||
                       (id_is_csr && !id_funct3[2]);
    wire id_rs2_used = id_is_branch || id_is_store || id_is_op ||
                       id_is_sc || id_is_amo_rmw;
    wire id_writes_rd = (id_is_lui || id_is_auipc || id_is_jal || id_is_jalr ||
                         id_is_load || id_is_op_imm || id_is_op || id_is_csr ||
                         id_is_atomic) &&
                        (id_rd != 5'd0);

    // Immediates
    logic [31:0] id_imm_i, id_imm_s, id_imm_b, id_imm_u, id_imm_j;
    imm_gen u_imm (.instr(id_instr_q),
                   .imm_i(id_imm_i), .imm_s(id_imm_s), .imm_b(id_imm_b),
                   .imm_u(id_imm_u), .imm_j(id_imm_j));

    // Illegal opcode / CSR
    logic id_illegal;
    always_comb begin
        id_illegal = 1'b0;
        unique case (id_opcode)
            `OP_LUI, `OP_AUIPC, `OP_JAL, `OP_JALR,
            `OP_BRANCH, `OP_LOAD, `OP_STORE,
            `OP_OP_IMM, `OP_OP, `OP_MISC_MEM, `OP_SYSTEM:
                id_illegal = 1'b0;
            `OP_AMO: begin
                if (!id_is_amo_w || !(id_is_lr || id_is_sc || id_is_amo_rmw)) id_illegal = 1'b1;
            end
            default:
                id_illegal = 1'b1;
        endcase
        if (id_is_op_imm && (id_funct3 == `F3_SLL)) begin
            if (id_funct7 != 7'b0000000) id_illegal = 1'b1;
        end else if (id_is_op_imm && (id_funct3 == `F3_SRL_SRA)) begin
            if ((id_funct7 != 7'b0000000) && (id_funct7 != 7'b0100000)) id_illegal = 1'b1;
        end
        if (id_is_op) begin
            unique case ({id_funct7, id_funct3})
                {7'b0000000, `F3_ADD_SUB}, {7'b0100000, `F3_ADD_SUB},
                {7'b0000000, `F3_SLL},
                {7'b0000000, `F3_SLT},
                {7'b0000000, `F3_SLTU},
                {7'b0000000, `F3_XOR},
                {7'b0000000, `F3_SRL_SRA}, {7'b0100000, `F3_SRL_SRA},
                {7'b0000000, `F3_OR},
                {7'b0000000, `F3_AND},
                {`F7_MULDIV, `F3_MUL},    {`F7_MULDIV, `F3_MULH},
                {`F7_MULDIV, `F3_MULHSU}, {`F7_MULDIV, `F3_MULHU},
                {`F7_MULDIV, `F3_DIV},    {`F7_MULDIV, `F3_DIVU},
                {`F7_MULDIV, `F3_REM},    {`F7_MULDIV, `F3_REMU}: /* ok */ ;
                default: id_illegal = 1'b1;
            endcase
        end
        if (id_is_system && (id_funct3 == `F3_PRIV)) begin
            if (id_is_sfence) begin
                // SFENCE.VMA rs1, rs2 — rs1/rs2 are operands, rd must be 0.
                // Illegal from U-mode; also illegal from S-mode when TVM=1.
                if (id_rd != 5'd0) id_illegal = 1'b1;
                if (priv_mode_v == `PRV_U) id_illegal = 1'b1;
                if (priv_mode_v == `PRV_S && mstatus_tvm_v) id_illegal = 1'b1;
            end else begin
                unique case (id_instr_q[31:20])
                    12'h000, 12'h001, 12'h302, 12'h102, 12'h105: /* ok */ ;
                    default: id_illegal = 1'b1;
                endcase
                if (id_rd != 5'd0 || id_rs1 != 5'd0) id_illegal = 1'b1;
                // SRET illegal from U always; illegal from S when TSR=1.
                if (id_is_sret && priv_mode_v == `PRV_U) id_illegal = 1'b1;
                if (id_is_sret && priv_mode_v == `PRV_S && mstatus_tsr_v) id_illegal = 1'b1;
                // MRET requires M-mode.
                if (id_is_mret && priv_mode_v != `PRV_M) id_illegal = 1'b1;
            end
        end
        // CSR illegal: writing a read-only CSR (addr[11:10]==11 and op is W/S/C with nonzero src)
        if (id_is_csr) begin
            logic csr_writes;
            csr_writes = 1'b0;
            unique case (id_funct3)
                `F3_CSRRW, `F3_CSRRWI:  csr_writes = 1'b1;
                `F3_CSRRS, `F3_CSRRC,
                `F3_CSRRSI, `F3_CSRRCI: csr_writes = (id_rs1 != 5'd0);
                default:                csr_writes = 1'b0;
            endcase
            if (id_csr_addr[11:10] == 2'b11 && csr_writes) id_illegal = 1'b1;
            // Non-implemented CSR addresses → illegal. Check against the CSR map.
            unique case (id_csr_addr)
                `CSR_MSTATUS, `CSR_MISA, `CSR_MIE, `CSR_MIP,
                `CSR_MEDELEG, `CSR_MIDELEG,
                `CSR_MTVEC, `CSR_MSCRATCH, `CSR_MEPC, `CSR_MCAUSE, `CSR_MTVAL,
                `CSR_MCYCLE, `CSR_MCYCLEH, `CSR_MINSTRET, `CSR_MINSTRETH,
                `CSR_CYCLE,  `CSR_CYCLEH,  `CSR_INSTRET,  `CSR_INSTRETH,
                `CSR_MHARTID, `CSR_MVENDORID, `CSR_MARCHID, `CSR_MIMPID,
                `CSR_SSTATUS, `CSR_SIE, `CSR_SIP, `CSR_STVEC, `CSR_SCOUNTEREN,
                `CSR_SSCRATCH, `CSR_SEPC, `CSR_SCAUSE, `CSR_STVAL, `CSR_SATP,
                `CSR_PMPCFG0,  `CSR_PMPCFG1,  `CSR_PMPCFG2,  `CSR_PMPCFG3,
                `CSR_PMPADDR0, `CSR_PMPADDR1, `CSR_PMPADDR2, `CSR_PMPADDR3,
                `CSR_PMPADDR4, `CSR_PMPADDR5, `CSR_PMPADDR6, `CSR_PMPADDR7,
                `CSR_PMPADDR8, `CSR_PMPADDR9, `CSR_PMPADDR10, `CSR_PMPADDR11,
                `CSR_PMPADDR12, `CSR_PMPADDR13, `CSR_PMPADDR14, `CSR_PMPADDR15:
                    /* ok */ ;
                default: id_illegal = 1'b1;
            endcase
            // satp access from S-mode with TVM=1 is illegal, regardless of op.
            if (id_csr_addr == `CSR_SATP &&
                priv_mode_v == `PRV_S && mstatus_tvm_v)
                id_illegal = 1'b1;
        end
    end

    // Register read with WB→ID bypass (WB drives regfile write this cycle;
    // async reads see old value until posedge).
    wire [31:0] id_rs1_data = (rf_wen && rf_rd_addr == id_rs1 && id_rs1 != 5'd0)
                              ? rf_rd_data : rf_rs1_data;
    wire [31:0] id_rs2_data = (rf_wen && rf_rd_addr == id_rs2 && id_rs2 != 5'd0)
                              ? rf_rd_data : rf_rs2_data;

    // ========================================================================
    // Hazard / stall detection
    // ========================================================================
    wire load_use_hazard = mem_valid_q && mem_is_load_q && mem_rd_wen_q && (mem_rd_q != 5'd0) &&
                           id_valid_q &&
                           ((id_rs1_used && mem_rd_q == id_rs1) ||
                            (id_rs2_used && mem_rd_q == id_rs2));

    wire serial_inflight = (ex_valid_q  && ex_is_serial_q) ||
                           (mem_valid_q && mem_is_serial_q) ||
                           (wb_valid_q  && wb_is_serial_q);
    wire pipe_busy_ahead_of_id = ex_valid_q || mem_valid_q || wb_valid_q;

    // Divider "busy": from the cycle we start until the cycle we've latched done
    // AND the DIV insn is actually advancing out of EX.
    logic        div_start_pulse;
    logic        div_busy_sig, div_done_sig;
    logic [31:0] div_result_sig;
    logic        div_started_q, div_started_d;     // divide has been kicked off
    logic        div_done_latched_q, div_done_latched_d;
    logic [31:0] div_result_q_reg, div_result_d_reg;
    wire  ex_div_stall = ex_valid_q && ex_is_div_q && !div_done_latched_q;

    // MEM stall: MEM holds a load/store and the dmem handshake hasn't finished.
    wire mem_busy = mem_valid_q && mem_ls_pending_q;

    // csrw satp in MEM must stall until any in-flight ifetch response has
    // drained. If the pre-satp speculative fetch for pc+4 is still in the
    // MMU/fabric and satp flips to Sv32 first, the MMU switches from bare
    // passthrough to needs-walk mid-transaction and silently swallows the
    // arriving bare-mode response (if_ds_rsp_ready=1 but if_core_rsp_valid=0
    // in the walk branch). The pipeline then deadlocks with fetch_inflight_q=1.
    // Hold the csrw until the fetch returns so satp flips only when the
    // pipeline is quiesced.
    wire mem_is_csr_op    = mem_valid_q && !mem_trap_q &&
                            (mem_instr_q[6:0]   == `OP_SYSTEM) &&
                            (mem_instr_q[14:12] != `F3_PRIV);
    wire mem_is_csrw_satp = mem_is_csr_op && (mem_instr_q[31:20] == `CSR_SATP);
    wire mem_stall_for_ifetch_drain = mem_is_csrw_satp && fetch_inflight_q;

    assign stall_mem = mem_busy || mem_stall_for_ifetch_drain;
    assign stall_ex  = stall_mem || ex_div_stall;
    assign stall_id  = stall_ex || load_use_hazard ||
                       (id_valid_q && id_is_serial && pipe_busy_ahead_of_id) ||
                       (id_valid_q && serial_inflight && !id_is_serial);

    // ========================================================================
    // Flush control
    // ========================================================================
    assign flush_if = branch_redirect || wb_redirect;
    assign flush_id = branch_redirect || wb_redirect;
    assign flush_ex = wb_redirect;   // branch_redirect: EX itself (the branch) advances normally;
                                     // EX gets a bubble next cycle because ID/IF got flushed this cycle

    // ========================================================================
    // ID → ID/EX — build next-cycle payload (or bubble when flushed/stalled)
    // ========================================================================
    logic id_will_bubble;
    // Force ID→EX to bubble when the IRQ inject is going to overwrite a real
    // (non-IRQ) instruction in ID this cycle. Without this, the in-flight ID
    // instr would advance to EX and commit its side effects, then the kernel
    // would re-execute it on mret return — doubling the side effect.
    assign id_will_bubble = flush_ex || !id_valid_q || stall_id ||
                            (allow_irq_inject && id_valid_q && !id_irq_q);

    always_comb begin
        // Hold by default
        ex_valid_d       = ex_valid_q;
        ex_pc_d          = ex_pc_q;
        ex_instr_d       = ex_instr_q;
        ex_rs1_d_data    = ex_rs1_q_data;
        ex_rs2_d_data    = ex_rs2_q_data;
        ex_imm_d         = ex_imm_q;
        ex_alu_op_d      = ex_alu_op_q;
        ex_alu_a_sel_d   = ex_alu_a_sel_q;
        ex_alu_b_sel_d   = ex_alu_b_sel_q;
        ex_rd_d          = ex_rd_q;
        ex_rs1_d         = ex_rs1_q;
        ex_rs2_d         = ex_rs2_q;
        ex_funct3_d      = ex_funct3_q;
        ex_csr_addr_d    = ex_csr_addr_q;
        ex_rd_wen_d      = ex_rd_wen_q;
        ex_rs1_used_d    = ex_rs1_used_q;
        ex_rs2_used_d    = ex_rs2_used_q;
        ex_is_lui_d      = ex_is_lui_q;
        ex_is_auipc_d    = ex_is_auipc_q;
        ex_is_jal_d      = ex_is_jal_q;
        ex_is_jalr_d     = ex_is_jalr_q;
        ex_is_branch_d   = ex_is_branch_q;
        ex_is_load_d     = ex_is_load_q;
        ex_is_store_d    = ex_is_store_q;
        ex_is_csr_d      = ex_is_csr_q;
        ex_is_ecall_d    = ex_is_ecall_q;
        ex_is_ebreak_d   = ex_is_ebreak_q;
        ex_is_mret_d     = ex_is_mret_q;
        ex_is_sret_d     = ex_is_sret_q;
        ex_is_wfi_d      = ex_is_wfi_q;
        ex_is_mul_d      = ex_is_mul_q;
        ex_is_div_d      = ex_is_div_q;
        ex_is_lr_d       = ex_is_lr_q;
        ex_is_sc_d       = ex_is_sc_q;
        ex_is_amo_rmw_d  = ex_is_amo_rmw_q;
        ex_amo_funct5_d  = ex_amo_funct5_q;
        ex_is_serial_d   = ex_is_serial_q;
        ex_fetch_fault_d = ex_fetch_fault_q;
        ex_fetch_pagefault_d = ex_fetch_pagefault_q;
        ex_illegal_d     = ex_illegal_q;
        ex_irq_d         = ex_irq_q;
        ex_irq_cause_d   = ex_irq_cause_q;

        if (!stall_ex) begin
            if (id_will_bubble) begin
                // Bubble
                ex_valid_d       = 1'b0;
                ex_rd_wen_d      = 1'b0;
                ex_is_lui_d      = 1'b0;
                ex_is_auipc_d    = 1'b0;
                ex_is_jal_d      = 1'b0;
                ex_is_jalr_d     = 1'b0;
                ex_is_branch_d   = 1'b0;
                ex_is_load_d     = 1'b0;
                ex_is_store_d    = 1'b0;
                ex_is_csr_d      = 1'b0;
                ex_is_ecall_d    = 1'b0;
                ex_is_ebreak_d   = 1'b0;
                ex_is_mret_d     = 1'b0;
                ex_is_sret_d     = 1'b0;
                ex_is_wfi_d      = 1'b0;
                ex_is_mul_d      = 1'b0;
                ex_is_div_d      = 1'b0;
                ex_is_lr_d       = 1'b0;
                ex_is_sc_d       = 1'b0;
                ex_is_amo_rmw_d  = 1'b0;
                ex_is_serial_d   = 1'b0;
                ex_fetch_fault_d = 1'b0;
                ex_fetch_pagefault_d = 1'b0;
                ex_illegal_d     = 1'b0;
                ex_irq_d         = 1'b0;
            end else begin
                ex_valid_d       = 1'b1;
                ex_pc_d          = id_pc_q;
                ex_instr_d       = id_instr_q;
                ex_rs1_d_data    = id_rs1_data;
                ex_rs2_d_data    = id_rs2_data;
                ex_rd_d          = id_rd;
                ex_rs1_d         = id_rs1;
                ex_rs2_d         = id_rs2;
                ex_funct3_d      = id_funct3;
                ex_csr_addr_d    = id_csr_addr;
                ex_rd_wen_d      = id_writes_rd;
                ex_rs1_used_d    = id_rs1_used;
                ex_rs2_used_d    = id_rs2_used;
                ex_is_lui_d      = id_is_lui;
                ex_is_auipc_d    = id_is_auipc;
                ex_is_jal_d      = id_is_jal;
                ex_is_jalr_d     = id_is_jalr;
                ex_is_branch_d   = id_is_branch;
                ex_is_load_d     = id_is_load;
                ex_is_store_d    = id_is_store;
                ex_is_csr_d      = id_is_csr;
                ex_is_ecall_d    = id_is_ecall;
                ex_is_ebreak_d   = id_is_ebreak;
                ex_is_mret_d     = id_is_mret;
                ex_is_sret_d     = id_is_sret;
                ex_is_wfi_d      = id_is_wfi;
                ex_is_mul_d      = id_is_mul;
                ex_is_div_d      = id_is_div;
                ex_is_lr_d       = id_is_lr;
                ex_is_sc_d       = id_is_sc;
                ex_is_amo_rmw_d  = id_is_amo_rmw;
                ex_amo_funct5_d  = id_amo_funct5;
                ex_is_serial_d   = id_is_serial;
                ex_fetch_fault_d = id_fault_q;
                ex_fetch_pagefault_d = id_pagefault_q;
                ex_illegal_d     = id_illegal;
                ex_irq_d         = id_irq_q;
                ex_irq_cause_d   = id_irq_cause_q;

                // Immediate selection
                ex_imm_d = id_imm_i;
                unique case (1'b1)
                    id_is_lui, id_is_auipc: ex_imm_d = id_imm_u;
                    id_is_jal:              ex_imm_d = id_imm_j;
                    id_is_store:            ex_imm_d = id_imm_s;
                    id_is_branch:           ex_imm_d = id_imm_b;
                    id_is_jalr, id_is_load, id_is_op_imm: ex_imm_d = id_imm_i;
                    default: /* imm_i */ ;
                endcase

                // ALU control
                ex_alu_a_sel_d = 2'd0;
                ex_alu_b_sel_d = 2'd0;
                ex_alu_op_d    = 4'd0;
                unique case (1'b1)
                    id_is_lui:    begin ex_alu_a_sel_d = 2'd2; ex_alu_b_sel_d = 2'd1; ex_alu_op_d = 4'd10; end
                    id_is_auipc:  begin ex_alu_a_sel_d = 2'd1; ex_alu_b_sel_d = 2'd1; ex_alu_op_d = 4'd0;  end
                    id_is_jal,
                    id_is_jalr:   begin ex_alu_a_sel_d = 2'd1; ex_alu_b_sel_d = 2'd2; ex_alu_op_d = 4'd0;  end
                    id_is_load:   begin ex_alu_a_sel_d = 2'd0; ex_alu_b_sel_d = 2'd1; ex_alu_op_d = 4'd0;  end
                    id_is_store:  begin ex_alu_a_sel_d = 2'd0; ex_alu_b_sel_d = 2'd1; ex_alu_op_d = 4'd0;  end
                    id_is_branch: begin ex_alu_a_sel_d = 2'd0; ex_alu_b_sel_d = 2'd0; ex_alu_op_d = 4'd1;  end
                    id_is_op_imm: begin
                        ex_alu_a_sel_d = 2'd0; ex_alu_b_sel_d = 2'd1;
                        unique case (id_funct3)
                            `F3_ADD_SUB: ex_alu_op_d = 4'd0;
                            `F3_SLL:     ex_alu_op_d = 4'd5;
                            `F3_SLT:     ex_alu_op_d = 4'd8;
                            `F3_SLTU:    ex_alu_op_d = 4'd9;
                            `F3_XOR:     ex_alu_op_d = 4'd4;
                            `F3_SRL_SRA: ex_alu_op_d = id_funct7[5] ? 4'd7 : 4'd6;
                            `F3_OR:      ex_alu_op_d = 4'd3;
                            `F3_AND:     ex_alu_op_d = 4'd2;
                            default:     ex_alu_op_d = 4'd0;
                        endcase
                    end
                    id_is_op: begin
                        ex_alu_a_sel_d = 2'd0; ex_alu_b_sel_d = 2'd0;
                        unique case (id_funct3)
                            `F3_ADD_SUB: ex_alu_op_d = id_funct7[5] ? 4'd1 : 4'd0;
                            `F3_SLL:     ex_alu_op_d = 4'd5;
                            `F3_SLT:     ex_alu_op_d = 4'd8;
                            `F3_SLTU:    ex_alu_op_d = 4'd9;
                            `F3_XOR:     ex_alu_op_d = 4'd4;
                            `F3_SRL_SRA: ex_alu_op_d = id_funct7[5] ? 4'd7 : 4'd6;
                            `F3_OR:      ex_alu_op_d = 4'd3;
                            `F3_AND:     ex_alu_op_d = 4'd2;
                            default:     ex_alu_op_d = 4'd0;
                        endcase
                    end
                    default: /* defaults fine */ ;
                endcase
            end
        end
    end

    // ========================================================================
    // EX stage
    // ========================================================================
    // Operand forwarding (MEM→EX, WB→EX). The value in the ID/EX register
    // (ex_rs1_q_data / ex_rs2_q_data) was snapshot-read at ID with WB bypass;
    // here we override with later-stage results if applicable.
    logic [31:0] ex_rs1_fwd, ex_rs2_fwd;
    always_comb begin
        ex_rs1_fwd = ex_rs1_q_data;
        if (mem_valid_q && mem_has_result_q && mem_rd_wen_q && (mem_rd_q != 5'd0)
            && (mem_rd_q == ex_rs1_q)) begin
            ex_rs1_fwd = mem_result_q;
        end else if (wb_valid_q && wb_rd_wen_q && (wb_rd_q != 5'd0)
                     && (wb_rd_q == ex_rs1_q)) begin
            ex_rs1_fwd = wb_result_q;
        end

        ex_rs2_fwd = ex_rs2_q_data;
        if (mem_valid_q && mem_has_result_q && mem_rd_wen_q && (mem_rd_q != 5'd0)
            && (mem_rd_q == ex_rs2_q)) begin
            ex_rs2_fwd = mem_result_q;
        end else if (wb_valid_q && wb_rd_wen_q && (wb_rd_q != 5'd0)
                     && (wb_rd_q == ex_rs2_q)) begin
            ex_rs2_fwd = wb_result_q;
        end
    end

    // ALU
    logic [31:0] alu_a, alu_b, alu_y;
    logic        alu_eq, alu_lt, alu_ltu;
    always_comb begin
        unique case (ex_alu_a_sel_q)
            2'd0:    alu_a = ex_rs1_fwd;
            2'd1:    alu_a = ex_pc_q;
            2'd2:    alu_a = 32'd0;
            default: alu_a = ex_rs1_fwd;
        endcase
        unique case (ex_alu_b_sel_q)
            2'd0:    alu_b = ex_rs2_fwd;
            2'd1:    alu_b = ex_imm_q;
            2'd2:    alu_b = 32'd4;
            default: alu_b = ex_rs2_fwd;
        endcase
    end
    alu u_alu (.op(ex_alu_op_q), .a(alu_a), .b(alu_b), .y(alu_y),
               .eq(alu_eq), .lt(alu_lt), .ltu(alu_ltu));

    // Branch
    logic ex_branch_taken;
    always_comb begin
        ex_branch_taken = 1'b0;
        unique case (ex_funct3_q)
            `F3_BEQ:  ex_branch_taken =  alu_eq;
            `F3_BNE:  ex_branch_taken = !alu_eq;
            `F3_BLT:  ex_branch_taken =  alu_lt;
            `F3_BGE:  ex_branch_taken = !alu_lt;
            `F3_BLTU: ex_branch_taken =  alu_ltu;
            `F3_BGEU: ex_branch_taken = !alu_ltu;
            default:  ex_branch_taken = 1'b0;
        endcase
    end

    wire [31:0] jal_target    = ex_pc_q + ex_imm_q;
    wire [31:0] jalr_target   = (ex_rs1_fwd + ex_imm_q) & ~32'd1;
    wire [31:0] branch_target = ex_pc_q + ex_imm_q;
    wire ex_is_atomic_q = ex_is_lr_q || ex_is_sc_q || ex_is_amo_rmw_q;
    wire [31:0] ls_addr       = ex_is_atomic_q ? ex_rs1_fwd : (ex_rs1_fwd + ex_imm_q);
    wire        ex_take_branch = ex_valid_q && ex_is_branch_q && ex_branch_taken;
    wire        ex_take_jal    = ex_valid_q && ex_is_jal_q;
    wire        ex_take_jalr   = ex_valid_q && ex_is_jalr_q;

    // Target misalignment
    logic ex_target_misaligned;
    logic [31:0] ex_misaligned_target;
    always_comb begin
        ex_target_misaligned = 1'b0;
        ex_misaligned_target = 32'd0;
        if (ex_take_jal    && (jal_target[1:0]    != 2'b00)) begin ex_target_misaligned = 1'b1; ex_misaligned_target = jal_target;    end
        if (ex_take_jalr   && (jalr_target[1:0]   != 2'b00)) begin ex_target_misaligned = 1'b1; ex_misaligned_target = jalr_target;   end
        if (ex_take_branch && (branch_target[1:0] != 2'b00)) begin ex_target_misaligned = 1'b1; ex_misaligned_target = branch_target; end
    end

    // Load/store misalignment
    logic ex_ls_misaligned;
    always_comb begin
        ex_ls_misaligned = 1'b0;
        if (ex_valid_q && (ex_is_load_q || ex_is_store_q)) begin
            unique case (ex_funct3_q)
                `F3_LH, `F3_LHU, `F3_SH: ex_ls_misaligned = (ls_addr[0]   != 1'b0);
                `F3_LW, `F3_SW:          ex_ls_misaligned = (ls_addr[1:0] != 2'b00);
                default:                 ex_ls_misaligned = 1'b0;
            endcase
        end
        if (ex_valid_q && ex_is_atomic_q) begin
            ex_ls_misaligned = (ls_addr[1:0] != 2'b00);  // word-only
        end
    end

    // MUL (1-cycle combinational)
    wire         mul_a_signed = (ex_funct3_q == `F3_MULH) || (ex_funct3_q == `F3_MULHSU);
    wire         mul_b_signed = (ex_funct3_q == `F3_MULH);
    wire         mul_hi       = (ex_funct3_q != `F3_MUL);
    logic [31:0] mul_result;
    mul_unit u_mul (.a(ex_rs1_fwd), .b(ex_rs2_fwd),
                    .a_signed(mul_a_signed), .b_signed(mul_b_signed),
                    .hi(mul_hi), .result(mul_result));

    // DIV (iterative)
    wire div_is_signed = !ex_funct3_q[0];
    wire div_want_rem  =  ex_funct3_q[1];
    div_unit u_div (
        .clk(clk), .rst(rst),
        .start(div_start_pulse),
        .is_signed(div_is_signed), .want_rem(div_want_rem),
        .dividend(ex_rs1_fwd), .divisor(ex_rs2_fwd),
        .busy(div_busy_sig), .done(div_done_sig), .result(div_result_sig)
    );

    // Divide pulse: 1-cycle start when a new DIV enters EX (and nothing in progress).
    assign div_start_pulse = ex_valid_q && ex_is_div_q && !div_started_q && !div_done_latched_q && !stall_mem && !wb_redirect;

    always_comb begin
        div_started_d      = div_started_q;
        div_done_latched_d = div_done_latched_q;
        div_result_d_reg   = div_result_q_reg;
        if (div_start_pulse) div_started_d = 1'b1;
        if (div_done_sig) begin
            div_done_latched_d = 1'b1;
            div_result_d_reg   = div_result_sig;
        end
        // Clear when the DIV instruction leaves EX (advances to MEM: !stall_ex,
        // no flush, and was valid div this cycle).
        if (!stall_ex && ex_valid_q && ex_is_div_q && div_done_latched_q) begin
            div_started_d      = 1'b0;
            div_done_latched_d = 1'b0;
        end
        if (wb_redirect) begin
            div_started_d      = 1'b0;
            div_done_latched_d = 1'b0;
        end
    end

    // Arithmetic writeback (for non-load insns) — used by MEM forwarding and WB.
    logic [31:0] ex_arith_wb;
    always_comb begin
        ex_arith_wb = alu_y;
        if (ex_is_jal_q || ex_is_jalr_q) ex_arith_wb = ex_pc_q + 32'd4;
        if (ex_is_mul_q)                 ex_arith_wb = mul_result;
        if (ex_is_div_q)                 ex_arith_wb = div_result_q_reg;
        // CSR value is resolved at WB — not available here.
    end

    // Trap detection at EX (exceptions that originate here; plus IRQ / fetch fault
    // carried from ID)
    logic        ex_trap;
    logic [31:0] ex_cause, ex_tval;
    always_comb begin
        ex_trap  = 1'b0;
        ex_cause = 32'd0;
        ex_tval  = 32'd0;
        if (ex_valid_q) begin
            if (ex_irq_q) begin
                ex_trap = 1'b1; ex_cause = ex_irq_cause_q; ex_tval = 32'd0;
            end else if (ex_fetch_pagefault_q) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_INSN_PAGE_FAULT; ex_tval = ex_pc_q;
            end else if (ex_fetch_fault_q) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_INSN_ACCESS_FAULT; ex_tval = ex_pc_q;
            end else if (ex_illegal_q) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_ILLEGAL_INSN; ex_tval = ex_instr_q;
            end else if (ex_is_ecall_q) begin
                ex_trap = 1'b1;
                unique case (priv_mode_v)
                    `PRV_U:  ex_cause = `CAUSE_ECALL_FROM_U;
                    `PRV_S:  ex_cause = `CAUSE_ECALL_FROM_S;
                    default: ex_cause = `CAUSE_ECALL_FROM_M;
                endcase
            end else if (ex_is_ebreak_q) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_BREAKPOINT;
            end else if (ex_target_misaligned) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_INSN_ADDR_MISALIGNED; ex_tval = ex_misaligned_target;
            end else if ((ex_is_load_q || ex_is_lr_q) && ex_ls_misaligned) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_LOAD_ADDR_MISALIGNED; ex_tval = ls_addr;
            end else if ((ex_is_store_q || ex_is_sc_q || ex_is_amo_rmw_q) && ex_ls_misaligned) begin
                ex_trap = 1'b1; ex_cause = `CAUSE_STORE_ADDR_MISALIGNED; ex_tval = ls_addr;
            end
        end
    end

    // Branch mispredict redirect — only if branch/jump and NOT trap.
    assign branch_redirect = (ex_take_branch || ex_take_jal || ex_take_jalr) && !ex_trap && !stall_ex;
    assign branch_redirect_pc = ex_take_jalr ? jalr_target
                             : (ex_take_jal  ? jal_target
                                             : branch_target);

    // Store alignment
    logic [31:0] store_wdata_w;
    logic [3:0]  store_wmask_w;
    always_comb begin
        store_wdata_w = 32'd0;
        store_wmask_w = 4'b0000;
        unique case (ex_funct3_q)
            `F3_SB: begin
                unique case (ls_addr[1:0])
                    2'd0: begin store_wdata_w = {24'd0, ex_rs2_fwd[7:0]};         store_wmask_w = 4'b0001; end
                    2'd1: begin store_wdata_w = {16'd0, ex_rs2_fwd[7:0],  8'd0};  store_wmask_w = 4'b0010; end
                    2'd2: begin store_wdata_w = { 8'd0, ex_rs2_fwd[7:0], 16'd0};  store_wmask_w = 4'b0100; end
                    2'd3: begin store_wdata_w = {ex_rs2_fwd[7:0], 24'd0};         store_wmask_w = 4'b1000; end
                endcase
            end
            `F3_SH: begin
                unique case (ls_addr[1])
                    1'd0: begin store_wdata_w = {16'd0, ex_rs2_fwd[15:0]};        store_wmask_w = 4'b0011; end
                    1'd1: begin store_wdata_w = {ex_rs2_fwd[15:0], 16'd0};        store_wmask_w = 4'b1100; end
                endcase
            end
            `F3_SW:  begin store_wdata_w = ex_rs2_fwd; store_wmask_w = 4'b1111; end
            default: begin store_wdata_w = ex_rs2_fwd; store_wmask_w = 4'b1111; end
        endcase
    end

    // ========================================================================
    // EX → EX/MEM
    // ========================================================================
    // SC reservation hit detection (at EX time — SC is serial so the pipe has
    // drained and resv_* is stable).
    wire ex_sc_hit = resv_valid_q && (resv_addr_q == ls_addr[31:2]);

    always_comb begin
        mem_valid_d       = mem_valid_q;
        mem_pc_d          = mem_pc_q;
        mem_instr_d       = mem_instr_q;
        mem_alu_y_d       = mem_alu_y_q;
        mem_has_result_d  = mem_has_result_q;
        mem_result_d      = mem_result_q;
        mem_store_wdata_d = mem_store_wdata_q;
        mem_store_wmask_d = mem_store_wmask_q;
        mem_funct3_d      = mem_funct3_q;
        mem_rd_d          = mem_rd_q;
        mem_rd_wen_d      = mem_rd_wen_q;
        mem_is_load_d     = mem_is_load_q;
        mem_is_store_d    = mem_is_store_q;
        mem_is_csr_d      = mem_is_csr_q;
        mem_is_mret_d     = mem_is_mret_q;
        mem_is_sret_d     = mem_is_sret_q;
        mem_is_serial_d   = mem_is_serial_q;
        mem_is_lr_d       = mem_is_lr_q;
        mem_is_sc_d       = mem_is_sc_q;
        mem_is_amo_rmw_d  = mem_is_amo_rmw_q;
        mem_amo_funct5_d  = mem_amo_funct5_q;
        mem_amo_rs2_d     = mem_amo_rs2_q;
        mem_amo_phase_d   = mem_amo_phase_q;
        mem_csr_addr_d    = mem_csr_addr_q;
        mem_csr_wdata_d   = mem_csr_wdata_q;
        mem_csr_op_d      = mem_csr_op_q;
        mem_csr_rs1imm_d  = mem_csr_rs1imm_q;
        mem_sfence_rs1_d  = mem_sfence_rs1_q;
        mem_sfence_rs2_d  = mem_sfence_rs2_q;
        mem_trap_d        = mem_trap_q;
        mem_cause_d       = mem_cause_q;
        mem_tval_d        = mem_tval_q;
        mem_ls_pending_d  = mem_ls_pending_q;

        if (stall_mem) begin
            // MEM is busy waiting on dmem_rsp. For AMO RMW phase 0, rsp ends
            // the load beat and starts the store beat — keep ls_pending high
            // and flip phase. Everything else (loads, stores, LR, SC-hit,
            // AMO RMW phase 1) clears ls_pending on rsp.
            if (mem_valid_q && mem_ls_pending_q && dmem_rsp_valid) begin
                if (mem_is_amo_rmw_q && (mem_amo_phase_q == 1'b0) && !dmem_rsp_fault) begin
                    mem_amo_phase_d  = 1'b1;
                    // ls_pending stays high for the store beat
                end else begin
                    mem_ls_pending_d = 1'b0;
                end
            end
        end else begin
            if (stall_ex || !ex_valid_q) begin
                // Bubble into MEM next cycle
                mem_valid_d       = 1'b0;
                mem_is_load_d     = 1'b0;
                mem_is_store_d    = 1'b0;
                mem_is_csr_d      = 1'b0;
                mem_is_mret_d     = 1'b0;
                mem_is_sret_d     = 1'b0;
                mem_is_serial_d   = 1'b0;
                mem_is_lr_d       = 1'b0;
                mem_is_sc_d       = 1'b0;
                mem_is_amo_rmw_d  = 1'b0;
                mem_rd_wen_d      = 1'b0;
                mem_has_result_d  = 1'b0;
                mem_trap_d        = 1'b0;
                mem_ls_pending_d  = 1'b0;
                mem_amo_phase_d   = 1'b0;
            end else begin
                mem_valid_d       = 1'b1;
                mem_pc_d          = ex_pc_q;
                mem_instr_d       = ex_instr_q;
                mem_funct3_d      = ex_funct3_q;
                mem_rd_d          = ex_rd_q;
                mem_alu_y_d       = (ex_is_load_q || ex_is_store_q || ex_is_atomic_q) ? ls_addr : ex_arith_wb;
                mem_store_wdata_d = store_wdata_w;
                mem_store_wmask_d = store_wmask_w;

                mem_is_load_d     = ex_is_load_q  && !ex_trap;
                mem_is_store_d    = ex_is_store_q && !ex_trap;
                mem_is_csr_d      = ex_is_csr_q   && !ex_trap;
                mem_is_mret_d     = ex_is_mret_q  && !ex_trap;
                mem_is_sret_d     = ex_is_sret_q  && !ex_trap;
                mem_is_serial_d   = ex_is_serial_q;
                mem_is_lr_d       = ex_is_lr_q    && !ex_trap;
                mem_is_sc_d       = ex_is_sc_q    && !ex_trap;
                mem_is_amo_rmw_d  = ex_is_amo_rmw_q && !ex_trap;
                mem_amo_funct5_d  = ex_amo_funct5_q;
                mem_amo_rs2_d     = ex_rs2_fwd;
                mem_amo_phase_d   = 1'b0;
                mem_rd_wen_d      = ex_rd_wen_q   && !ex_trap;

                mem_has_result_d  = ex_rd_wen_q && !ex_is_load_q && !ex_is_csr_q &&
                                    !ex_is_lr_q && !ex_is_sc_q && !ex_is_amo_rmw_q &&
                                    !ex_trap;
                mem_result_d      = ex_arith_wb;

                mem_csr_addr_d    = ex_csr_addr_q;
                mem_csr_op_d      = ex_funct3_q;
                mem_csr_rs1imm_d  = ex_rs1_q;
                mem_csr_wdata_d   = ex_funct3_q[2] ? {27'd0, ex_rs1_q} : ex_rs1_fwd;

                // Snapshot rs1/rs2 for SFENCE.VMA. Value is harmless for
                // other ops; we only observe it at WB when wb_is_sfence.
                mem_sfence_rs1_d  = ex_rs1_fwd;
                mem_sfence_rs2_d  = ex_rs2_fwd;

                mem_trap_d        = ex_trap;
                mem_cause_d       = ex_cause;
                mem_tval_d        = ex_tval;

                // ls_pending: needs a bus transaction?
                //   - load / store / LR / AMO RMW : always
                //   - SC: only if reservation hits; on miss we short-circuit
                //     below to write rd=1 through the arith path.
                if (!ex_trap && (ex_is_load_q || ex_is_store_q ||
                                 ex_is_lr_q || ex_is_amo_rmw_q ||
                                 (ex_is_sc_q && ex_sc_hit))) begin
                    mem_ls_pending_d = 1'b1;
                end else begin
                    mem_ls_pending_d = 1'b0;
                end
                if (ex_is_sc_q && !ex_trap && !ex_sc_hit) begin
                    // SC miss: no bus activity; write rd=1 via the arith path.
                    mem_has_result_d = 1'b1;
                    mem_result_d     = 32'd1;
                end
            end
        end

        // WB-trap flush clears MEM
        if (wb_redirect) begin
            mem_valid_d       = 1'b0;
            mem_is_load_d     = 1'b0;
            mem_is_store_d    = 1'b0;
            mem_is_csr_d      = 1'b0;
            mem_is_mret_d     = 1'b0;
            mem_is_sret_d     = 1'b0;
            mem_is_serial_d   = 1'b0;
            mem_is_lr_d       = 1'b0;
            mem_is_sc_d       = 1'b0;
            mem_is_amo_rmw_d  = 1'b0;
            mem_rd_wen_d      = 1'b0;
            mem_has_result_d  = 1'b0;
            mem_trap_d        = 1'b0;
            mem_ls_pending_d  = 1'b0;
            mem_amo_phase_d   = 1'b0;
        end
    end

    // ========================================================================
    // MEM stage — drive dmem_req / wait for dmem_rsp
    // ========================================================================
    // AMO RMW store-beat data = op(amo_old_q, amo_rs2_q)
    logic [31:0] amo_store_data;
    always_comb begin
        unique case (mem_amo_funct5_q)
            `AMO_SWAP: amo_store_data = mem_amo_rs2_q;
            `AMO_ADD:  amo_store_data = mem_amo_old_q + mem_amo_rs2_q;
            `AMO_XOR:  amo_store_data = mem_amo_old_q ^ mem_amo_rs2_q;
            `AMO_AND:  amo_store_data = mem_amo_old_q & mem_amo_rs2_q;
            `AMO_OR:   amo_store_data = mem_amo_old_q | mem_amo_rs2_q;
            `AMO_MIN:  amo_store_data = ($signed(mem_amo_old_q) < $signed(mem_amo_rs2_q)) ? mem_amo_old_q : mem_amo_rs2_q;
            `AMO_MAX:  amo_store_data = ($signed(mem_amo_old_q) < $signed(mem_amo_rs2_q)) ? mem_amo_rs2_q : mem_amo_old_q;
            `AMO_MINU: amo_store_data = (mem_amo_old_q < mem_amo_rs2_q) ? mem_amo_old_q : mem_amo_rs2_q;
            `AMO_MAXU: amo_store_data = (mem_amo_old_q < mem_amo_rs2_q) ? mem_amo_rs2_q : mem_amo_old_q;
            default:   amo_store_data = mem_amo_rs2_q;
        endcase
    end

    wire mem_amo_store_beat = mem_is_amo_rmw_q && (mem_amo_phase_q == 1'b1);
    wire mem_is_store_op    = mem_is_store_q || mem_is_sc_q || mem_amo_store_beat;
    wire mem_has_bus_op     = mem_is_load_q || mem_is_store_q || mem_is_lr_q ||
                              mem_is_sc_q   || mem_is_amo_rmw_q;

    assign dmem_req_valid = mem_valid_q && mem_has_bus_op && mem_ls_pending_q && !mem_req_fired_q;
    assign dmem_req_addr  = {mem_alu_y_q[31:2], 2'b00};
    assign dmem_req_wen   = mem_is_store_op;
    assign dmem_req_wdata = mem_amo_store_beat ? amo_store_data : mem_store_wdata_q;
    assign dmem_req_wmask = mem_is_store_op ? ((mem_is_store_q && !mem_is_sc_q) ? mem_store_wmask_q : 4'b1111)
                          : (mem_funct3_q == `F3_LB || mem_funct3_q == `F3_LBU) ? 4'b0001
                          : (mem_funct3_q == `F3_LH || mem_funct3_q == `F3_LHU) ? 4'b0011
                          : 4'b1111;
    assign dmem_req_size  = (mem_is_lr_q || mem_is_sc_q || mem_is_amo_rmw_q) ? 2'b10
                          : (mem_funct3_q == `F3_LB || mem_funct3_q == `F3_LBU || mem_funct3_q == `F3_SB) ? 2'b00
                          : (mem_funct3_q == `F3_LH || mem_funct3_q == `F3_LHU || mem_funct3_q == `F3_SH) ? 2'b01
                          : 2'b10;
    assign dmem_rsp_ready = 1'b1;

    // Load alignment / sign-ext
    logic [7:0]  load_b_sel;
    logic [15:0] load_h_sel;
    logic [31:0] load_aligned;
    always_comb begin
        unique case (mem_alu_y_q[1:0])
            2'd0:    load_b_sel = dmem_rsp_rdata[ 7: 0];
            2'd1:    load_b_sel = dmem_rsp_rdata[15: 8];
            2'd2:    load_b_sel = dmem_rsp_rdata[23:16];
            2'd3:    load_b_sel = dmem_rsp_rdata[31:24];
            default: load_b_sel = dmem_rsp_rdata[7:0];
        endcase
        load_h_sel = mem_alu_y_q[1] ? dmem_rsp_rdata[31:16] : dmem_rsp_rdata[15:0];
        unique case (mem_funct3_q)
            `F3_LB:  load_aligned = {{24{load_b_sel[7]}},  load_b_sel};
            `F3_LBU: load_aligned = {24'd0,                load_b_sel};
            `F3_LH:  load_aligned = {{16{load_h_sel[15]}}, load_h_sel};
            `F3_LHU: load_aligned = {16'd0,                load_h_sel};
            `F3_LW:  load_aligned = dmem_rsp_rdata;
            default: load_aligned = dmem_rsp_rdata;
        endcase
    end

    // ls_pending clears on rsp arrival (handled inside the EX→MEM always_comb).
    wire mem_rsp_this_cycle = mem_valid_q && mem_ls_pending_q && dmem_rsp_valid;

    // ========================================================================
    // MEM → MEM/WB
    // ========================================================================
    // Conditions for advance: no stall_mem AND (if L/S, rsp has arrived, which
    // clears ls_pending). If MEM is not in busy state (e.g. arith passing
    // through), it can advance every cycle.
    //
    // Note: stall_mem=mem_busy=mem_valid_q && mem_ls_pending_q, so !stall_mem
    // means either MEM is a bubble OR it's an L/S whose rsp arrived this cycle
    // OR it's a non-L/S insn.

    wire mem_bus_trap_now = mem_rsp_this_cycle && dmem_rsp_fault;

    always_comb begin
        wb_valid_d          = 1'b0;
        wb_pc_d             = mem_pc_q;
        wb_instr_d          = mem_instr_q;
        wb_rd_d             = mem_rd_q;
        wb_rd_wen_d         = 1'b0;
        wb_result_d         = 32'd0;
        wb_trap_d           = 1'b0;
        wb_cause_d          = mem_cause_q;
        wb_tval_d           = mem_tval_q;
        wb_is_mret_d        = 1'b0;
        wb_is_sret_d        = 1'b0;
        wb_is_csr_d         = 1'b0;
        wb_is_serial_d      = 1'b0;
        wb_csr_addr_d       = mem_csr_addr_q;
        wb_csr_wdata_d      = mem_csr_wdata_q;
        wb_csr_op_d         = mem_csr_op_q;
        wb_csr_rs1imm_d     = mem_csr_rs1imm_q;
        wb_sfence_rs1_d     = mem_sfence_rs1_q;
        wb_sfence_rs2_d     = mem_sfence_rs2_q;

        if (mem_valid_q && !stall_mem) begin
            wb_valid_d      = 1'b1;
            wb_is_serial_d  = mem_is_serial_q;
            // mem_has_result_q = 1 means the result was computed at EX (arith /
            // SC-miss with rd=1) — take the arith path even if a bus-op flag is
            // set for bookkeeping (e.g. mem_is_sc_q on miss).
            if (mem_has_bus_op && !mem_has_result_q) begin
                if (mem_bus_pagefault_q) begin
                    wb_trap_d   = 1'b1;
                    wb_cause_d  = (mem_is_store_q || mem_is_sc_q || mem_is_amo_rmw_q)
                                  ? `CAUSE_STORE_PAGE_FAULT : `CAUSE_LOAD_PAGE_FAULT;
                    wb_tval_d   = mem_alu_y_q;
                    wb_rd_wen_d = 1'b0;
                end else if (mem_bus_fault_q) begin
                    wb_trap_d   = 1'b1;
                    wb_cause_d  = (mem_is_store_q || mem_is_sc_q || mem_is_amo_rmw_q)
                                  ? `CAUSE_STORE_ACCESS_FAULT : `CAUSE_LOAD_ACCESS_FAULT;
                    wb_tval_d   = mem_alu_y_q;
                    wb_rd_wen_d = 1'b0;
                end else if (mem_is_lr_q) begin
                    wb_rd_wen_d = mem_rd_wen_q;
                    wb_result_d = mem_load_data_q;  // LR returns loaded word
                end else if (mem_is_sc_q) begin
                    wb_rd_wen_d = mem_rd_wen_q;
                    wb_result_d = 32'd0;            // SC hit: store completed → 0
                end else if (mem_is_amo_rmw_q) begin
                    wb_rd_wen_d = mem_rd_wen_q;
                    wb_result_d = mem_amo_old_q;    // AMO returns pre-op value
                end else begin
                    wb_rd_wen_d = mem_is_load_q && mem_rd_wen_q;
                    wb_result_d = mem_load_data_q;
                end
            end else begin
                wb_rd_wen_d  = mem_rd_wen_q;
                wb_result_d  = mem_result_q;    // arith (ALU/MUL/DIV/SC-miss) — CSR below
                wb_trap_d    = mem_trap_q;
                wb_is_mret_d = mem_is_mret_q && !mem_trap_q;
                wb_is_sret_d = mem_is_sret_q && !mem_trap_q;
                wb_is_csr_d  = mem_is_csr_q  && !mem_trap_q;
            end
        end

        if (wb_redirect) begin
            wb_valid_d  = 1'b0;
            wb_trap_d   = 1'b0;
            wb_rd_wen_d = 1'b0;
            wb_is_mret_d = 1'b0;
            wb_is_sret_d = 1'b0;
            wb_is_csr_d = 1'b0;
            wb_is_serial_d = 1'b0;
        end
    end

    // ========================================================================
    // WB stage — CSR read/write, commit trace, redirects
    // ========================================================================
    // CSR read (combinational from csr module) provides rd_data for CSR insns.
    // We need to use the CSR module's rdata in the same cycle that we're also
    // driving csr_en=1 and csr_addr. The csr module reads combinationally from
    // its state (csr_q), so this is safe — the write only commits on posedge.
    logic [31:0] wb_commit_rd_data;
    always_comb begin
        wb_commit_rd_data = wb_result_q;
        if (wb_is_csr_q) wb_commit_rd_data = csr_rdata_w;
    end

    assign csr_en_wb    = wb_valid_q && wb_is_csr_q && !wb_trap_q;
    assign trap_take_wb = wb_valid_q && wb_trap_q;
    assign mret_wb      = wb_valid_q && wb_is_mret_q && !wb_trap_q;
    assign sret_wb      = wb_valid_q && wb_is_sret_q && !wb_trap_q;
    assign retire_wb    = wb_valid_q && !wb_trap_q;

    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_en(csr_en_wb),
        .csr_op(wb_csr_op_q),
        .csr_addr(wb_csr_addr_q),
        .csr_rs1_or_imm(wb_csr_rs1imm_q),
        .csr_wdata(wb_csr_wdata_q),
        .csr_rdata(csr_rdata_w),
        .csr_illegal(csr_illegal_w),
        .trap_take(trap_take_wb),
        .trap_pc(wb_pc_q),
        .trap_cause(wb_cause_q),
        .trap_tval(wb_tval_q),
        .mret(mret_wb), .sret(sret_wb),
        .retire(retire_wb),
        .ext_mti(ext_mti), .ext_msi(ext_msi), .ext_mei(ext_mei),
        .ext_sei(ext_sei),
        .mtvec(mtvec_v), .stvec(stvec_v),
        .mepc_out(mepc_v), .sepc_out(sepc_v),
        .priv_mode(priv_mode_v), .trap_to_s(trap_to_s_v),
        .satp_out(satp_v),
        .sstatus_sum(sstatus_sum_v),
        .mstatus_mxr(mstatus_mxr_v),
        .mstatus_mprv(mstatus_mprv_v),
        .mstatus_mpp(mstatus_mpp_v),
        .mstatus_tvm(mstatus_tvm_v),
        .mstatus_tsr(mstatus_tsr_v),
        .irq_pending(irq_pending_v),
        .irq_cause(irq_cause_v),
        .pmp_cfg_out(mmu_pmp_cfg),
        .pmp_addr_out(mmu_pmp_addr)
    );

`ifdef DEBUG_PIPE
    always_ff @(posedge clk) begin
        if (!rst && wb_valid_q) begin
            $display("[%0t] WB  pc=%08x rd=%0d wen=%0d data=%08x trap=%0d cause=%08x",
                     $time, wb_pc_q, wb_rd_q, wb_rd_wen_q, wb_result_q, wb_trap_q, wb_cause_q);
        end
        if (!rst && branch_redirect) begin
            $display("[%0t] BRANCH pc=%08x -> %08x", $time, ex_pc_q, branch_redirect_pc);
        end
        if (!rst && wb_redirect) begin
            $display("[%0t] WBREDIR pc=%08x -> %08x trap=%0d mret=%0d cause=%08x",
                     $time, wb_pc_q, wb_redirect_pc, wb_trap_q, wb_is_mret_q, wb_cause_q);
        end
    end
`endif


    // Regfile write
    assign rf_wen     = wb_valid_q && wb_rd_wen_q && !wb_trap_q && (wb_rd_q != 5'd0);
    assign rf_rd_addr = wb_rd_q;
    assign rf_rd_data = wb_commit_rd_data;

    // Commit trace
    assign commit_valid   = wb_valid_q;
    assign commit_pc      = wb_pc_q;
    assign commit_insn    = wb_instr_q;
    assign commit_rd_wen  = rf_wen;
    assign commit_rd_addr = wb_rd_q;
    assign commit_rd_data = wb_commit_rd_data;
    assign commit_trap    = wb_valid_q && wb_trap_q;
    assign commit_cause   = wb_cause_q;

    // FENCE.I retiring at WB: detected directly from the instr bits — no need
    // to carry a dedicated bit through every stage. We treat it like a
    // mini-redirect: flush IF/ID/EX (wb_redirect) and pulse an icache
    // invalidate so the next fetch (pc+4) misses and re-reads from memory.
    wire wb_is_fence_i = wb_valid_q && !wb_trap_q &&
                         (wb_instr_q[6:0]   == `OP_MISC_MEM) &&
                         (wb_instr_q[14:12] == 3'b001);

    // Redirect on trap, MRET/SRET, FENCE.I, or SFENCE.VMA. SFENCE flushes the
    // TLB — any instruction fetched after it (and still in earlier stages
    // when it retires) might have been translated against the stale TLB, so
    // re-issue from pc+4.
    wire wb_is_sfence_redirect = wb_valid_q && !wb_trap_q &&
                                 (wb_instr_q[6:0]   == `OP_SYSTEM) &&
                                 (wb_instr_q[14:12] == `F3_PRIV) &&
                                 (wb_instr_q[31:25] == 7'b0001001);
    // A CSR write that changes satp (mode/asid/ppn) must also redirect:
    // in-flight fetches past the csrw were translated under the old satp,
    // and post-csrw instructions must be translated under the new one.
    // Match any CSR opcode (funct3 != 000, i.e. !F3_PRIV) targeting CSR_SATP.
    // Detected at WB so the pipeline ahead is empty by the time we redirect.
    // Without this, Linux's `sfence.vma; csrw satp` turn-on-MMU sequence
    // leaves a pre-satp fetch for pc+4 in IF/ID translated under satp=0,
    // which on our memory map sends it to the UART aperture (0xC...) and
    // the pipeline hangs silently after executing the garbage response.
    wire wb_is_csr_op    = wb_valid_q && !wb_trap_q &&
                           (wb_instr_q[6:0]   == `OP_SYSTEM) &&
                           (wb_instr_q[14:12] != `F3_PRIV);
    wire wb_is_csrw_satp = wb_is_csr_op && (wb_instr_q[31:20] == `CSR_SATP);
    assign wb_redirect = wb_valid_q && (wb_trap_q || wb_is_mret_q || wb_is_sret_q ||
                                        wb_is_fence_i || wb_is_sfence_redirect ||
                                        wb_is_csrw_satp);

    always_comb begin
        // Default: M-mode trap vector.
        wb_redirect_pc = {mtvec_v[31:2], 2'b00};
        if (wb_is_mret_q && !wb_trap_q) begin
            wb_redirect_pc = mepc_v;
        end else if (wb_is_sret_q && !wb_trap_q) begin
            wb_redirect_pc = sepc_v;
        end else if (wb_is_fence_i || wb_is_sfence_redirect || wb_is_csrw_satp) begin
            wb_redirect_pc = wb_pc_q + 32'd4;
        end else if (wb_trap_q && trap_to_s_v) begin
            // Trap delegated to S-mode.
            wb_redirect_pc = {stvec_v[31:2], 2'b00};
            if (stvec_v[0] && wb_cause_q[31]) begin
                wb_redirect_pc = {stvec_v[31:2], 2'b00} + {26'd0, wb_cause_q[3:0], 2'b00};
            end
        end else if (wb_trap_q && mtvec_v[0] && wb_cause_q[31]) begin
            // Vectored M-mode, interrupt: base + 4*cause_code[3:0]
            wb_redirect_pc = {mtvec_v[31:2], 2'b00} + {26'd0, wb_cause_q[3:0], 2'b00};
        end
    end

    // Pulse the icache invalidate line when FENCE.I retires. Serializing
    // semantics ensure IF/ID/EX/MEM are drained at this point, and the
    // wb_redirect above forces the next fetch (pc+4) to go through the cache
    // with its valid bits freshly cleared.
    assign icache_invalidate = wb_is_fence_i;

    // Pulse the MMU TLB flush on SFENCE.VMA retirement. Same drain argument
    // as FENCE.I — by WB the pipeline ahead of us is empty.
    wire wb_is_sfence = wb_valid_q && !wb_trap_q &&
                        (wb_instr_q[6:0]   == `OP_SYSTEM) &&
                        (wb_instr_q[14:12] == `F3_PRIV) &&
                        (wb_instr_q[31:25] == 7'b0001001);
    assign mmu_sfence_vma      = wb_is_sfence;
    assign mmu_sfence_rs1_nz   = (wb_instr_q[19:15] != 5'd0);
    assign mmu_sfence_rs1_va   = wb_sfence_rs1_q;
    assign mmu_sfence_rs2_nz   = (wb_instr_q[24:20] != 5'd0);
    assign mmu_sfence_rs2_asid = wb_sfence_rs2_q[8:0];

    // trap_pending latch: prevents further fetches between EX trap detect and
    // WB trap commit. Redundant with wb_redirect now that branch_redirect is
    // orthogonal; keep for safety.
    always_comb begin
        trap_pending_d = trap_pending_q;
        if (ex_trap && ex_valid_q && !stall_ex) trap_pending_d = 1'b1;
        if (wb_redirect)                        trap_pending_d = 1'b0;
    end

    // ========================================================================
    // Sequential register update
    // ========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_q                 <= RESET_PC;
            fetch_inflight_q     <= 1'b0;
            fetch_inflight_pc_q  <= 32'd0;
            fetch_squash_q       <= 1'b0;

            id_valid_q           <= 1'b0;
            id_pc_q              <= 32'd0;
            id_instr_q           <= 32'h0000_0013;
            id_fault_q           <= 1'b0;
            id_pagefault_q       <= 1'b0;
            id_irq_q             <= 1'b0;
            id_irq_cause_q       <= 32'd0;

            ex_valid_q           <= 1'b0;
            ex_pc_q              <= 32'd0;
            ex_instr_q           <= 32'h0000_0013;
            ex_rs1_q_data        <= 32'd0;
            ex_rs2_q_data        <= 32'd0;
            ex_imm_q             <= 32'd0;
            ex_alu_op_q          <= 4'd0;
            ex_alu_a_sel_q       <= 2'd0;
            ex_alu_b_sel_q       <= 2'd0;
            ex_rd_q              <= 5'd0;
            ex_rs1_q             <= 5'd0;
            ex_rs2_q             <= 5'd0;
            ex_funct3_q          <= 3'd0;
            ex_csr_addr_q        <= 12'd0;
            ex_rd_wen_q          <= 1'b0;
            ex_rs1_used_q        <= 1'b0;
            ex_rs2_used_q        <= 1'b0;
            ex_is_lui_q          <= 1'b0;
            ex_is_auipc_q        <= 1'b0;
            ex_is_jal_q          <= 1'b0;
            ex_is_jalr_q         <= 1'b0;
            ex_is_branch_q       <= 1'b0;
            ex_is_load_q         <= 1'b0;
            ex_is_store_q        <= 1'b0;
            ex_is_csr_q          <= 1'b0;
            ex_is_ecall_q        <= 1'b0;
            ex_is_ebreak_q       <= 1'b0;
            ex_is_mret_q         <= 1'b0;
            ex_is_sret_q         <= 1'b0;
            ex_is_wfi_q          <= 1'b0;
            ex_is_mul_q          <= 1'b0;
            ex_is_div_q          <= 1'b0;
            ex_is_lr_q           <= 1'b0;
            ex_is_sc_q           <= 1'b0;
            ex_is_amo_rmw_q      <= 1'b0;
            ex_amo_funct5_q      <= 5'd0;
            ex_is_serial_q       <= 1'b0;
            ex_fetch_fault_q     <= 1'b0;
            ex_fetch_pagefault_q <= 1'b0;
            ex_illegal_q         <= 1'b0;
            ex_irq_q             <= 1'b0;
            ex_irq_cause_q       <= 32'd0;

            mem_valid_q          <= 1'b0;
            mem_pc_q             <= 32'd0;
            mem_instr_q          <= 32'h0000_0013;
            mem_alu_y_q          <= 32'd0;
            mem_has_result_q     <= 1'b0;
            mem_result_q         <= 32'd0;
            mem_store_wdata_q    <= 32'd0;
            mem_store_wmask_q    <= 4'b0;
            mem_funct3_q         <= 3'd0;
            mem_rd_q             <= 5'd0;
            mem_rd_wen_q         <= 1'b0;
            mem_is_load_q        <= 1'b0;
            mem_is_store_q       <= 1'b0;
            mem_is_csr_q         <= 1'b0;
            mem_is_mret_q        <= 1'b0;
            mem_is_sret_q        <= 1'b0;
            mem_is_serial_q      <= 1'b0;
            mem_is_lr_q          <= 1'b0;
            mem_is_sc_q          <= 1'b0;
            mem_is_amo_rmw_q     <= 1'b0;
            mem_amo_funct5_q     <= 5'd0;
            mem_amo_rs2_q        <= 32'd0;
            mem_amo_phase_q      <= 1'b0;
            mem_amo_old_q        <= 32'd0;
            resv_valid_q         <= 1'b0;
            resv_addr_q          <= 30'd0;
            mem_csr_addr_q       <= 12'd0;
            mem_csr_wdata_q      <= 32'd0;
            mem_csr_op_q         <= 3'd0;
            mem_csr_rs1imm_q     <= 5'd0;
            mem_sfence_rs1_q     <= 32'd0;
            mem_sfence_rs2_q     <= 32'd0;
            mem_trap_q           <= 1'b0;
            mem_cause_q          <= 32'd0;
            mem_tval_q           <= 32'd0;
            mem_ls_pending_q     <= 1'b0;
            mem_req_fired_q      <= 1'b0;
            mem_bus_fault_q      <= 1'b0;
            mem_bus_pagefault_q  <= 1'b0;
            mem_load_data_q      <= 32'd0;

            wb_valid_q           <= 1'b0;
            wb_pc_q              <= 32'd0;
            wb_instr_q           <= 32'h0000_0013;
            wb_rd_q              <= 5'd0;
            wb_rd_wen_q          <= 1'b0;
            wb_result_q          <= 32'd0;
            wb_trap_q            <= 1'b0;
            wb_cause_q           <= 32'd0;
            wb_tval_q            <= 32'd0;
            wb_is_mret_q         <= 1'b0;
            wb_is_sret_q         <= 1'b0;
            wb_is_csr_q          <= 1'b0;
            wb_is_serial_q       <= 1'b0;
            wb_csr_addr_q        <= 12'd0;
            wb_csr_wdata_q       <= 32'd0;
            wb_csr_op_q          <= 3'd0;
            wb_csr_rs1imm_q      <= 5'd0;
            wb_sfence_rs1_q      <= 32'd0;
            wb_sfence_rs2_q      <= 32'd0;

            div_started_q        <= 1'b0;
            div_done_latched_q   <= 1'b0;
            div_result_q_reg     <= 32'd0;
            trap_pending_q       <= 1'b0;
        end else begin
            pc_q                 <= pc_d;
            fetch_inflight_q     <= fetch_inflight_d;
            fetch_inflight_pc_q  <= fetch_inflight_pc_d;
            fetch_squash_q       <= fetch_squash_d;

            id_valid_q           <= id_valid_d;
            id_pc_q              <= id_pc_d;
            id_instr_q           <= id_instr_d;
            id_fault_q           <= id_fault_d;
            id_pagefault_q       <= id_pagefault_d;
            id_irq_q             <= id_irq_d;
            id_irq_cause_q       <= id_irq_cause_d;

            ex_valid_q           <= ex_valid_d;
            ex_pc_q              <= ex_pc_d;
            ex_instr_q           <= ex_instr_d;
            ex_rs1_q_data        <= ex_rs1_d_data;
            ex_rs2_q_data        <= ex_rs2_d_data;
            ex_imm_q             <= ex_imm_d;
            ex_alu_op_q          <= ex_alu_op_d;
            ex_alu_a_sel_q       <= ex_alu_a_sel_d;
            ex_alu_b_sel_q       <= ex_alu_b_sel_d;
            ex_rd_q              <= ex_rd_d;
            ex_rs1_q             <= ex_rs1_d;
            ex_rs2_q             <= ex_rs2_d;
            ex_funct3_q          <= ex_funct3_d;
            ex_csr_addr_q        <= ex_csr_addr_d;
            ex_rd_wen_q          <= ex_rd_wen_d;
            ex_rs1_used_q        <= ex_rs1_used_d;
            ex_rs2_used_q        <= ex_rs2_used_d;
            ex_is_lui_q          <= ex_is_lui_d;
            ex_is_auipc_q        <= ex_is_auipc_d;
            ex_is_jal_q          <= ex_is_jal_d;
            ex_is_jalr_q         <= ex_is_jalr_d;
            ex_is_branch_q       <= ex_is_branch_d;
            ex_is_load_q         <= ex_is_load_d;
            ex_is_store_q        <= ex_is_store_d;
            ex_is_csr_q          <= ex_is_csr_d;
            ex_is_ecall_q        <= ex_is_ecall_d;
            ex_is_ebreak_q       <= ex_is_ebreak_d;
            ex_is_mret_q         <= ex_is_mret_d;
            ex_is_sret_q         <= ex_is_sret_d;
            ex_is_wfi_q          <= ex_is_wfi_d;
            ex_is_mul_q          <= ex_is_mul_d;
            ex_is_div_q          <= ex_is_div_d;
            ex_is_lr_q           <= ex_is_lr_d;
            ex_is_sc_q           <= ex_is_sc_d;
            ex_is_amo_rmw_q      <= ex_is_amo_rmw_d;
            ex_amo_funct5_q      <= ex_amo_funct5_d;
            ex_is_serial_q       <= ex_is_serial_d;
            ex_fetch_fault_q     <= ex_fetch_fault_d;
            ex_fetch_pagefault_q <= ex_fetch_pagefault_d;
            ex_illegal_q         <= ex_illegal_d;
            ex_irq_q             <= ex_irq_d;
            ex_irq_cause_q       <= ex_irq_cause_d;

            mem_valid_q          <= mem_valid_d;
            mem_pc_q             <= mem_pc_d;
            mem_instr_q          <= mem_instr_d;
            mem_alu_y_q          <= mem_alu_y_d;
            mem_has_result_q     <= mem_has_result_d;
            mem_result_q         <= mem_result_d;
            mem_store_wdata_q    <= mem_store_wdata_d;
            mem_store_wmask_q    <= mem_store_wmask_d;
            mem_funct3_q         <= mem_funct3_d;
            mem_rd_q             <= mem_rd_d;
            mem_rd_wen_q         <= mem_rd_wen_d;
            mem_is_load_q        <= mem_is_load_d;
            mem_is_store_q       <= mem_is_store_d;
            mem_is_csr_q         <= mem_is_csr_d;
            mem_is_mret_q        <= mem_is_mret_d;
            mem_is_sret_q        <= mem_is_sret_d;
            mem_is_serial_q      <= mem_is_serial_d;
            mem_is_lr_q          <= mem_is_lr_d;
            mem_is_sc_q          <= mem_is_sc_d;
            mem_is_amo_rmw_q     <= mem_is_amo_rmw_d;
            mem_amo_funct5_q     <= mem_amo_funct5_d;
            mem_amo_rs2_q        <= mem_amo_rs2_d;
            mem_amo_phase_q      <= mem_amo_phase_d;
            mem_csr_addr_q       <= mem_csr_addr_d;
            mem_csr_wdata_q      <= mem_csr_wdata_d;
            mem_csr_op_q         <= mem_csr_op_d;
            mem_csr_rs1imm_q     <= mem_csr_rs1imm_d;
            mem_sfence_rs1_q     <= mem_sfence_rs1_d;
            mem_sfence_rs2_q     <= mem_sfence_rs2_d;
            mem_trap_q           <= mem_trap_d;
            mem_cause_q          <= mem_cause_d;
            mem_tval_q           <= mem_tval_d;
            mem_ls_pending_q     <= mem_ls_pending_d;
            // mem_req_fired_q: set the cycle req was accepted; clear on rsp arrival.
            if (dmem_req_valid && dmem_req_ready)        mem_req_fired_q <= 1'b1;
            if (mem_valid_q && mem_ls_pending_q && dmem_rsp_valid) mem_req_fired_q <= 1'b0;
            if (wb_redirect)                             mem_req_fired_q <= 1'b0;
            // Latch load data / bus fault on rsp arrival; must be held until WB advance.
            // For AMO RMW phase 0, latch into mem_amo_old_q instead of mem_load_data_q;
            // bus fault latches normally. Phase 1's rsp only carries fault (it's a store).
            if (mem_valid_q && mem_ls_pending_q && dmem_rsp_valid) begin
                mem_bus_fault_q     <= dmem_rsp_fault;
                mem_bus_pagefault_q <= dmem_rsp_pagefault;
                if (mem_is_amo_rmw_q && (mem_amo_phase_q == 1'b0)) begin
                    mem_amo_old_q <= dmem_rsp_rdata; // word load, no alignment
                end else if (mem_is_lr_q) begin
                    mem_load_data_q <= dmem_rsp_rdata; // LR is always word
                end else begin
                    mem_load_data_q <= load_aligned;
                end
            end
            if (!stall_mem && mem_valid_q && mem_has_bus_op) begin
                // Advancing to WB — clear latches for the next op.
                mem_bus_fault_q     <= 1'b0;
                mem_bus_pagefault_q <= 1'b0;
                mem_load_data_q     <= 32'd0;
                mem_amo_old_q       <= 32'd0;
            end
            if (wb_redirect) begin
                mem_bus_fault_q     <= 1'b0;
                mem_bus_pagefault_q <= 1'b0;
                mem_load_data_q     <= 32'd0;
                mem_amo_old_q       <= 32'd0;
            end

            // Reservation state: LR arms on successful load rsp; SC and AMO-RMW
            // commit clear it; traps clear it.
            if (mem_valid_q && mem_is_lr_q && mem_ls_pending_q && dmem_rsp_valid && !dmem_rsp_fault) begin
                resv_valid_q <= 1'b1;
                resv_addr_q  <= mem_alu_y_q[31:2];
            end
            if (!stall_mem && mem_valid_q && (mem_is_sc_q || mem_is_amo_rmw_q)) begin
                resv_valid_q <= 1'b0;
            end
            if (wb_redirect) begin
                resv_valid_q <= 1'b0;
            end

            wb_valid_q           <= wb_valid_d;
            wb_pc_q              <= wb_pc_d;
            wb_instr_q           <= wb_instr_d;
            wb_rd_q              <= wb_rd_d;
            wb_rd_wen_q          <= wb_rd_wen_d;
            wb_result_q          <= wb_result_d;
            wb_trap_q            <= wb_trap_d;
            wb_cause_q           <= wb_cause_d;
            wb_tval_q            <= wb_tval_d;
            wb_is_mret_q         <= wb_is_mret_d;
            wb_is_sret_q         <= wb_is_sret_d;
            wb_is_csr_q          <= wb_is_csr_d;
            wb_is_serial_q       <= wb_is_serial_d;
            wb_csr_addr_q        <= wb_csr_addr_d;
            wb_csr_wdata_q       <= wb_csr_wdata_d;
            wb_csr_op_q          <= wb_csr_op_d;
            wb_csr_rs1imm_q      <= wb_csr_rs1imm_d;
            wb_sfence_rs1_q      <= wb_sfence_rs1_d;
            wb_sfence_rs2_q      <= wb_sfence_rs2_d;

            div_started_q        <= div_started_d;
            div_done_latched_q   <= div_done_latched_d;
            div_result_q_reg     <= div_result_d_reg;
            trap_pending_q       <= trap_pending_d;
        end
    end

`ifdef RISCV_FORMAL
`include "core_pipeline_rvfi.svh"
`endif

endmodule
