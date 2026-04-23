// Platform-Level Interrupt Controller (PLIC): SiFive-style, 2 contexts
// (hart 0 M-mode = context 0, hart 0 S-mode = context 1).
//
// Compressed register layout inside a 16 MiB window at base 0x0C00_0000:
//   + 0x00_0000       priority[0]       (source 0 reserved, priority ignored)
//   + 0x00_0004..     priority[1..N-1]  (3-bit priority, 0 disables)
//   + 0x00_1000       pending[31:0]     (source 0 bit = 0 always)
//   + 0x00_2000       enable[ctx=0]     (one 32-bit word per 32 sources)
//   + 0x00_2080       enable[ctx=1]
//   + 0x20_0000       threshold[ctx=0]
//   + 0x20_0004       claim/complete[ctx=0]
//   + 0x20_1000       threshold[ctx=1]
//   + 0x20_1004       claim/complete[ctx=1]
//
// Behaviour:
//   - Interrupt source i asserts `sources_i[i]` on its IRQ line (level, active high).
//     pending[i] latches when sources_i[i] & !enable_any_ctx[i] & (not claimed);
//     actually per spec: pending[i] sets on a 0→1 transition OR stays high while
//     the source is asserted *until* a claim for that source happens. We model
//     the simpler "pending follows source until claim" which is fine for level-
//     triggered sources like UartLite.
//   - claim[ctx] returns the highest-priority enabled pending source > threshold,
//     clears pending for that source, and records "claimed by ctx" so a second
//     context can't re-claim the same interrupt while in flight.
//   - complete[ctx] (write to the same offset) releases the claim. If the source
//     line is still asserted, pending re-arms next cycle.
//   - irq_o[ctx] = 1 whenever ∃ enabled pending source with priority > threshold[ctx].
//
// Minimal parameterisation: NUM_SOURCES up to 32 (one pending word). For this SoC
// we set NUM_SOURCES = 4 (source 1 = UartLite). Any future source wires in at
// sources_i[i], i >= 1; source 0 is hardwired inactive.

`timescale 1ns/1ps

module plic #(
    parameter int NUM_SOURCES = 4,   // including reserved source 0
    parameter int NUM_CTX     = 2    // 0 = M-mode hart0, 1 = S-mode hart0
)(
    input  logic        clk,
    input  logic        rst,

    // dmem-fabric slave (same shape as CLINT/MMIO).
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic        req_wen,
    input  logic [31:0] req_wdata,
    input  logic [3:0]  req_wmask,
    output logic        req_ready,
    output logic        rsp_valid,
    output logic [31:0] rsp_rdata,
    output logic        rsp_fault,

    // Interrupt source lines (level, active-high). sources_i[0] ignored.
    input  logic [NUM_SOURCES-1:0] sources_i,

    // One IRQ output per context.
    output logic [NUM_CTX-1:0]     irq_o
);

    localparam int PRIO_W = 3;  // 3-bit priority (0..7); 0 disables

    // ---------- address decode ----------
    // offset bits [23:0] within the 16 MiB window.
    wire [23:0] off = req_addr[23:0];

    // priority[i] at offset i*4 for i in [0..NUM_SOURCES-1]. Use a byte range
    // check rather than a wide equality so future NUM_SOURCES growth works.
    wire in_prio_window   = (off <  24'h00_1000);
    wire in_pending       = (off == 24'h00_1000);
    wire in_enable_window = (off >= 24'h00_2000) && (off <  24'h00_2000 + NUM_CTX*24'h80);
    wire in_ctx_window    = (off >= 24'h20_0000) && (off <  24'h20_0000 + NUM_CTX*24'h1000);

    // priority index = off/4 when in_prio_window.
    wire [31:0] prio_idx = off[23:2];
    // enable context and word index. One 32-bit word per 32 sources per context.
    wire [31:0] en_rel   = off - 24'h00_2000;
    wire [31:0] en_ctx   = en_rel / 24'h80;
    // context index for threshold/claim.
    wire [31:0] ctx_rel  = off - 24'h20_0000;
    wire [31:0] ctx_idx  = ctx_rel / 24'h1000;
    wire [11:0] ctx_off  = ctx_rel[11:0];

    // ---------- storage ----------
    logic [PRIO_W-1:0]          priority_q   [NUM_SOURCES];
    logic [NUM_SOURCES-1:0]     pending_q;                   // pending bits
    logic [NUM_SOURCES-1:0]     enable_q     [NUM_CTX];
    logic [PRIO_W-1:0]          threshold_q  [NUM_CTX];
    logic [$clog2(NUM_SOURCES+1)-1:0] claimed_src_q [NUM_CTX]; // 0 = not claimed

    // Gateway: pending = (source_i & !active_gate) | pending_q, cleared only by claim.
    // For level-triggered sources, we want: pending sticks while source is high
    // until claimed; after claim, pending clears and only re-arms once the source
    // deasserts (otherwise M-mode would re-claim the same IRQ on every cycle).
    // We implement this with a per-source "in-flight" state: when claim fires,
    // we clear pending AND set `inflight_q[src]` to 1; while inflight, pending
    // does not re-arm even if source is high. On complete, inflight clears.
    logic [NUM_SOURCES-1:0]     inflight_q;

    // ---------- pick: find best enabled pending source for a context ----------
    // Combinational priority-encode: walk sources 1..N-1, keep the one with the
    // highest priority that is both enabled and pending; tie-break by lowest ID.
    function automatic [$clog2(NUM_SOURCES+1)-1:0] pick_best_src(input int ctx);
        logic [PRIO_W-1:0] best_prio;
        logic [$clog2(NUM_SOURCES+1)-1:0] best_idx;
        begin
            best_prio = '0;
            best_idx  = '0;
            for (int s = 1; s < NUM_SOURCES; s++) begin
                if (enable_q[ctx][s] && pending_q[s]
                    && priority_q[s] > threshold_q[ctx]
                    && priority_q[s] > best_prio) begin
                    best_prio = priority_q[s];
                    best_idx  = s[$clog2(NUM_SOURCES+1)-1:0];
                end
            end
            pick_best_src = best_idx;
        end
    endfunction

    // ---------- IRQ outputs ----------
    // Context ctx asserts irq_o[ctx] when pick_best_src(ctx) != 0.
    always_comb begin
        for (int c = 0; c < NUM_CTX; c++) begin
            irq_o[c] = (pick_best_src(c) != '0);
        end
    end

    // ---------- bus ----------
    assign req_ready = 1'b1;

    logic        rsp_valid_q;
    logic [31:0] rsp_rdata_q;
    logic        rsp_fault_q;
    assign rsp_valid = rsp_valid_q;
    assign rsp_rdata = rsp_rdata_q;
    assign rsp_fault = rsp_fault_q;

    // ---------- sequential ----------
    // apply_wmask — same helper as CLINT.
    function automatic [31:0] apply_wmask(input [31:0] old_v,
                                          input [31:0] new_v,
                                          input [3:0]  mask);
        apply_wmask[ 7: 0] = mask[0] ? new_v[ 7: 0] : old_v[ 7: 0];
        apply_wmask[15: 8] = mask[1] ? new_v[15: 8] : old_v[15: 8];
        apply_wmask[23:16] = mask[2] ? new_v[23:16] : old_v[23:16];
        apply_wmask[31:24] = mask[3] ? new_v[31:24] : old_v[31:24];
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < NUM_SOURCES; i++) priority_q[i]  <= '0;
            pending_q    <= '0;
            inflight_q   <= '0;
            for (int c = 0; c < NUM_CTX; c++) begin
                enable_q[c]      <= '0;
                threshold_q[c]   <= '0;
                claimed_src_q[c] <= '0;
            end
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_fault_q <= 1'b0;
        end else begin
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_fault_q <= 1'b0;

            // Gateway: latch pending when source goes high (and not inflight).
            for (int s = 1; s < NUM_SOURCES; s++) begin
                if (sources_i[s] && !inflight_q[s])
                    pending_q[s] <= 1'b1;
            end
            // Source 0 is always inactive.
            pending_q[0] <= 1'b0;

            // Bus access.
            if (req_valid) begin
                rsp_valid_q <= 1'b1;

                if (in_prio_window) begin
                    // priority_q[prio_idx]: 3-bit write in the low bits.
                    if (req_wen) begin
                        if (prio_idx > 0 && prio_idx < NUM_SOURCES && req_wmask[0])
                            priority_q[prio_idx] <= req_wdata[PRIO_W-1:0];
                    end else begin
                        if (prio_idx < NUM_SOURCES)
                            rsp_rdata_q <= {{(32-PRIO_W){1'b0}}, priority_q[prio_idx]};
                        else
                            rsp_rdata_q <= 32'd0;
                    end
                end
                else if (in_pending) begin
                    // pending is RO for software (hardware-managed).
                    if (req_wen) begin
                        // ignore writes
                    end else begin
                        rsp_rdata_q <= {{(32-NUM_SOURCES){1'b0}}, pending_q};
                    end
                end
                else if (in_enable_window) begin
                    if (en_ctx < NUM_CTX) begin
                        if (req_wen) begin
                            automatic logic [31:0] old_en;
                            automatic logic [31:0] new_en;
                            old_en = {{(32-NUM_SOURCES){1'b0}}, enable_q[en_ctx]};
                            new_en = apply_wmask(old_en, req_wdata, req_wmask);
                            enable_q[en_ctx] <= new_en[NUM_SOURCES-1:0];
                            // Source 0 enable is always 0.
                            enable_q[en_ctx][0] <= 1'b0;
                        end else begin
                            rsp_rdata_q <= {{(32-NUM_SOURCES){1'b0}}, enable_q[en_ctx]};
                        end
                    end else begin
                        rsp_fault_q <= 1'b1;
                    end
                end
                else if (in_ctx_window) begin
                    if (ctx_idx < NUM_CTX) begin
                        if (ctx_off[11:0] == 12'h000) begin
                            // threshold
                            if (req_wen) begin
                                if (req_wmask[0])
                                    threshold_q[ctx_idx] <= req_wdata[PRIO_W-1:0];
                            end else begin
                                rsp_rdata_q <= {{(32-PRIO_W){1'b0}}, threshold_q[ctx_idx]};
                            end
                        end
                        else if (ctx_off[11:0] == 12'h004) begin
                            // claim (read) / complete (write)
                            if (req_wen) begin
                                // complete: release inflight for the completed src ID.
                                // We accept any write value equal to a currently inflight
                                // source owned by *any* context — standard spec.
                                if (req_wdata < NUM_SOURCES && req_wdata != 0) begin
                                    inflight_q[req_wdata[$clog2(NUM_SOURCES)-1:0]] <= 1'b0;
                                    // If source still asserted, let the next cycle re-pend.
                                    if (claimed_src_q[ctx_idx] ==
                                        req_wdata[$clog2(NUM_SOURCES+1)-1:0]) begin
                                        claimed_src_q[ctx_idx] <= '0;
                                    end
                                end
                            end else begin
                                automatic logic [$clog2(NUM_SOURCES+1)-1:0] best;
                                best = pick_best_src(ctx_idx);
                                rsp_rdata_q <= {{(32-$bits(best)){1'b0}}, best};
                                if (best != '0) begin
                                    pending_q[best]      <= 1'b0;
                                    inflight_q[best]     <= 1'b1;
                                    claimed_src_q[ctx_idx] <= best;
                                end
                            end
                        end
                        else begin
                            rsp_fault_q <= 1'b1;
                        end
                    end else begin
                        rsp_fault_q <= 1'b1;
                    end
                end
                else begin
                    rsp_fault_q <= 1'b1;
                end
            end
        end
    end

endmodule
