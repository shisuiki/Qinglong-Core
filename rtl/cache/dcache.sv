// Data cache. Write-through, write-allocate, 4-way / 64 B lines / 16 KiB default.
//
// Drops between the core's `dmem_*` bus and memory. Same valid/ready req
// shape on both sides, single outstanding. Byte-masked writes via
// core_req_wmask[3:0]; memory side carries the same wmask so stores apply
// to SRAM with their original granularity.
//
// Write-through ⇒ memory is always current. No dirty bits, no writeback FSM,
// and FENCE.I needs no D-side flush — the I-cache can invalidate and refill
// from memory the moment the core retires the FENCE.I. It also matches the
// simulator's `sram_dpi_read` poll on `tohost` / MMIO addresses that lie in
// the cached SRAM range: a WB cache would strand those stores, WT does not.
//
// Hit latency: 2 cycles req-to-rsp on reads (matches icache). Write hit
// pipelines a single-cycle memory write and completes in ~3 cycles. Read
// miss: fill the full 64 B line with sixteen single-word reads (~20 cycles).
// Write miss: allocate-then-store — do the fill, merge the store into the
// filled line on the target word, and issue the memory write.
//
// Replacement is tree-pLRU (3 bits/set). The core still handles LR/SC/AMO
// atomicity itself (pipe drain + reservation); to the cache they're plain
// word loads and stores.

module dcache #(
    parameter int LINE_BYTES = 64,
    parameter int SETS       = 64,
    parameter int WAYS       = 4
)(
    input  logic        clk,
    input  logic        rst,

    // Core side — shape matches core_pipeline.dmem_*.
    input  logic        core_req_valid,
    input  logic [31:0] core_req_addr,
    input  logic        core_req_wen,
    input  logic [31:0] core_req_wdata,
    input  logic [3:0]  core_req_wmask,
    output logic        core_req_ready,
    output logic        core_rsp_valid,
    output logic [31:0] core_rsp_rdata,
    output logic        core_rsp_fault,

    // Memory side — single-word, writeable (mirrors sram_dp port B).
    output logic        mem_req_valid,
    output logic [31:0] mem_req_addr,
    output logic        mem_req_wen,
    output logic [3:0]  mem_req_wmask,
    output logic [31:0] mem_req_wdata,
    input  logic        mem_req_ready,
    input  logic        mem_rsp_valid,
    input  logic [31:0] mem_rsp_rdata
);

    // -------------------------------------------------------------------------
    // Geometry
    // -------------------------------------------------------------------------
    localparam int LINE_WORDS  = LINE_BYTES / 4;                 // 16
    localparam int OFFSET_BITS = $clog2(LINE_BYTES);             // 6
    localparam int WOFF_BITS   = $clog2(LINE_WORDS);             // 4
    localparam int INDEX_BITS  = $clog2(SETS);                   // 6
    localparam int TAG_BITS    = 32 - OFFSET_BITS - INDEX_BITS;  // 20
    localparam int WAY_BITS    = $clog2(WAYS);                   // 2
    localparam int DATA_DEPTH  = SETS * LINE_WORDS;              // 1024

    `define A_TAG(a)  (a[31 : OFFSET_BITS+INDEX_BITS])
    `define A_IDX(a)  (a[OFFSET_BITS+INDEX_BITS-1 : OFFSET_BITS])
    `define A_WOFF(a) (a[OFFSET_BITS-1 : 2])

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    logic [TAG_BITS-1:0] tag_ram    [WAYS][SETS];
    logic [31:0]         data_ram   [WAYS][DATA_DEPTH];
    logic [WAYS-1:0]     valid_bits [SETS];
    logic [WAYS-2:0]     plru_ram   [SETS];

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE,
        S_LOOKUP,   // tags/data out; hit/miss decide next step
        S_WT,       // write-through: drive mem_req write, wait for ready+rsp
        S_FILL,     // line fill on miss
        S_WT_MISS,  // after fill for a store-miss: issue the store to memory
        S_DONE      // drive rsp for one cycle
    } state_t;
    state_t state_q, state_d;

    // Saved request latched at S_IDLE → S_LOOKUP.
    logic [31:0] saved_addr_q;
    logic        saved_wen_q;
    logic [31:0] saved_wdata_q;
    logic [3:0]  saved_wmask_q;

    // Fill counters.
    logic [WOFF_BITS:0]  fill_req_cnt_q, fill_req_cnt_d;
    logic [WOFF_BITS:0]  fill_rsp_cnt_q, fill_rsp_cnt_d;
    logic [WAY_BITS-1:0] victim_way_q,   victim_way_d;
    logic                fill_fault_q,   fill_fault_d;

    // Write-through memory-side bookkeeping (one in-flight beat).
    logic wt_req_fired_q, wt_req_fired_d;
    logic wt_rsp_seen_q,  wt_rsp_seen_d;

    // rsp bookkeeping (read-hit returns data_rd[hit_way]).
    logic                rsp_hit_q, rsp_hit_d;
    logic [WAY_BITS-1:0] rsp_way_q, rsp_way_d;
    logic [31:0]         fill_target_q;

    // -------------------------------------------------------------------------
    // Read-port mux. One synchronous read port per way. Point at incoming req
    // during S_IDLE, otherwise stay on the saved line so data_rd is stable.
    // -------------------------------------------------------------------------
    logic [INDEX_BITS-1:0] rd_idx_w;
    logic [WOFF_BITS-1:0]  rd_woff_w;
    always_comb begin
        rd_idx_w  = `A_IDX (saved_addr_q);
        rd_woff_w = `A_WOFF(saved_addr_q);
        if (state_q == S_IDLE && core_req_valid) begin
            rd_idx_w  = `A_IDX (core_req_addr);
            rd_woff_w = `A_WOFF(core_req_addr);
        end
    end

    logic [TAG_BITS-1:0] tag_rd   [WAYS];
    logic [WAYS-1:0]     valid_rd;
    logic [31:0]         data_rd  [WAYS];

    always_ff @(posedge clk) begin
        for (int w = 0; w < WAYS; w++) begin
            tag_rd[w]  <= tag_ram [w][rd_idx_w];
            data_rd[w] <= data_ram[w][{rd_idx_w, rd_woff_w}];
        end
        valid_rd <= valid_bits[rd_idx_w];
    end

    // -------------------------------------------------------------------------
    // Hit detection (S_LOOKUP).
    // -------------------------------------------------------------------------
    logic [WAYS-1:0]     hit_vec_w;
    logic                hit_any_w;
    logic [WAY_BITS-1:0] hit_way_w;
    always_comb begin
        hit_vec_w = '0;
        for (int w = 0; w < WAYS; w++) begin
            hit_vec_w[w] = valid_rd[w] && (tag_rd[w] == `A_TAG(saved_addr_q));
        end
        hit_any_w = |hit_vec_w;
        hit_way_w = '0;
        for (int w = 0; w < WAYS; w++) begin
            if (hit_vec_w[w]) hit_way_w = w[WAY_BITS-1:0];
        end
    end

    // -------------------------------------------------------------------------
    // Tree-pLRU helpers.
    // -------------------------------------------------------------------------
    function automatic logic [WAY_BITS-1:0] plru_pick(input logic [WAYS-2:0] p);
        plru_pick = p[WAYS-2] ? (p[0] ? 2'd3 : 2'd2)
                              : (p[1] ? 2'd1 : 2'd0);
    endfunction

    function automatic logic [WAYS-2:0] plru_update(
            input logic [WAYS-2:0]     p,
            input logic [WAY_BITS-1:0] way);
        logic [WAYS-2:0] q;
        q = p;
        q[2] = (way[1] == 1'b1) ? 1'b0 : 1'b1;
        if (way[1] == 1'b0) q[1] = (way[0] == 1'b1) ? 1'b0 : 1'b1;
        else                q[0] = (way[0] == 1'b1) ? 1'b0 : 1'b1;
        return q;
    endfunction

    // -------------------------------------------------------------------------
    // Common signals.
    // -------------------------------------------------------------------------
    wire accept_req_w    = (state_q == S_IDLE) && core_req_valid;
    wire fill_complete_w = (fill_rsp_cnt_d == LINE_WORDS[WOFF_BITS:0]);

    // WT completion: both the mem request has been accepted and the response
    // has come back. sram_dp returns a rsp on writes (the usual ported shape),
    // so we wait for it rather than guessing.
    wire wt_done_w = wt_req_fired_q && wt_rsp_seen_q;

    // -------------------------------------------------------------------------
    // FSM — next-state.
    // -------------------------------------------------------------------------
    always_comb begin
        state_d        = state_q;
        fill_req_cnt_d = fill_req_cnt_q;
        fill_rsp_cnt_d = fill_rsp_cnt_q;
        victim_way_d   = victim_way_q;
        fill_fault_d   = fill_fault_q;
        rsp_hit_d      = rsp_hit_q;
        rsp_way_d      = rsp_way_q;
        wt_req_fired_d = wt_req_fired_q;
        wt_rsp_seen_d  = wt_rsp_seen_q;

        unique case (state_q)
            S_IDLE: begin
                if (accept_req_w) state_d = S_LOOKUP;
            end

            S_LOOKUP: begin
                if (hit_any_w) begin
                    rsp_hit_d = 1'b1;
                    rsp_way_d = hit_way_w;
                    if (saved_wen_q) begin
                        // Write-through: send the store to memory.
                        wt_req_fired_d = 1'b0;
                        wt_rsp_seen_d  = 1'b0;
                        state_d        = S_WT;
                    end else begin
                        state_d = S_DONE;
                    end
                end else begin
                    victim_way_d   = plru_pick(plru_ram[`A_IDX(saved_addr_q)]);
                    fill_req_cnt_d = '0;
                    fill_rsp_cnt_d = '0;
                    fill_fault_d   = 1'b0;
                    state_d        = S_FILL;
                end
            end

            S_WT: begin
                if (mem_req_valid && mem_req_ready) wt_req_fired_d = 1'b1;
                if (mem_rsp_valid)                  wt_rsp_seen_d  = 1'b1;
                // Handle same-cycle accept+rsp (1-cycle memory).
                if ((mem_req_fired_d_w || wt_req_fired_q) &&
                    (mem_rsp_valid    || wt_rsp_seen_q)) begin
                    state_d = S_DONE;
                end
            end

            S_FILL: begin
                if (mem_req_valid && mem_req_ready)
                    fill_req_cnt_d = fill_req_cnt_q + 1'b1;
                if (mem_rsp_valid) begin
                    fill_rsp_cnt_d = fill_rsp_cnt_q + 1'b1;
                end
                if (fill_complete_w) begin
                    rsp_hit_d = 1'b0;
                    rsp_way_d = victim_way_q;
                    if (saved_wen_q && !fill_fault_d) begin
                        // Store miss: line is now installed with the merged
                        // word (see data_ram write block); issue the store
                        // to memory as well for write-through.
                        wt_req_fired_d = 1'b0;
                        wt_rsp_seen_d  = 1'b0;
                        state_d        = S_WT_MISS;
                    end else begin
                        state_d = S_DONE;
                    end
                end
            end

            S_WT_MISS: begin
                if (mem_req_valid && mem_req_ready) wt_req_fired_d = 1'b1;
                if (mem_rsp_valid)                  wt_rsp_seen_d  = 1'b1;
                if ((mem_req_fired_d_w || wt_req_fired_q) &&
                    (mem_rsp_valid    || wt_rsp_seen_q)) begin
                    state_d = S_DONE;
                end
            end

            S_DONE: begin
                state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // Helper: did the mem req fire combinationally this cycle?
    wire mem_req_fired_d_w = mem_req_valid && mem_req_ready;

    // -------------------------------------------------------------------------
    // Sequential state + tag/valid/plru updates.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q        <= S_IDLE;
            saved_addr_q   <= '0;
            saved_wen_q    <= 1'b0;
            saved_wdata_q  <= '0;
            saved_wmask_q  <= '0;
            fill_req_cnt_q <= '0;
            fill_rsp_cnt_q <= '0;
            victim_way_q   <= '0;
            fill_fault_q   <= 1'b0;
            rsp_hit_q      <= 1'b0;
            rsp_way_q      <= '0;
            fill_target_q  <= '0;
            wt_req_fired_q <= 1'b0;
            wt_rsp_seen_q  <= 1'b0;
            for (int s = 0; s < SETS; s++) begin
                valid_bits[s] <= '0;
                plru_ram[s]   <= '0;
            end
        end else begin
            state_q        <= state_d;
            fill_req_cnt_q <= fill_req_cnt_d;
            fill_rsp_cnt_q <= fill_rsp_cnt_d;
            victim_way_q   <= victim_way_d;
            fill_fault_q   <= fill_fault_d;
            rsp_hit_q      <= rsp_hit_d;
            rsp_way_q      <= rsp_way_d;
            wt_req_fired_q <= wt_req_fired_d;
            wt_rsp_seen_q  <= wt_rsp_seen_d;

            if (accept_req_w) begin
                saved_addr_q  <= core_req_addr;
                saved_wen_q   <= core_req_wen;
                saved_wdata_q <= core_req_wdata;
                saved_wmask_q <= core_req_wmask;
            end

            // Capture the target word as it streams in during fill.
            if (state_q == S_FILL && mem_rsp_valid &&
                fill_rsp_cnt_q[WOFF_BITS-1:0] == `A_WOFF(saved_addr_q)) begin
                fill_target_q <= mem_rsp_rdata;
            end

            // Install tag + valid on successful fill completion.
            if (state_q == S_FILL && state_d != S_FILL && !fill_fault_d) begin
                tag_ram   [victim_way_q][`A_IDX(saved_addr_q)] <= `A_TAG(saved_addr_q);
                valid_bits[`A_IDX(saved_addr_q)][victim_way_q] <= 1'b1;
            end

            // pLRU: update on hit or successful fill.
            if (state_q == S_LOOKUP && hit_any_w) begin
                plru_ram[`A_IDX(saved_addr_q)] <= plru_update(
                    plru_ram[`A_IDX(saved_addr_q)], hit_way_w);
            end else if (state_q == S_FILL && state_d != S_FILL && !fill_fault_d) begin
                plru_ram[`A_IDX(saved_addr_q)] <= plru_update(
                    plru_ram[`A_IDX(saved_addr_q)], victim_way_q);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Data RAM write port — three sources (no dirty bit; write-through means
    // the cache copy and memory are always in sync after each write completes):
    //   (1) Hit-write: byte-masked merge into hit_way during S_LOOKUP.
    //   (2) Fill rsp: full-word write to victim_way during S_FILL. On the
    //       target word for a store-miss, merge the store with the fetched
    //       word so the cache reflects the post-store state immediately.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        for (int w = 0; w < WAYS; w++) begin
            if (state_q == S_LOOKUP && hit_any_w && saved_wen_q
                && w == int'(hit_way_w)) begin
                for (int b = 0; b < 4; b++) begin
                    if (saved_wmask_q[b])
                        data_ram[w][{`A_IDX(saved_addr_q), `A_WOFF(saved_addr_q)}][b*8 +: 8]
                            <= saved_wdata_q[b*8 +: 8];
                end
            end
            if (state_q == S_FILL && mem_rsp_valid && w == int'(victim_way_q)) begin
                if (saved_wen_q &&
                    fill_rsp_cnt_q[WOFF_BITS-1:0] == `A_WOFF(saved_addr_q)) begin
                    for (int b = 0; b < 4; b++) begin
                        data_ram[w][{`A_IDX(saved_addr_q), `A_WOFF(saved_addr_q)}][b*8 +: 8]
                            <= saved_wmask_q[b] ? saved_wdata_q[b*8 +: 8]
                                                : mem_rsp_rdata[b*8 +: 8];
                    end
                end else begin
                    data_ram[w][{`A_IDX(saved_addr_q),
                                 fill_rsp_cnt_q[WOFF_BITS-1:0]}] <= mem_rsp_rdata;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign core_req_ready = (state_q == S_IDLE);
    assign core_rsp_valid = (state_q == S_DONE);
    assign core_rsp_rdata = rsp_hit_q ? data_rd[rsp_way_q] : fill_target_q;
    assign core_rsp_fault = (state_q == S_DONE) && !rsp_hit_q && fill_fault_q;

    // Mem-side request:
    //   - S_FILL:    issue fill reads up to LINE_WORDS.
    //   - S_WT:      hit-write write-through (full word from data_ram is OK,
    //                but drive the core's original wmask so byte stores stay
    //                byte-granular in memory).
    //   - S_WT_MISS: miss-then-store write-through (core wdata + wmask).
    wire [31:0] line_base = {`A_TAG(saved_addr_q),
                             `A_IDX(saved_addr_q),
                             {OFFSET_BITS{1'b0}}};
    wire [31:0] target_addr_w = {saved_addr_q[31:2], 2'b00};

    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_addr  = 32'd0;
        mem_req_wen   = 1'b0;
        mem_req_wmask = 4'b0000;
        mem_req_wdata = 32'd0;
        unique case (state_q)
            S_FILL: begin
                mem_req_valid = (fill_req_cnt_q < LINE_WORDS[WOFF_BITS:0]);
                mem_req_addr  = line_base |
                                {{(32-OFFSET_BITS){1'b0}},
                                 fill_req_cnt_q[WOFF_BITS-1:0], 2'b00};
                mem_req_wen   = 1'b0;
                mem_req_wmask = 4'b0000;
                mem_req_wdata = 32'd0;
            end
            S_WT, S_WT_MISS: begin
                mem_req_valid = !wt_req_fired_q;
                mem_req_addr  = target_addr_w;
                mem_req_wen   = 1'b1;
                mem_req_wmask = saved_wmask_q;
                mem_req_wdata = saved_wdata_q;
            end
            default: ;
        endcase
    end

    `undef A_TAG
    `undef A_IDX
    `undef A_WOFF

endmodule
