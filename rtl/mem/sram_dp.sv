// Dual-port byte-maskable SRAM.
// Port A: read-only (for instruction fetch).
// Port B: read/write (for data memory).
//
// Synthesizes to BRAM on 7-series; Verilator models it as a packed array.
// DPI backdoor is exported for the C++ testbench to load ELF images pre-reset
// and poll the tohost symbol.

module sram_dp #(
    parameter int WORDS      = 16384,  // default 64 KB (16K * 4B)
    parameter     INIT_FILE  = ""       // optional $readmemh file
)(
    input  logic clk,

    // ---- Port A: read-only ----
    input  logic        a_req_valid,
    input  logic [31:0] a_req_addr,     // byte address, word-aligned (low 2 bits ignored)
    output logic        a_req_ready,
    output logic        a_rsp_valid,
    output logic [31:0] a_rsp_rdata,

    // ---- Port B: R/W ----
    input  logic        b_req_valid,
    input  logic [31:0] b_req_addr,
    input  logic        b_req_wen,
    input  logic [3:0]  b_req_wmask,
    input  logic [31:0] b_req_wdata,
    output logic        b_req_ready,
    output logic        b_rsp_valid,
    output logic [31:0] b_rsp_rdata
);
    localparam int ADDR_BITS = $clog2(WORDS);

    logic [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // ---- Port A (read-only, 1-cycle latency) ----
    assign a_req_ready = 1'b1;
    logic [ADDR_BITS-1:0] a_word_addr;
    assign a_word_addr = a_req_addr[ADDR_BITS+1:2];

    always_ff @(posedge clk) begin
        a_rsp_valid <= a_req_valid;
        if (a_req_valid) begin
            a_rsp_rdata <= mem[a_word_addr];
        end
    end

    // ---- Port B (R/W, 1-cycle latency, byte-masked write) ----
    assign b_req_ready = 1'b1;
    logic [ADDR_BITS-1:0] b_word_addr;
    assign b_word_addr = b_req_addr[ADDR_BITS+1:2];

    always_ff @(posedge clk) begin
        // Ack every accepted request (both reads and writes).  The core waits
        // for rsp_valid in both cases; stores' rdata is simply ignored.
        b_rsp_valid <= b_req_valid;
        if (b_req_valid) begin
            if (b_req_wen) begin
                if (b_req_wmask[0]) mem[b_word_addr][ 7: 0] <= b_req_wdata[ 7: 0];
                if (b_req_wmask[1]) mem[b_word_addr][15: 8] <= b_req_wdata[15: 8];
                if (b_req_wmask[2]) mem[b_word_addr][23:16] <= b_req_wdata[23:16];
                if (b_req_wmask[3]) mem[b_word_addr][31:24] <= b_req_wdata[31:24];
            end else begin
                b_rsp_rdata <= mem[b_word_addr];
            end
        end
    end

    // ---- DPI backdoor for the C++ testbench ----
    // These are pure SV functions — Verilator exposes them to C++ via DPI-C.
    // Word-addressed (not byte-addressed) for simplicity.
`ifdef VERILATOR
    export "DPI-C" function sram_dpi_write;
    export "DPI-C" function sram_dpi_read;

    function void sram_dpi_write(input int word_addr, input int data);
        if (word_addr >= 0 && word_addr < WORDS) begin
            mem[word_addr] = data;
        end
    endfunction

    function int sram_dpi_read(input int word_addr);
        if (word_addr >= 0 && word_addr < WORDS) begin
            return mem[word_addr];
        end else begin
            return 32'hDEADBEEF;
        end
    endfunction
`endif

endmodule
