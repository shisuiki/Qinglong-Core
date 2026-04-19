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

    // AXI4-full master port — peripheral crossbar lives outside the SoC core.
    // In sim this fans into axi4_router_1x2 + behavioural Lite slaves; on FPGA
    // this connects to a Vivado axi_crossbar IP, which then talks to MIG /
    // axi_uartlite / PLIC / etc. via the standard protocol converters.
    //
    // The shim is single-beat / single-outstanding today (Stage 7a). When
    // 7c brings up the cached burst master we extend axi4_master to issue
    // bursts; the bus type stays the same.
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_awaddr,
    output logic [3:0]  m_axi_awid,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awlock,
    output logic [3:0]  m_axi_awcache,
    output logic [2:0]  m_axi_awprot,
    output logic [3:0]  m_axi_awqos,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    input  logic [3:0]  m_axi_bid,
    input  logic [1:0]  m_axi_bresp,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    output logic [31:0] m_axi_araddr,
    output logic [3:0]  m_axi_arid,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arlock,
    output logic [3:0]  m_axi_arcache,
    output logic [2:0]  m_axi_arprot,
    output logic [3:0]  m_axi_arqos,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    input  logic [3:0]  m_axi_rid,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,

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

    // ---------- core ↔ MMU (pre-translation) ----------
    logic        core_if_req_valid, core_if_req_ready;
    logic [31:0] core_if_req_addr;
    logic        core_if_rsp_valid, core_if_rsp_fault, core_if_rsp_ready;
    logic [31:0] core_if_rsp_data;

    logic        core_dm_req_valid, core_dm_req_ready;
    logic [31:0] core_dm_req_addr, core_dm_req_wdata;
    logic        core_dm_req_wen;
    logic [3:0]  core_dm_req_wmask;
    logic [1:0]  core_dm_req_size;
    logic        core_dm_rsp_valid, core_dm_rsp_fault, core_dm_rsp_ready;
    logic [31:0] core_dm_rsp_rdata;

    // ---------- MMU ↔ bus (post-translation, physical addresses) ----------
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

    // ---------- CSR state for the MMU ----------
    logic [31:0] mmu_satp_w;
    logic [1:0]  mmu_priv_w, mmu_mpp_w;
    logic        mmu_mprv_w, mmu_sum_w, mmu_mxr_w;

    // PMP static config exported by CSR, consumed by MMU's PMP checker.
    logic [15:0][7:0]  mmu_pmp_cfg_w;
    logic [15:0][31:0] mmu_pmp_addr_w;

    // Page-fault outputs from the MMU (Stage 6C-2d). Mutually exclusive with
    // the access-fault path.
    logic core_if_rsp_pagefault, core_dm_rsp_pagefault;

    // ---------- interrupt inputs from CLINT ----------
    logic clint_mti, clint_msi;

    // FENCE.I → icache invalidate pulse. Only the pipeline core emits it; the
    // multicycle core doesn't pair with the icache in supported configs.
    // The D-cache is write-through so memory is always current — no D-side
    // flush is needed to pair with FENCE.I.
    logic icache_invalidate_w;

    // SFENCE.VMA → MMU TLB flush pulse (Stage 6C-2c).
    logic        mmu_sfence_vma_w;
    logic        mmu_sfence_rs1_nz_w;
    logic [31:0] mmu_sfence_rs1_va_w;
    logic        mmu_sfence_rs2_nz_w;
    logic [8:0]  mmu_sfence_rs2_asid_w;

`ifdef USE_PIPELINE_CORE
    core_pipeline #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .rst(rst),

        .ifetch_req_valid(core_if_req_valid), .ifetch_req_addr(core_if_req_addr), .ifetch_req_ready(core_if_req_ready),
        .ifetch_rsp_valid(core_if_rsp_valid), .ifetch_rsp_data(core_if_rsp_data), .ifetch_rsp_fault(core_if_rsp_fault),
        .ifetch_rsp_pagefault(core_if_rsp_pagefault),
        .ifetch_rsp_ready(core_if_rsp_ready),

        .dmem_req_valid(core_dm_req_valid), .dmem_req_addr(core_dm_req_addr), .dmem_req_wen(core_dm_req_wen),
        .dmem_req_wdata(core_dm_req_wdata), .dmem_req_wmask(core_dm_req_wmask), .dmem_req_size(core_dm_req_size),
        .dmem_req_ready(core_dm_req_ready),
        .dmem_rsp_valid(core_dm_rsp_valid), .dmem_rsp_rdata(core_dm_rsp_rdata), .dmem_rsp_fault(core_dm_rsp_fault),
        .dmem_rsp_pagefault(core_dm_rsp_pagefault),
        .dmem_rsp_ready(core_dm_rsp_ready),

        .ext_mti(clint_mti), .ext_msi(clint_msi), .ext_mei(ext_mei),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause),

        .icache_invalidate(icache_invalidate_w),
        .mmu_sfence_vma(mmu_sfence_vma_w),
        .mmu_sfence_rs1_nz(mmu_sfence_rs1_nz_w),
        .mmu_sfence_rs1_va(mmu_sfence_rs1_va_w),
        .mmu_sfence_rs2_nz(mmu_sfence_rs2_nz_w),
        .mmu_sfence_rs2_asid(mmu_sfence_rs2_asid_w),

        .mmu_satp(mmu_satp_w), .mmu_priv(mmu_priv_w),
        .mmu_mprv(mmu_mprv_w), .mmu_mpp(mmu_mpp_w),
        .mmu_sum(mmu_sum_w),   .mmu_mxr(mmu_mxr_w),
        .mmu_pmp_cfg(mmu_pmp_cfg_w), .mmu_pmp_addr(mmu_pmp_addr_w)
    );
`else
    assign icache_invalidate_w = 1'b0;
    core_multicycle #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .rst(rst),

        .ifetch_req_valid(core_if_req_valid), .ifetch_req_addr(core_if_req_addr), .ifetch_req_ready(core_if_req_ready),
        .ifetch_rsp_valid(core_if_rsp_valid), .ifetch_rsp_data(core_if_rsp_data), .ifetch_rsp_fault(core_if_rsp_fault),
        .ifetch_rsp_pagefault(core_if_rsp_pagefault),
        .ifetch_rsp_ready(core_if_rsp_ready),

        .dmem_req_valid(core_dm_req_valid), .dmem_req_addr(core_dm_req_addr), .dmem_req_wen(core_dm_req_wen),
        .dmem_req_wdata(core_dm_req_wdata), .dmem_req_wmask(core_dm_req_wmask), .dmem_req_size(core_dm_req_size),
        .dmem_req_ready(core_dm_req_ready),
        .dmem_rsp_valid(core_dm_rsp_valid), .dmem_rsp_rdata(core_dm_rsp_rdata), .dmem_rsp_fault(core_dm_rsp_fault),
        .dmem_rsp_pagefault(core_dm_rsp_pagefault),
        .dmem_rsp_ready(core_dm_rsp_ready),

        .ext_mti(clint_mti), .ext_msi(clint_msi), .ext_mei(ext_mei),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause),

        .mmu_satp(mmu_satp_w), .mmu_priv(mmu_priv_w),
        .mmu_mprv(mmu_mprv_w), .mmu_mpp(mmu_mpp_w),
        .mmu_sum(mmu_sum_w),   .mmu_mxr(mmu_mxr_w),
        .mmu_pmp_cfg(mmu_pmp_cfg_w), .mmu_pmp_addr(mmu_pmp_addr_w),
        .mmu_sfence_vma(mmu_sfence_vma_w),
        .mmu_sfence_rs1_nz(mmu_sfence_rs1_nz_w),
        .mmu_sfence_rs1_va(mmu_sfence_rs1_va_w),
        .mmu_sfence_rs2_nz(mmu_sfence_rs2_nz_w),
        .mmu_sfence_rs2_asid(mmu_sfence_rs2_asid_w)
    );
`endif

    // ---------- PTW memory port (arbitrated onto SRAM port B below) ----------
    logic        ptw_mem_req_valid, ptw_mem_req_ready;
    logic [31:0] ptw_mem_req_addr;
    logic        ptw_mem_rsp_valid, ptw_mem_rsp_fault;
    logic [31:0] ptw_mem_rsp_rdata;

    // ---------- MMU (Stage 6C-2c: SV32 PTW + per-side fully-assoc TLB) ----------
    mmu u_mmu (
        .clk(clk), .rst(rst),
        .satp_i(mmu_satp_w), .priv_i(mmu_priv_w),
        .mprv_i(mmu_mprv_w), .mpp_i(mmu_mpp_w),
        .sum_i(mmu_sum_w),   .mxr_i(mmu_mxr_w),
        .pmp_cfg_i(mmu_pmp_cfg_w), .pmp_addr_i(mmu_pmp_addr_w),
        .sfence_vma_i(mmu_sfence_vma_w),
        .sfence_rs1_nz_i(mmu_sfence_rs1_nz_w),
        .sfence_rs1_va_i(mmu_sfence_rs1_va_w),
        .sfence_rs2_nz_i(mmu_sfence_rs2_nz_w),
        .sfence_rs2_asid_i(mmu_sfence_rs2_asid_w),

        .if_core_req_valid(core_if_req_valid), .if_core_req_addr(core_if_req_addr), .if_core_req_ready(core_if_req_ready),
        .if_core_rsp_valid(core_if_rsp_valid), .if_core_rsp_data(core_if_rsp_data), .if_core_rsp_fault(core_if_rsp_fault),
        .if_core_rsp_pagefault(core_if_rsp_pagefault),
        .if_core_rsp_ready(core_if_rsp_ready),

        .if_ds_req_valid(if_req_valid), .if_ds_req_addr(if_req_addr), .if_ds_req_ready(if_req_ready),
        .if_ds_rsp_valid(if_rsp_valid), .if_ds_rsp_data(if_rsp_data), .if_ds_rsp_fault(if_rsp_fault),
        .if_ds_rsp_ready(if_rsp_ready),

        .dm_core_req_valid(core_dm_req_valid), .dm_core_req_addr(core_dm_req_addr),
        .dm_core_req_wen(core_dm_req_wen),     .dm_core_req_wdata(core_dm_req_wdata),
        .dm_core_req_wmask(core_dm_req_wmask), .dm_core_req_size(core_dm_req_size),
        .dm_core_req_ready(core_dm_req_ready),
        .dm_core_rsp_valid(core_dm_rsp_valid), .dm_core_rsp_rdata(core_dm_rsp_rdata),
        .dm_core_rsp_fault(core_dm_rsp_fault), .dm_core_rsp_pagefault(core_dm_rsp_pagefault),
        .dm_core_rsp_ready(core_dm_rsp_ready),

        .dm_ds_req_valid(dm_req_valid), .dm_ds_req_addr(dm_req_addr),
        .dm_ds_req_wen(dm_req_wen),     .dm_ds_req_wdata(dm_req_wdata),
        .dm_ds_req_wmask(dm_req_wmask), .dm_ds_req_size(dm_req_size),
        .dm_ds_req_ready(dm_req_ready),
        .dm_ds_rsp_valid(dm_rsp_valid), .dm_ds_rsp_rdata(dm_rsp_rdata),
        .dm_ds_rsp_fault(dm_rsp_fault), .dm_ds_rsp_ready(dm_rsp_ready),

        .ptw_req_valid(ptw_mem_req_valid), .ptw_req_addr(ptw_mem_req_addr),
        .ptw_req_ready(ptw_mem_req_ready),
        .ptw_rsp_valid(ptw_mem_rsp_valid), .ptw_rsp_rdata(ptw_mem_rsp_rdata),
        .ptw_rsp_fault(ptw_mem_rsp_fault)
    );

    // ---------- dmem address decode ----------
    // CLINT: addr[31:20] == 12'h020 → 1 MiB @ 0x0200_0000
    // SRAM:  addr[31:16] == 16'h8000 → port B
    // AXI:   addr[31:28] == 4'hC    → 256 MiB window @ 0xC000_0000
    // MMIO:  addr[31:16] == 16'hD058 → MMIO block
    wire dm_is_clint = (dm_req_addr[31:20] == 12'h020);
    wire dm_is_sram  = (dm_req_addr[31:16] == 16'h8000);
    wire dm_is_axi   = (dm_req_addr[31:28] == 4'hC);
    wire dm_is_mmio  = (dm_req_addr[31:16] == 16'hD058);

    // Dmem-side signals for the SRAM region. Under USE_DCACHE they terminate
    // at the D-cache's core side; otherwise they drive SRAM port B directly.
    logic        dm_sram_req_valid;
    logic [31:0] dm_sram_req_addr;
    logic        dm_sram_req_wen;
    logic [3:0]  dm_sram_req_wmask;
    logic [31:0] dm_sram_req_wdata;
    logic        dm_sram_req_ready;
    logic        dm_sram_rsp_valid;
    logic [31:0] dm_sram_rsp_rdata;
    logic        dm_sram_rsp_fault;

    // SRAM port B connections (downstream of the optional D-cache).
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

    assign dm_sram_req_valid = dm_req_valid && dm_is_sram;
    assign dm_sram_req_addr  = dm_req_addr;
    assign dm_sram_req_wen   = dm_req_wen;
    assign dm_sram_req_wmask = dm_req_wmask;
    assign dm_sram_req_wdata = dm_req_wdata;

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

    assign dm_req_ready   = dm_is_sram  ? dm_sram_req_ready
                          : dm_is_mmio  ? mmio_req_ready
                          : dm_is_clint ? clint_req_ready
                          : dm_is_axi   ? axi_req_ready
                          :               1'b1; // bad address: accept immediately, fault response
    assign dm_rsp_valid   = dm_sram_rsp_valid | mmio_rsp_valid | clint_rsp_valid | axi_rsp_valid | dmem_bad_rsp_valid;
    assign dm_rsp_rdata   = dm_sram_rsp_valid ? dm_sram_rsp_rdata
                          : mmio_rsp_valid    ? mmio_rsp_rdata
                          : clint_rsp_valid   ? clint_rsp_rdata
                          : axi_rsp_valid     ? axi_rsp_rdata
                          :                     32'd0;
    assign dm_rsp_fault   = dm_sram_rsp_fault | mmio_rsp_fault | clint_rsp_fault | axi_rsp_fault | dmem_bad_rsp_valid;

    // Bad-address path: latch a 1-cycle fault response (matches SRAM latency).
    logic dmem_bad_rsp_valid;
    always_ff @(posedge clk) begin
        if (rst) dmem_bad_rsp_valid <= 1'b0;
        else     dmem_bad_rsp_valid <= dm_req_valid && !dm_is_sram && !dm_is_mmio && !dm_is_clint && !dm_is_axi;
    end

    // ---------- D-cache (optional, between DMEM SRAM region and port B) ----------
    //
    // Enabled with `define USE_DCACHE. Only the SRAM region goes through the
    // cache; MMIO / CLINT / AXI remain uncached bypass paths. The D-cache
    // (or the direct SRAM passthrough) now shares SRAM port B with the MMU's
    // PTW through a priority arbiter defined below.
    logic        dc_sram_req_valid, dc_sram_req_ready;
    logic [31:0] dc_sram_req_addr, dc_sram_req_wdata;
    logic        dc_sram_req_wen;
    logic [3:0]  dc_sram_req_wmask;
    logic        dc_sram_rsp_valid;
    logic [31:0] dc_sram_rsp_rdata;

`ifdef USE_DCACHE
    dcache #(
        .LINE_BYTES(64), .SETS(64), .WAYS(4)
    ) u_dcache (
        .clk(clk), .rst(rst),

        .core_req_valid(dm_sram_req_valid), .core_req_addr(dm_sram_req_addr),
        .core_req_wen(dm_sram_req_wen),     .core_req_wdata(dm_sram_req_wdata),
        .core_req_wmask(dm_sram_req_wmask), .core_req_ready(dm_sram_req_ready),
        .core_rsp_valid(dm_sram_rsp_valid), .core_rsp_rdata(dm_sram_rsp_rdata),
        .core_rsp_fault(dm_sram_rsp_fault),

        .mem_req_valid(dc_sram_req_valid), .mem_req_addr(dc_sram_req_addr),
        .mem_req_wen(dc_sram_req_wen),     .mem_req_wmask(dc_sram_req_wmask),
        .mem_req_wdata(dc_sram_req_wdata), .mem_req_ready(dc_sram_req_ready),
        .mem_rsp_valid(dc_sram_rsp_valid), .mem_rsp_rdata(dc_sram_rsp_rdata)
    );
`else
    assign dc_sram_req_valid = dm_sram_req_valid;
    assign dc_sram_req_addr  = dm_sram_req_addr;
    assign dc_sram_req_wen   = dm_sram_req_wen;
    assign dc_sram_req_wmask = dm_sram_req_wmask;
    assign dc_sram_req_wdata = dm_sram_req_wdata;
    assign dm_sram_req_ready = dc_sram_req_ready;
    assign dm_sram_rsp_valid = dc_sram_rsp_valid;
    assign dm_sram_rsp_rdata = dc_sram_rsp_rdata;
    assign dm_sram_rsp_fault = 1'b0;
`endif

    // ---------- SRAM port B arbiter: PTW (priority) vs D-cache / dmem_sram ----------
    // PTW accesses are single-beat reads; both masters are single-outstanding
    // with a 1-cycle rsp from sram_dp. The mux picks PTW whenever it asserts;
    // D-cache's req_ready drops during that cycle. The req→rsp pipeline is
    // tracked with `last_was_ptw_q` so rsp_valid routes back to the correct
    // master the next cycle.
    wire arb_pick_ptw = ptw_mem_req_valid;

    assign sram_b_req_valid  = arb_pick_ptw ? ptw_mem_req_valid : dc_sram_req_valid;
    assign sram_b_req_addr   = arb_pick_ptw ? ptw_mem_req_addr  : dc_sram_req_addr;
    assign sram_b_req_wen    = arb_pick_ptw ? 1'b0              : dc_sram_req_wen;
    assign sram_b_req_wmask  = arb_pick_ptw ? 4'b1111           : dc_sram_req_wmask;
    assign sram_b_req_wdata  = arb_pick_ptw ? 32'd0             : dc_sram_req_wdata;

    assign ptw_mem_req_ready = sram_b_req_ready;
    assign dc_sram_req_ready = arb_pick_ptw ? 1'b0 : sram_b_req_ready;

    logic last_was_ptw_q;
    always_ff @(posedge clk) begin
        if (rst)
            last_was_ptw_q <= 1'b0;
        else if (sram_b_req_valid && sram_b_req_ready)
            last_was_ptw_q <= arb_pick_ptw;
    end

    assign ptw_mem_rsp_valid = sram_b_rsp_valid &&  last_was_ptw_q;
    assign ptw_mem_rsp_rdata = sram_b_rsp_rdata;
    assign ptw_mem_rsp_fault = 1'b0;
    assign dc_sram_rsp_valid = sram_b_rsp_valid && !last_was_ptw_q;
    assign dc_sram_rsp_rdata = sram_b_rsp_rdata;

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

    // ---------- AXI4-full master shim ----------
    // Master-side signals are ports of this module (wired to the sim router or
    // a real Vivado axi_crossbar above us).
    axi4_master #(.ID_W(4)) u_axi_master (
        .clk(clk), .rst(rst),
        .req_valid(axi_req_valid), .req_addr(axi_req_addr), .req_wen(axi_req_wen),
        .req_wdata(axi_req_wdata), .req_wmask(axi_req_wmask),
        .req_ready(axi_req_ready),
        .rsp_valid(axi_rsp_valid), .rsp_rdata(axi_rsp_rdata), .rsp_fault(axi_rsp_fault),

        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_awaddr(m_axi_awaddr),   .m_axi_awid(m_axi_awid),
        .m_axi_awlen(m_axi_awlen),     .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_wvalid(m_axi_wvalid),   .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata),     .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid),   .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid),         .m_axi_bresp(m_axi_bresp),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_araddr(m_axi_araddr),   .m_axi_arid(m_axi_arid),
        .m_axi_arlen(m_axi_arlen),     .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_rvalid(m_axi_rvalid),   .m_axi_rready(m_axi_rready),
        .m_axi_rid(m_axi_rid),         .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),     .m_axi_rlast(m_axi_rlast)
    );

endmodule
