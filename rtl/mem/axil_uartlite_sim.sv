// Sim-only behavioural model of AMD AXI UartLite. Enough to convince a
// polling driver (sw/common/uartlite.h) and FreeRTOS that there's a real UART
// there; TX bytes are printed to the Verilator stdout via $write.
//
// Register offsets (low 4 addr bits):
//   0x00  RX_FIFO  (RO)  — always empty (returns 0)
//   0x04  TX_FIFO  (WO)  — byte is emitted to stdout immediately
//   0x08  STAT     (RO)  — TX_EMPTY=1 (bit 2) once IRQ-fidelity on, 0 before
//   0x0C  CTRL     (WO)  — IE bit (0x10) tracked for irq_o drive
//
// Fidelity vs real IP: no FIFOs, no RX. IRQ output added (2026-04-24) to let
// sim exercise S-mode external-IRQ delivery via PLIC — matches silicon's
// behavior where the level-triggered IRQ asserts whenever CTRL.IE=1 AND
// TX FIFO is empty (or RX valid). Sim has no FIFO so TX is always empty,
// meaning once the driver writes IE=1 the IRQ stays high forever — which is
// exactly the condition that breaks silicon's S-mode IRQ path.

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
    output logic [1:0]  s_axil_rresp,

    output logic        irq_o
);

    // CTRL.IE bit (0x10 = bit 4). Sticky until next CTRL write.
    logic ctrl_ie_q;
    assign irq_o = ctrl_ie_q;   // TX always "empty" in sim → IRQ high whenever IE=1

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
            aw_hs_q   <= 1'b0;
            w_hs_q    <= 1'b0;
            bvalid_q  <= 1'b0;
            ctrl_ie_q <= 1'b0;
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
                // Track CTRL.IE (bit 4) on writes to CTRL (offset 0x0c).
                if (awaddr_q[3:0] == 4'hc && wstrb_q[0]) begin
                    ctrl_ie_q <= wdata_q[4];
                end
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
