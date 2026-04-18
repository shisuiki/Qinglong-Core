// Stage 6C-2b MMU — SV32 page-table walker + permission checks.
//
// Two translation ports (ifetch + dmem) sit as a bump-in-the-wire between the
// core and the downstream cache/memory path. A single shared PTW state
// machine owns PTE fetches; when priv/satp place us in bare mode the whole
// thing is a zero-latency combinational wire.
//
// Per-side "walk result" registers (if_xlate_*, dm_xlate_*) cache the most
// recent successful translation so the core can issue its physical request
// on the cycle after the walk completes and we don't re-walk while the same
// request is still being serviced downstream. The result clears when the
// downstream response handshake retires.
//
// Bare mode rules:
//   - ifetch: satp.MODE==0 OR priv==M
//   - dmem:   satp.MODE==0 OR effective-priv==M
//             (effective-priv = (priv==M && MPRV) ? MPP : priv)
//
// Permission checks (on leaf PTE):
//   - V=0 or (W=1 && R=0): invalid encoding → fault
//   - fetch and X=0                         → fault
//   - load  and not (R=1 || (MXR && X=1))   → fault
//   - store and (R=0 || W=0)                → fault
//   - U-bit: S-mode never executes U=1 code; S-mode only accesses U=1 data
//            with SUM=1; U-mode only accesses U=1 pages.
//   - A=0                                    → fault (SW-managed A)
//   - store && D=0                           → fault (SW-managed D)
//
// Superpage (4 MiB) support at L1-leaf: reject if pte.ppn0 != 0 (misaligned
// superpage — fault).
//
// No TLB in this cut; each translated access does a full 2-level walk. A
// future Stage 6C-2c drops a small fully-associative TLB in front of the
// walker.
//
// Stage 6C-2b still folds page faults into the downstream rsp_fault bit
// (i.e. they report as access faults to the core, not page faults). A later
// refinement adds a rsp_pagefault signal and maps to INSN/LOAD/STORE
// _PAGE_FAULT causes.

`include "defs.svh"

module mmu (
    input  logic        clk,
    input  logic        rst,

    // CSR state from the core's csr.sv
    input  logic [31:0] satp_i,
    input  logic [1:0]  priv_i,
    input  logic        mprv_i,
    input  logic [1:0]  mpp_i,
    input  logic        sum_i,
    input  logic        mxr_i,

    // --- ifetch core-facing (upstream) ---
    input  logic        if_core_req_valid,
    input  logic [31:0] if_core_req_addr,
    output logic        if_core_req_ready,
    output logic        if_core_rsp_valid,
    output logic [31:0] if_core_rsp_data,
    output logic        if_core_rsp_fault,
    input  logic        if_core_rsp_ready,

    // --- ifetch downstream ---
    output logic        if_ds_req_valid,
    output logic [31:0] if_ds_req_addr,
    input  logic        if_ds_req_ready,
    input  logic        if_ds_rsp_valid,
    input  logic [31:0] if_ds_rsp_data,
    input  logic        if_ds_rsp_fault,
    output logic        if_ds_rsp_ready,

    // --- dmem core-facing (upstream) ---
    input  logic        dm_core_req_valid,
    input  logic [31:0] dm_core_req_addr,
    input  logic        dm_core_req_wen,
    input  logic [31:0] dm_core_req_wdata,
    input  logic [3:0]  dm_core_req_wmask,
    input  logic [1:0]  dm_core_req_size,
    output logic        dm_core_req_ready,
    output logic        dm_core_rsp_valid,
    output logic [31:0] dm_core_rsp_rdata,
    output logic        dm_core_rsp_fault,
    input  logic        dm_core_rsp_ready,

    // --- dmem downstream ---
    output logic        dm_ds_req_valid,
    output logic [31:0] dm_ds_req_addr,
    output logic        dm_ds_req_wen,
    output logic [31:0] dm_ds_req_wdata,
    output logic [3:0]  dm_ds_req_wmask,
    output logic [1:0]  dm_ds_req_size,
    input  logic        dm_ds_req_ready,
    input  logic        dm_ds_rsp_valid,
    input  logic [31:0] dm_ds_rsp_rdata,
    input  logic        dm_ds_rsp_fault,
    output logic        dm_ds_rsp_ready,

    // --- PTW memory port (read-only) ---
    output logic        ptw_req_valid,
    output logic [31:0] ptw_req_addr,
    input  logic        ptw_req_ready,
    input  logic        ptw_rsp_valid,
    input  logic [31:0] ptw_rsp_rdata,
    input  logic        ptw_rsp_fault
);

    // ---------------------------------------------------------------------
    // Translation-needed predicates
    // ---------------------------------------------------------------------
    wire satp_on = satp_i[31];
    wire xlate_if = satp_on && (priv_i != `PRV_M);
    wire [1:0] dm_eff_priv = (priv_i == `PRV_M && mprv_i) ? mpp_i : priv_i;
    wire       xlate_dm    = satp_on && (dm_eff_priv != `PRV_M);

    // ---------------------------------------------------------------------
    // Per-side "walk result" cache
    //   valid[s] = 1 → current req has a translation decision (pa or fault)
    // ---------------------------------------------------------------------
    logic        if_xlate_valid_q, if_xlate_valid_d;
    logic        if_xlate_fault_q, if_xlate_fault_d;
    logic [31:0] if_xlate_pa_q,    if_xlate_pa_d;

    logic        dm_xlate_valid_q, dm_xlate_valid_d;
    logic        dm_xlate_fault_q, dm_xlate_fault_d;
    logic [31:0] dm_xlate_pa_q,    dm_xlate_pa_d;

    // ---------------------------------------------------------------------
    // Shared PTW
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        PTW_IDLE,
        PTW_L1_REQ,
        PTW_L1_WAIT,
        PTW_L0_REQ,
        PTW_L0_WAIT
    } ptw_state_t;

    ptw_state_t  ptw_state_q, ptw_state_d;
    logic        ptw_side_q,  ptw_side_d;       // 0 = ifetch, 1 = dmem
    logic        ptw_is_fetch_q, ptw_is_fetch_d;
    logic        ptw_is_store_q, ptw_is_store_d;
    logic [1:0]  ptw_eff_priv_q, ptw_eff_priv_d;
    logic [31:0] ptw_va_q,    ptw_va_d;
    logic [11:0] ptw_l1_ppn1_q, ptw_l1_ppn1_d; // from L1 PTE for L0 step
    logic [9:0]  ptw_l1_ppn0_q, ptw_l1_ppn0_d;

    // Walk kickoff (only from IDLE).
    wire if_needs_walk = xlate_if && if_core_req_valid && !if_xlate_valid_q;
    wire dm_needs_walk = xlate_dm && dm_core_req_valid && !dm_xlate_valid_q;
    wire launch_if = (ptw_state_q == PTW_IDLE) && if_needs_walk;
    wire launch_dm = (ptw_state_q == PTW_IDLE) && !if_needs_walk && dm_needs_walk;

    // PTE fields (on rsp).
    wire [31:0] pte        = ptw_rsp_rdata;
    wire        pte_v      = pte[0];
    wire        pte_r      = pte[1];
    wire        pte_w      = pte[2];
    wire        pte_x      = pte[3];
    wire        pte_u      = pte[4];
    wire        pte_a      = pte[6];
    wire        pte_d      = pte[7];
    wire [9:0]  pte_ppn0   = pte[19:10];
    wire [11:0] pte_ppn1   = pte[31:20];
    wire        pte_is_leaf = pte_r | pte_x; // (W without R is reserved; handled)
    wire        pte_is_bad  = !pte_v || (pte_w && !pte_r);

    // Permission check — returns 1 if access is permitted on this leaf PTE.
    function automatic logic perm_ok (
        input logic [1:0] eff_priv,
        input logic       is_fetch,
        input logic       is_store,
        input logic       p_r, input logic p_w, input logic p_x,
        input logic       p_u, input logic p_a, input logic p_d,
        input logic       sum, input logic mxr
    );
        logic op_ok;
        logic u_ok;
        if (is_fetch)       op_ok = p_x;
        else if (is_store)  op_ok = p_r && p_w;
        else                op_ok = p_r || (mxr && p_x);
        if (eff_priv == `PRV_U)
            u_ok = p_u;
        else if (eff_priv == `PRV_S)
            u_ok = is_fetch ? !p_u : (!p_u || sum);
        else
            u_ok = 1'b1;
        return op_ok && u_ok && p_a && (!is_store || p_d);
    endfunction

    // Superpage alignment check (L1 leaf): ppn0 must be zero.
    wire l1_leaf_misaligned = (pte_ppn0 != 10'd0);

    // Combinational permission results used by the FSM (hoisted to avoid
    // inline latch-inference warnings on per-branch `logic ok;`).
    wire pte_perm_ok = perm_ok(ptw_eff_priv_q, ptw_is_fetch_q, ptw_is_store_q,
                               pte_r, pte_w, pte_x, pte_u, pte_a, pte_d,
                               sum_i, mxr_i);
    wire l1_leaf_ok = !l1_leaf_misaligned && pte_perm_ok;
    wire l0_leaf_ok = !ptw_rsp_fault && !pte_is_bad && pte_is_leaf && pte_perm_ok;

    // Default next-state
    always_comb begin
        ptw_state_d      = ptw_state_q;
        ptw_side_d       = ptw_side_q;
        ptw_is_fetch_d   = ptw_is_fetch_q;
        ptw_is_store_d   = ptw_is_store_q;
        ptw_eff_priv_d   = ptw_eff_priv_q;
        ptw_va_d         = ptw_va_q;
        ptw_l1_ppn1_d    = ptw_l1_ppn1_q;
        ptw_l1_ppn0_d    = ptw_l1_ppn0_q;

        if_xlate_valid_d = if_xlate_valid_q;
        if_xlate_fault_d = if_xlate_fault_q;
        if_xlate_pa_d    = if_xlate_pa_q;
        dm_xlate_valid_d = dm_xlate_valid_q;
        dm_xlate_fault_d = dm_xlate_fault_q;
        dm_xlate_pa_d    = dm_xlate_pa_q;

        ptw_req_valid = 1'b0;
        ptw_req_addr  = 32'd0;

        case (ptw_state_q)
            PTW_IDLE: begin
                if (launch_if) begin
                    ptw_state_d    = PTW_L1_REQ;
                    ptw_side_d     = 1'b0;
                    ptw_va_d       = if_core_req_addr;
                    ptw_is_fetch_d = 1'b1;
                    ptw_is_store_d = 1'b0;
                    ptw_eff_priv_d = priv_i;
                end else if (launch_dm) begin
                    ptw_state_d    = PTW_L1_REQ;
                    ptw_side_d     = 1'b1;
                    ptw_va_d       = dm_core_req_addr;
                    ptw_is_fetch_d = 1'b0;
                    ptw_is_store_d = dm_core_req_wen;
                    ptw_eff_priv_d = dm_eff_priv;
                end
            end

            PTW_L1_REQ: begin
                ptw_req_valid = 1'b1;
                // satp.PPN*4096 + VPN[1]*4.
                // {ppn[21:0], 12'd0} is 34 bits; Verilog truncates to 32 on
                // assign — the top 2 bits of satp.PPN fall off (we only
                // service 4 GiB of PA).
                ptw_req_addr  = {satp_i[21:0], 12'd0} + {20'd0, ptw_va_q[31:22], 2'b00};
                if (ptw_req_ready) ptw_state_d = PTW_L1_WAIT;
            end

            PTW_L1_WAIT: begin
                if (ptw_rsp_valid) begin
                    if (ptw_rsp_fault || pte_is_bad) begin
                        // fault on L1
                        if (ptw_side_q == 1'b0) begin
                            if_xlate_valid_d = 1'b1;
                            if_xlate_fault_d = 1'b1;
                        end else begin
                            dm_xlate_valid_d = 1'b1;
                            dm_xlate_fault_d = 1'b1;
                        end
                        ptw_state_d = PTW_IDLE;
                    end else if (pte_is_leaf) begin
                        // superpage leaf
                        if (ptw_side_q == 1'b0) begin
                            if_xlate_valid_d = 1'b1;
                            if_xlate_fault_d = !l1_leaf_ok;
                            if_xlate_pa_d    = l1_leaf_ok ? {pte_ppn1, ptw_va_q[21:0]} : 32'd0;
                        end else begin
                            dm_xlate_valid_d = 1'b1;
                            dm_xlate_fault_d = !l1_leaf_ok;
                            dm_xlate_pa_d    = l1_leaf_ok ? {pte_ppn1, ptw_va_q[21:0]} : 32'd0;
                        end
                        ptw_state_d = PTW_IDLE;
                    end else begin
                        // non-leaf — walk to L0
                        ptw_l1_ppn1_d = pte_ppn1;
                        ptw_l1_ppn0_d = pte_ppn0;
                        ptw_state_d   = PTW_L0_REQ;
                    end
                end
            end

            PTW_L0_REQ: begin
                ptw_req_valid = 1'b1;
                ptw_req_addr  = {ptw_l1_ppn1_q[9:0], ptw_l1_ppn0_q, 12'd0} +
                                {20'd0, ptw_va_q[21:12], 2'b00};
                if (ptw_req_ready) ptw_state_d = PTW_L0_WAIT;
            end

            PTW_L0_WAIT: begin
                if (ptw_rsp_valid) begin
                    if (ptw_side_q == 1'b0) begin
                        if_xlate_valid_d = 1'b1;
                        if_xlate_fault_d = !l0_leaf_ok;
                        if_xlate_pa_d    = l0_leaf_ok ? {pte_ppn1[9:0], pte_ppn0, ptw_va_q[11:0]} : 32'd0;
                    end else begin
                        dm_xlate_valid_d = 1'b1;
                        dm_xlate_fault_d = !l0_leaf_ok;
                        dm_xlate_pa_d    = l0_leaf_ok ? {pte_ppn1[9:0], pte_ppn0, ptw_va_q[11:0]} : 32'd0;
                    end
                    ptw_state_d = PTW_IDLE;
                end
            end

            default: ptw_state_d = PTW_IDLE;
        endcase

    end
    // PTW is always ready to consume SRAM responses — no ptw_rsp_ready port,
    // the SRAM port B path is unconditionally routed via last_was_ptw_q.

    // ---------------------------------------------------------------------
    // Request / response forwarding per side
    // ---------------------------------------------------------------------
    // IFETCH
    wire if_forward = xlate_if && if_xlate_valid_q && !if_xlate_fault_q;
    wire if_fault_reply = xlate_if && if_xlate_valid_q &&  if_xlate_fault_q;

    always_comb begin
        if (!xlate_if) begin
            // Bare passthrough.
            if_ds_req_valid   = if_core_req_valid;
            if_ds_req_addr    = if_core_req_addr;
            if_core_req_ready = if_ds_req_ready;
            if_core_rsp_valid = if_ds_rsp_valid;
            if_core_rsp_data  = if_ds_rsp_data;
            if_core_rsp_fault = if_ds_rsp_fault;
            if_ds_rsp_ready   = if_core_rsp_ready;
        end else if (if_forward) begin
            // Forward with translated PA.
            if_ds_req_valid   = if_core_req_valid;
            if_ds_req_addr    = if_xlate_pa_q;
            if_core_req_ready = if_ds_req_ready;
            if_core_rsp_valid = if_ds_rsp_valid;
            if_core_rsp_data  = if_ds_rsp_data;
            if_core_rsp_fault = if_ds_rsp_fault;
            if_ds_rsp_ready   = if_core_rsp_ready;
        end else if (if_fault_reply) begin
            // Synthetic fault response, no downstream request.
            if_ds_req_valid   = 1'b0;
            if_ds_req_addr    = 32'd0;
            if_core_req_ready = 1'b1;   // accept and respond same-cycle window
            if_core_rsp_valid = 1'b1;
            if_core_rsp_data  = 32'd0;
            if_core_rsp_fault = 1'b1;
            if_ds_rsp_ready   = 1'b1;
        end else begin
            // Walk in progress (or about to be). Stall the core.
            if_ds_req_valid   = 1'b0;
            if_ds_req_addr    = 32'd0;
            if_core_req_ready = 1'b0;
            if_core_rsp_valid = 1'b0;
            if_core_rsp_data  = 32'd0;
            if_core_rsp_fault = 1'b0;
            if_ds_rsp_ready   = 1'b1;
        end
    end

    // Clear the walk-result cache once the request/response handshake retires.
    wire if_forward_rsp_done = if_forward && if_ds_rsp_valid && if_core_rsp_ready;
    wire if_fault_rsp_done   = if_fault_reply && if_core_rsp_ready;

    // DMEM
    wire dm_forward     = xlate_dm && dm_xlate_valid_q && !dm_xlate_fault_q;
    wire dm_fault_reply = xlate_dm && dm_xlate_valid_q &&  dm_xlate_fault_q;

    always_comb begin
        if (!xlate_dm) begin
            dm_ds_req_valid   = dm_core_req_valid;
            dm_ds_req_addr    = dm_core_req_addr;
            dm_ds_req_wen     = dm_core_req_wen;
            dm_ds_req_wdata   = dm_core_req_wdata;
            dm_ds_req_wmask   = dm_core_req_wmask;
            dm_ds_req_size    = dm_core_req_size;
            dm_core_req_ready = dm_ds_req_ready;
            dm_core_rsp_valid = dm_ds_rsp_valid;
            dm_core_rsp_rdata = dm_ds_rsp_rdata;
            dm_core_rsp_fault = dm_ds_rsp_fault;
            dm_ds_rsp_ready   = dm_core_rsp_ready;
        end else if (dm_forward) begin
            dm_ds_req_valid   = dm_core_req_valid;
            dm_ds_req_addr    = dm_xlate_pa_q;
            dm_ds_req_wen     = dm_core_req_wen;
            dm_ds_req_wdata   = dm_core_req_wdata;
            dm_ds_req_wmask   = dm_core_req_wmask;
            dm_ds_req_size    = dm_core_req_size;
            dm_core_req_ready = dm_ds_req_ready;
            dm_core_rsp_valid = dm_ds_rsp_valid;
            dm_core_rsp_rdata = dm_ds_rsp_rdata;
            dm_core_rsp_fault = dm_ds_rsp_fault;
            dm_ds_rsp_ready   = dm_core_rsp_ready;
        end else if (dm_fault_reply) begin
            dm_ds_req_valid   = 1'b0;
            dm_ds_req_addr    = 32'd0;
            dm_ds_req_wen     = 1'b0;
            dm_ds_req_wdata   = 32'd0;
            dm_ds_req_wmask   = 4'd0;
            dm_ds_req_size    = 2'd0;
            dm_core_req_ready = 1'b1;
            dm_core_rsp_valid = 1'b1;
            dm_core_rsp_rdata = 32'd0;
            dm_core_rsp_fault = 1'b1;
            dm_ds_rsp_ready   = 1'b1;
        end else begin
            dm_ds_req_valid   = 1'b0;
            dm_ds_req_addr    = 32'd0;
            dm_ds_req_wen     = 1'b0;
            dm_ds_req_wdata   = 32'd0;
            dm_ds_req_wmask   = 4'd0;
            dm_ds_req_size    = 2'd0;
            dm_core_req_ready = 1'b0;
            dm_core_rsp_valid = 1'b0;
            dm_core_rsp_rdata = 32'd0;
            dm_core_rsp_fault = 1'b0;
            dm_ds_rsp_ready   = 1'b1;
        end
    end

    wire dm_forward_rsp_done = dm_forward && dm_ds_rsp_valid && dm_core_rsp_ready;
    wire dm_fault_rsp_done   = dm_fault_reply && dm_core_rsp_ready;

    // ---------------------------------------------------------------------
    // Sequential state
    // ---------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            ptw_state_q      <= PTW_IDLE;
            ptw_side_q       <= 1'b0;
            ptw_is_fetch_q   <= 1'b0;
            ptw_is_store_q   <= 1'b0;
            ptw_eff_priv_q   <= `PRV_M;
            ptw_va_q         <= 32'd0;
            ptw_l1_ppn1_q    <= 12'd0;
            ptw_l1_ppn0_q    <= 10'd0;
            if_xlate_valid_q <= 1'b0;
            if_xlate_fault_q <= 1'b0;
            if_xlate_pa_q    <= 32'd0;
            dm_xlate_valid_q <= 1'b0;
            dm_xlate_fault_q <= 1'b0;
            dm_xlate_pa_q    <= 32'd0;
        end else begin
            ptw_state_q    <= ptw_state_d;
            ptw_side_q     <= ptw_side_d;
            ptw_is_fetch_q <= ptw_is_fetch_d;
            ptw_is_store_q <= ptw_is_store_d;
            ptw_eff_priv_q <= ptw_eff_priv_d;
            ptw_va_q       <= ptw_va_d;
            ptw_l1_ppn1_q  <= ptw_l1_ppn1_d;
            ptw_l1_ppn0_q  <= ptw_l1_ppn0_d;

            // Commit walk-result updates (from the PTW FSM default block).
            if_xlate_valid_q <= if_xlate_valid_d;
            if_xlate_fault_q <= if_xlate_fault_d;
            if_xlate_pa_q    <= if_xlate_pa_d;
            dm_xlate_valid_q <= dm_xlate_valid_d;
            dm_xlate_fault_q <= dm_xlate_fault_d;
            dm_xlate_pa_q    <= dm_xlate_pa_d;

            // Clear the result when the current transaction retires.
            if (if_forward_rsp_done || if_fault_rsp_done) begin
                if_xlate_valid_q <= 1'b0;
                if_xlate_fault_q <= 1'b0;
            end
            if (dm_forward_rsp_done || dm_fault_rsp_done) begin
                dm_xlate_valid_q <= 1'b0;
                dm_xlate_fault_q <= 1'b0;
            end
        end
    end

endmodule
