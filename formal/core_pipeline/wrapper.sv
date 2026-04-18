// rvfi_wrapper for core_pipeline.
//
// Wraps the DUT with symbolic ifetch/dmem/irq stimulus for the riscv-formal
// BMC engine. No real memory — every response datum is a `rvformal_rand_reg`
// so the solver can explore all possible returns. Correctness of the core
// against the ISA spec must hold for any legal bus behaviour.

module rvfi_wrapper (
    input  logic clock,
    input  logic reset,
    `RVFI_OUTPUTS
);

    // ---- symbolic bus stimulus ----
    (* keep *) `rvformal_rand_reg        ifetch_req_ready;
    (* keep *) `rvformal_rand_reg        ifetch_rsp_valid;
    (* keep *) `rvformal_rand_reg [31:0] ifetch_rsp_data;
    (* keep *) `rvformal_rand_reg        ifetch_rsp_fault;
    (* keep *) `rvformal_rand_reg        ifetch_rsp_pagefault;

    (* keep *) `rvformal_rand_reg        dmem_req_ready;
    (* keep *) `rvformal_rand_reg        dmem_rsp_valid;
    (* keep *) `rvformal_rand_reg [31:0] dmem_rsp_rdata;
    (* keep *) `rvformal_rand_reg        dmem_rsp_fault;
    (* keep *) `rvformal_rand_reg        dmem_rsp_pagefault;

    // Interrupts: leave them free for now. `insn` checks don't cover irq semantics
    // so it's fine if the solver flips them; they just become potential traps.
    (* keep *) `rvformal_rand_reg        ext_mti;
    (* keep *) `rvformal_rand_reg        ext_msi;
    (* keep *) `rvformal_rand_reg        ext_mei;

    // ---- observable outputs (kept so they appear in the VCD on cex) ----
    (* keep *) wire        ifetch_req_valid;
    (* keep *) wire [31:0] ifetch_req_addr;
    (* keep *) wire        ifetch_rsp_ready;
    (* keep *) wire        dmem_req_valid;
    (* keep *) wire [31:0] dmem_req_addr;
    (* keep *) wire        dmem_req_wen;
    (* keep *) wire [31:0] dmem_req_wdata;
    (* keep *) wire [3:0]  dmem_req_wmask;
    (* keep *) wire [1:0]  dmem_req_size;
    (* keep *) wire        dmem_rsp_ready;

    // Commit trace (unused by checks but keep for debugging cex).
    (* keep *) wire        commit_valid;
    (* keep *) wire [31:0] commit_pc;
    (* keep *) wire [31:0] commit_insn;
    (* keep *) wire        commit_rd_wen;
    (* keep *) wire [4:0]  commit_rd_addr;
    (* keep *) wire [31:0] commit_rd_data;
    (* keep *) wire        commit_trap;
    (* keep *) wire [31:0] commit_cause;

    core_pipeline uut (
        .clk(clock), .rst(reset),

        .ifetch_req_valid (ifetch_req_valid),
        .ifetch_req_addr  (ifetch_req_addr),
        .ifetch_req_ready (ifetch_req_ready),
        .ifetch_rsp_valid (ifetch_rsp_valid),
        .ifetch_rsp_data  (ifetch_rsp_data),
        .ifetch_rsp_fault (ifetch_rsp_fault),
        .ifetch_rsp_pagefault (ifetch_rsp_pagefault),
        .ifetch_rsp_ready (ifetch_rsp_ready),

        .dmem_req_valid   (dmem_req_valid),
        .dmem_req_addr    (dmem_req_addr),
        .dmem_req_wen     (dmem_req_wen),
        .dmem_req_wdata   (dmem_req_wdata),
        .dmem_req_wmask   (dmem_req_wmask),
        .dmem_req_size    (dmem_req_size),
        .dmem_req_ready   (dmem_req_ready),
        .dmem_rsp_valid   (dmem_rsp_valid),
        .dmem_rsp_rdata   (dmem_rsp_rdata),
        .dmem_rsp_fault   (dmem_rsp_fault),
        .dmem_rsp_pagefault (dmem_rsp_pagefault),
        .dmem_rsp_ready   (dmem_rsp_ready),

        .ext_mti (ext_mti), .ext_msi (ext_msi), .ext_mei (ext_mei),

        .commit_valid    (commit_valid),
        .commit_pc       (commit_pc),
        .commit_insn     (commit_insn),
        .commit_rd_wen   (commit_rd_wen),
        .commit_rd_addr  (commit_rd_addr),
        .commit_rd_data  (commit_rd_data),
        .commit_trap     (commit_trap),
        .commit_cause    (commit_cause),

        `RVFI_CONN32
    );

    // --- fairness: assume ifetch eventually responds when requested ---
    // Without this the solver finds trivial "never retire anything" cexes.
    // `insn` checks only need _liveness_ on retirement up to the depth, which
    // we get by assuming ifetch_rsp_valid tracks the one-outstanding protocol.
    // We don't model the req/rsp ordering here — the core's own trap-on-fault
    // path will trap on unexpected rsps, which is handled by rvfi_trap.

    // No memory model: let the solver pick arbitrary data. The riscv-formal
    // `insn` checks prove retirement correctness against observed rs1/rs2,
    // so the actual fetched instruction word the solver picks IS the insn
    // under test.

    // For the first-pass insn checks: exclude fault/interrupt paths. These
    // have their own checks (bus_imem_fault, bus_dmem_fault, future CSR
    // work) and would otherwise let the solver turn any ADDI into a trap
    // via ifetch_rsp_fault, masking the arith behaviour we're proving.
    always @* begin
        assume (!ifetch_rsp_fault);
        assume (!ifetch_rsp_pagefault);
        assume (!dmem_rsp_fault);
        assume (!dmem_rsp_pagefault);
        assume (!ext_mti);
        assume (!ext_msi);
        assume (!ext_mei);
    end

endmodule
