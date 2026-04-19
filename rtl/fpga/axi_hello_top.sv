// -----------------------------------------------------------------------------
// axi_hello_top.sv
// RealDigital Urbana (xc7s50csga324-1) Stage 7b AXI bringup top.
//
// Topology:
//   soc_top.m_axi (AXI4-full, 4-bit ID, 32-bit, single-beat)
//      └─ axi_crossbar_0 (1×2, AXI4-full → AXI4-full)
//            ├─ M00 → MIG7 DDR3L @ 0x4000_0000 / 128 MB        (AXI4-full)
//            └─ M01 → axi_protocol_converter_0
//                        └─ axi_uartlite_0 @ 0xC000_0000 / 4 KB  (AXI4-Lite)
//
// The Vivado axi_crossbar IP only takes one PROTOCOL setting for the whole
// instance, so the protocol downgrade for the UartLite branch lives in a
// downstream axi_protocol_converter rather than in the crossbar itself. The
// crossbar M-side also drops AXI IDs (single SI, in-order responses), so
// MIG/protocol_converter ID inputs are tied off to 0.
//
// Clocking:
//   N15  (100 MHz LVCMOS33)  -> alive_clk  (heartbeat LED only — proves the
//                                          FPGA is configured even if MIG
//                                          fails to calibrate).
//   C1/B1 (100 MHz LVDS_25)  -> MIG -> ui_clk (≈83 MHz @ 666 MT/s) -> SoC.
//
// Reset:
//   BTN0 (J2, active-low) -> sync to alive_clk -> MIG.sys_rst (active low).
//   MIG drives ui_clk_sync_rst back; SoC reset is held until both that
//   release and init_calib_complete asserts.
//
// LEDs:
//   [0] heartbeat (alive_clk)
//   [1] mmcm_locked
//   [2] rst_n (BTN0, raw)
//   [3] !soc_rst (high once MIG calibrated and SoC out of reset)
//   [4] commit_valid stretched
//   [5] exit_valid
//   [6] console_seen
//   [7] init_calib_complete
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module axi_hello_top #(
    parameter SRAM_INIT_FILE = ""
)(
    input  wire        clk,            // 100 MHz LVCMOS33 (N15) — heartbeat only
    input  wire        rst_n,          // BTN0, active-low (J2)

    // MIG7 system clock (dedicated diff pair @ C1/B1, LVDS_25)
    input  wire        sys_clk_p,
    input  wire        sys_clk_n,

    // DDR3L (pin LOC + IOSTANDARD constraints come from the MIG IP XDC)
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_p,
    inout  wire [1:0]  ddr3_dqs_n,
    output wire [12:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    // UART (host-perspective names — see board memory)
    output wire        uart_tx_pin,    // A16 → host RX
    input  wire        uart_rx_pin,    // B16 ← host TX

    output wire [7:0]  led
);

    // ---------- Alive heartbeat (independent of MIG) ----------
    wire alive_clk;
    BUFG u_bufg_alive (.I(clk), .O(alive_clk));

    reg [25:0] alive_hb = 26'd0;
    always_ff @(posedge alive_clk) alive_hb <= alive_hb + 26'd1;

    (* ASYNC_REG = "TRUE" *) reg rst_n_meta  = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg rst_n_alive = 1'b0;
    always_ff @(posedge alive_clk) begin
        rst_n_meta  <= rst_n;
        rst_n_alive <= rst_n_meta;
    end

    // ---------- MIG7 DDR3L controller ----------
    wire ui_clk;
    wire ui_clk_sync_rst;
    wire mmcm_locked;
    wire init_calib_complete;

    // MIG AXI4 slave port (27-bit addr — 1Gbit / 128 MB total)
    wire [3:0]  mig_awid    = 4'd0;
    wire [26:0] mig_awaddr;
    wire [7:0]  mig_awlen;
    wire [2:0]  mig_awsize;
    wire [1:0]  mig_awburst;
    wire [0:0]  mig_awlock;
    wire [3:0]  mig_awcache;
    wire [2:0]  mig_awprot;
    wire [3:0]  mig_awqos;
    wire        mig_awvalid;
    wire        mig_awready;
    wire [31:0] mig_wdata;
    wire [3:0]  mig_wstrb;
    wire        mig_wlast;
    wire        mig_wvalid;
    wire        mig_wready;
    wire [3:0]  mig_bid;
    wire [1:0]  mig_bresp;
    wire        mig_bvalid;
    wire        mig_bready;
    wire [3:0]  mig_arid    = 4'd0;
    wire [26:0] mig_araddr;
    wire [7:0]  mig_arlen;
    wire [2:0]  mig_arsize;
    wire [1:0]  mig_arburst;
    wire [0:0]  mig_arlock;
    wire [3:0]  mig_arcache;
    wire [2:0]  mig_arprot;
    wire [3:0]  mig_arqos;
    wire        mig_arvalid;
    wire        mig_arready;
    wire [3:0]  mig_rid;
    wire [31:0] mig_rdata;
    wire [1:0]  mig_rresp;
    wire        mig_rlast;
    wire        mig_rvalid;
    wire        mig_rready;

    mig_ddr3_0 u_mig (
        // DDR3 physical
        .ddr3_dq      (ddr3_dq),
        .ddr3_dqs_p   (ddr3_dqs_p),
        .ddr3_dqs_n   (ddr3_dqs_n),
        .ddr3_addr    (ddr3_addr),
        .ddr3_ba      (ddr3_ba),
        .ddr3_ras_n   (ddr3_ras_n),
        .ddr3_cas_n   (ddr3_cas_n),
        .ddr3_we_n    (ddr3_we_n),
        .ddr3_reset_n (ddr3_reset_n),
        .ddr3_ck_p    (ddr3_ck_p),
        .ddr3_ck_n    (ddr3_ck_n),
        .ddr3_cke     (ddr3_cke),
        .ddr3_dm      (ddr3_dm),
        .ddr3_odt     (ddr3_odt),

        // System
        .sys_clk_p    (sys_clk_p),
        .sys_clk_n    (sys_clk_n),
        .sys_rst      (rst_n_alive),       // active-low (matches PRJ)

        // User clock + status
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_clk_sync_rst),
        .mmcm_locked        (mmcm_locked),
        .init_calib_complete(init_calib_complete),
        .app_sr_req         (1'b0),
        .app_ref_req        (1'b0),
        .app_zq_req         (1'b0),
        .app_sr_active      (),
        .app_ref_ack        (),
        .app_zq_ack         (),
        .device_temp_i      (12'd0),
        .device_temp        (),
        // calib_tap_* ports exist in MIG's full wrapper but are absent from
        // the synth stub — they're a debug/override interface that's only
        // pulled in for special builds. Leave them disconnected.

        // AXI4 slave
        .aresetn      (~ui_clk_sync_rst),

        .s_axi_awid   (mig_awid),
        .s_axi_awaddr (mig_awaddr),
        .s_axi_awlen  (mig_awlen),
        .s_axi_awsize (mig_awsize),
        .s_axi_awburst(mig_awburst),
        .s_axi_awlock (mig_awlock),
        .s_axi_awcache(mig_awcache),
        .s_axi_awprot (mig_awprot),
        .s_axi_awqos  (mig_awqos),
        .s_axi_awvalid(mig_awvalid),
        .s_axi_awready(mig_awready),

        .s_axi_wdata  (mig_wdata),
        .s_axi_wstrb  (mig_wstrb),
        .s_axi_wlast  (mig_wlast),
        .s_axi_wvalid (mig_wvalid),
        .s_axi_wready (mig_wready),

        .s_axi_bid    (mig_bid),
        .s_axi_bresp  (mig_bresp),
        .s_axi_bvalid (mig_bvalid),
        .s_axi_bready (mig_bready),

        .s_axi_arid   (mig_arid),
        .s_axi_araddr (mig_araddr),
        .s_axi_arlen  (mig_arlen),
        .s_axi_arsize (mig_arsize),
        .s_axi_arburst(mig_arburst),
        .s_axi_arlock (mig_arlock),
        .s_axi_arcache(mig_arcache),
        .s_axi_arprot (mig_arprot),
        .s_axi_arqos  (mig_arqos),
        .s_axi_arvalid(mig_arvalid),
        .s_axi_arready(mig_arready),

        .s_axi_rid    (mig_rid),
        .s_axi_rdata  (mig_rdata),
        .s_axi_rresp  (mig_rresp),
        .s_axi_rlast  (mig_rlast),
        .s_axi_rvalid (mig_rvalid),
        .s_axi_rready (mig_rready)
    );

    // ---------- SoC reset (held until MIG calibrates) ----------
    wire soc_rst = ui_clk_sync_rst | ~init_calib_complete;

    // ---------- AXI4 master out of soc_top ----------
    wire        m_axi_awvalid, m_axi_awready;
    wire [31:0] m_axi_awaddr;
    wire [3:0]  m_axi_awid;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awlock;
    wire [3:0]  m_axi_awcache;
    wire [2:0]  m_axi_awprot;
    wire [3:0]  m_axi_awqos;
    wire        m_axi_wvalid, m_axi_wready;
    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_bvalid, m_axi_bready;
    wire [3:0]  m_axi_bid;
    wire [1:0]  m_axi_bresp;
    wire        m_axi_arvalid, m_axi_arready;
    wire [31:0] m_axi_araddr;
    wire [3:0]  m_axi_arid;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arlock;
    wire [3:0]  m_axi_arcache;
    wire [2:0]  m_axi_arprot;
    wire [3:0]  m_axi_arqos;
    wire        m_axi_rvalid, m_axi_rready;
    wire [3:0]  m_axi_rid;
    wire [31:0] m_axi_rdata;
    wire [1:0]  m_axi_rresp;
    wire        m_axi_rlast;

    wire        console_valid;
    wire [7:0]  console_byte;
    wire        exit_valid;
    wire [31:0] exit_code;

    wire        commit_valid;
    wire [31:0] commit_pc, commit_insn, commit_rd_data, commit_cause;
    wire        commit_rd_wen, commit_trap;
    wire [4:0]  commit_rd_addr;

    soc_top #(
        .SRAM_WORDS     (16384),
        .RESET_PC       (32'h8000_0000),
        .SRAM_INIT_FILE (SRAM_INIT_FILE)
    ) u_soc (
        .clk(ui_clk), .rst(soc_rst),

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

        .ext_mei(1'b0),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr),
        .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );

    // ---------- AXI4 1×2 crossbar (M00 = MIG, M01 = uart-via-protoconv) ----------
    // Crossbar M-side concatenation puts M00 at low bits, M01 at high bits.
    // Crossbar drops AXI IDs (NUM_SI=1, in-order responses).
    wire [31:0] mig_awaddr_full;       // 32 bits from xbar; MIG only takes [26:0]
    wire [31:0] mig_araddr_full;
    wire [3:0]  mig_awregion_unused;   // MIG has no awregion port
    wire [3:0]  mig_arregion_unused;

    // M01 (protocol_converter slave-side) signals
    wire        pc_awvalid, pc_awready;
    wire [31:0] pc_awaddr;
    wire [7:0]  pc_awlen;
    wire [2:0]  pc_awsize;
    wire [1:0]  pc_awburst;
    wire        pc_awlock;
    wire [3:0]  pc_awcache;
    wire [2:0]  pc_awprot;
    wire [3:0]  pc_awregion;
    wire [3:0]  pc_awqos;
    wire        pc_wvalid,  pc_wready;
    wire [31:0] pc_wdata;
    wire [3:0]  pc_wstrb;
    wire        pc_wlast;
    wire        pc_bvalid,  pc_bready;
    wire [1:0]  pc_bresp;
    wire        pc_arvalid, pc_arready;
    wire [31:0] pc_araddr;
    wire [7:0]  pc_arlen;
    wire [2:0]  pc_arsize;
    wire [1:0]  pc_arburst;
    wire        pc_arlock;
    wire [3:0]  pc_arcache;
    wire [2:0]  pc_arprot;
    wire [3:0]  pc_arregion;
    wire [3:0]  pc_arqos;
    wire        pc_rvalid,  pc_rready;
    wire [31:0] pc_rdata;
    wire [1:0]  pc_rresp;
    wire        pc_rlast;

    assign mig_awaddr = mig_awaddr_full[26:0];
    assign mig_araddr = mig_araddr_full[26:0];

    axi_crossbar_0 u_xbar (
        .aclk    (ui_clk),
        .aresetn (~soc_rst),

        // S00 — from soc_top
        .s_axi_awid    (m_axi_awid),
        .s_axi_awaddr  (m_axi_awaddr),
        .s_axi_awlen   (m_axi_awlen),
        .s_axi_awsize  (m_axi_awsize),
        .s_axi_awburst (m_axi_awburst),
        .s_axi_awlock  (m_axi_awlock),
        .s_axi_awcache (m_axi_awcache),
        .s_axi_awprot  (m_axi_awprot),
        .s_axi_awqos   (m_axi_awqos),
        .s_axi_awvalid (m_axi_awvalid),
        .s_axi_awready (m_axi_awready),

        .s_axi_wdata   (m_axi_wdata),
        .s_axi_wstrb   (m_axi_wstrb),
        .s_axi_wlast   (m_axi_wlast),
        .s_axi_wvalid  (m_axi_wvalid),
        .s_axi_wready  (m_axi_wready),

        .s_axi_bid     (m_axi_bid),
        .s_axi_bresp   (m_axi_bresp),
        .s_axi_bvalid  (m_axi_bvalid),
        .s_axi_bready  (m_axi_bready),

        .s_axi_arid    (m_axi_arid),
        .s_axi_araddr  (m_axi_araddr),
        .s_axi_arlen   (m_axi_arlen),
        .s_axi_arsize  (m_axi_arsize),
        .s_axi_arburst (m_axi_arburst),
        .s_axi_arlock  (m_axi_arlock),
        .s_axi_arcache (m_axi_arcache),
        .s_axi_arprot  (m_axi_arprot),
        .s_axi_arqos   (m_axi_arqos),
        .s_axi_arvalid (m_axi_arvalid),
        .s_axi_arready (m_axi_arready),

        .s_axi_rid     (m_axi_rid),
        .s_axi_rdata   (m_axi_rdata),
        .s_axi_rresp   (m_axi_rresp),
        .s_axi_rlast   (m_axi_rlast),
        .s_axi_rvalid  (m_axi_rvalid),
        .s_axi_rready  (m_axi_rready),

        // M-side: M00 = MIG (low bits), M01 = uart-via-pc (high bits).
        .m_axi_awaddr  ({pc_awaddr,   mig_awaddr_full}),
        .m_axi_awlen   ({pc_awlen,    mig_awlen}),
        .m_axi_awsize  ({pc_awsize,   mig_awsize}),
        .m_axi_awburst ({pc_awburst,  mig_awburst}),
        .m_axi_awlock  ({pc_awlock,   mig_awlock}),
        .m_axi_awcache ({pc_awcache,  mig_awcache}),
        .m_axi_awprot  ({pc_awprot,   mig_awprot}),
        .m_axi_awregion({pc_awregion, mig_awregion_unused}),
        .m_axi_awqos   ({pc_awqos,    mig_awqos}),
        .m_axi_awvalid ({pc_awvalid,  mig_awvalid}),
        .m_axi_awready ({pc_awready,  mig_awready}),

        .m_axi_wdata   ({pc_wdata,    mig_wdata}),
        .m_axi_wstrb   ({pc_wstrb,    mig_wstrb}),
        .m_axi_wlast   ({pc_wlast,    mig_wlast}),
        .m_axi_wvalid  ({pc_wvalid,   mig_wvalid}),
        .m_axi_wready  ({pc_wready,   mig_wready}),

        .m_axi_bresp   ({pc_bresp,    mig_bresp}),
        .m_axi_bvalid  ({pc_bvalid,   mig_bvalid}),
        .m_axi_bready  ({pc_bready,   mig_bready}),

        .m_axi_araddr  ({pc_araddr,   mig_araddr_full}),
        .m_axi_arlen   ({pc_arlen,    mig_arlen}),
        .m_axi_arsize  ({pc_arsize,   mig_arsize}),
        .m_axi_arburst ({pc_arburst,  mig_arburst}),
        .m_axi_arlock  ({pc_arlock,   mig_arlock}),
        .m_axi_arcache ({pc_arcache,  mig_arcache}),
        .m_axi_arprot  ({pc_arprot,   mig_arprot}),
        .m_axi_arregion({pc_arregion, mig_arregion_unused}),
        .m_axi_arqos   ({pc_arqos,    mig_arqos}),
        .m_axi_arvalid ({pc_arvalid,  mig_arvalid}),
        .m_axi_arready ({pc_arready,  mig_arready}),

        .m_axi_rdata   ({pc_rdata,    mig_rdata}),
        .m_axi_rresp   ({pc_rresp,    mig_rresp}),
        .m_axi_rlast   ({pc_rlast,    mig_rlast}),
        .m_axi_rvalid  ({pc_rvalid,   mig_rvalid}),
        .m_axi_rready  ({pc_rready,   mig_rready})
    );

    // ---------- AXI4 → AXI4-Lite protocol converter ----------
    wire        ul_awvalid, ul_awready;
    wire [31:0] ul_awaddr;
    wire [2:0]  ul_awprot;
    wire        ul_wvalid,  ul_wready;
    wire [31:0] ul_wdata;
    wire [3:0]  ul_wstrb;
    wire        ul_bvalid,  ul_bready;
    wire [1:0]  ul_bresp;
    wire        ul_arvalid, ul_arready;
    wire [31:0] ul_araddr;
    wire [2:0]  ul_arprot;
    wire        ul_rvalid,  ul_rready;
    wire [31:0] ul_rdata;
    wire [1:0]  ul_rresp;

    axi_protocol_converter_0 u_proto_conv (
        .aclk    (ui_clk),
        .aresetn (~soc_rst),

        .s_axi_awid    (4'd0),         // crossbar drops IDs
        .s_axi_awaddr  (pc_awaddr),
        .s_axi_awlen   (pc_awlen),
        .s_axi_awsize  (pc_awsize),
        .s_axi_awburst (pc_awburst),
        .s_axi_awlock  (pc_awlock),
        .s_axi_awcache (pc_awcache),
        .s_axi_awprot  (pc_awprot),
        .s_axi_awregion(pc_awregion),
        .s_axi_awqos   (pc_awqos),
        .s_axi_awvalid (pc_awvalid),
        .s_axi_awready (pc_awready),

        .s_axi_wdata   (pc_wdata),
        .s_axi_wstrb   (pc_wstrb),
        .s_axi_wlast   (pc_wlast),
        .s_axi_wvalid  (pc_wvalid),
        .s_axi_wready  (pc_wready),

        .s_axi_bid     (),
        .s_axi_bresp   (pc_bresp),
        .s_axi_bvalid  (pc_bvalid),
        .s_axi_bready  (pc_bready),

        .s_axi_arid    (4'd0),
        .s_axi_araddr  (pc_araddr),
        .s_axi_arlen   (pc_arlen),
        .s_axi_arsize  (pc_arsize),
        .s_axi_arburst (pc_arburst),
        .s_axi_arlock  (pc_arlock),
        .s_axi_arcache (pc_arcache),
        .s_axi_arprot  (pc_arprot),
        .s_axi_arregion(pc_arregion),
        .s_axi_arqos   (pc_arqos),
        .s_axi_arvalid (pc_arvalid),
        .s_axi_arready (pc_arready),

        .s_axi_rid     (),
        .s_axi_rdata   (pc_rdata),
        .s_axi_rresp   (pc_rresp),
        .s_axi_rlast   (pc_rlast),
        .s_axi_rvalid  (pc_rvalid),
        .s_axi_rready  (pc_rready),

        // Master side (AXI4-Lite) → uartlite
        .m_axi_awaddr  (ul_awaddr),
        .m_axi_awprot  (ul_awprot),
        .m_axi_awvalid (ul_awvalid),
        .m_axi_awready (ul_awready),
        .m_axi_wdata   (ul_wdata),
        .m_axi_wstrb   (ul_wstrb),
        .m_axi_wvalid  (ul_wvalid),
        .m_axi_wready  (ul_wready),
        .m_axi_bresp   (ul_bresp),
        .m_axi_bvalid  (ul_bvalid),
        .m_axi_bready  (ul_bready),
        .m_axi_araddr  (ul_araddr),
        .m_axi_arprot  (ul_arprot),
        .m_axi_arvalid (ul_arvalid),
        .m_axi_arready (ul_arready),
        .m_axi_rdata   (ul_rdata),
        .m_axi_rresp   (ul_rresp),
        .m_axi_rvalid  (ul_rvalid),
        .m_axi_rready  (ul_rready)
    );

    // ---------- AMD AXI UartLite ----------
    wire uartlite_irq;
    axi_uartlite_0 u_uartlite (
        .s_axi_aclk   (ui_clk),
        .s_axi_aresetn(~soc_rst),

        .s_axi_awaddr (ul_awaddr[3:0]),
        .s_axi_awvalid(ul_awvalid),
        .s_axi_awready(ul_awready),

        .s_axi_wdata  (ul_wdata),
        .s_axi_wstrb  (ul_wstrb),
        .s_axi_wvalid (ul_wvalid),
        .s_axi_wready (ul_wready),

        .s_axi_bresp  (ul_bresp),
        .s_axi_bvalid (ul_bvalid),
        .s_axi_bready (ul_bready),

        .s_axi_araddr (ul_araddr[3:0]),
        .s_axi_arvalid(ul_arvalid),
        .s_axi_arready(ul_arready),

        .s_axi_rdata  (ul_rdata),
        .s_axi_rresp  (ul_rresp),
        .s_axi_rvalid (ul_rvalid),
        .s_axi_rready (ul_rready),

        .rx           (uart_rx_pin),
        .tx           (uart_tx_pin),
        .interrupt    (uartlite_irq)
    );

    // ---------- LED indicators ----------
    reg [19:0] commit_stretch = 20'd0;
    always_ff @(posedge ui_clk) begin
        if (soc_rst) begin
            commit_stretch <= 20'd0;
        end else if (commit_valid) begin
            commit_stretch <= 20'hFFFFF;
        end else if (commit_stretch != 20'd0) begin
            commit_stretch <= commit_stretch - 20'd1;
        end
    end

    reg console_seen = 1'b0;
    always_ff @(posedge ui_clk) begin
        if (soc_rst)            console_seen <= 1'b0;
        else if (console_valid) console_seen <= 1'b1;
    end

    assign led[0] = alive_hb[25];
    assign led[1] = mmcm_locked;
    assign led[2] = rst_n;
    assign led[3] = ~soc_rst;
    assign led[4] = commit_stretch[19];
    assign led[5] = exit_valid;
    assign led[6] = console_seen;
    assign led[7] = init_calib_complete;

endmodule

`default_nettype wire
