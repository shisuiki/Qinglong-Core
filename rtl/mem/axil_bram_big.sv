// Large AXI-Lite BRAM slave used as a sim-only DDR stand-in.
//
// Same behavioural contract as axil_bram_slave.sv (single-outstanding,
// 1-cycle read/write, OKAY-only) but sized to hold a full Linux image
// (OpenSBI + kernel + DTB + initramfs) at base 0x4000_0000. Word-addressed
// internal memory; byte strobes honoured.
//
// Distinct DPI backdoor names from sram_dp so both can be co-exported in
// the same sim build (the C++ harness picks the right scope for each).

module axil_bram_big #(
    parameter int WORDS = 32 * 1024 * 1024   // 128 MiB default
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

            if (aw_hs_q && w_hs_q && !bvalid_q) begin
                if (wstrb_q[0]) mem[aw_idx][ 7: 0] <= wdata_q[ 7: 0];
                if (wstrb_q[1]) mem[aw_idx][15: 8] <= wdata_q[15: 8];
                if (wstrb_q[2]) mem[aw_idx][23:16] <= wdata_q[23:16];
                if (wstrb_q[3]) mem[aw_idx][31:24] <= wdata_q[31:24];
                bvalid_q <= 1'b1;
            end

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

    // DPI backdoor — distinct names from sram_dp so both coexist in one sim.
`ifdef VERILATOR
    export "DPI-C" function ddr_dpi_write;
    export "DPI-C" function ddr_dpi_read;

    function void ddr_dpi_write(input int word_addr, input int data);
        if (word_addr >= 0 && word_addr < WORDS) begin
            mem[word_addr] = data;
        end
    endfunction

    function int ddr_dpi_read(input int word_addr);
        if (word_addr >= 0 && word_addr < WORDS) begin
            return mem[word_addr];
        end else begin
            return 32'hDEADBEEF;
        end
    endfunction
`endif

endmodule
