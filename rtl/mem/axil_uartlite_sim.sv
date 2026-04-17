// Sim-only behavioural model of AMD AXI UartLite. Enough to convince a
// polling driver (sw/common/uartlite.h) and FreeRTOS that there's a real UART
// there; TX bytes are printed to the Verilator stdout via $write.
//
// Register offsets (low 4 addr bits):
//   0x00  RX_FIFO  (RO)  — always empty (returns 0)
//   0x04  TX_FIFO  (WO)  — byte is emitted to stdout immediately
//   0x08  STAT     (RO)  — always 0 (TX not full, RX not valid)
//   0x0C  CTRL     (WO)  — accepted, ignored
//
// Fidelity vs real IP: no FIFOs, no RX, no interrupt. That's fine for bringup.

module axil_uartlite_sim (
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

    // ---- Write side ----
    logic        aw_hs_q, w_hs_q;
    logic [31:0] awaddr_q, wdata_q;
    logic [3:0]  wstrb_q;
    logic        bvalid_q;

    assign s_axil_awready = !aw_hs_q;
    assign s_axil_wready  = !w_hs_q;
    assign s_axil_bvalid  = bvalid_q;
    assign s_axil_bresp   = 2'b00;

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
                // Emit byte on write to TX_FIFO (offset 0x04).
                if (awaddr_q[3:0] == 4'h4 && wstrb_q[0]) begin
                    $write("%c", wdata_q[7:0]);
                    $fflush;
                end
                // Other offsets are silently accepted.
                bvalid_q <= 1'b1;
            end

            if (bvalid_q && s_axil_bready) begin
                bvalid_q <= 1'b0;
                aw_hs_q  <= 1'b0;
                w_hs_q   <= 1'b0;
            end
        end
    end

    // ---- Read side ----
    logic        ar_hs_q, rvalid_q;
    logic [31:0] araddr_q;

    assign s_axil_arready = !ar_hs_q;
    assign s_axil_rvalid  = rvalid_q;
    assign s_axil_rresp   = 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_hs_q      <= 1'b0;
            rvalid_q     <= 1'b0;
            s_axil_rdata <= 32'd0;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                araddr_q <= s_axil_araddr;
                ar_hs_q  <= 1'b1;
            end
            if (ar_hs_q && !rvalid_q) begin
                // STAT, RX_FIFO, CTRL all read 0 — TX_FULL=0 so a polling
                // writer proceeds immediately, RX_VALID=0 so nothing to read.
                s_axil_rdata <= 32'd0;
                rvalid_q     <= 1'b1;
            end
            if (rvalid_q && s_axil_rready) begin
                rvalid_q <= 1'b0;
                ar_hs_q  <= 1'b0;
            end
        end
    end

endmodule
