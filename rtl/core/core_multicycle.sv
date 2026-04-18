// Stage 1 RV32I core.  Multi-cycle FSM around synchronous memory.
//
// States:
//   S_FETCH : drive ifetch_req_valid=1 with addr=PC; on ifetch_rsp_valid, capture
//             the instruction, move to S_EXEC.  On fetch fault, redirect PC to
//             mtvec and stay in S_FETCH.
//   S_EXEC  : decode + execute.  Most instructions commit here (writeback + PC+4
//             or branch/jump target).  Load/Store issue a dmem_req and advance
//             to S_MEM.  Traps (illegal, ecall, ebreak, misaligned) redirect PC
//             to mtvec and return to S_FETCH.
//   S_MEM   : wait for dmem_rsp_valid → align/extend load, writeback, commit,
//             S_FETCH.  Store commits here too (no writeback).
//
// Output `commit_*` is the retirement trace: exactly one commit per instruction,
// or one trap-commit per trapped instruction.  This is what the Verilator harness
// compares against Spike's commit log.

`include "defs.svh"

module core_multicycle #(
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

    // ---- external interrupt lines (M-mode) ----
    input  logic        ext_mti,
    input  logic        ext_msi,
    input  logic        ext_mei,

    // ---- commit trace ----
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic        commit_rd_wen,
    output logic [4:0]  commit_rd_addr,
    output logic [31:0] commit_rd_data,
    output logic        commit_trap,
    output logic [31:0] commit_cause,

    // ---- CSR state visible to the MMU (Stage 6C-2) ----
    output logic [31:0] mmu_satp,
    output logic [1:0]  mmu_priv,
    output logic        mmu_mprv,
    output logic [1:0]  mmu_mpp,
    output logic        mmu_sum,
    output logic        mmu_mxr,

    // ---- TLB flush on SFENCE.VMA retirement (1-cycle pulse) ----
    output logic        mmu_sfence_vma
);

    // =========================================================================
    // State
    // =========================================================================
    typedef enum logic [2:0] {
        S_FETCH      = 3'd0,
        S_EXEC       = 3'd1,
        S_MEM        = 3'd2,
        S_DIV        = 3'd3,
        S_AMO_STORE  = 3'd4,
        S_AMO_WAIT   = 3'd5
    } state_t;
    state_t state_q;

    logic [31:0] pc_q;
    logic [31:0] instr_q;
    logic [31:0] mem_addr_q;
    logic [2:0]  funct3_q;
    logic [4:0]  rd_q;
    logic [31:0] pc_of_mem_q;
    logic [31:0] instr_of_mem_q;
    logic        is_load_q;
    logic        is_lr_q;
    logic        is_sc_q;
    logic        is_rmw_q;
    logic [31:0] amo_old_q;
    logic        resv_valid_q;
    logic [29:0] resv_addr_q;   // word-aligned reservation (bits [31:2] of the address)

    // =========================================================================
    // Decode helpers
    // =========================================================================
    wire [6:0]  opcode = instr_q[6:0];
    wire [2:0]  funct3 = instr_q[14:12];
    wire [6:0]  funct7 = instr_q[31:25];
    wire [4:0]  rd_i   = instr_q[11:7];
    wire [4:0]  rs1_i  = instr_q[19:15];
    wire [4:0]  rs2_i  = instr_q[24:20];

    wire is_lui    = (opcode == `OP_LUI);
    wire is_auipc  = (opcode == `OP_AUIPC);
    wire is_jal    = (opcode == `OP_JAL);
    wire is_jalr   = (opcode == `OP_JALR);
    wire is_branch = (opcode == `OP_BRANCH);
    wire is_load   = (opcode == `OP_LOAD);
    wire is_store  = (opcode == `OP_STORE);
    wire is_op_imm = (opcode == `OP_OP_IMM);
    wire is_op     = (opcode == `OP_OP);
    wire is_misc   = (opcode == `OP_MISC_MEM);
    wire is_system = (opcode == `OP_SYSTEM);
    wire is_amo    = (opcode == `OP_AMO) && (funct3 == `F3_AMO_W);

    wire [4:0] amo_funct5 = instr_q[31:27];
    wire is_lr     = is_amo && (amo_funct5 == `AMO_LR) && (rs2_i == 5'd0);
    wire is_sc     = is_amo && (amo_funct5 == `AMO_SC);
    wire is_amo_rmw = is_amo && !is_lr && !is_sc &&
                      ((amo_funct5 == `AMO_SWAP) || (amo_funct5 == `AMO_ADD)  ||
                       (amo_funct5 == `AMO_XOR)  || (amo_funct5 == `AMO_AND)  ||
                       (amo_funct5 == `AMO_OR)   || (amo_funct5 == `AMO_MIN)  ||
                       (amo_funct5 == `AMO_MAX)  || (amo_funct5 == `AMO_MINU) ||
                       (amo_funct5 == `AMO_MAXU));

    wire is_ecall  = is_system && (funct3 == `F3_PRIV) && (instr_q[31:20] == 12'h000);
    wire is_ebreak = is_system && (funct3 == `F3_PRIV) && (instr_q[31:20] == 12'h001);
    wire is_mret   = is_system && (funct3 == `F3_PRIV) && (instr_q[31:20] == 12'h302);
    wire is_wfi    = is_system && (funct3 == `F3_PRIV) && (instr_q[31:20] == 12'h105);
    wire is_sfence = is_system && (funct3 == `F3_PRIV) && (instr_q[31:25] == 7'b0001001);
    wire is_csr    = is_system && (funct3 != `F3_PRIV);
    wire is_priv_op = is_ecall | is_ebreak | is_mret | is_wfi;

    // M-extension: funct7 == 0000001 with OP.  funct3[2] splits MUL-group (0) from DIV-group (1).
    wire is_muldiv      = is_op && (funct7 == `F7_MULDIV);
    wire is_mul_variant = is_muldiv && !funct3[2];
    wire is_div_variant = is_muldiv &&  funct3[2];

    // =========================================================================
    // Sub-blocks
    // =========================================================================
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    imm_gen u_imm (.instr(instr_q), .imm_i(imm_i), .imm_s(imm_s), .imm_b(imm_b), .imm_u(imm_u), .imm_j(imm_j));

    logic        rf_wen;
    logic [4:0]  rf_rd;
    logic [31:0] rf_wd;
    logic [31:0] rs1_data, rs2_data;
    regfile u_rf (
        .clk(clk),
        .rs1_addr(rs1_i), .rs1_data(rs1_data),
        .rs2_addr(rs2_i), .rs2_data(rs2_data),
        .wen(rf_wen), .rd_addr(rf_rd), .rd_data(rf_wd)
    );

    logic [3:0]  alu_op;
    logic [31:0] alu_a, alu_b, alu_y;
    logic        alu_eq, alu_lt, alu_ltu;
    alu u_alu (.op(alu_op), .a(alu_a), .b(alu_b), .y(alu_y), .eq(alu_eq), .lt(alu_lt), .ltu(alu_ltu));

    logic        csr_en;
    logic [31:0] csr_rdata;
    logic        csr_illegal;
    logic        trap_take;
    logic [31:0] trap_pc_in, trap_cause_in, trap_tval_in;
    logic        do_mret;
    logic [31:0] mtvec_v, mepc_v;
    logic [31:0] stvec_v, sepc_v, satp_v;
    logic [1:0]  priv_mode_v, mstatus_mpp_v;
    logic        trap_to_s_v, sstatus_sum_v, mstatus_mxr_v, mstatus_mprv_v;
    logic        mstatus_tvm_v, mstatus_tsr_v;
    logic        irq_pending_v;
    logic [31:0] irq_cause_v;
    // Multicycle core stays M-only; SRET is not decoded here. The unused
    // S-mode outputs from csr.sv are bound to spare wires and left floating.
    csr u_csr (
        .clk(clk), .rst(rst),
        .csr_en(csr_en), .csr_op(funct3), .csr_addr(instr_q[31:20]),
        .csr_rs1_or_imm(rs1_i),
        .csr_wdata(funct3[2] ? {27'd0, rs1_i} : rs1_data),
        .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
        .trap_take(trap_take), .trap_pc(trap_pc_in),
        .trap_cause(trap_cause_in), .trap_tval(trap_tval_in),
        .mret(do_mret), .sret(1'b0),
        .retire(commit_valid && !commit_trap),
        .ext_mti(ext_mti), .ext_msi(ext_msi), .ext_mei(ext_mei),
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
        .irq_pending(irq_pending_v), .irq_cause(irq_cause_v)
    );

    assign mmu_satp = satp_v;
    assign mmu_priv = priv_mode_v;
    assign mmu_mprv = mstatus_mprv_v;
    assign mmu_mpp  = mstatus_mpp_v;

    // SFENCE.VMA pulses on retirement. Multicycle already drains fully
    // between instructions, so no redirect is needed — just flash the line.
    assign mmu_sfence_vma = is_sfence && commit_valid && !commit_trap;
    assign mmu_sum  = sstatus_sum_v;
    assign mmu_mxr  = mstatus_mxr_v;

    // M-extension: combinational multiplier (1 EX cycle) + iterative divider (32 cycles).
    // MUL   : a_signed=0, b_signed=0, hi=0 (low 32)
    // MULH  : a_signed=1, b_signed=1, hi=1
    // MULHSU: a_signed=1, b_signed=0, hi=1
    // MULHU : a_signed=0, b_signed=0, hi=1
    wire         mul_a_signed = (funct3 == `F3_MULH) || (funct3 == `F3_MULHSU);
    wire         mul_b_signed = (funct3 == `F3_MULH);
    wire         mul_hi       = (funct3 != `F3_MUL);
    logic [31:0] mul_result;
    mul_unit u_mul (
        .a(rs1_data), .b(rs2_data),
        .a_signed(mul_a_signed), .b_signed(mul_b_signed),
        .hi(mul_hi),
        .result(mul_result)
    );

    logic        div_start;
    logic        div_busy, div_done;
    logic [31:0] div_result;
    // DIV=100, DIVU=101, REM=110, REMU=111.  funct3[0]=0 → signed; funct3[1]=1 → rem.
    wire         div_is_signed = !funct3[0];
    wire         div_want_rem  =  funct3[1];
    div_unit u_div (
        .clk(clk), .rst(rst),
        .start(div_start),
        .is_signed(div_is_signed),
        .want_rem(div_want_rem),
        .dividend(rs1_data),
        .divisor(rs2_data),
        .busy(div_busy),
        .done(div_done),
        .result(div_result)
    );

    // =========================================================================
    // Combinational decode / ALU inputs
    // =========================================================================
    always_comb begin
        alu_a  = rs1_data;
        alu_b  = rs2_data;
        alu_op = 4'd0;
        unique case (1'b1)
            is_lui:    begin alu_a = 32'd0;    alu_b = imm_u; alu_op = 4'd10; end
            is_auipc:  begin alu_a = pc_q;     alu_b = imm_u; alu_op = 4'd0;  end
            is_jal,
            is_jalr:   begin alu_a = pc_q;     alu_b = 32'd4; alu_op = 4'd0;  end
            is_load:   begin alu_a = rs1_data; alu_b = imm_i; alu_op = 4'd0;  end
            is_store:  begin alu_a = rs1_data; alu_b = imm_s; alu_op = 4'd0;  end
            is_amo:    begin alu_a = rs1_data; alu_b = 32'd0; alu_op = 4'd0;  end
            is_branch: begin alu_a = rs1_data; alu_b = rs2_data; alu_op = 4'd1; end
            is_op_imm: begin
                alu_a = rs1_data; alu_b = imm_i;
                unique case (funct3)
                    `F3_ADD_SUB: alu_op = 4'd0;
                    `F3_SLL:     alu_op = 4'd5;
                    `F3_SLT:     alu_op = 4'd8;
                    `F3_SLTU:    alu_op = 4'd9;
                    `F3_XOR:     alu_op = 4'd4;
                    `F3_SRL_SRA: alu_op = funct7[5] ? 4'd7 : 4'd6;
                    `F3_OR:      alu_op = 4'd3;
                    `F3_AND:     alu_op = 4'd2;
                endcase
            end
            is_op: begin
                alu_a = rs1_data; alu_b = rs2_data;
                unique case (funct3)
                    `F3_ADD_SUB: alu_op = funct7[5] ? 4'd1 : 4'd0;
                    `F3_SLL:     alu_op = 4'd5;
                    `F3_SLT:     alu_op = 4'd8;
                    `F3_SLTU:    alu_op = 4'd9;
                    `F3_XOR:     alu_op = 4'd4;
                    `F3_SRL_SRA: alu_op = funct7[5] ? 4'd7 : 4'd6;
                    `F3_OR:      alu_op = 4'd3;
                    `F3_AND:     alu_op = 4'd2;
                endcase
            end
            default: /* defaults fine */ ;
        endcase
    end

    // =========================================================================
    // Illegal-opcode detection (stage-1 conservative)
    // =========================================================================
    logic illegal_opcode;
    always_comb begin
        illegal_opcode = 1'b0;
        unique case (opcode)
            `OP_LUI, `OP_AUIPC, `OP_JAL, `OP_JALR,
            `OP_BRANCH, `OP_LOAD, `OP_STORE,
            `OP_OP_IMM, `OP_OP, `OP_MISC_MEM, `OP_SYSTEM, `OP_AMO:
                illegal_opcode = 1'b0;
            default:
                illegal_opcode = 1'b1;
        endcase

        // AMO must be funct3 = 010 with a recognized funct5; LR.W requires rs2 == 0.
        if (opcode == `OP_AMO) begin
            if (funct3 != `F3_AMO_W) illegal_opcode = 1'b1;
            else if (!(is_lr || is_sc || is_amo_rmw)) illegal_opcode = 1'b1;
        end

        // OP-IMM shift funct7 / shamt checks
        if (is_op_imm && (funct3 == `F3_SLL)) begin
            if (funct7 != 7'b0000000) illegal_opcode = 1'b1;
        end else if (is_op_imm && (funct3 == `F3_SRL_SRA)) begin
            if ((funct7 != 7'b0000000) && (funct7 != 7'b0100000)) illegal_opcode = 1'b1;
        end

        // OP register-register funct7 checks (RV32I + RV32M)
        if (is_op) begin
            case ({funct7, funct3})
                {7'b0000000, `F3_ADD_SUB}, {7'b0100000, `F3_ADD_SUB},
                {7'b0000000, `F3_SLL},
                {7'b0000000, `F3_SLT},
                {7'b0000000, `F3_SLTU},
                {7'b0000000, `F3_XOR},
                {7'b0000000, `F3_SRL_SRA}, {7'b0100000, `F3_SRL_SRA},
                {7'b0000000, `F3_OR},
                {7'b0000000, `F3_AND},
                // RV32M
                {`F7_MULDIV, `F3_MUL},    {`F7_MULDIV, `F3_MULH},
                {`F7_MULDIV, `F3_MULHSU}, {`F7_MULDIV, `F3_MULHU},
                {`F7_MULDIV, `F3_DIV},    {`F7_MULDIV, `F3_DIVU},
                {`F7_MULDIV, `F3_REM},    {`F7_MULDIV, `F3_REMU}: /* ok */ ;
                default: illegal_opcode = 1'b1;
            endcase
        end

        // SYSTEM / CSR decode
        if (is_system && (funct3 == `F3_PRIV)) begin
            if (is_sfence) begin
                // SFENCE.VMA rs1, rs2. rs1/rs2 are operands; rd must be 0.
                if (rd_i != 5'd0) illegal_opcode = 1'b1;
            end else begin
                // ECALL (0x000), EBREAK (0x001), MRET (0x302), WFI (0x105).
                case (instr_q[31:20])
                    12'h000, 12'h001, 12'h302, 12'h105: /* ok */ ;
                    default: illegal_opcode = 1'b1;
                endcase
                // rs1 and rd must be zero for these
                if (rd_i != 5'd0 || rs1_i != 5'd0) illegal_opcode = 1'b1;
            end
        end
    end

    // =========================================================================
    // Branch / target / load-store address
    // =========================================================================
    logic branch_taken;
    always_comb begin
        branch_taken = 1'b0;
        unique case (funct3)
            `F3_BEQ:  branch_taken =  alu_eq;
            `F3_BNE:  branch_taken = !alu_eq;
            `F3_BLT:  branch_taken =  alu_lt;
            `F3_BGE:  branch_taken = !alu_lt;
            `F3_BLTU: branch_taken =  alu_ltu;
            `F3_BGEU: branch_taken = !alu_ltu;
            default:  branch_taken = 1'b0;
        endcase
    end

    wire [31:0] jal_target    = pc_q + imm_j;
    wire [31:0] jalr_target   = (rs1_data + imm_i) & ~32'd1;
    wire [31:0] branch_target = pc_q + imm_b;
    wire [31:0] mem_addr      = alu_y;                 // rs1 + imm_{i,s}

    logic        target_misaligned;
    logic [31:0] misaligned_target;
    always_comb begin
        target_misaligned = 1'b0;
        misaligned_target = 32'd0;
        if (is_jal   && (jal_target[1:0]  != 2'b00))           begin target_misaligned = 1'b1; misaligned_target = jal_target;    end
        if (is_jalr  && (jalr_target[1:0] != 2'b00))           begin target_misaligned = 1'b1; misaligned_target = jalr_target;   end
        if (is_branch && branch_taken && (branch_target[1:0] != 2'b00))
                                                                begin target_misaligned = 1'b1; misaligned_target = branch_target; end
    end

    logic ls_misaligned;
    logic amo_misaligned;
    always_comb begin
        ls_misaligned = 1'b0;
        unique case (funct3)
            `F3_LH, `F3_LHU, `F3_SH: ls_misaligned = (mem_addr[0]   != 1'b0);
            `F3_LW, `F3_SW:          ls_misaligned = (mem_addr[1:0] != 2'b00);
            default:                 ls_misaligned = 1'b0;
        endcase
        amo_misaligned = is_amo && (mem_addr[1:0] != 2'b00);
    end

    // =========================================================================
    // Store lane + write mask
    // =========================================================================
    logic [31:0] store_wdata;
    logic [3:0]  store_wmask;
    always_comb begin
        store_wdata = 32'd0;
        store_wmask = 4'b0000;
        unique case (funct3)
            `F3_SB: begin
                unique case (mem_addr[1:0])
                    2'd0: begin store_wdata = {24'd0, rs2_data[7:0]};               store_wmask = 4'b0001; end
                    2'd1: begin store_wdata = {16'd0, rs2_data[7:0],  8'd0};        store_wmask = 4'b0010; end
                    2'd2: begin store_wdata = { 8'd0, rs2_data[7:0], 16'd0};        store_wmask = 4'b0100; end
                    2'd3: begin store_wdata = {rs2_data[7:0], 24'd0};               store_wmask = 4'b1000; end
                endcase
            end
            `F3_SH: begin
                unique case (mem_addr[1])
                    1'd0: begin store_wdata = {16'd0, rs2_data[15:0]};              store_wmask = 4'b0011; end
                    1'd1: begin store_wdata = {rs2_data[15:0], 16'd0};              store_wmask = 4'b1100; end
                endcase
            end
            `F3_SW:  begin store_wdata = rs2_data; store_wmask = 4'b1111; end
            default: begin store_wdata = rs2_data; store_wmask = 4'b1111; end
        endcase
    end

    // =========================================================================
    // Load alignment / sign-extension (driven in S_MEM using latched metadata)
    // =========================================================================
    logic [7:0]  load_b0, load_b1, load_b2, load_b3, load_b_sel;
    logic [15:0] load_h_lo, load_h_hi, load_h_sel;
    logic [31:0] load_result;
    always_comb begin
        load_b0    = dmem_rsp_rdata[ 7: 0];
        load_b1    = dmem_rsp_rdata[15: 8];
        load_b2    = dmem_rsp_rdata[23:16];
        load_b3    = dmem_rsp_rdata[31:24];
        load_h_lo  = dmem_rsp_rdata[15: 0];
        load_h_hi  = dmem_rsp_rdata[31:16];

        unique case (mem_addr_q[1:0])
            2'd0: load_b_sel = load_b0;
            2'd1: load_b_sel = load_b1;
            2'd2: load_b_sel = load_b2;
            2'd3: load_b_sel = load_b3;
        endcase
        load_h_sel = mem_addr_q[1] ? load_h_hi : load_h_lo;

        unique case (funct3_q)
            `F3_LB:  load_result = {{24{load_b_sel[7]}},  load_b_sel};
            `F3_LBU: load_result = {24'd0,                load_b_sel};
            `F3_LH:  load_result = {{16{load_h_sel[15]}}, load_h_sel};
            `F3_LHU: load_result = {16'd0,                load_h_sel};
            `F3_LW:  load_result = dmem_rsp_rdata;
            default: load_result = dmem_rsp_rdata;
        endcase
    end

    // =========================================================================
    // A-extension helpers
    // =========================================================================
    // SC hit: reservation valid AND the word-aligned address matches.
    wire sc_hit = resv_valid_q && (resv_addr_q == mem_addr[31:2]);

    // AMO RMW result: combines old memory value (latched in amo_old_q) with rs2_data
    // using the funct5 of the in-flight AMO (still in instr_q).
    wire [4:0] amo_funct5_live = instr_q[31:27];
    logic [31:0] amo_result;
    always_comb begin
        unique case (amo_funct5_live)
            `AMO_SWAP: amo_result = rs2_data;
            `AMO_ADD:  amo_result = amo_old_q + rs2_data;
            `AMO_XOR:  amo_result = amo_old_q ^ rs2_data;
            `AMO_AND:  amo_result = amo_old_q & rs2_data;
            `AMO_OR:   amo_result = amo_old_q | rs2_data;
            `AMO_MIN:  amo_result = ($signed(amo_old_q) < $signed(rs2_data)) ? amo_old_q : rs2_data;
            `AMO_MAX:  amo_result = ($signed(amo_old_q) < $signed(rs2_data)) ? rs2_data : amo_old_q;
            `AMO_MINU: amo_result = (amo_old_q < rs2_data) ? amo_old_q : rs2_data;
            `AMO_MAXU: amo_result = (amo_old_q < rs2_data) ? rs2_data : amo_old_q;
            default:   amo_result = 32'd0;
        endcase
    end

    // =========================================================================
    // Arithmetic writeback value (valid for non-load commits at S_EXEC)
    // =========================================================================
    logic [31:0] arith_wb;
    always_comb begin
        arith_wb = alu_y;
        if (is_jal || is_jalr) arith_wb = pc_q + 32'd4;
        if (is_csr)            arith_wb = csr_rdata;
        if (is_mul_variant)    arith_wb = mul_result;
    end

    // =========================================================================
    // Trap composition (at S_EXEC, S_FETCH fetch-fault, S_MEM bus-fault)
    // =========================================================================
    logic        exec_trap;
    logic [31:0] exec_cause, exec_tval;
    always_comb begin
        exec_trap  = 1'b0;
        exec_cause = 32'd0;
        exec_tval  = 32'd0;
        if (is_ecall) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_ECALL_FROM_M;
        end else if (is_ebreak) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_BREAKPOINT;
        end else if (illegal_opcode || (is_csr && csr_illegal)) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_ILLEGAL_INSN;
            exec_tval  = instr_q;
        end else if (target_misaligned) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_INSN_ADDR_MISALIGNED;
            exec_tval  = misaligned_target;
        end else if (is_load && ls_misaligned) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_LOAD_ADDR_MISALIGNED;
            exec_tval  = mem_addr;
        end else if (is_store && ls_misaligned) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_STORE_ADDR_MISALIGNED;
            exec_tval  = mem_addr;
        end else if (is_lr && amo_misaligned) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_LOAD_ADDR_MISALIGNED;
            exec_tval  = mem_addr;
        end else if ((is_sc || is_amo_rmw) && amo_misaligned) begin
            exec_trap  = 1'b1;
            exec_cause = `CAUSE_STORE_ADDR_MISALIGNED;
            exec_tval  = mem_addr;
        end
    end

    // Fetch / MEM faults are combinationally derived below in the state machine.
    // `trap_take` wires into csr.sv.  For interrupts taken at the S_FETCH
    // boundary, mtval is architecturally 0; for fetch-access faults it's the
    // faulting PC (we route pc_q in both cases, but override to 0 when the
    // S_FETCH trap is an interrupt — signalled by `fetch_irq_trap` below).
    logic fetch_irq_trap;
    assign trap_take     = commit_trap;
    assign trap_pc_in    = (state_q == S_MEM || state_q == S_AMO_WAIT) ? pc_of_mem_q : pc_q;
    assign trap_cause_in = commit_cause;
    assign trap_tval_in  = (state_q == S_EXEC)                         ? exec_tval
                         : (state_q == S_MEM || state_q == S_AMO_WAIT) ? mem_addr_q
                         : (state_q == S_FETCH && fetch_irq_trap)      ? 32'd0
                         :                                               pc_q;
    assign do_mret       = (state_q == S_EXEC) && is_mret && !exec_trap;

    // =========================================================================
    // State machine — purely combinational drives of *_next and outputs
    // =========================================================================
    state_t      state_d;
    logic [31:0] pc_d, instr_d;
    logic [31:0] mem_addr_d;
    logic [2:0]  funct3_d;
    logic [4:0]  rd_d;
    logic [31:0] pc_of_mem_d, instr_of_mem_d;
    logic        is_load_d;
    logic        is_lr_d, is_sc_d, is_rmw_d;
    logic [31:0] amo_old_d;
    logic        resv_valid_d;
    logic [29:0] resv_addr_d;

    always_comb begin
        // --- defaults (hold) ---
        state_d         = state_q;
        pc_d            = pc_q;
        instr_d         = instr_q;
        mem_addr_d      = mem_addr_q;
        funct3_d        = funct3_q;
        rd_d            = rd_q;
        pc_of_mem_d     = pc_of_mem_q;
        instr_of_mem_d  = instr_of_mem_q;
        is_load_d       = is_load_q;
        is_lr_d         = is_lr_q;
        is_sc_d         = is_sc_q;
        is_rmw_d        = is_rmw_q;
        amo_old_d       = amo_old_q;
        resv_valid_d    = resv_valid_q;
        resv_addr_d     = resv_addr_q;

        ifetch_req_valid = 1'b0;
        ifetch_req_addr  = pc_q;
        ifetch_rsp_ready = 1'b1;

        dmem_req_valid = 1'b0;
        dmem_req_addr  = 32'd0;
        dmem_req_wen   = 1'b0;
        dmem_req_wdata = 32'd0;
        dmem_req_wmask = 4'b0000;
        dmem_req_size  = 2'b10;
        // Only the states that actually consume a dmem response assert
        // rsp_ready. Otherwise, the MMU's zero-latency tlb_deny (same-cycle
        // pagefault rsp during S_EXEC) would handshake out and get dropped
        // before S_MEM observes it.
        dmem_rsp_ready = (state_q == S_MEM) || (state_q == S_AMO_WAIT);

        rf_wen = 1'b0;
        rf_rd  = 5'd0;
        rf_wd  = 32'd0;

        csr_en         = 1'b0;
        div_start      = 1'b0;
        fetch_irq_trap = 1'b0;

        commit_valid   = 1'b0;
        commit_pc      = pc_q;
        commit_insn    = instr_q;
        commit_rd_wen  = 1'b0;
        commit_rd_addr = 5'd0;
        commit_rd_data = 32'd0;
        commit_trap    = 1'b0;
        commit_cause   = 32'd0;

        unique case (state_q)

            // -------------------------------------------------------------
            S_FETCH: begin
                if (irq_pending_v) begin
                    // Take interrupt at instruction boundary. mepc = pc_q; mtval = 0.
                    // Vectored mode (mtvec[0]==1) adds 4 * cause_code to the base
                    // *for interrupts only*; exceptions always go to the base.
                    fetch_irq_trap = 1'b1;
                    commit_valid   = 1'b1;
                    commit_trap    = 1'b1;
                    commit_cause   = irq_cause_v;
                    commit_pc      = pc_q;
                    commit_insn    = 32'h0;
                    pc_d           = mtvec_v[0]
                                   ? ({mtvec_v[31:2], 2'b00} + {26'd0, irq_cause_v[3:0], 2'b00})
                                   : {mtvec_v[31:2], 2'b00};
                    state_d        = S_FETCH;
                end else begin
                    ifetch_req_valid = 1'b1;
                    ifetch_req_addr  = pc_q;
                    if (ifetch_rsp_valid) begin
                        if (ifetch_rsp_fault || ifetch_rsp_pagefault) begin
                            // Fetch-fault trap: commit trap, redirect to mtvec.
                            commit_valid = 1'b1;
                            commit_trap  = 1'b1;
                            commit_cause = ifetch_rsp_pagefault
                                           ? `CAUSE_INSN_PAGE_FAULT
                                           : `CAUSE_INSN_ACCESS_FAULT;
                            commit_pc    = pc_q;
                            commit_insn  = 32'h0;
                            pc_d         = {mtvec_v[31:2], 2'b00};
                            state_d      = S_FETCH;
                        end else begin
                            instr_d = ifetch_rsp_data;
                            state_d = S_EXEC;
                        end
                    end
                end
            end

            // -------------------------------------------------------------
            S_EXEC: begin
                csr_en = is_csr && !exec_trap;

                if (exec_trap) begin
                    // Trap: no writeback, jump to mtvec base. Traps clear any reservation.
                    commit_valid = 1'b1;
                    commit_trap  = 1'b1;
                    commit_cause = exec_cause;
                    commit_pc    = pc_q;
                    commit_insn  = instr_q;
                    pc_d         = {mtvec_v[31:2], 2'b00};
                    resv_valid_d = 1'b0;
                    state_d      = S_FETCH;
                end else if (is_mret) begin
                    commit_valid = 1'b1;
                    commit_pc    = pc_q;
                    commit_insn  = instr_q;
                    pc_d         = mepc_v;
                    state_d      = S_FETCH;
                end else if (is_load || is_store) begin
                    dmem_req_valid = 1'b1;
                    dmem_req_addr  = {mem_addr[31:2], 2'b00};
                    dmem_req_wen   = is_store;
                    dmem_req_wdata = store_wdata;
                    dmem_req_wmask = is_store ? store_wmask :
                                     (funct3 == `F3_LB || funct3 == `F3_LBU) ? 4'b0001 :
                                     (funct3 == `F3_LH || funct3 == `F3_LHU) ? 4'b0011 : 4'b1111;
                    dmem_req_size  = (funct3 == `F3_LB || funct3 == `F3_LBU || funct3 == `F3_SB) ? 2'b00 :
                                     (funct3 == `F3_LH || funct3 == `F3_LHU || funct3 == `F3_SH) ? 2'b01 : 2'b10;
                    if (dmem_req_ready) begin
                        mem_addr_d     = mem_addr;
                        funct3_d       = funct3;
                        rd_d           = rd_i;
                        pc_of_mem_d    = pc_q;
                        instr_of_mem_d = instr_q;
                        is_load_d      = is_load;
                        is_lr_d        = 1'b0;
                        is_sc_d        = 1'b0;
                        is_rmw_d       = 1'b0;
                        state_d        = S_MEM;
                    end
                end else if (is_lr) begin
                    // Load-Reserved: issue word load; reservation is armed on response.
                    dmem_req_valid = 1'b1;
                    dmem_req_addr  = {mem_addr[31:2], 2'b00};
                    dmem_req_wen   = 1'b0;
                    dmem_req_wmask = 4'b1111;
                    dmem_req_size  = 2'b10;
                    if (dmem_req_ready) begin
                        mem_addr_d     = mem_addr;
                        funct3_d       = `F3_LW;
                        rd_d           = rd_i;
                        pc_of_mem_d    = pc_q;
                        instr_of_mem_d = instr_q;
                        is_load_d      = 1'b1;
                        is_lr_d        = 1'b1;
                        is_sc_d        = 1'b0;
                        is_rmw_d       = 1'b0;
                        state_d        = S_MEM;
                    end
                end else if (is_sc) begin
                    // Store-Conditional: if reservation matches, issue the store and
                    // commit rd=0 on response. Otherwise skip the store and commit rd=1
                    // this cycle. Either way the reservation is cleared.
                    if (sc_hit) begin
                        dmem_req_valid = 1'b1;
                        dmem_req_addr  = {mem_addr[31:2], 2'b00};
                        dmem_req_wen   = 1'b1;
                        dmem_req_wdata = rs2_data;
                        dmem_req_wmask = 4'b1111;
                        dmem_req_size  = 2'b10;
                        if (dmem_req_ready) begin
                            mem_addr_d     = mem_addr;
                            funct3_d       = `F3_SW;
                            rd_d           = rd_i;
                            pc_of_mem_d    = pc_q;
                            instr_of_mem_d = instr_q;
                            is_load_d      = 1'b0;
                            is_lr_d        = 1'b0;
                            is_sc_d        = 1'b1;
                            is_rmw_d       = 1'b0;
                            resv_valid_d   = 1'b0;
                            state_d        = S_MEM;
                        end
                    end else begin
                        // SC failure: write a non-zero code to rd and fall through.
                        rf_wen         = (rd_i != 5'd0);
                        rf_rd          = rd_i;
                        rf_wd          = 32'd1;
                        commit_valid   = 1'b1;
                        commit_pc      = pc_q;
                        commit_insn    = instr_q;
                        commit_rd_wen  = (rd_i != 5'd0);
                        commit_rd_addr = rd_i;
                        commit_rd_data = 32'd1;
                        pc_d           = pc_q + 32'd4;
                        resv_valid_d   = 1'b0;
                        state_d        = S_FETCH;
                    end
                end else if (is_amo_rmw) begin
                    // AMO RMW: issue the load half; S_MEM latches amo_old_q, then S_AMO_STORE
                    // issues the store of op(amo_old_q, rs2).
                    dmem_req_valid = 1'b1;
                    dmem_req_addr  = {mem_addr[31:2], 2'b00};
                    dmem_req_wen   = 1'b0;
                    dmem_req_wmask = 4'b1111;
                    dmem_req_size  = 2'b10;
                    if (dmem_req_ready) begin
                        mem_addr_d     = mem_addr;
                        funct3_d       = `F3_LW;
                        rd_d           = rd_i;
                        pc_of_mem_d    = pc_q;
                        instr_of_mem_d = instr_q;
                        is_load_d      = 1'b1;
                        is_lr_d        = 1'b0;
                        is_sc_d        = 1'b0;
                        is_rmw_d       = 1'b1;
                        state_d        = S_MEM;
                    end
                end else if (is_div_variant) begin
                    // Kick off the iterative divider; commit happens in S_DIV when done pulses.
                    div_start   = 1'b1;
                    rd_d        = rd_i;
                    pc_of_mem_d = pc_q;      // reuse mem-path latches to park the pending commit
                    instr_of_mem_d = instr_q;
                    state_d     = S_DIV;
                end else begin
                    // Single-cycle commit path (arith / JAL / JALR / LUI / AUIPC / branch / CSR / FENCE / MUL*).
                    // Writeback for everything that has an rd other than branch/store/priv-non-mret.
                    logic wb_en;
                    wb_en = (is_lui | is_auipc | is_jal | is_jalr | is_op_imm | is_op | is_csr)
                            && (rd_i != 5'd0);

                    rf_wen = wb_en;
                    rf_rd  = rd_i;
                    rf_wd  = arith_wb;

                    commit_valid   = 1'b1;
                    commit_pc      = pc_q;
                    commit_insn    = instr_q;
                    commit_rd_wen  = wb_en;
                    commit_rd_addr = rd_i;
                    commit_rd_data = arith_wb;

                    pc_d    = (is_jal)                  ? jal_target
                            : (is_jalr)                 ? jalr_target
                            : (is_branch && branch_taken) ? branch_target
                            :                             (pc_q + 32'd4);
                    state_d = S_FETCH;
                end
            end

            // -------------------------------------------------------------
            S_MEM: begin
                if (dmem_rsp_valid) begin
                    if (dmem_rsp_fault || dmem_rsp_pagefault) begin
                        logic is_store_op;
                        is_store_op = is_sc_q || is_rmw_q || !is_load_q;
                        commit_valid = 1'b1;
                        commit_trap  = 1'b1;
                        commit_cause = dmem_rsp_pagefault
                            ? (is_store_op ? `CAUSE_STORE_PAGE_FAULT : `CAUSE_LOAD_PAGE_FAULT)
                            : (is_store_op ? `CAUSE_STORE_ACCESS_FAULT : `CAUSE_LOAD_ACCESS_FAULT);
                        commit_pc    = pc_of_mem_q;
                        commit_insn  = instr_of_mem_q;
                        pc_d         = {mtvec_v[31:2], 2'b00};
                        resv_valid_d = 1'b0;
                        is_lr_d      = 1'b0;
                        is_sc_d      = 1'b0;
                        is_rmw_d     = 1'b0;
                        state_d      = S_FETCH;
                    end else if (is_rmw_q) begin
                        // AMO RMW load phase complete: latch old value, go drive the store.
                        amo_old_d = dmem_rsp_rdata;
                        state_d   = S_AMO_STORE;
                    end else begin
                        logic wb_en_mem;
                        logic [31:0] wb_data_mem;
                        if (is_sc_q) begin
                            wb_en_mem   = (rd_q != 5'd0);
                            wb_data_mem = 32'd0;       // SC success writes 0 to rd
                        end else begin
                            wb_en_mem   = is_load_q && (rd_q != 5'd0);
                            wb_data_mem = load_result; // LR falls into this path (is_load_q=1)
                        end

                        rf_wen = wb_en_mem;
                        rf_rd  = rd_q;
                        rf_wd  = wb_data_mem;

                        commit_valid   = 1'b1;
                        commit_pc      = pc_of_mem_q;
                        commit_insn    = instr_of_mem_q;
                        commit_rd_wen  = wb_en_mem;
                        commit_rd_addr = rd_q;
                        commit_rd_data = wb_data_mem;

                        // LR.W arms the reservation (word-aligned).
                        if (is_lr_q) begin
                            resv_valid_d = 1'b1;
                            resv_addr_d  = mem_addr_q[31:2];
                        end

                        is_lr_d = 1'b0;
                        is_sc_d = 1'b0;
                        pc_d    = pc_of_mem_q + 32'd4;
                        state_d = S_FETCH;
                    end
                end
            end

            // -------------------------------------------------------------
            S_AMO_STORE: begin
                // Drive the store half of the AMO using amo_result (amo_old_q op rs2).
                dmem_req_valid = 1'b1;
                dmem_req_addr  = {mem_addr_q[31:2], 2'b00};
                dmem_req_wen   = 1'b1;
                dmem_req_wdata = amo_result;
                dmem_req_wmask = 4'b1111;
                dmem_req_size  = 2'b10;
                if (dmem_req_ready) begin
                    state_d = S_AMO_WAIT;
                end
            end

            // -------------------------------------------------------------
            S_AMO_WAIT: begin
                if (dmem_rsp_valid) begin
                    if (dmem_rsp_fault || dmem_rsp_pagefault) begin
                        commit_valid = 1'b1;
                        commit_trap  = 1'b1;
                        commit_cause = dmem_rsp_pagefault
                                       ? `CAUSE_STORE_PAGE_FAULT
                                       : `CAUSE_STORE_ACCESS_FAULT;
                        commit_pc    = pc_of_mem_q;
                        commit_insn  = instr_of_mem_q;
                        pc_d         = {mtvec_v[31:2], 2'b00};
                        resv_valid_d = 1'b0;
                        is_rmw_d     = 1'b0;
                        state_d      = S_FETCH;
                    end else begin
                        // AMO commits the *original* loaded value to rd.
                        logic wb_en_amo;
                        wb_en_amo = (rd_q != 5'd0);

                        rf_wen = wb_en_amo;
                        rf_rd  = rd_q;
                        rf_wd  = amo_old_q;

                        commit_valid   = 1'b1;
                        commit_pc      = pc_of_mem_q;
                        commit_insn    = instr_of_mem_q;
                        commit_rd_wen  = wb_en_amo;
                        commit_rd_addr = rd_q;
                        commit_rd_data = amo_old_q;

                        resv_valid_d = 1'b0;    // AMO invalidates any outstanding reservation
                        is_rmw_d     = 1'b0;
                        pc_d         = pc_of_mem_q + 32'd4;
                        state_d      = S_FETCH;
                    end
                end
            end

            // -------------------------------------------------------------
            S_DIV: begin
                // Wait for the divider to pulse `done`, then commit the result.
                if (div_done) begin
                    logic wb_en_div;
                    wb_en_div = (rd_q != 5'd0);

                    rf_wen = wb_en_div;
                    rf_rd  = rd_q;
                    rf_wd  = div_result;

                    commit_valid   = 1'b1;
                    commit_pc      = pc_of_mem_q;
                    commit_insn    = instr_of_mem_q;
                    commit_rd_wen  = wb_en_div;
                    commit_rd_addr = rd_q;
                    commit_rd_data = div_result;

                    pc_d    = pc_of_mem_q + 32'd4;
                    state_d = S_FETCH;
                end
            end

            default: state_d = S_FETCH;
        endcase
    end

    // =========================================================================
    // Sequential state update
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q        <= S_FETCH;
            pc_q           <= RESET_PC;
            instr_q        <= 32'h0000_0013; // NOP
            mem_addr_q     <= 32'd0;
            funct3_q       <= 3'd0;
            rd_q           <= 5'd0;
            pc_of_mem_q    <= 32'd0;
            instr_of_mem_q <= 32'h0000_0013;
            is_load_q      <= 1'b0;
            is_lr_q        <= 1'b0;
            is_sc_q        <= 1'b0;
            is_rmw_q       <= 1'b0;
            amo_old_q      <= 32'd0;
            resv_valid_q   <= 1'b0;
            resv_addr_q    <= 30'd0;
        end else begin
            state_q        <= state_d;
            pc_q           <= pc_d;
            instr_q        <= instr_d;
            mem_addr_q     <= mem_addr_d;
            funct3_q       <= funct3_d;
            rd_q           <= rd_d;
            pc_of_mem_q    <= pc_of_mem_d;
            instr_of_mem_q <= instr_of_mem_d;
            is_load_q      <= is_load_d;
            is_lr_q        <= is_lr_d;
            is_sc_q        <= is_sc_d;
            is_rmw_q       <= is_rmw_d;
            amo_old_q      <= amo_old_d;
            resv_valid_q   <= resv_valid_d;
            resv_addr_q    <= resv_addr_d;
        end
    end

endmodule
