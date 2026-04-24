// Testbench wrapper for Verilator — brings up OpenSBI + Linux in simulation.
//
// Mirrors the FPGA memory map: 64 MiB of AXI-backed "DDR" at 0x4000_0000 and
// AXI-UartLite at 0xC000_0000. The CPU reset vector is 0x4000_0000 — the
// C++ harness preloads fw_jump / Image / DTB / initramfs directly into the
// DDR model via the ddr_dpi_write backdoor, skipping the BootROM handshake
// entirely (the BootROM's only job in silicon is to wait for JTAG to stage
// images, which we accomplish before the first clock tick here).

module soc_tb_linux (
    input  logic        clk,
    input  logic        rst,

    output logic        console_valid,
    output logic [7:0]  console_byte,
    output logic        exit_valid,
    output logic [31:0] exit_code,

    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic        commit_rd_wen,
    output logic [4:0]  commit_rd_addr,
    output logic [31:0] commit_rd_data,
    output logic        commit_trap,
    output logic [31:0] commit_cause,

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

    // ---------- AXI4 master out of soc_top ----------
    logic        m_axi_awvalid, m_axi_awready;
    logic [31:0] m_axi_awaddr;
    logic [3:0]  m_axi_awid;
    logic [7:0]  m_axi_awlen;
    logic [2:0]  m_axi_awsize;
    logic [1:0]  m_axi_awburst;
    logic        m_axi_awlock;
    logic [3:0]  m_axi_awcache;
    logic [2:0]  m_axi_awprot;
    logic [3:0]  m_axi_awqos;
    logic        m_axi_wvalid, m_axi_wready;
    logic [31:0] m_axi_wdata;
    logic [3:0]  m_axi_wstrb;
    logic        m_axi_wlast;
    logic        m_axi_bvalid, m_axi_bready;
    logic [3:0]  m_axi_bid;
    logic [1:0]  m_axi_bresp;
    logic        m_axi_arvalid, m_axi_arready;
    logic [31:0] m_axi_araddr;
    logic [3:0]  m_axi_arid;
    logic [7:0]  m_axi_arlen;
    logic [2:0]  m_axi_arsize;
    logic [1:0]  m_axi_arburst;
    logic        m_axi_arlock;
    logic [3:0]  m_axi_arcache;
    logic [2:0]  m_axi_arprot;
    logic [3:0]  m_axi_arqos;
    logic        m_axi_rvalid, m_axi_rready;
    logic [3:0]  m_axi_rid;
    logic [31:0] m_axi_rdata;
    logic [1:0]  m_axi_rresp;
    logic        m_axi_rlast;

    // Driven by axil_uartlite_sim's irq_o output (bottom of file). When CTRL.IE=1,
    // this is high, matching silicon's level-triggered IRQ on TX_EMPTY+IE.
    logic        uart_irq_sim;

    // Reset vector matches silicon: BootROM in SRAM polls the handshake word
    // in DDR and jumps to OpenSBI. Harness preloads SRAM + DDR + handshake
    // via DPI, then releases reset — exactly what JTAG-to-AXI does on FPGA.
    soc_top #(.RESET_PC(32'h8000_0000)) u_soc (
        .clk(clk), .rst(rst),
        .console_valid(console_valid), .console_byte(console_byte),
        .console_ready(1'b1),
        .exit_valid(exit_valid), .exit_code(exit_code),

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
        .m_axi_rresp(m_axi_rresp),     .m_axi_rlast(m_axi_rlast),

        .uart_irq_i(uart_irq_sim),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause),

        .tap_dm_req_fire(tap_dm_req_fire),
        .tap_dm_req_va(tap_dm_req_va),
        .tap_dm_req_pa(tap_dm_req_pa),
        .tap_dm_req_wen(tap_dm_req_wen),
        .tap_dm_req_wdata(tap_dm_req_wdata),
        .tap_dm_req_wmask(tap_dm_req_wmask),
        .tap_dm_req_size(tap_dm_req_size),
        .tap_dm_rsp_fire(tap_dm_rsp_fire),
        .tap_dm_rsp_rdata(tap_dm_rsp_rdata),
        .tap_dm_rsp_fault(tap_dm_rsp_fault),
        .tap_dm_rsp_pagefault(tap_dm_rsp_pagefault),
        .tap_priv_mode(tap_priv_mode)
    );

    // ---------- AXI4 router → DDR + UartLite ----------
    logic        s0_aw_v, s0_aw_r, s0_w_v, s0_w_r, s0_b_v, s0_b_r;
    logic [31:0] s0_aw_a, s0_w_d, s0_ar_a, s0_r_d;
    logic [2:0]  s0_aw_p, s0_ar_p;
    logic [3:0]  s0_w_s;
    logic [1:0]  s0_b_resp, s0_r_resp;
    logic        s0_ar_v, s0_ar_r, s0_r_v, s0_r_r;

    logic        s1_aw_v, s1_aw_r, s1_w_v, s1_w_r, s1_b_v, s1_b_r;
    logic [31:0] s1_aw_a, s1_w_d, s1_ar_a, s1_r_d;
    logic [2:0]  s1_aw_p, s1_ar_p;
    logic [3:0]  s1_w_s;
    logic [1:0]  s1_b_resp, s1_r_resp;
    logic        s1_ar_v, s1_ar_r, s1_r_v, s1_r_r;

    axi4_router_linux #(.ID_W(4)) u_xbar (
        .clk(clk), .rst(rst),

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
        .m_axi_rresp(m_axi_rresp),     .m_axi_rlast(m_axi_rlast),

        .s0_axil_awvalid(s0_aw_v), .s0_axil_awready(s0_aw_r),
        .s0_axil_awaddr(s0_aw_a),  .s0_axil_awprot(s0_aw_p),
        .s0_axil_wvalid(s0_w_v),   .s0_axil_wready(s0_w_r),
        .s0_axil_wdata(s0_w_d),    .s0_axil_wstrb(s0_w_s),
        .s0_axil_bvalid(s0_b_v),   .s0_axil_bready(s0_b_r),
        .s0_axil_bresp(s0_b_resp),
        .s0_axil_arvalid(s0_ar_v), .s0_axil_arready(s0_ar_r),
        .s0_axil_araddr(s0_ar_a),  .s0_axil_arprot(s0_ar_p),
        .s0_axil_rvalid(s0_r_v),   .s0_axil_rready(s0_r_r),
        .s0_axil_rdata(s0_r_d),    .s0_axil_rresp(s0_r_resp),

        .s1_axil_awvalid(s1_aw_v), .s1_axil_awready(s1_aw_r),
        .s1_axil_awaddr(s1_aw_a),  .s1_axil_awprot(s1_aw_p),
        .s1_axil_wvalid(s1_w_v),   .s1_axil_wready(s1_w_r),
        .s1_axil_wdata(s1_w_d),    .s1_axil_wstrb(s1_w_s),
        .s1_axil_bvalid(s1_b_v),   .s1_axil_bready(s1_b_r),
        .s1_axil_bresp(s1_b_resp),
        .s1_axil_arvalid(s1_ar_v), .s1_axil_arready(s1_ar_r),
        .s1_axil_araddr(s1_ar_a),  .s1_axil_arprot(s1_ar_p),
        .s1_axil_rvalid(s1_r_v),   .s1_axil_rready(s1_r_r),
        .s1_axil_rdata(s1_r_d),    .s1_axil_rresp(s1_r_resp)
    );

    // ---------- slave 0: DDR @ 0x4000_0000 (128 MiB) ----------
    // Address into the slave is the full 32-bit bus address; the slave
    // strips high bits implicitly via its internal WORDS-sized index.
    // WORDS=32M gives a 128 MiB aperture, matching the DT's memory node.
    axil_bram_big #(.WORDS(32 * 1024 * 1024)) u_ddr (
        .clk(clk), .rst(rst),
        .s_axil_awvalid(s0_aw_v),  .s_axil_awready(s0_aw_r),
        .s_axil_awaddr(s0_aw_a),   .s_axil_awprot(s0_aw_p),
        .s_axil_wvalid(s0_w_v),    .s_axil_wready(s0_w_r),
        .s_axil_wdata(s0_w_d),     .s_axil_wstrb(s0_w_s),
        .s_axil_bvalid(s0_b_v),    .s_axil_bready(s0_b_r),
        .s_axil_bresp(s0_b_resp),
        .s_axil_arvalid(s0_ar_v),  .s_axil_arready(s0_ar_r),
        .s_axil_araddr(s0_ar_a),   .s_axil_arprot(s0_ar_p),
        .s_axil_rvalid(s0_r_v),    .s_axil_rready(s0_r_r),
        .s_axil_rdata(s0_r_d),     .s_axil_rresp(s0_r_resp)
    );

    // ---------- slave 1: UartLite @ 0xC000_0000 ----------
    axil_uartlite_sim u_ul (
        .clk(clk), .rst(rst),
        .s_axil_awvalid(s1_aw_v),  .s_axil_awready(s1_aw_r),
        .s_axil_awaddr(s1_aw_a),   .s_axil_awprot(s1_aw_p),
        .s_axil_wvalid(s1_w_v),    .s_axil_wready(s1_w_r),
        .s_axil_wdata(s1_w_d),     .s_axil_wstrb(s1_w_s),
        .s_axil_bvalid(s1_b_v),    .s_axil_bready(s1_b_r),
        .s_axil_bresp(s1_b_resp),
        .s_axil_arvalid(s1_ar_v),  .s_axil_arready(s1_ar_r),
        .s_axil_araddr(s1_ar_a),   .s_axil_arprot(s1_ar_p),
        .s_axil_rvalid(s1_r_v),    .s_axil_rready(s1_r_r),
        .s_axil_rdata(s1_r_d),     .s_axil_rresp(s1_r_resp),
        .irq_o(uart_irq_sim)
    );

endmodule
