// AXI4-Lite BRAM slave — sim-only, used to exercise the axi_lite_master shim.
//
// Word-addressed internal memory of WORDS entries. Accepts AW+W together
// (deasserting ready until both have arrived), responds on B one cycle
// later with OKAY. Reads are 1-cycle AR → R. Byte strobes honoured.
//
// Not intended for FPGA synthesis — a production design would use
// axi_bram_ctrl + a BRAM primitive. This is just enough fidelity to test
// the master shim.

module axil_bram_slave #(
    parameter int WORDS = 1024   // 4 KiB default
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_awaddr,
    input  logic [2:0]  s_axil_awprot,

    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,

    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    output logic [1:0]  s_axil_bresp,

    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    input  logic [31:0] s_axil_araddr,
    input  logic [2:0]  s_axil_arprot,

    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp
);

    localparam int AWIDTH = $clog2(WORDS);

    logic [31:0] mem [0:WORDS-1];

    // --------- Write side ---------
    logic        aw_hs_q, w_hs_q;
    logic [31:0] awaddr_q, wdata_q;
    logic [3:0]  wstrb_q;
    logic        bvalid_q;

    // Accept AW / W independently; hold ready until we have both captured.
    assign s_axil_awready = !aw_hs_q;
    assign s_axil_wready  = !w_hs_q;
    assign s_axil_bvalid  = bvalid_q;
    assign s_axil_bresp   = 2'b00;

    wire [AWIDTH-1:0] aw_idx = awaddr_q[AWIDTH+1:2];

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_hs_q  <= 1'b0;
            w_hs_q   <= 1'b0;
            bvalid_q <= 1'b0;
        end else begin
            if (s_axil_awvalid && s_axil_awready) begin
                awaddr_q <= s_axil_awaddr;
                aw_hs_q  <= 1'b1;
            end
            if (s_axil_wvalid && s_axil_wready) begin
                wdata_q <= s_axil_wdata;
                wstrb_q <= s_axil_wstrb;
                w_hs_q  <= 1'b1;
            end

            // Once both halves captured, perform the write and pulse B.
            if (aw_hs_q && w_hs_q && !bvalid_q) begin
                if (wstrb_q[0]) mem[aw_idx][ 7: 0] <= wdata_q[ 7: 0];
                if (wstrb_q[1]) mem[aw_idx][15: 8] <= wdata_q[15: 8];
                if (wstrb_q[2]) mem[aw_idx][23:16] <= wdata_q[23:16];
                if (wstrb_q[3]) mem[aw_idx][31:24] <= wdata_q[31:24];
                bvalid_q <= 1'b1;
            end

            // Retire B once acked, and clear the aw/w flags for the next txn.
            if (bvalid_q && s_axil_bready) begin
                bvalid_q <= 1'b0;
                aw_hs_q  <= 1'b0;
                w_hs_q   <= 1'b0;
            end
        end
    end

    // --------- Read side ---------
    logic        ar_hs_q, rvalid_q;
    logic [31:0] araddr_q;

    assign s_axil_arready = !ar_hs_q;
    assign s_axil_rvalid  = rvalid_q;
    assign s_axil_rresp   = 2'b00;

    wire [AWIDTH-1:0] ar_idx = araddr_q[AWIDTH+1:2];

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_hs_q  <= 1'b0;
            rvalid_q <= 1'b0;
            s_axil_rdata <= 32'd0;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                araddr_q <= s_axil_araddr;
                ar_hs_q  <= 1'b1;
            end
            if (ar_hs_q && !rvalid_q) begin
                s_axil_rdata <= mem[ar_idx];
                rvalid_q     <= 1'b1;
            end
            if (rvalid_q && s_axil_rready) begin
                rvalid_q <= 1'b0;
                ar_hs_q  <= 1'b0;
            end
        end
    end

endmodule
