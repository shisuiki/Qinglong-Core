// AXI4-Lite master shim.
//
// Translates the core's native ready/valid dmem slave interface into an
// AXI4-Lite master. One transaction is in flight at a time — the slave-side
// req_ready goes low while we drive an AXI-side request and wait for its
// B / R response. AXI responses other than OKAY map to rsp_fault=1.
//
// Channel handshaking follows the AMBA AXI-Lite spec:
//   AW and W may handshake in either order; we do them in parallel.
//   B and R are separate response channels; we keep r_ready / b_ready high
//   only while waiting for the corresponding response.
//
// Parameters are modest: 32-bit data/address, strb[3:0], prot tied off.
// aq/rl are irrelevant for AXI-Lite — atomics are out of scope for this bus.
// No exclusive access support; LR/SC on the AXI region is undefined behavior
// (we don't send AMOs down this path — AXI region is peripherals only).

module axi_lite_master (
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

    // ---- AXI4-Lite master port ----
    output logic        m_axil_awvalid,
    input  logic        m_axil_awready,
    output logic [31:0] m_axil_awaddr,
    output logic [2:0]  m_axil_awprot,

    output logic        m_axil_wvalid,
    input  logic        m_axil_wready,
    output logic [31:0] m_axil_wdata,
    output logic [3:0]  m_axil_wstrb,

    input  logic        m_axil_bvalid,
    output logic        m_axil_bready,
    input  logic [1:0]  m_axil_bresp,

    output logic        m_axil_arvalid,
    input  logic        m_axil_arready,
    output logic [31:0] m_axil_araddr,
    output logic [2:0]  m_axil_arprot,

    input  logic        m_axil_rvalid,
    output logic        m_axil_rready,
    input  logic [31:0] m_axil_rdata,
    input  logic [1:0]  m_axil_rresp
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

    assign m_axil_awvalid = (state_q == S_WRITE) && !aw_sent_q;
    assign m_axil_awaddr  = addr_q;
    assign m_axil_awprot  = 3'b000;

    assign m_axil_wvalid  = (state_q == S_WRITE) && !w_sent_q;
    assign m_axil_wdata   = wdata_q;
    assign m_axil_wstrb   = wmask_q;

    assign m_axil_bready  = (state_q == S_WRITE_B);

    assign m_axil_arvalid = (state_q == S_READ);
    assign m_axil_araddr  = addr_q;
    assign m_axil_arprot  = 3'b000;

    assign m_axil_rready  = (state_q == S_READ_R);

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
                    // AW / W accept independently.
                    if (m_axil_awvalid && m_axil_awready) aw_sent_q <= 1'b1;
                    if (m_axil_wvalid  && m_axil_wready)  w_sent_q  <= 1'b1;
                    if ((aw_sent_q || (m_axil_awvalid && m_axil_awready))
                     && (w_sent_q  || (m_axil_wvalid  && m_axil_wready))) begin
                        state_q <= S_WRITE_B;
                    end
                end

                S_WRITE_B: begin
                    if (m_axil_bvalid) begin
                        rsp_valid_q <= 1'b1;
                        rsp_rdata_q <= 32'd0;
                        rsp_fault_q <= (m_axil_bresp != 2'b00);
                        state_q     <= S_IDLE;
                    end
                end

                S_READ: begin
                    if (m_axil_arvalid && m_axil_arready) begin
                        state_q <= S_READ_R;
                    end
                end

                S_READ_R: begin
                    if (m_axil_rvalid) begin
                        rsp_valid_q <= 1'b1;
                        rsp_rdata_q <= m_axil_rdata;
                        rsp_fault_q <= (m_axil_rresp != 2'b00);
                        state_q     <= S_IDLE;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
