// Stage 0/1 SoC top.  Wraps the core + SRAM + MMIO decoder.
//
// Memory map:
//   0x8000_0000 .. 0x8000_FFFF  SRAM (64 KiB, dual-port BRAM)
//   0xD058_0000 .. 0xD058_000F  MMIO (console / exit / status)
//
// On FPGA this module is extended with a real UART at the console tap; here in
// sim/Stage-1 we just expose the console byte stream and exit lines.

module soc_top #(
    parameter int          SRAM_WORDS = 16384,  // 64 KiB
    parameter logic [31:0] RESET_PC   = 32'h8000_0000,
    parameter              SRAM_INIT_FILE = ""
)(
    input  logic clk,
    input  logic rst,

    output logic        console_valid,
    output logic [7:0]  console_byte,
    input  logic        console_ready,   // back-pressure from an external UART (tie 1 in sim)
    output logic        exit_valid,
    output logic [31:0] exit_code,

    // commit trace pass-through for Verilator
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic        commit_rd_wen,
    output logic [4:0]  commit_rd_addr,
    output logic [31:0] commit_rd_data,
    output logic        commit_trap,
    output logic [31:0] commit_cause
);

    // ---------- core ↔ bus ----------
    logic        if_req_valid, if_req_ready;
    logic [31:0] if_req_addr;
    logic        if_rsp_valid, if_rsp_fault, if_rsp_ready;
    logic [31:0] if_rsp_data;

    logic        dm_req_valid, dm_req_ready;
    logic [31:0] dm_req_addr, dm_req_wdata;
    logic        dm_req_wen;
    logic [3:0]  dm_req_wmask;
    logic [1:0]  dm_req_size;
    logic        dm_rsp_valid, dm_rsp_fault, dm_rsp_ready;
    logic [31:0] dm_rsp_rdata;

    core_multicycle #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .rst(rst),

        .ifetch_req_valid(if_req_valid), .ifetch_req_addr(if_req_addr), .ifetch_req_ready(if_req_ready),
        .ifetch_rsp_valid(if_rsp_valid), .ifetch_rsp_data(if_rsp_data), .ifetch_rsp_fault(if_rsp_fault),
        .ifetch_rsp_ready(if_rsp_ready),

        .dmem_req_valid(dm_req_valid), .dmem_req_addr(dm_req_addr), .dmem_req_wen(dm_req_wen),
        .dmem_req_wdata(dm_req_wdata), .dmem_req_wmask(dm_req_wmask), .dmem_req_size(dm_req_size),
        .dmem_req_ready(dm_req_ready),
        .dmem_rsp_valid(dm_rsp_valid), .dmem_rsp_rdata(dm_rsp_rdata), .dmem_rsp_fault(dm_rsp_fault),
        .dmem_rsp_ready(dm_rsp_ready),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );

    // ---------- dmem address decode ----------
    // SRAM: addr[31:16] == 16'h8000 → port B
    // MMIO: addr[31:16] == 16'hD058 → MMIO block
    wire dm_is_sram = (dm_req_addr[31:16] == 16'h8000);
    wire dm_is_mmio = (dm_req_addr[31:16] == 16'hD058);

    logic        sram_b_req_valid;
    logic [31:0] sram_b_req_addr;
    logic        sram_b_req_wen;
    logic [3:0]  sram_b_req_wmask;
    logic [31:0] sram_b_req_wdata;
    logic        sram_b_req_ready;
    logic        sram_b_rsp_valid;
    logic [31:0] sram_b_rsp_rdata;

    logic        mmio_req_valid, mmio_req_ready;
    logic [31:0] mmio_req_addr, mmio_req_wdata;
    logic        mmio_req_wen;
    logic [3:0]  mmio_req_wmask;
    logic        mmio_rsp_valid, mmio_rsp_fault;
    logic [31:0] mmio_rsp_rdata;

    assign sram_b_req_valid = dm_req_valid && dm_is_sram;
    assign sram_b_req_addr  = dm_req_addr;
    assign sram_b_req_wen   = dm_req_wen;
    assign sram_b_req_wmask = dm_req_wmask;
    assign sram_b_req_wdata = dm_req_wdata;

    assign mmio_req_valid = dm_req_valid && dm_is_mmio;
    assign mmio_req_addr  = dm_req_addr;
    assign mmio_req_wen   = dm_req_wen;
    assign mmio_req_wdata = dm_req_wdata;
    assign mmio_req_wmask = dm_req_wmask;

    assign dm_req_ready   = dm_is_sram ? sram_b_req_ready
                          : dm_is_mmio ? mmio_req_ready
                          :              1'b1; // bad address: accept immediately, fault response
    assign dm_rsp_valid   = sram_b_rsp_valid | mmio_rsp_valid | dmem_bad_rsp_valid;
    assign dm_rsp_rdata   = sram_b_rsp_valid ? sram_b_rsp_rdata
                          : mmio_rsp_valid   ? mmio_rsp_rdata
                          :                    32'd0;
    assign dm_rsp_fault   = mmio_rsp_fault | dmem_bad_rsp_valid;

    // Bad-address path: latch a 1-cycle fault response (matches SRAM latency).
    logic dmem_bad_rsp_valid;
    always_ff @(posedge clk) begin
        if (rst) dmem_bad_rsp_valid <= 1'b0;
        else     dmem_bad_rsp_valid <= dm_req_valid && !dm_is_sram && !dm_is_mmio;
    end

    // ---------- SRAM ----------
    sram_dp #(.WORDS(SRAM_WORDS), .INIT_FILE(SRAM_INIT_FILE)) u_sram (
        .clk(clk),
        .a_req_valid(if_req_valid), .a_req_addr(if_req_addr),
        .a_req_ready(if_req_ready),
        .a_rsp_valid(if_rsp_valid), .a_rsp_rdata(if_rsp_data),

        .b_req_valid(sram_b_req_valid), .b_req_addr(sram_b_req_addr),
        .b_req_wen(sram_b_req_wen), .b_req_wmask(sram_b_req_wmask), .b_req_wdata(sram_b_req_wdata),
        .b_req_ready(sram_b_req_ready),
        .b_rsp_valid(sram_b_rsp_valid), .b_rsp_rdata(sram_b_rsp_rdata)
    );

    // ifetch cannot fault in Stage 0/1 (we only ever fetch from SRAM region).
    // If the PC ever lands outside, the access is simply undefined; we don't
    // propagate a fault in this revision.
    assign if_rsp_fault = 1'b0;

    // ---------- MMIO ----------
    mmio u_mmio (
        .clk(clk), .rst(rst),
        .req_valid(mmio_req_valid), .req_addr(mmio_req_addr), .req_wen(mmio_req_wen),
        .req_wdata(mmio_req_wdata), .req_wmask(mmio_req_wmask),
        .req_ready(mmio_req_ready),
        .rsp_valid(mmio_rsp_valid), .rsp_rdata(mmio_rsp_rdata), .rsp_fault(mmio_rsp_fault),
        .console_valid(console_valid), .console_byte(console_byte),
        .console_ready(console_ready),
        .exit_valid(exit_valid), .exit_code(exit_code)
    );

endmodule
