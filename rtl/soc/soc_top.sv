// SoC top.  Wraps the core + SRAM + CLINT + MMIO decoder.
//
// Memory map:
//   0x0200_0000 .. 0x020F_FFFF  CLINT (msip / mtimecmp / mtime)
//   0x8000_0000 .. 0x8000_FFFF  SRAM (64 KiB, dual-port BRAM)
//   0xC000_0000 .. 0xC000_0FFF  AXI-Lite region (4 KiB sim BRAM; FPGA swaps
//                               this out for real AXI peripherals — UartLite,
//                               Timer, Intc — through a crossbar).
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

    // AXI4-Lite master port — peripheral crossbar lives outside the SoC core.
    // In sim this is tied to axil_bram_slave inside soc_tb_top; on FPGA it
    // fans out to UartLite / Timer / Intc through a Xilinx AXI crossbar.
    output logic        m_axil_awvalid,
    input  logic        m_axil_awready,
    output logic [31:0] m_axil_awaddr,
    output logic [2:0]  m_axil_awprot,
    output logic        m_axil_wvalid,
    input  logic        m_axil_wready,
    output logic [31:0] m_axil_wdata,
    output logic [3:0]  m_axil_wstrb,
    input  logic        m_axil_bvalid,
    output logic        m_axil_bready,
    input  logic [1:0]  m_axil_bresp,
    output logic        m_axil_arvalid,
    input  logic        m_axil_arready,
    output logic [31:0] m_axil_araddr,
    output logic [2:0]  m_axil_arprot,
    input  logic        m_axil_rvalid,
    output logic        m_axil_rready,
    input  logic [31:0] m_axil_rdata,
    input  logic [1:0]  m_axil_rresp,

    // External MEI — from an off-chip AXI Intc on FPGA, tied 0 in sim.
    input  logic        ext_mei,

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

    // ---------- interrupt inputs from CLINT ----------
    logic clint_mti, clint_msi;

    // FENCE.I → icache invalidate pulse. Only the pipeline core emits it; the
    // multicycle core doesn't pair with the icache in supported configs.
    logic icache_invalidate_w;

`ifdef USE_PIPELINE_CORE
    core_pipeline #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .rst(rst),

        .ifetch_req_valid(if_req_valid), .ifetch_req_addr(if_req_addr), .ifetch_req_ready(if_req_ready),
        .ifetch_rsp_valid(if_rsp_valid), .ifetch_rsp_data(if_rsp_data), .ifetch_rsp_fault(if_rsp_fault),
        .ifetch_rsp_ready(if_rsp_ready),

        .dmem_req_valid(dm_req_valid), .dmem_req_addr(dm_req_addr), .dmem_req_wen(dm_req_wen),
        .dmem_req_wdata(dm_req_wdata), .dmem_req_wmask(dm_req_wmask), .dmem_req_size(dm_req_size),
        .dmem_req_ready(dm_req_ready),
        .dmem_rsp_valid(dm_rsp_valid), .dmem_rsp_rdata(dm_rsp_rdata), .dmem_rsp_fault(dm_rsp_fault),
        .dmem_rsp_ready(dm_rsp_ready),

        .ext_mti(clint_mti), .ext_msi(clint_msi), .ext_mei(ext_mei),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause),

        .icache_invalidate(icache_invalidate_w)
    );
`else
    assign icache_invalidate_w = 1'b0;
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

        .ext_mti(clint_mti), .ext_msi(clint_msi), .ext_mei(ext_mei),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );
`endif

    // ---------- dmem address decode ----------
    // CLINT: addr[31:20] == 12'h020 → 1 MiB @ 0x0200_0000
    // SRAM:  addr[31:16] == 16'h8000 → port B
    // AXI:   addr[31:28] == 4'hC    → 256 MiB window @ 0xC000_0000
    // MMIO:  addr[31:16] == 16'hD058 → MMIO block
    wire dm_is_clint = (dm_req_addr[31:20] == 12'h020);
    wire dm_is_sram  = (dm_req_addr[31:16] == 16'h8000);
    wire dm_is_axi   = (dm_req_addr[31:28] == 4'hC);
    wire dm_is_mmio  = (dm_req_addr[31:16] == 16'hD058);

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

    logic        clint_req_valid, clint_req_ready;
    logic [31:0] clint_req_addr, clint_req_wdata;
    logic        clint_req_wen;
    logic [3:0]  clint_req_wmask;
    logic        clint_rsp_valid, clint_rsp_fault;
    logic [31:0] clint_rsp_rdata;

    logic        axi_req_valid, axi_req_ready;
    logic [31:0] axi_req_addr, axi_req_wdata;
    logic        axi_req_wen;
    logic [3:0]  axi_req_wmask;
    logic        axi_rsp_valid, axi_rsp_fault;
    logic [31:0] axi_rsp_rdata;

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

    assign clint_req_valid = dm_req_valid && dm_is_clint;
    assign clint_req_addr  = dm_req_addr;
    assign clint_req_wen   = dm_req_wen;
    assign clint_req_wdata = dm_req_wdata;
    assign clint_req_wmask = dm_req_wmask;

    assign axi_req_valid = dm_req_valid && dm_is_axi;
    assign axi_req_addr  = dm_req_addr;
    assign axi_req_wen   = dm_req_wen;
    assign axi_req_wdata = dm_req_wdata;
    assign axi_req_wmask = dm_req_wmask;

    assign dm_req_ready   = dm_is_sram  ? sram_b_req_ready
                          : dm_is_mmio  ? mmio_req_ready
                          : dm_is_clint ? clint_req_ready
                          : dm_is_axi   ? axi_req_ready
                          :               1'b1; // bad address: accept immediately, fault response
    assign dm_rsp_valid   = sram_b_rsp_valid | mmio_rsp_valid | clint_rsp_valid | axi_rsp_valid | dmem_bad_rsp_valid;
    assign dm_rsp_rdata   = sram_b_rsp_valid ? sram_b_rsp_rdata
                          : mmio_rsp_valid   ? mmio_rsp_rdata
                          : clint_rsp_valid  ? clint_rsp_rdata
                          : axi_rsp_valid    ? axi_rsp_rdata
                          :                    32'd0;
    assign dm_rsp_fault   = mmio_rsp_fault | clint_rsp_fault | axi_rsp_fault | dmem_bad_rsp_valid;

    // Bad-address path: latch a 1-cycle fault response (matches SRAM latency).
    logic dmem_bad_rsp_valid;
    always_ff @(posedge clk) begin
        if (rst) dmem_bad_rsp_valid <= 1'b0;
        else     dmem_bad_rsp_valid <= dm_req_valid && !dm_is_sram && !dm_is_mmio && !dm_is_clint && !dm_is_axi;
    end

    // ---------- I-cache (optional, between core IF and SRAM port A) ----------
    //
    // Enabled with `define USE_ICACHE. Drops in at the ifetch path only; the
    // core-facing side uses the same valid/ready protocol that previously
    // wired direct-to-SRAM, so this is transparent to the core.
    logic        sram_a_req_valid, sram_a_req_ready;
    logic [31:0] sram_a_req_addr;
    logic        sram_a_rsp_valid;
    logic [31:0] sram_a_rsp_rdata;

`ifdef USE_ICACHE
    icache #(
        .LINE_BYTES(64), .SETS(64), .WAYS(4)
    ) u_icache (
        .clk(clk), .rst(rst),

        .core_req_valid(if_req_valid), .core_req_addr(if_req_addr),
        .core_req_ready(if_req_ready),
        .core_rsp_valid(if_rsp_valid), .core_rsp_data(if_rsp_data),
        .core_rsp_fault(if_rsp_fault), .core_rsp_ready(if_rsp_ready),

        .mem_req_valid(sram_a_req_valid), .mem_req_addr(sram_a_req_addr),
        .mem_req_ready(sram_a_req_ready),
        .mem_rsp_valid(sram_a_rsp_valid), .mem_rsp_data(sram_a_rsp_rdata),
        .mem_rsp_fault(1'b0),

        .invalidate(icache_invalidate_w)
    );
`else
    // No icache: core IF port goes straight to SRAM port A.
    assign sram_a_req_valid = if_req_valid;
    assign sram_a_req_addr  = if_req_addr;
    assign if_req_ready     = sram_a_req_ready;
    assign if_rsp_valid     = sram_a_rsp_valid;
    assign if_rsp_data      = sram_a_rsp_rdata;
    assign if_rsp_fault     = 1'b0;
`endif

    // ---------- SRAM ----------
    sram_dp #(.WORDS(SRAM_WORDS), .INIT_FILE(SRAM_INIT_FILE)) u_sram (
        .clk(clk),
        .a_req_valid(sram_a_req_valid), .a_req_addr(sram_a_req_addr),
        .a_req_ready(sram_a_req_ready),
        .a_rsp_valid(sram_a_rsp_valid), .a_rsp_rdata(sram_a_rsp_rdata),

        .b_req_valid(sram_b_req_valid), .b_req_addr(sram_b_req_addr),
        .b_req_wen(sram_b_req_wen), .b_req_wmask(sram_b_req_wmask), .b_req_wdata(sram_b_req_wdata),
        .b_req_ready(sram_b_req_ready),
        .b_rsp_valid(sram_b_rsp_valid), .b_rsp_rdata(sram_b_rsp_rdata)
    );

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

    // ---------- CLINT ----------
    clint u_clint (
        .clk(clk), .rst(rst),
        .req_valid(clint_req_valid), .req_addr(clint_req_addr), .req_wen(clint_req_wen),
        .req_wdata(clint_req_wdata), .req_wmask(clint_req_wmask),
        .req_ready(clint_req_ready),
        .rsp_valid(clint_rsp_valid), .rsp_rdata(clint_rsp_rdata), .rsp_fault(clint_rsp_fault),
        .mti(clint_mti), .msi(clint_msi)
    );

    // ---------- AXI4-Lite master shim ----------
    // Master-side signals are ports of this module (wired to sim slave or real
    // peripheral crossbar above us).
    axi_lite_master u_axi_master (
        .clk(clk), .rst(rst),
        .req_valid(axi_req_valid), .req_addr(axi_req_addr), .req_wen(axi_req_wen),
        .req_wdata(axi_req_wdata), .req_wmask(axi_req_wmask),
        .req_ready(axi_req_ready),
        .rsp_valid(axi_rsp_valid), .rsp_rdata(axi_rsp_rdata), .rsp_fault(axi_rsp_fault),

        .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),
        .m_axil_awaddr(m_axil_awaddr),   .m_axil_awprot(m_axil_awprot),
        .m_axil_wvalid(m_axil_wvalid),   .m_axil_wready(m_axil_wready),
        .m_axil_wdata(m_axil_wdata),     .m_axil_wstrb(m_axil_wstrb),
        .m_axil_bvalid(m_axil_bvalid),   .m_axil_bready(m_axil_bready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_arvalid(m_axil_arvalid), .m_axil_arready(m_axil_arready),
        .m_axil_araddr(m_axil_araddr),   .m_axil_arprot(m_axil_arprot),
        .m_axil_rvalid(m_axil_rvalid),   .m_axil_rready(m_axil_rready),
        .m_axil_rdata(m_axil_rdata),     .m_axil_rresp(m_axil_rresp)
    );

endmodule
