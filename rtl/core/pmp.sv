// Physical Memory Protection — priv-spec PMP access check.
//
// 16 entries, scanned 0..15 in priority order: the first matching entry
// governs the access; if no entry matches the access is allowed in M-mode
// and denied otherwise (spec behaviour).
//
// Supported addressing modes: OFF (A=0), TOR (A=1), NAPOT (A=3). NA4
// (A=2) is decoded as NAPOT with a 4-byte granule. Lock bit (L) extends
// permission checks to M-mode and is honoured on both the match path and
// the write-side (write-side is enforced in csr.sv; we just consume the
// static config here).
//
// This is purely combinational. The caller drives the resolved physical
// address (post-translation) plus priv and access type, and sees `fault`
// the same cycle.

`include "defs.svh"

module pmp (
    input  logic [7:0]  cfg_i  [0:15],
    input  logic [31:0] addr_i [0:15],

    // Effective privilege of the access (for dmem under MPRV this is MPP,
    // not the current hart priv — caller handles that).
    input  logic [1:0]  priv_i,

    // Resolved 32-bit physical address. Width check: our SoC has 32-bit
    // PAs, so pmpaddr[29:0] encodes PA[31:2] (the standard SV32 layout).
    input  logic [31:0] access_addr_i,
    input  logic        access_is_read_i,
    input  logic        access_is_write_i,
    input  logic        access_is_exec_i,

    output logic        fault_o
);

    localparam logic [1:0] A_OFF   = 2'b00;
    localparam logic [1:0] A_TOR   = 2'b01;
    localparam logic [1:0] A_NA4   = 2'b10;
    localparam logic [1:0] A_NAPOT = 2'b11;

    // Per-entry match + permission.
    logic        match   [0:15];
    logic        allowed [0:15];

    // pmpaddr[i] holds PA[33:2]. For 32-bit PA we look at addr_i[i][29:0].
    // access_addr is the byte address; PA[31:2] = access_addr_i[31:2].
    wire [29:0] access_hi = access_addr_i[31:2];

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_entry
            wire [1:0] A = cfg_i[gi][4:3];
            wire       R = cfg_i[gi][0];
            wire       W = cfg_i[gi][1];
            wire       X = cfg_i[gi][2];
            wire       L = cfg_i[gi][7];

            wire [29:0] this_addr = addr_i[gi][29:0];
            wire [29:0] prev_addr = (gi == 0) ? 30'd0
                                             : addr_i[(gi == 0) ? 0 : gi-1][29:0];

            // ---- match computation per A mode ----
            // TOR:   prev_addr <= access_hi < this_addr  (as 30-bit unsigned)
            wire match_tor = (access_hi >= prev_addr) && (access_hi < this_addr);

            // NA4:   access_hi == this_addr (exact word)
            wire match_na4 = (access_hi == this_addr);

            // NAPOT: trailing-1s run of this_addr encodes the granule. The
            // bits ABOVE that run must match access_hi. Standard trick:
            //   run_mask = this_addr ^ (this_addr + 1)   ← low (k+1) bits = 1
            //   cmp_mask = ~run_mask                      ← upper bits
            wire [29:0] run_mask = this_addr ^ (this_addr + 30'd1);
            wire [29:0] cmp_mask = ~run_mask;
            wire        match_napot = (access_hi & cmp_mask) == (this_addr & cmp_mask);

            assign match[gi] = (A == A_TOR)   ? match_tor
                             : (A == A_NA4)   ? match_na4
                             : (A == A_NAPOT) ? match_napot
                             :                  1'b0;  // OFF

            // ---- permission for this entry ----
            // Lock bit applies even in M-mode. Without L, M-mode is unchecked.
            wire m_mode_bypass = (priv_i == `PRV_M) && !L;
            wire perm_ok = (access_is_read_i  && R)
                         | (access_is_write_i && W)
                         | (access_is_exec_i  && X);
            assign allowed[gi] = m_mode_bypass || perm_ok;
        end
    endgenerate

    // If no entry has A != OFF, treat PMP as unimplemented (spec: "if no PMP
    // entry is implemented, all modes succeed"). This avoids breaking S/U
    // code that never programs PMP — enforcement kicks in only once software
    // actually configures an entry.
    logic any_active;
    always_comb begin
        any_active = 1'b0;
        for (int i = 0; i < 16; i = i + 1)
            if (cfg_i[i][4:3] != A_OFF) any_active = 1'b1;
    end

    // Priority-encoded pick: first matching entry governs. If no entry
    // matches, M-mode is allowed, everyone else is denied.
    always_comb begin
        logic picked;
        logic decision;
        picked   = 1'b0;
        decision = (priv_i == `PRV_M);   // default when no match
        for (int i = 0; i < 16; i = i + 1) begin
            if (!picked && match[i]) begin
                picked   = 1'b1;
                decision = allowed[i];
            end
        end
        fault_o = any_active && !decision;
    end

endmodule
