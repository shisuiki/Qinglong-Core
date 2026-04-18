// Stage 6C-2a MMU skeleton — bare passthrough + page-fault stub.
//
// Two translation ports (ifetch + dmem). Each sits as a "bump in the wire"
// between the core and the downstream cache/memory path. Bare mode
// (satp.MODE == 0 or priv == M with MPRV == 0 for D-side) is a pure wire.
// Translated mode (the rest) is currently stubbed: the MMU accepts the
// request, latches the VA, and next cycle returns rsp_fault=1 (an access
// fault, observationally — Stage 6C-2b swaps the stub for a real PTW and
// refines this into a page fault cause).
//
// Interface shape matches the existing ifetch/dmem buses: valid/ready req +
// valid/ready rsp, single outstanding per port. This module adds no latency
// to the bare-mode path (all signals combinational through).
//
// CSR state (satp, priv, mstatus.MPRV/MPP/SUM/MXR) comes in as inputs and
// is sampled on every cycle — the core's CSR changes are visible the
// following cycle (MRET/SRET take effect at retirement, then the MMU sees
// them on the next access).

`include "defs.svh"

module mmu (
    input  logic        clk,
    input  logic        rst,

    // CSR state from the core's csr.sv
    input  logic [31:0] satp_i,
    input  logic [1:0]  priv_i,
    input  logic        mprv_i,
    input  logic [1:0]  mpp_i,
    input  logic        sum_i,    // unused in Stage 6C-2a
    input  logic        mxr_i,    // unused in Stage 6C-2a

    // --- ifetch core-facing (upstream) ---
    input  logic        if_core_req_valid,
    input  logic [31:0] if_core_req_addr,
    output logic        if_core_req_ready,
    output logic        if_core_rsp_valid,
    output logic [31:0] if_core_rsp_data,
    output logic        if_core_rsp_fault,
    input  logic        if_core_rsp_ready,

    // --- ifetch downstream (cache / SRAM) ---
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
    output logic        dm_ds_rsp_ready
);

    // --- translation-needed predicates ---
    // SV32: satp[31] is the MODE bit.
    wire satp_on = satp_i[31];

    // Ifetch always uses the current priv (MPRV does not affect fetch).
    wire xlate_if = satp_on && (priv_i != `PRV_M);

    // Dmem effective priv: if priv == M and MPRV set, use MPP instead.
    wire [1:0] dm_eff_priv = (priv_i == `PRV_M && mprv_i) ? mpp_i : priv_i;
    wire       xlate_dm    = satp_on && (dm_eff_priv != `PRV_M);

    // ---------------------------------------------------------------------
    // Ifetch path — bare passthrough + translated-mode fault stub.
    // ---------------------------------------------------------------------
    // Translation stub: 1-cycle pending register. On an accepted req in
    // translated mode we set `if_xlate_pend_q` and next cycle return fault.
    logic if_xlate_pend_q, if_xlate_pend_d;

    always_comb begin
        if_xlate_pend_d = if_xlate_pend_q;
        if (if_xlate_pend_q && if_core_rsp_ready) if_xlate_pend_d = 1'b0;
        if (xlate_if && if_core_req_valid && if_core_req_ready && !if_xlate_pend_q)
            if_xlate_pend_d = 1'b1;
    end

    always_comb begin
        if (xlate_if) begin
            // Stub: don't issue to downstream. Accept one req at a time and
            // respond with fault next cycle.
            if_ds_req_valid   = 1'b0;
            if_ds_req_addr    = 32'd0;
            if_ds_rsp_ready   = 1'b1;
            if_core_req_ready = !if_xlate_pend_q;
            if_core_rsp_valid = if_xlate_pend_q;
            if_core_rsp_data  = 32'd0;
            if_core_rsp_fault = if_xlate_pend_q;
        end else begin
            // Bare passthrough.
            if_ds_req_valid   = if_core_req_valid;
            if_ds_req_addr    = if_core_req_addr;
            if_core_req_ready = if_ds_req_ready;
            if_core_rsp_valid = if_ds_rsp_valid;
            if_core_rsp_data  = if_ds_rsp_data;
            if_core_rsp_fault = if_ds_rsp_fault;
            if_ds_rsp_ready   = if_core_rsp_ready;
        end
    end

    // ---------------------------------------------------------------------
    // Dmem path — bare passthrough + translated-mode fault stub.
    // ---------------------------------------------------------------------
    logic dm_xlate_pend_q, dm_xlate_pend_d;

    always_comb begin
        dm_xlate_pend_d = dm_xlate_pend_q;
        if (dm_xlate_pend_q && dm_core_rsp_ready) dm_xlate_pend_d = 1'b0;
        if (xlate_dm && dm_core_req_valid && dm_core_req_ready && !dm_xlate_pend_q)
            dm_xlate_pend_d = 1'b1;
    end

    always_comb begin
        if (xlate_dm) begin
            dm_ds_req_valid   = 1'b0;
            dm_ds_req_addr    = 32'd0;
            dm_ds_req_wen     = 1'b0;
            dm_ds_req_wdata   = 32'd0;
            dm_ds_req_wmask   = 4'd0;
            dm_ds_req_size    = 2'd0;
            dm_ds_rsp_ready   = 1'b1;
            dm_core_req_ready = !dm_xlate_pend_q;
            dm_core_rsp_valid = dm_xlate_pend_q;
            dm_core_rsp_rdata = 32'd0;
            dm_core_rsp_fault = dm_xlate_pend_q;
        end else begin
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
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            if_xlate_pend_q <= 1'b0;
            dm_xlate_pend_q <= 1'b0;
        end else begin
            if_xlate_pend_q <= if_xlate_pend_d;
            dm_xlate_pend_q <= dm_xlate_pend_d;
        end
    end

    // Unused inputs (reserved for Stage 6C-2b PTW access checks).
    wire _unused = &{1'b0, sum_i, mxr_i, 1'b0};

endmodule
