// Instruction cache. 4-way set-associative, 64 B lines, 16 KiB default.
//
// Drops between the core's `ifetch_*` bus and memory. Same protocol on both
// sides (valid/ready req + valid-only rsp, single outstanding). A miss
// stalls the core by dropping `core_req_ready`, fills a full 64 B line via
// sixteen single-word back-to-back memory requests, writes it into the
// chosen-victim way, and drives the rsp for the originally-requested word.
//
// Hit latency: 1 cycle (matches sram_dp). Miss latency: ~18 cycles against
// a single-cycle memory port.
//
// Replacement is tree-pLRU (3 bits/set for 4-way). `invalidate` pulses
// clear all valid bits in one cycle (drives FENCE.I from core_pipeline).

module icache #(
    parameter int LINE_BYTES = 64,
    parameter int SETS       = 64,
    parameter int WAYS       = 4
)(
    input  logic        clk,
    input  logic        rst,

    // Core side — shape matches core_pipeline.ifetch_*.
    input  logic        core_req_valid,
    input  logic [31:0] core_req_addr,
    output logic        core_req_ready,
    output logic        core_rsp_valid,
    output logic [31:0] core_rsp_data,
    output logic        core_rsp_fault,
    input  logic        core_rsp_ready,   // ignored — core always ready

    // Memory side — single-word fetches on miss fills.
    output logic        mem_req_valid,
    output logic [31:0] mem_req_addr,
    input  logic        mem_req_ready,
    input  logic        mem_rsp_valid,
    input  logic [31:0] mem_rsp_data,
    input  logic        mem_rsp_fault,

    // 1-cycle pulse: clear all valid bits (FENCE.I). During the pulse cycle
    // core_req_ready is held low so the next request sees the cleared state.
    input  logic        invalidate
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

    // -------------------------------------------------------------------------
    // Address-field extractors (evaluated on any 32-bit byte address).
    // -------------------------------------------------------------------------
    `define A_TAG(a)  (a[31 : OFFSET_BITS+INDEX_BITS])
    `define A_IDX(a)  (a[OFFSET_BITS+INDEX_BITS-1 : OFFSET_BITS])
    `define A_WOFF(a) (a[OFFSET_BITS-1 : 2])

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    // Tag and data arrays: synthesised to BRAM on Xilinx (no reset).
    logic [TAG_BITS-1:0] tag_ram  [WAYS][SETS];
    logic [31:0]         data_ram [WAYS][DATA_DEPTH];
    // Valid bits in FFs so reset clears them cheaply in one cycle.
    logic [WAYS-1:0]     valid_bits [SETS];
    // Tree-pLRU, 3 bits per set for 4-way.
    logic [WAYS-2:0]     plru_ram   [SETS];

    // -------------------------------------------------------------------------
    // Tag/valid/data synchronous read ports — 1-cycle latency.
    //
    // During S_IDLE with accept: drive read address from the incoming req so
    // the output is valid on the S_LOOKUP cycle.
    // During S_LOOKUP / S_FILL / S_DONE: keep the read address pointed at the
    // saved-request line so data_rd is stable until consumed.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_LOOKUP, S_FILL, S_DONE } state_t;
    state_t state_q, state_d;

    logic [31:0]          saved_addr_q;

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
    // Hit detection (S_LOOKUP cycle, off registered reads).
    // -------------------------------------------------------------------------
    logic [WAYS-1:0]      hit_vec_w;
    logic                 hit_any_w;
    logic [WAY_BITS-1:0]  hit_way_w;
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
    // Tree-pLRU helpers (parameterised for 4-way; left-as-exercise for others).
    //
    //        plru[2]
    //       /        \
    //  plru[1]       plru[0]
    //   /  \          /  \
    //  w0  w1        w2  w3
    //
    // plru[b]=1 means "right subtree is LRU". On access to way W, flip the
    // bits on the root-to-leaf path so they point *away* from W.
    // -------------------------------------------------------------------------
    function automatic logic [WAY_BITS-1:0] plru_pick(input logic [WAYS-2:0] p);
        plru_pick = p[WAYS-2] ? (p[0] ? 2'd3 : 2'd2)
                              : (p[1] ? 2'd1 : 2'd0);
    endfunction

    function automatic logic [WAYS-2:0] plru_update(
            input logic [WAYS-2:0]    p,
            input logic [WAY_BITS-1:0] way);
        logic [WAYS-2:0] q;
        q = p;
        // Root bit: 0 → accessed right half, 1 → accessed left half.
        q[2] = (way[1] == 1'b1) ? 1'b0 : 1'b1;
        if (way[1] == 1'b0) q[1] = (way[0] == 1'b1) ? 1'b0 : 1'b1;
        else                q[0] = (way[0] == 1'b1) ? 1'b0 : 1'b1;
        return q;
    endfunction

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    logic [WOFF_BITS:0]   fill_req_cnt_q,  fill_req_cnt_d;   // 0..LINE_WORDS
    logic [WOFF_BITS:0]   fill_rsp_cnt_q,  fill_rsp_cnt_d;
    logic [WAY_BITS-1:0]  victim_way_q,    victim_way_d;
    logic                 fill_fault_q,    fill_fault_d;

    // rsp bookkeeping: distinguish hit-rsp vs fill-rsp, and the way involved.
    logic                 rsp_hit_q,       rsp_hit_d;
    logic [WAY_BITS-1:0]  rsp_way_q,       rsp_way_d;
    // Bypass: capture the *target* word the cycle it arrives from memory, so
    // we don't race the data_ram write against its re-read.
    logic [31:0]          fill_target_q;

    wire accept_req_w = (state_q == S_IDLE) && core_req_valid;
    wire fill_complete_w = (fill_rsp_cnt_d == LINE_WORDS[WOFF_BITS:0]);

    always_comb begin
        state_d        = state_q;
        fill_req_cnt_d = fill_req_cnt_q;
        fill_rsp_cnt_d = fill_rsp_cnt_q;
        victim_way_d   = victim_way_q;
        fill_fault_d   = fill_fault_q;
        rsp_hit_d      = rsp_hit_q;
        rsp_way_d      = rsp_way_q;

        unique case (state_q)
            S_IDLE: begin
                if (accept_req_w) state_d = S_LOOKUP;
            end

            S_LOOKUP: begin
                if (hit_any_w) begin
                    rsp_hit_d = 1'b1;
                    rsp_way_d = hit_way_w;
                    state_d   = S_DONE;
                end else begin
                    victim_way_d   = plru_pick(plru_ram[`A_IDX(saved_addr_q)]);
                    fill_req_cnt_d = '0;
                    fill_rsp_cnt_d = '0;
                    fill_fault_d   = 1'b0;
                    state_d        = S_FILL;
                end
            end

            S_FILL: begin
                if (mem_req_valid && mem_req_ready)
                    fill_req_cnt_d = fill_req_cnt_q + 1'b1;
                if (mem_rsp_valid) begin
                    fill_rsp_cnt_d = fill_rsp_cnt_q + 1'b1;
                    if (mem_rsp_fault) fill_fault_d = 1'b1;
                end
                if (fill_complete_w) begin
                    rsp_hit_d = 1'b0;
                    rsp_way_d = victim_way_q;
                    state_d   = S_DONE;
                end
            end

            S_DONE: begin
                state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential state updates.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q        <= S_IDLE;
            saved_addr_q   <= '0;
            fill_req_cnt_q <= '0;
            fill_rsp_cnt_q <= '0;
            victim_way_q   <= '0;
            fill_fault_q   <= 1'b0;
            rsp_hit_q      <= 1'b0;
            rsp_way_q      <= '0;
            fill_target_q  <= '0;
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

            if (accept_req_w) saved_addr_q <= core_req_addr;

            // Invalidate pulse: clear all valid bits. core_req_ready is held
            // low on the same cycle (see the outputs block), so no request
            // is mid-flight here. One cycle is enough — NBAs land at posedge
            // and the next cycle's lookup reads the cleared bits.
            if (invalidate) begin
                for (int s = 0; s < SETS; s++) valid_bits[s] <= '0;
            end

            // Capture target word as it streams in — avoids the read-after-
            // write race on the data BRAM when saved_woff == LINE_WORDS-1.
            if (state_q == S_FILL && mem_rsp_valid && !mem_rsp_fault &&
                fill_rsp_cnt_q[WOFF_BITS-1:0] == `A_WOFF(saved_addr_q)) begin
                fill_target_q <= mem_rsp_data;
            end

            // Commit tag + valid on successful fill completion.
            if (state_q == S_FILL && state_d == S_DONE && !fill_fault_d) begin
                tag_ram[victim_way_q][`A_IDX(saved_addr_q)]        <= `A_TAG(saved_addr_q);
                valid_bits[`A_IDX(saved_addr_q)][victim_way_q]     <= 1'b1;
            end

            // pLRU update on hit or on successful fill.
            if (state_q == S_LOOKUP && hit_any_w) begin
                plru_ram[`A_IDX(saved_addr_q)] <= plru_update(
                    plru_ram[`A_IDX(saved_addr_q)], hit_way_w);
            end else if (state_q == S_FILL && state_d == S_DONE && !fill_fault_d) begin
                plru_ram[`A_IDX(saved_addr_q)] <= plru_update(
                    plru_ram[`A_IDX(saved_addr_q)], victim_way_q);
            end
        end
    end

    // -------------------------------------------------------------------------
    // Data RAM write port — only the victim way during a fill.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        for (int w = 0; w < WAYS; w++) begin
            if (state_q == S_FILL && mem_rsp_valid && !mem_rsp_fault &&
                w == int'(victim_way_q)) begin
                data_ram[w][{`A_IDX(saved_addr_q),
                             fill_rsp_cnt_q[WOFF_BITS-1:0]}] <= mem_rsp_data;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    // Hold ready low on the invalidate cycle so the next req (if any) is
    // blocked until the cleared valid bits have taken effect.
    assign core_req_ready = (state_q == S_IDLE) && !invalidate;

    assign core_rsp_valid = (state_q == S_DONE);
    assign core_rsp_data  = rsp_hit_q ? data_rd[rsp_way_q] : fill_target_q;
    assign core_rsp_fault = (state_q == S_DONE) && !rsp_hit_q && fill_fault_q;

    // Memory-side request stream.
    wire [31:0] line_base = {`A_TAG(saved_addr_q),
                             `A_IDX(saved_addr_q),
                             {OFFSET_BITS{1'b0}}};
    assign mem_req_valid = (state_q == S_FILL) &&
                           (fill_req_cnt_q < LINE_WORDS[WOFF_BITS:0]);
    assign mem_req_addr  = line_base |
                           {{(32-OFFSET_BITS){1'b0}},
                            fill_req_cnt_q[WOFF_BITS-1:0], 2'b00};

    `undef A_TAG
    `undef A_IDX
    `undef A_WOFF

endmodule
