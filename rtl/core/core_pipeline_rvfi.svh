// RVFI (RISC-V Formal Interface) tap for core_pipeline.
//
// Textually included near the end of core_pipeline.sv under `ifdef RISCV_FORMAL.
// Emits retirement trace signals consumed by YosysHQ/riscv-formal.
//
// Strategy: shadow the EX/MEM/WB pipeline with parallel RVFI-only registers
// that carry per-instruction observables (rs1/rs2 addr+rdata, next-pc,
// memory trace). At WB-commit time, drive the rvfi_* output ports.

// -----------------------------------------------------------------------------
// EX-stage snapshots (combinational — valid the cycle EX is latched into MEM).
// -----------------------------------------------------------------------------
logic [31:0] ex_rvfi_next_pc;
always_comb begin
    // Default: PC + 4. Redirects override below.
    ex_rvfi_next_pc = ex_pc_q + 32'd4;
    if (ex_is_jal_q)                              ex_rvfi_next_pc = jal_target;
    else if (ex_is_jalr_q)                        ex_rvfi_next_pc = jalr_target;
    else if (ex_is_branch_q && ex_branch_taken)   ex_rvfi_next_pc = branch_target;
end

// Memory trace at EX. For loads/atomics: rmask from funct3+offset; for
// stores: use the computed store_wmask_w and store_wdata_w.
logic [3:0]  ex_rvfi_mem_rmask, ex_rvfi_mem_wmask;
logic [31:0] ex_rvfi_mem_wdata;
always_comb begin
    ex_rvfi_mem_rmask = 4'b0000;
    ex_rvfi_mem_wmask = 4'b0000;
    ex_rvfi_mem_wdata = 32'd0;
    if (ex_is_load_q && !ex_ls_misaligned) begin
        unique case (ex_funct3_q)
            `F3_LB, `F3_LBU: ex_rvfi_mem_rmask = 4'b0001 << ls_addr[1:0];
            `F3_LH, `F3_LHU: ex_rvfi_mem_rmask = ls_addr[1] ? 4'b1100 : 4'b0011;
            `F3_LW:          ex_rvfi_mem_rmask = 4'b1111;
            default:         ex_rvfi_mem_rmask = 4'b0000;
        endcase
    end else if (ex_is_store_q && !ex_ls_misaligned) begin
        ex_rvfi_mem_wmask = store_wmask_w;
        ex_rvfi_mem_wdata = store_wdata_w;
    end else if (ex_is_lr_q && !ex_ls_misaligned) begin
        ex_rvfi_mem_rmask = 4'b1111;
    end else if (ex_is_sc_q && !ex_ls_misaligned && ex_sc_hit) begin
        ex_rvfi_mem_wmask = 4'b1111;
        ex_rvfi_mem_wdata = ex_rs2_fwd;
    end else if (ex_is_amo_rmw_q && !ex_ls_misaligned) begin
        // AMO's RVFI view: the load+store pair collapses to one retirement with
        // both rmask and wmask set. rdata/wdata filled at MEM when the beats
        // actually land.
        ex_rvfi_mem_rmask = 4'b1111;
        ex_rvfi_mem_wmask = 4'b1111;
    end
end

wire [31:0] ex_rvfi_mem_addr = {ls_addr[31:2], 2'b00};

// -----------------------------------------------------------------------------
// Forward-operand view for RVFI.
//
// Forwarding (ex_rs1_fwd/ex_rs2_fwd) is only guaranteed to reflect the
// operand the core used on cycles where the insn had a chance to consume it.
// On the first cycle an insn is in EX, the producer is still in MEM or WB
// and the forward paths cover it. If EX then stalls (DIV, or mem_busy
// stalling an insn upstream), the producer can drain past WB into the
// regfile. ex_rs1_fwd then falls through to ex_rs1_q_data, which was
// snapshotted at ID-time with the OLD value. For DIV this doesn't affect
// the result (div_start_pulse latched the correct operand on cycle 1), but
// the RVFI shadow that samples at EX→MEM would see the stale fall-through.
//
// So: on the first cycle we observe stall_ex=1 while this insn is in EX,
// latch the forwarded operand. On subsequent stall cycles hold the latched
// value; on the advance cycle, mux it in. For insns that never stall in EX
// (single-cycle common case), pass ex_rs1_fwd through combinationally — this
// matches the old behaviour and avoids a stale-latched-prior-insn NBA hazard.
logic [31:0] ex_rvfi_rs1_held_q, ex_rvfi_rs2_held_q;
logic        ex_rvfi_stalled_q;

wire [31:0] ex_rs1_fwd_z = (ex_rs1_q == 5'd0) ? 32'd0 : ex_rs1_fwd;
wire [31:0] ex_rs2_fwd_z = (ex_rs2_q == 5'd0) ? 32'd0 : ex_rs2_fwd;

wire [31:0] ex_rvfi_rs1_now = ex_rvfi_stalled_q ? ex_rvfi_rs1_held_q : ex_rs1_fwd_z;
wire [31:0] ex_rvfi_rs2_now = ex_rvfi_stalled_q ? ex_rvfi_rs2_held_q : ex_rs2_fwd_z;

always_ff @(posedge clk) begin
    if (rst) begin
        ex_rvfi_rs1_held_q <= 32'd0;
        ex_rvfi_rs2_held_q <= 32'd0;
        ex_rvfi_stalled_q  <= 1'b0;
    end else begin
        // First cycle EX stalls for this insn: latch the current forward view.
        if (ex_valid_q && stall_ex && !ex_rvfi_stalled_q) begin
            ex_rvfi_rs1_held_q <= ex_rs1_fwd_z;
            ex_rvfi_rs2_held_q <= ex_rs2_fwd_z;
            ex_rvfi_stalled_q  <= 1'b1;
        end
        // EX advances: next cycle holds a different insn (or bubble) — re-arm.
        if (!stall_ex && ex_valid_q) begin
            ex_rvfi_stalled_q <= 1'b0;
        end
        if (flush_ex) begin
            ex_rvfi_stalled_q <= 1'b0;
        end
    end
end

// -----------------------------------------------------------------------------
// EX → MEM shadow pipeline
// -----------------------------------------------------------------------------
logic [4:0]  mem_rvfi_rs1_addr_q, mem_rvfi_rs2_addr_q;
logic [31:0] mem_rvfi_rs1_rdata_q, mem_rvfi_rs2_rdata_q;
logic [31:0] mem_rvfi_next_pc_q;
logic [31:0] mem_rvfi_mem_addr_q;
logic [3:0]  mem_rvfi_mem_rmask_q, mem_rvfi_mem_wmask_q;
logic [31:0] mem_rvfi_mem_wdata_q;
// Captures the raw bus rsp word at rsp arrival, so we can surface it at WB
// even if the MEM→WB advance happens a cycle later.
logic [31:0] mem_rvfi_mem_rdata_q;
logic        mem_rvfi_intr_q;

// -----------------------------------------------------------------------------
// MEM → WB shadow pipeline
// -----------------------------------------------------------------------------
logic [4:0]  wb_rvfi_rs1_addr_q, wb_rvfi_rs2_addr_q;
logic [31:0] wb_rvfi_rs1_rdata_q, wb_rvfi_rs2_rdata_q;
logic [31:0] wb_rvfi_next_pc_q;
logic [31:0] wb_rvfi_mem_addr_q;
logic [3:0]  wb_rvfi_mem_rmask_q, wb_rvfi_mem_wmask_q;
logic [31:0] wb_rvfi_mem_rdata_q, wb_rvfi_mem_wdata_q;
logic        wb_rvfi_intr_q;

// -----------------------------------------------------------------------------
// rvfi_order counter + intr-pending latch (set by a cause[31] trap retirement,
// emitted on the next valid retirement).
// -----------------------------------------------------------------------------
logic [63:0] rvfi_order_q;
logic        rvfi_intr_pending_q;

always_ff @(posedge clk) begin
    if (rst) begin
        mem_rvfi_rs1_addr_q  <= 5'd0;
        mem_rvfi_rs2_addr_q  <= 5'd0;
        mem_rvfi_rs1_rdata_q <= 32'd0;
        mem_rvfi_rs2_rdata_q <= 32'd0;
        mem_rvfi_next_pc_q   <= 32'd0;
        mem_rvfi_mem_addr_q  <= 32'd0;
        mem_rvfi_mem_rmask_q <= 4'd0;
        mem_rvfi_mem_wmask_q <= 4'd0;
        mem_rvfi_mem_wdata_q <= 32'd0;
        mem_rvfi_mem_rdata_q <= 32'd0;
        mem_rvfi_intr_q      <= 1'b0;

        wb_rvfi_rs1_addr_q   <= 5'd0;
        wb_rvfi_rs2_addr_q   <= 5'd0;
        wb_rvfi_rs1_rdata_q  <= 32'd0;
        wb_rvfi_rs2_rdata_q  <= 32'd0;
        wb_rvfi_next_pc_q    <= 32'd0;
        wb_rvfi_mem_addr_q   <= 32'd0;
        wb_rvfi_mem_rmask_q  <= 4'd0;
        wb_rvfi_mem_wmask_q  <= 4'd0;
        wb_rvfi_mem_rdata_q  <= 32'd0;
        wb_rvfi_mem_wdata_q  <= 32'd0;
        wb_rvfi_intr_q       <= 1'b0;

        rvfi_order_q         <= 64'd0;
        rvfi_intr_pending_q  <= 1'b0;
    end else begin
        // EX → MEM: latch when ex advances (same condition as mem_valid_d flip).
        // We use "ex is committed this cycle to MEM" = !stall_ex && ex_valid_q.
        if (!stall_ex && ex_valid_q) begin
            mem_rvfi_rs1_addr_q  <= ex_rs1_q;
            mem_rvfi_rs2_addr_q  <= ex_rs2_q;
            // ex_rvfi_rs{1,2}_now: held-through-stall view of the forward operand.
            mem_rvfi_rs1_rdata_q <= ex_rvfi_rs1_now;
            mem_rvfi_rs2_rdata_q <= ex_rvfi_rs2_now;
            mem_rvfi_next_pc_q   <= ex_rvfi_next_pc;
            mem_rvfi_mem_addr_q  <= ex_rvfi_mem_addr;
            mem_rvfi_mem_rmask_q <= ex_rvfi_mem_rmask;
            mem_rvfi_mem_wmask_q <= ex_rvfi_mem_wmask;
            mem_rvfi_mem_wdata_q <= ex_rvfi_mem_wdata;
            mem_rvfi_intr_q      <= ex_irq_q;
        end

        // Capture raw bus rsp word at rsp arrival — MEM→WB advance may be a
        // cycle later, at which point dmem_rsp_rdata is no longer held.
        if (mem_valid_q && mem_ls_pending_q && dmem_rsp_valid) begin
            if ((mem_is_load_q || mem_is_lr_q) ||
                (mem_is_amo_rmw_q && mem_amo_phase_q == 1'b0))
                mem_rvfi_mem_rdata_q <= dmem_rsp_rdata;
        end

        // MEM → WB: latch on the same condition as the main MEM→WB pipe-fwd,
        // which is "wb_valid_d && !stall_mem". Reuse wb_valid_d as the gate.
        if (wb_valid_d) begin
            wb_rvfi_rs1_addr_q   <= mem_rvfi_rs1_addr_q;
            wb_rvfi_rs2_addr_q   <= mem_rvfi_rs2_addr_q;
            wb_rvfi_rs1_rdata_q  <= mem_rvfi_rs1_rdata_q;
            wb_rvfi_rs2_rdata_q  <= mem_rvfi_rs2_rdata_q;
            wb_rvfi_next_pc_q    <= mem_rvfi_next_pc_q;
            wb_rvfi_mem_addr_q   <= mem_rvfi_mem_addr_q;
            wb_rvfi_mem_rmask_q  <= mem_rvfi_mem_rmask_q;
            wb_rvfi_mem_wmask_q  <= mem_rvfi_mem_wmask_q;
            wb_rvfi_mem_wdata_q  <= mem_rvfi_mem_wdata_q;
            // For loads/LR/AMO: the raw bus word was captured into
            // mem_rvfi_mem_rdata_q when the rsp arrived (may be this same
            // cycle if rsp lands the cycle before wb advances, or an
            // earlier cycle when stall_mem held the pipe).
            if (mem_is_load_q || mem_is_lr_q ||
                (mem_is_amo_rmw_q && mem_amo_phase_q == 1'b0))
                wb_rvfi_mem_rdata_q <= mem_valid_q && mem_ls_pending_q && dmem_rsp_valid
                                       ? dmem_rsp_rdata
                                       : mem_rvfi_mem_rdata_q;
            else
                wb_rvfi_mem_rdata_q <= 32'd0;
            wb_rvfi_intr_q       <= mem_rvfi_intr_q;
        end

        // rvfi_order: increment on each retirement.
        if (wb_valid_q) rvfi_order_q <= rvfi_order_q + 64'd1;

        // rvfi_intr_pending: set on any interrupt retirement, consumed by next.
        if (wb_valid_q && wb_trap_q && wb_cause_q[31]) rvfi_intr_pending_q <= 1'b1;
        else if (wb_valid_q)                           rvfi_intr_pending_q <= 1'b0;
    end
end

// -----------------------------------------------------------------------------
// RVFI outputs
// -----------------------------------------------------------------------------
assign rvfi_valid     = wb_valid_q;
assign rvfi_order     = rvfi_order_q;
assign rvfi_insn      = wb_instr_q;
assign rvfi_trap      = wb_trap_q;
assign rvfi_halt      = 1'b0;
assign rvfi_intr      = rvfi_intr_pending_q;
assign rvfi_mode      = 2'b11;
assign rvfi_ixl       = 2'b01;

assign rvfi_rs1_addr  = wb_rvfi_rs1_addr_q;
assign rvfi_rs2_addr  = wb_rvfi_rs2_addr_q;
assign rvfi_rs1_rdata = wb_rvfi_rs1_rdata_q;
assign rvfi_rs2_rdata = wb_rvfi_rs2_rdata_q;

// rd: zero out if the instruction didn't actually write (trap, wen=0, rd=0).
assign rvfi_rd_addr   = (rf_wen) ? wb_rd_q : 5'd0;
assign rvfi_rd_wdata  = (rf_wen) ? wb_commit_rd_data : 32'd0;

assign rvfi_pc_rdata  = wb_pc_q;
// pc_wdata: if this retirement redirects (trap/mret), use the redirect target.
// Otherwise use the EX-resolved next-pc we shadowed in.
assign rvfi_pc_wdata  = wb_redirect ? wb_redirect_pc : wb_rvfi_next_pc_q;

assign rvfi_mem_addr  = wb_rvfi_mem_addr_q;
assign rvfi_mem_rmask = wb_trap_q ? 4'd0 : wb_rvfi_mem_rmask_q;
assign rvfi_mem_wmask = wb_trap_q ? 4'd0 : wb_rvfi_mem_wmask_q;
assign rvfi_mem_rdata = wb_rvfi_mem_rdata_q;
assign rvfi_mem_wdata = wb_rvfi_mem_wdata_q;
