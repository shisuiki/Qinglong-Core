// Thin Verilator testbench wrapper: pins out only the signals the C++ harness
// needs to observe directly.  (Verilator treats this as the `top` module.)
//
// Owns the sim peripheral fabric hanging off soc_top's AXI4-Lite master port.
// Two slaves, steered by m_axil_*addr[12]:
//   addr[12]=0  →  axil_uartlite_sim   @ 0xC000_0000 .. 0xC000_0FFF
//                 (behavioural AMD UartLite model; TX → stdout)
//   addr[12]=1  →  axil_bram_slave     @ 0xC000_1000 .. 0xC000_1FFF
//                 (plain BRAM used by the asm-level axi_bram smoke test)

module soc_tb_top (
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
    output logic [31:0] commit_cause
);

    // ---------- master (out of soc_top) ----------
    logic        m_axil_awvalid, m_axil_awready;
    logic [31:0] m_axil_awaddr;
    logic [2:0]  m_axil_awprot;
    logic        m_axil_wvalid, m_axil_wready;
    logic [31:0] m_axil_wdata;
    logic [3:0]  m_axil_wstrb;
    logic        m_axil_bvalid, m_axil_bready;
    logic [1:0]  m_axil_bresp;
    logic        m_axil_arvalid, m_axil_arready;
    logic [31:0] m_axil_araddr;
    logic [2:0]  m_axil_arprot;
    logic        m_axil_rvalid, m_axil_rready;
    logic [31:0] m_axil_rdata;
    logic [1:0]  m_axil_rresp;

    soc_top u_soc (
        .clk(clk), .rst(rst),
        .console_valid(console_valid), .console_byte(console_byte),
        .console_ready(1'b1),
        .exit_valid(exit_valid), .exit_code(exit_code),

        .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),
        .m_axil_awaddr(m_axil_awaddr),   .m_axil_awprot(m_axil_awprot),
        .m_axil_wvalid(m_axil_wvalid),   .m_axil_wready(m_axil_wready),
        .m_axil_wdata(m_axil_wdata),     .m_axil_wstrb(m_axil_wstrb),
        .m_axil_bvalid(m_axil_bvalid),   .m_axil_bready(m_axil_bready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_arvalid(m_axil_arvalid), .m_axil_arready(m_axil_arready),
        .m_axil_araddr(m_axil_araddr),   .m_axil_arprot(m_axil_arprot),
        .m_axil_rvalid(m_axil_rvalid),   .m_axil_rready(m_axil_rready),
        .m_axil_rdata(m_axil_rdata),     .m_axil_rresp(m_axil_rresp),

        .ext_mei(1'b0),

        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );

    // ---------- tiny 1→2 AXI-Lite decoder ----------
    // Slave select is remembered per outstanding transaction (one in flight
    // at a time, enforced by the master shim), so responses route back to
    // the right slave even when the master's addr has already changed.

    logic sel_w_q, sel_w_valid_q;
    logic sel_r_q, sel_r_valid_q;

    // Combinational select for the *current* AW/AR — valid when we're in
    // the handshake phase for that channel.
    wire sel_w_next = m_axil_awaddr[12];
    wire sel_r_next = m_axil_araddr[12];

    always_ff @(posedge clk) begin
        if (rst) begin
            sel_w_q       <= 1'b0;
            sel_w_valid_q <= 1'b0;
            sel_r_q       <= 1'b0;
            sel_r_valid_q <= 1'b0;
        end else begin
            if (m_axil_awvalid && m_axil_awready) begin
                sel_w_q       <= sel_w_next;
                sel_w_valid_q <= 1'b1;
            end else if (m_axil_bvalid && m_axil_bready) begin
                sel_w_valid_q <= 1'b0;
            end
            if (m_axil_arvalid && m_axil_arready) begin
                sel_r_q       <= sel_r_next;
                sel_r_valid_q <= 1'b1;
            end else if (m_axil_rvalid && m_axil_rready) begin
                sel_r_valid_q <= 1'b0;
            end
        end
    end

    // Per-slave signals
    logic [1:0]        s_awvalid, s_awready;
    logic [1:0]        s_wvalid,  s_wready;
    logic [1:0]        s_bvalid;
    logic [1:0][1:0]   s_bresp;
    logic [1:0]        s_arvalid, s_arready;
    logic [1:0]        s_rvalid;
    logic [1:0][31:0]  s_rdata;
    logic [1:0][1:0]   s_rresp;

    // AW / W fan-out: only the selected slave sees valid; unselected sees 0
    assign s_awvalid[0] = m_axil_awvalid && (sel_w_next == 1'b0);
    assign s_awvalid[1] = m_axil_awvalid && (sel_w_next == 1'b1);
    assign m_axil_awready = (sel_w_next == 1'b0) ? s_awready[0] : s_awready[1];

    // W follows the AW select captured *at AW accept* (one-in-flight so this is
    // the same as the current sel_w_next until AW handshakes, and then sel_w_q).
    wire sel_w_eff = sel_w_valid_q ? sel_w_q : sel_w_next;
    assign s_wvalid[0] = m_axil_wvalid && (sel_w_eff == 1'b0);
    assign s_wvalid[1] = m_axil_wvalid && (sel_w_eff == 1'b1);
    assign m_axil_wready = (sel_w_eff == 1'b0) ? s_wready[0] : s_wready[1];

    // B response comes back from captured slave
    assign m_axil_bvalid = sel_w_valid_q ? s_bvalid[sel_w_q] : 1'b0;
    assign m_axil_bresp  = sel_w_valid_q ? s_bresp[sel_w_q]  : 2'b00;
    assign s_bready_0 = sel_w_valid_q && (sel_w_q == 1'b0) && m_axil_bready;
    assign s_bready_1 = sel_w_valid_q && (sel_w_q == 1'b1) && m_axil_bready;
    wire s_bready_0, s_bready_1;

    // AR fan-out / R funnel
    assign s_arvalid[0] = m_axil_arvalid && (sel_r_next == 1'b0);
    assign s_arvalid[1] = m_axil_arvalid && (sel_r_next == 1'b1);
    assign m_axil_arready = (sel_r_next == 1'b0) ? s_arready[0] : s_arready[1];

    assign m_axil_rvalid = sel_r_valid_q ? s_rvalid[sel_r_q] : 1'b0;
    assign m_axil_rdata  = sel_r_valid_q ? s_rdata[sel_r_q]  : 32'd0;
    assign m_axil_rresp  = sel_r_valid_q ? s_rresp[sel_r_q]  : 2'b00;
    wire s_rready_0 = sel_r_valid_q && (sel_r_q == 1'b0) && m_axil_rready;
    wire s_rready_1 = sel_r_valid_q && (sel_r_q == 1'b1) && m_axil_rready;

    // ---------- slave 0: UartLite stub @ 0xC000_0000 ----------
    axil_uartlite_sim u_ul (
        .clk(clk), .rst(rst),
        .s_axil_awvalid(s_awvalid[0]), .s_axil_awready(s_awready[0]),
        .s_axil_awaddr(m_axil_awaddr),  .s_axil_awprot(m_axil_awprot),
        .s_axil_wvalid(s_wvalid[0]),    .s_axil_wready(s_wready[0]),
        .s_axil_wdata(m_axil_wdata),    .s_axil_wstrb(m_axil_wstrb),
        .s_axil_bvalid(s_bvalid[0]),    .s_axil_bready(s_bready_0),
        .s_axil_bresp(s_bresp[0]),
        .s_axil_arvalid(s_arvalid[0]),  .s_axil_arready(s_arready[0]),
        .s_axil_araddr(m_axil_araddr),  .s_axil_arprot(m_axil_arprot),
        .s_axil_rvalid(s_rvalid[0]),    .s_axil_rready(s_rready_0),
        .s_axil_rdata(s_rdata[0]),      .s_axil_rresp(s_rresp[0])
    );

    // ---------- slave 1: BRAM @ 0xC000_1000 ----------
    axil_bram_slave #(.WORDS(1024)) u_axi_bram (
        .clk(clk), .rst(rst),
        .s_axil_awvalid(s_awvalid[1]), .s_axil_awready(s_awready[1]),
        .s_axil_awaddr(m_axil_awaddr),  .s_axil_awprot(m_axil_awprot),
        .s_axil_wvalid(s_wvalid[1]),    .s_axil_wready(s_wready[1]),
        .s_axil_wdata(m_axil_wdata),    .s_axil_wstrb(m_axil_wstrb),
        .s_axil_bvalid(s_bvalid[1]),    .s_axil_bready(s_bready_1),
        .s_axil_bresp(s_bresp[1]),
        .s_axil_arvalid(s_arvalid[1]),  .s_axil_arready(s_arready[1]),
        .s_axil_araddr(m_axil_araddr),  .s_axil_arprot(m_axil_arprot),
        .s_axil_rvalid(s_rvalid[1]),    .s_axil_rready(s_rready_1),
        .s_axil_rdata(s_rdata[1]),      .s_axil_rresp(s_rresp[1])
    );

endmodule
