// SoC top.  Wraps the core + SRAM + CLINT + PLIC + MMIO decoder.
//
// Memory map:
//   0x0200_0000 .. 0x020F_FFFF  CLINT (msip / mtimecmp / mtime)
//   0x0C00_0000 .. 0x0CFF_FFFF  PLIC  (SiFive layout, 2 contexts: M + S hart0)
//   0x4000_0000 .. 0x47FF_FFFF  DDR via AXI master (FPGA MIG; sim has no slave)
//   0x8000_0000 .. 0x8000_FFFF  SRAM (64 KiB, dual-port BRAM)
//   0xC000_0000 .. 0xC000_0FFF  AXI-Lite region (4 KiB sim BRAM; FPGA swaps
//                               this out for real AXI peripherals — UartLite,
//                               Timer, Intc — through a crossbar).
//   0xD058_0000 .. 0xD058_000F  MMIO (console / exit / status)
//
// On FPGA this module is extended with a real UART at the console tap; here in
// sim/Stage-1 we just expose the console byte stream and exit lines.
//
// Interrupts:
//   - CLINT drives ext_mti / ext_msi internally.
//   - PLIC sources[1] = uart_irq_i (external, tied 0 in sim for now).
//     PLIC irq_o[0] → core ext_mei  (context 0 = M-mode hart0)
//     PLIC irq_o[1] → core ext_sei  (context 1 = S-mode hart0)

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

    // UART-lite IRQ source. Wired to PLIC source 1 on FPGA; tied 0 in sim.
    input  logic        uart_irq_i,

    // commit trace pass-through for Verilator
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic        commit_rd_wen,
    output logic [4:0]  commit_rd_addr,
    output logic [31:0] commit_rd_data,
    output logic        commit_trap,
    output logic [31:0] commit_cause,

    // dmem-bus tap (post-MMU). Per-cycle observation of issued LD/ST/AMO ops
    // for sim diff between pipeline and multicycle: matches VA→PA, wdata,
    // wmask, size at issue; rsp side carries rdata/fault.
    output logic        tap_dm_req_fire,
    output logic [31:0] tap_dm_req_va,
    output logic [31:0] tap_dm_req_pa,
    output logic        tap_dm_req_wen,
    output logic [31:0] tap_dm_req_wdata,
    output logic [3:0]  tap_dm_req_wmask,
    output logic [1:0]  tap_dm_req_size,
    output logic        tap_dm_rsp_fire,
    output logic [31:0] tap_dm_rsp_rdata,
    output logic        tap_dm_rsp_fault,
    output logic        tap_dm_rsp_pagefault,
    output logic [1:0]  tap_priv_mode
);

    assign tap_dm_req_fire     = dm_req_valid     && dm_req_ready;
    assign tap_dm_req_va       = core_dm_req_addr;
    assign tap_dm_req_pa       = dm_req_addr;
    assign tap_dm_req_wen      = dm_req_wen;
    assign tap_dm_req_wdata    = dm_req_wdata;
    assign tap_dm_req_wmask    = dm_req_wmask;
    assign tap_dm_req_size     = dm_req_size;
    assign tap_dm_rsp_fire     = dm_rsp_valid     && dm_rsp_ready;
    assign tap_dm_rsp_rdata    = dm_rsp_rdata;
    assign tap_dm_rsp_fault    = dm_rsp_fault;
    assign tap_dm_rsp_pagefault = core_dm_rsp_pagefault;
    assign tap_priv_mode         = mmu_priv_w;

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

    // ---------- Dmem req pipeline stage (soc_clk timing closure) ----------
    // Breaks the long combinational path mem_alu_y_q → TLB-lookup →
    // dm_xlate_pa_q/CE inside MMU (WNS was -0.574 ns at 50 MHz). Registers the
    // core-side req here; MMU's internal logic now drives from a local FF.
    // Handshake: ready when the register is empty OR its downstream accepted
    // this cycle, so back-to-back txns still flow at 1/cycle when MMU is
    // ready. Response path (rdata/valid/fault) stays direct, not pipelined.
    logic        mmu_dm_req_valid, mmu_dm_req_ready;
    logic [31:0] mmu_dm_req_addr, mmu_dm_req_wdata;
    logic        mmu_dm_req_wen;
    logic [3:0]  mmu_dm_req_wmask;
    logic [1:0]  mmu_dm_req_size;

    logic        dm_pipe_q_valid;
    logic [31:0] dm_pipe_q_addr, dm_pipe_q_wdata;
    logic        dm_pipe_q_wen;
    logic [3:0]  dm_pipe_q_wmask;
    logic [1:0]  dm_pipe_q_size;

    wire dm_pipe_up_fire = core_dm_req_valid && core_dm_req_ready;
    wire dm_pipe_dn_fire = mmu_dm_req_valid  && mmu_dm_req_ready;

    assign core_dm_req_ready = !dm_pipe_q_valid || mmu_dm_req_ready;
    assign mmu_dm_req_valid  = dm_pipe_q_valid;
    assign mmu_dm_req_addr   = dm_pipe_q_addr;
    assign mmu_dm_req_wen    = dm_pipe_q_wen;
    assign mmu_dm_req_wdata  = dm_pipe_q_wdata;
    assign mmu_dm_req_wmask  = dm_pipe_q_wmask;
    assign mmu_dm_req_size   = dm_pipe_q_size;

    always_ff @(posedge clk) begin
        if (rst) begin
            dm_pipe_q_valid <= 1'b0;
        end else begin
            if (dm_pipe_up_fire) begin
                dm_pipe_q_valid <= 1'b1;
                dm_pipe_q_addr  <= core_dm_req_addr;
                dm_pipe_q_wen   <= core_dm_req_wen;
                dm_pipe_q_wdata <= core_dm_req_wdata;
                dm_pipe_q_wmask <= core_dm_req_wmask;
                dm_pipe_q_size  <= core_dm_req_size;
            end else if (dm_pipe_dn_fire) begin
                dm_pipe_q_valid <= 1'b0;
            end
        end
    end

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

    // ---------- interrupt outputs from PLIC ----------
    // PLIC has 2 contexts: [0] = hart 0 M-mode, [1] = hart 0 S-mode.
    localparam int PLIC_NUM_SOURCES = 4;
    localparam int PLIC_NUM_CTX     = 2;
    logic [PLIC_NUM_CTX-1:0]     plic_irq;
    logic [PLIC_NUM_SOURCES-1:0] plic_sources;
    wire  ext_mei = plic_irq[0];
    wire  ext_sei = plic_irq[1];

    // Source 0 reserved per spec. Source 1 = UartLite IRQ. Rest tied 0 for now.
    always_comb begin
        plic_sources       = '0;
        plic_sources[1]    = uart_irq_i;
    end

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
        .ext_sei(ext_sei),
        .mtime(clint_mtime),

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
        .ext_sei(ext_sei),
        .mtime(clint_mtime),

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

        .dm_core_req_valid(mmu_dm_req_valid), .dm_core_req_addr(mmu_dm_req_addr),
        .dm_core_req_wen(mmu_dm_req_wen),     .dm_core_req_wdata(mmu_dm_req_wdata),
        .dm_core_req_wmask(mmu_dm_req_wmask), .dm_core_req_size(mmu_dm_req_size),
        .dm_core_req_ready(mmu_dm_req_ready),
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
    // PLIC:  addr[31:24] ==  8'h0C → 16 MiB @ 0x0C00_0000
    // SRAM:  addr[31:16] == 16'h8000 → port B
    // AXI:   addr[31:28] == 4'h4 (DDR via MIG @ 0x4000_0000/128 MiB)
    //     or addr[31:28] == 4'hC (UART-lite via xbar @ 0xC000_0000/4 KiB).
    //     The external axi_crossbar does the finer-grain decode + DECERR.
    // MMIO:  addr[31:16] == 16'hD058 → MMIO block
    wire dm_is_clint = (dm_req_addr[31:20] == 12'h020);
    wire dm_is_plic  = (dm_req_addr[31:24] == 8'h0C);
    wire dm_is_sram  = (dm_req_addr[31:16] == 16'h8000);
    wire dm_is_axi   = (dm_req_addr[31:28] == 4'h4) || (dm_req_addr[31:28] == 4'hC);
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

    logic        plic_req_valid, plic_req_ready;
    logic [31:0] plic_req_addr, plic_req_wdata;
    logic        plic_req_wen;
    logic [3:0]  plic_req_wmask;
    logic        plic_rsp_valid, plic_rsp_fault;
    logic [31:0] plic_rsp_rdata;

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

    assign plic_req_valid = dm_req_valid && dm_is_plic;
    assign plic_req_addr  = dm_req_addr;
    assign plic_req_wen   = dm_req_wen;
    assign plic_req_wdata = dm_req_wdata;
    assign plic_req_wmask = dm_req_wmask;

    assign axi_req_valid = dm_req_valid && dm_is_axi;
    assign axi_req_addr  = dm_req_addr;
    assign axi_req_wen   = dm_req_wen;
    assign axi_req_wdata = dm_req_wdata;
    assign axi_req_wmask = dm_req_wmask;

    assign dm_req_ready   = dm_is_sram  ? dm_sram_req_ready
                          : dm_is_mmio  ? mmio_req_ready
                          : dm_is_clint ? clint_req_ready
                          : dm_is_plic  ? plic_req_ready
                          : dm_is_axi   ? axi_req_ready
                          :               1'b1; // bad address: accept immediately, fault response
    assign dm_rsp_valid   = dm_sram_rsp_valid | mmio_rsp_valid | clint_rsp_valid | plic_rsp_valid | axi_rsp_valid | dmem_bad_rsp_valid;
    assign dm_rsp_rdata   = dm_sram_rsp_valid ? dm_sram_rsp_rdata
                          : mmio_rsp_valid    ? mmio_rsp_rdata
                          : clint_rsp_valid   ? clint_rsp_rdata
                          : plic_rsp_valid    ? plic_rsp_rdata
                          : axi_rsp_valid     ? axi_rsp_rdata
                          :                     32'd0;
    assign dm_rsp_fault   = dm_sram_rsp_fault | mmio_rsp_fault | clint_rsp_fault | plic_rsp_fault | axi_rsp_fault | dmem_bad_rsp_valid;

    // Bad-address path: latch a 1-cycle fault response (matches SRAM latency).
    logic dmem_bad_rsp_valid;
    always_ff @(posedge clk) begin
        if (rst) dmem_bad_rsp_valid <= 1'b0;
        else     dmem_bad_rsp_valid <= dm_req_valid && !dm_is_sram && !dm_is_mmio && !dm_is_clint && !dm_is_plic && !dm_is_axi;
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

    // ---------- PTW address decode: SRAM vs AXI (DDR) ----------
    // The MMU walks page tables from whatever PPN the OS loaded into satp.
    // For Linux that's a DDR-resident trampoline/swapper PGD (~0x42xxxxxx),
    // so PTW must be able to read from AXI; the SRAM-only path only serves
    // the bare-metal tests whose page tables live in the 0x8000_xxxx SRAM.
    wire ptw_is_sram = (ptw_mem_req_addr[31:16] == 16'h8000);
    wire ptw_is_axi  = (ptw_mem_req_addr[31:28] == 4'h4);
    // Anything else: synthesize a 1-cycle fault response.
    wire ptw_is_bad  = ptw_mem_req_valid && !ptw_is_sram && !ptw_is_axi;

    // PTW-to-SRAM sub-path (only when ptw_is_sram).
    logic        ptw_sram_req_valid_w;
    logic [31:0] ptw_sram_req_addr_w;
    logic        ptw_sram_req_ready_w;
    logic        ptw_sram_rsp_valid_w;
    logic [31:0] ptw_sram_rsp_rdata_w;

    assign ptw_sram_req_valid_w = ptw_mem_req_valid && ptw_is_sram;
    assign ptw_sram_req_addr_w  = ptw_mem_req_addr;

    // PTW-to-AXI sub-path (only when ptw_is_axi) — driven into axi4_master by
    // the 3-way arbiter below alongside ifetch and dmem.
    logic        ptw_axi_req_valid_w;
    logic [31:0] ptw_axi_req_addr_w;
    logic        ptw_axi_req_ready_w;
    logic        ptw_axi_rsp_valid_w;
    logic [31:0] ptw_axi_rsp_rdata_w;
    logic        ptw_axi_rsp_fault_w;

    assign ptw_axi_req_valid_w = ptw_mem_req_valid && ptw_is_axi;
    assign ptw_axi_req_addr_w  = ptw_mem_req_addr;

    // Bad-address PTW: 1-cycle zeros+fault response.
    logic        ptw_bad_rsp_valid_q;
    always_ff @(posedge clk) begin
        if (rst) ptw_bad_rsp_valid_q <= 1'b0;
        else     ptw_bad_rsp_valid_q <= ptw_is_bad;
    end

    // Merge PTW sub-paths back onto the MMU-facing ptw_mem port.
    assign ptw_mem_req_ready = ptw_is_sram ? ptw_sram_req_ready_w
                             : ptw_is_axi  ? ptw_axi_req_ready_w
                             :               1'b1;
    assign ptw_mem_rsp_valid = ptw_sram_rsp_valid_w | ptw_axi_rsp_valid_w | ptw_bad_rsp_valid_q;
    assign ptw_mem_rsp_rdata = ptw_sram_rsp_valid_w ? ptw_sram_rsp_rdata_w
                             : ptw_axi_rsp_valid_w  ? ptw_axi_rsp_rdata_w
                             :                        32'd0;
    assign ptw_mem_rsp_fault = ptw_axi_rsp_fault_w | ptw_bad_rsp_valid_q;

    // ---------- SRAM port B arbiter: PTW-SRAM (priority) vs D-cache / dmem_sram ----------
    // PTW accesses are single-beat reads; both masters are single-outstanding
    // with a 1-cycle rsp from sram_dp. The mux picks PTW whenever it asserts;
    // D-cache's req_ready drops during that cycle. The req→rsp pipeline is
    // tracked with `last_was_ptw_q` so rsp_valid routes back to the correct
    // master the next cycle.
    wire arb_pick_ptw = ptw_sram_req_valid_w;

    assign sram_b_req_valid  = arb_pick_ptw ? ptw_sram_req_valid_w : dc_sram_req_valid;
    assign sram_b_req_addr   = arb_pick_ptw ? ptw_sram_req_addr_w  : dc_sram_req_addr;
    assign sram_b_req_wen    = arb_pick_ptw ? 1'b0                 : dc_sram_req_wen;
    assign sram_b_req_wmask  = arb_pick_ptw ? 4'b1111              : dc_sram_req_wmask;
    assign sram_b_req_wdata  = arb_pick_ptw ? 32'd0                : dc_sram_req_wdata;

    assign ptw_sram_req_ready_w = sram_b_req_ready;
    assign dc_sram_req_ready    = arb_pick_ptw ? 1'b0 : sram_b_req_ready;

    logic last_was_ptw_q;
    always_ff @(posedge clk) begin
        if (rst)
            last_was_ptw_q <= 1'b0;
        else if (sram_b_req_valid && sram_b_req_ready)
            last_was_ptw_q <= arb_pick_ptw;
    end

    assign ptw_sram_rsp_valid_w = sram_b_rsp_valid &&  last_was_ptw_q;
    assign ptw_sram_rsp_rdata_w = sram_b_rsp_rdata;
    assign dc_sram_rsp_valid    = sram_b_rsp_valid && !last_was_ptw_q;
    assign dc_sram_rsp_rdata    = sram_b_rsp_rdata;

    // ---------- Ifetch routing (Stage 7e: SRAM + DDR) ----------
    // Ifetch targets:
    //   - SRAM region  (addr[31:16] == 16'h8000): through optional I-cache,
    //                    backed by SRAM port A.
    //   - DDR via AXI  (addr[31:28] == 4'h4):     through the AXI master, on
    //                    the same axi4_master shared with dmem (see arbiter
    //                    lower down). No ifetch cache for DDR in this stage —
    //                    every fetch hits the bus. Perf is fine for OpenSBI/
    //                    kernel bring-up; revisit with an AXI-backed icache
    //                    if a workload needs it.
    //   - anything else: immediate fault (1-cycle latency to match SRAM).
    //
    // The core issues one ifetch at a time (single-outstanding), so a
    // per-request address decode is safe; we don't need to track in-flight
    // state between path changes.
    wire if_is_sram = (if_req_addr[31:16] == 16'h8000);
    wire if_is_axi  = (if_req_addr[31:28] == 4'h4);
    wire if_is_bad  = if_req_valid && !if_is_sram && !if_is_axi;

    // SRAM ifetch sub-path (possibly through I-cache).
    logic        sram_a_req_valid, sram_a_req_ready;
    logic [31:0] sram_a_req_addr;
    logic        sram_a_rsp_valid;
    logic [31:0] sram_a_rsp_rdata;

    logic        if_sram_req_valid, if_sram_req_ready;
    logic [31:0] if_sram_req_addr;
    logic        if_sram_rsp_valid, if_sram_rsp_fault;
    logic [31:0] if_sram_rsp_data;

    assign if_sram_req_valid = if_req_valid && if_is_sram;
    assign if_sram_req_addr  = if_req_addr;

`ifdef USE_ICACHE
    icache #(
        .LINE_BYTES(64), .SETS(64), .WAYS(4)
    ) u_icache (
        .clk(clk), .rst(rst),

        .core_req_valid(if_sram_req_valid), .core_req_addr(if_sram_req_addr),
        .core_req_ready(if_sram_req_ready),
        .core_rsp_valid(if_sram_rsp_valid), .core_rsp_data(if_sram_rsp_data),
        .core_rsp_fault(if_sram_rsp_fault), .core_rsp_ready(if_rsp_ready),

        .mem_req_valid(sram_a_req_valid), .mem_req_addr(sram_a_req_addr),
        .mem_req_ready(sram_a_req_ready),
        .mem_rsp_valid(sram_a_rsp_valid), .mem_rsp_data(sram_a_rsp_rdata),
        .mem_rsp_fault(1'b0),

        .invalidate(icache_invalidate_w)
    );
`else
    assign sram_a_req_valid  = if_sram_req_valid;
    assign sram_a_req_addr   = if_sram_req_addr;
    assign if_sram_req_ready = sram_a_req_ready;
    assign if_sram_rsp_valid = sram_a_rsp_valid;
    assign if_sram_rsp_data  = sram_a_rsp_rdata;
    assign if_sram_rsp_fault = 1'b0;
`endif

    // DDR ifetch sub-path — driven into the axi4_master via the arb below.
    logic        if_axi_req_valid, if_axi_req_ready;
    logic [31:0] if_axi_req_addr;
    logic        if_axi_rsp_valid, if_axi_rsp_fault;
    logic [31:0] if_axi_rsp_rdata;

    assign if_axi_req_valid = if_req_valid && if_is_axi;
    assign if_axi_req_addr  = if_req_addr;

    // Bad-address ifetch: pulse a 1-cycle fault response per bad request.
    //
    // We can't just latch `if_bad_rsp_valid_q <= if_is_bad` every cycle: the
    // core holds req_valid high in S_FETCH, and on a trap-commit cycle its
    // ifetch_req_addr is still the bad PC for one more cycle while pc_q
    // updates to mtvec. That produces a second is_bad=1 cycle, which would
    // then latch a spurious bad_q=1 in the *next* cycle when pc_q has already
    // moved to the valid mtvec, causing the core to accept it as a second
    // fault response and trap again at mtvec — an infinite double-fault loop.
    // Fix: only pulse bad_q for one cycle following each bad req, gated by
    // !bad_q so a steady is_bad stream yields alternating 1/0 responses (the
    // core drops req_valid after the first fault anyway).
    logic if_bad_rsp_valid_q;
    always_ff @(posedge clk) begin
        if (rst) if_bad_rsp_valid_q <= 1'b0;
        else     if_bad_rsp_valid_q <= if_is_bad && !if_bad_rsp_valid_q;
    end

    // Merge the three sub-paths back onto the MMU-facing ifetch channel.
    assign if_req_ready = if_is_sram ? if_sram_req_ready
                        : if_is_axi  ? if_axi_req_ready
                        :              1'b1;
    assign if_rsp_valid = if_sram_rsp_valid | if_axi_rsp_valid | if_bad_rsp_valid_q;
    assign if_rsp_data  = if_sram_rsp_valid ? if_sram_rsp_data
                        : if_axi_rsp_valid  ? if_axi_rsp_rdata
                        :                     32'd0;
    assign if_rsp_fault = if_sram_rsp_fault | if_axi_rsp_fault | if_bad_rsp_valid_q;

`ifdef VERILATOR
    // Fault-only (~0 events on clean boot), always-on real-error indicator.
    always_ff @(posedge clk) begin
        if (!rst && if_rsp_valid && if_rsp_fault) begin
            $display("[SOC-IF-FAULT] t=%0t addr=%08x sram_f=%0d axi_v=%0d axi_f=%0d bad_q=%0d inflight=%0d am_rsp_v=%0d am_rsp_f=%0d",
                $time, if_req_addr, if_sram_rsp_fault, if_axi_rsp_valid, if_axi_rsp_fault,
                if_bad_rsp_valid_q, inflight_client_q, am_rsp_valid, am_rsp_fault);
        end
    end
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
    logic [63:0] clint_mtime;
    clint u_clint (
        .clk(clk), .rst(rst),
        .req_valid(clint_req_valid), .req_addr(clint_req_addr), .req_wen(clint_req_wen),
        .req_wdata(clint_req_wdata), .req_wmask(clint_req_wmask),
        .req_ready(clint_req_ready),
        .rsp_valid(clint_rsp_valid), .rsp_rdata(clint_rsp_rdata), .rsp_fault(clint_rsp_fault),
        .mti(clint_mti), .msi(clint_msi),
        .mtime_out(clint_mtime)
    );

    // ---------- PLIC (Stage 7d) ----------
    plic #(
        .NUM_SOURCES(PLIC_NUM_SOURCES),
        .NUM_CTX    (PLIC_NUM_CTX)
    ) u_plic (
        .clk(clk), .rst(rst),
        .req_valid(plic_req_valid), .req_addr(plic_req_addr), .req_wen(plic_req_wen),
        .req_wdata(plic_req_wdata), .req_wmask(plic_req_wmask),
        .req_ready(plic_req_ready),
        .rsp_valid(plic_rsp_valid), .rsp_rdata(plic_rsp_rdata), .rsp_fault(plic_rsp_fault),
        .sources_i(plic_sources),
        .irq_o    (plic_irq)
    );

    // ---------- AXI arbiter: {PTW, ifetch, dmem} → single axi4_master ----------
    // Three clients share the single-outstanding axi4_master. PTW gets top
    // priority because the core is stalled on its translation result and
    // can't release the ifetch/dmem valids until the walk completes — so
    // making PTW wait behind them just extends the same stall. Between
    // ifetch and dmem we keep the original round-robin.
    localparam int AM_CLI_PTW = 0;
    localparam int AM_CLI_IF  = 1;
    localparam int AM_CLI_DM  = 2;

    logic        am_req_valid, am_req_ready;
    logic [31:0] am_req_addr;
    logic        am_req_wen;
    logic [31:0] am_req_wdata;
    logic [3:0]  am_req_wmask;
    logic        am_rsp_valid, am_rsp_fault;
    logic [31:0] am_rsp_rdata;

    logic arb_last_grant_if_q;  // 1 = ifetch got the last grant (for RR fairness between IF/DM)
    wire  arb_pick_ptw_ax = ptw_axi_req_valid_w;
    wire  arb_pick_if     = !arb_pick_ptw_ax
                          && if_axi_req_valid
                          && (!axi_req_valid || !arb_last_grant_if_q);
    wire  arb_pick_dm     = !arb_pick_ptw_ax && !arb_pick_if && axi_req_valid;

    assign am_req_valid = ptw_axi_req_valid_w | if_axi_req_valid | axi_req_valid;
    assign am_req_addr  = arb_pick_ptw_ax ? ptw_axi_req_addr_w
                        : arb_pick_if     ? if_axi_req_addr
                        :                   axi_req_addr;
    assign am_req_wen   = arb_pick_ptw_ax ? 1'b0
                        : arb_pick_if     ? 1'b0
                        :                   axi_req_wen;
    assign am_req_wdata = arb_pick_ptw_ax ? 32'd0
                        : arb_pick_if     ? 32'd0
                        :                   axi_req_wdata;
    assign am_req_wmask = arb_pick_ptw_ax ? 4'b0000
                        : arb_pick_if     ? 4'b0000
                        :                   axi_req_wmask;

    assign ptw_axi_req_ready_w = arb_pick_ptw_ax && am_req_ready;
    assign if_axi_req_ready    = arb_pick_if     && am_req_ready;
    assign axi_req_ready       = arb_pick_dm     && am_req_ready;

    // Latch the winning client on each req handshake so we can route the rsp.
    logic [1:0] inflight_client_q;  // 0=PTW 1=IF 2=DM
    always_ff @(posedge clk) begin
        if (rst) begin
            inflight_client_q   <= 2'd0;
            arb_last_grant_if_q <= 1'b0;
        end else if (am_req_valid && am_req_ready) begin
            inflight_client_q <= arb_pick_ptw_ax ? 2'd0
                               : arb_pick_if     ? 2'd1
                               :                   2'd2;
            if (arb_pick_if || arb_pick_dm)
                arb_last_grant_if_q <= arb_pick_if;
        end
    end

    wire inflight_is_ptw_ax = (inflight_client_q == 2'd0);
    wire inflight_is_if     = (inflight_client_q == 2'd1);
    wire inflight_is_dm     = (inflight_client_q == 2'd2);

    assign ptw_axi_rsp_valid_w = am_rsp_valid && inflight_is_ptw_ax;
    assign ptw_axi_rsp_rdata_w = am_rsp_rdata;
    assign ptw_axi_rsp_fault_w = am_rsp_fault && inflight_is_ptw_ax;
    assign if_axi_rsp_valid    = am_rsp_valid && inflight_is_if;
    assign if_axi_rsp_rdata    = am_rsp_rdata;
    assign if_axi_rsp_fault    = am_rsp_fault && inflight_is_if;
    assign axi_rsp_valid       = am_rsp_valid && inflight_is_dm;
    assign axi_rsp_rdata       = am_rsp_rdata;
    assign axi_rsp_fault       = am_rsp_fault && inflight_is_dm;

    // ---------- AXI4-full master shim ----------
    // Master-side signals are ports of this module (wired to the sim router or
    // a real Vivado axi_crossbar above us).
    axi4_master #(.ID_W(4)) u_axi_master (
        .clk(clk), .rst(rst),
        .req_valid(am_req_valid), .req_addr(am_req_addr), .req_wen(am_req_wen),
        .req_wdata(am_req_wdata), .req_wmask(am_req_wmask),
        .req_ready(am_req_ready),
        .rsp_valid(am_rsp_valid), .rsp_rdata(am_rsp_rdata), .rsp_fault(am_rsp_fault),

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
