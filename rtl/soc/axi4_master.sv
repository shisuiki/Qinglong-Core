// AXI4-full master shim (single-beat, single-outstanding).
//
// Stage 7a: replaces axi_lite_master at the SoC boundary so the bus type
// matches what MIG7 (Stage 7b), Vivado axi_crossbar, and the future cached
// burst master (Stage 7c) expect. Behaviour for now is identical to the
// AXI-Lite shim — len=0, size=2 (4 bytes), burst=INCR, single in-flight —
// just dressed in full AXI4 signals so we don't have to break the bus type
// again when D-cache lands.
//
// ID is fixed at 4'h0; we never have more than one transaction in flight.
// LOCK/CACHE/QOS/REGION are tied to safe defaults that match what Vivado's
// AXI Lite→Full protocol converter would emit.

module axi4_master #(
    parameter int unsigned ID_W = 4
) (
    input  logic        clk,
    input  logic        rst,

    // ---- native slave port (from core dmem decode) ----
    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic        req_wen,
    input  logic [31:0] req_wdata,
    input  logic [3:0]  req_wmask,
    output logic        req_ready,
    output logic        rsp_valid,
    output logic [31:0] rsp_rdata,
    output logic        rsp_fault,

    // ---- AXI4 master port ----
    output logic              m_axi_awvalid,
    input  logic              m_axi_awready,
    output logic [31:0]       m_axi_awaddr,
    output logic [ID_W-1:0]   m_axi_awid,
    output logic [7:0]        m_axi_awlen,
    output logic [2:0]        m_axi_awsize,
    output logic [1:0]        m_axi_awburst,
    output logic              m_axi_awlock,
    output logic [3:0]        m_axi_awcache,
    output logic [2:0]        m_axi_awprot,
    output logic [3:0]        m_axi_awqos,

    output logic              m_axi_wvalid,
    input  logic              m_axi_wready,
    output logic [31:0]       m_axi_wdata,
    output logic [3:0]        m_axi_wstrb,
    output logic              m_axi_wlast,

    input  logic              m_axi_bvalid,
    output logic              m_axi_bready,
    input  logic [ID_W-1:0]   m_axi_bid,
    input  logic [1:0]        m_axi_bresp,

    output logic              m_axi_arvalid,
    input  logic              m_axi_arready,
    output logic [31:0]       m_axi_araddr,
    output logic [ID_W-1:0]   m_axi_arid,
    output logic [7:0]        m_axi_arlen,
    output logic [2:0]        m_axi_arsize,
    output logic [1:0]        m_axi_arburst,
    output logic              m_axi_arlock,
    output logic [3:0]        m_axi_arcache,
    output logic [2:0]        m_axi_arprot,
    output logic [3:0]        m_axi_arqos,

    input  logic              m_axi_rvalid,
    output logic              m_axi_rready,
    input  logic [ID_W-1:0]   m_axi_rid,
    input  logic [31:0]       m_axi_rdata,
    input  logic [1:0]        m_axi_rresp,
    input  logic              m_axi_rlast
);

    typedef enum logic [2:0] {
        S_IDLE     = 3'd0,
        S_WRITE    = 3'd1,
        S_WRITE_B  = 3'd2,
        S_READ     = 3'd3,
        S_READ_R   = 3'd4
    } state_t;
    state_t state_q;

    logic [31:0] addr_q, wdata_q;
    logic [3:0]  wmask_q;
    logic        aw_sent_q, w_sent_q;

    logic        rsp_valid_q, rsp_fault_q;
    logic [31:0] rsp_rdata_q;

    assign req_ready  = (state_q == S_IDLE);
    assign rsp_valid  = rsp_valid_q;
    assign rsp_rdata  = rsp_rdata_q;
    assign rsp_fault  = rsp_fault_q;

    // --- Constant AXI4 attributes (single-beat, INCR, normal device) ---
    assign m_axi_awid    = '0;
    assign m_axi_awlen   = 8'd0;            // 1 beat
    assign m_axi_awsize  = 3'd2;            // 4 bytes
    assign m_axi_awburst = 2'b01;           // INCR
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0011;         // Normal Non-cacheable Bufferable
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'd0;

    assign m_axi_arid    = '0;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'd2;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'd0;

    assign m_axi_awvalid = (state_q == S_WRITE) && !aw_sent_q;
    assign m_axi_awaddr  = addr_q;

    assign m_axi_wvalid  = (state_q == S_WRITE) && !w_sent_q;
    assign m_axi_wdata   = wdata_q;
    assign m_axi_wstrb   = wmask_q;
    assign m_axi_wlast   = 1'b1;            // single-beat → always last

    assign m_axi_bready  = (state_q == S_WRITE_B);

    assign m_axi_arvalid = (state_q == S_READ);
    assign m_axi_araddr  = addr_q;

    assign m_axi_rready  = (state_q == S_READ_R);

    always_ff @(posedge clk) begin
        if (rst) begin
            state_q     <= S_IDLE;
            addr_q      <= 32'd0;
            wdata_q     <= 32'd0;
            wmask_q     <= 4'd0;
            aw_sent_q   <= 1'b0;
            w_sent_q    <= 1'b0;
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_fault_q <= 1'b0;
        end else begin
            rsp_valid_q <= 1'b0;
            rsp_fault_q <= 1'b0;

            unique case (state_q)
                S_IDLE: begin
                    if (req_valid) begin
                        addr_q    <= req_addr;
                        wdata_q   <= req_wdata;
                        wmask_q   <= req_wmask;
                        aw_sent_q <= 1'b0;
                        w_sent_q  <= 1'b0;
                        state_q   <= req_wen ? S_WRITE : S_READ;
                    end
                end

                S_WRITE: begin
                    if (m_axi_awvalid && m_axi_awready) aw_sent_q <= 1'b1;
                    if (m_axi_wvalid  && m_axi_wready)  w_sent_q  <= 1'b1;
                    if ((aw_sent_q || (m_axi_awvalid && m_axi_awready))
                     && (w_sent_q  || (m_axi_wvalid  && m_axi_wready))) begin
                        state_q <= S_WRITE_B;
                    end
                end

                S_WRITE_B: begin
                    if (m_axi_bvalid) begin
                        rsp_valid_q <= 1'b1;
                        rsp_rdata_q <= 32'd0;
                        rsp_fault_q <= (m_axi_bresp != 2'b00);
                        state_q     <= S_IDLE;
                    end
                end

                S_READ: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        state_q <= S_READ_R;
                    end
                end

                S_READ_R: begin
                    if (m_axi_rvalid) begin
                        rsp_valid_q <= 1'b1;
                        rsp_rdata_q <= m_axi_rdata;
                        rsp_fault_q <= (m_axi_rresp != 2'b00);
                        state_q     <= S_IDLE;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
