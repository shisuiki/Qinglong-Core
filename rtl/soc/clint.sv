// Core-Local Interruptor (CLINT): SiFive-style, single hart.
//
// Memory map (base = 0x0200_0000):
//   +0x0000  msip       — software interrupt pending; bit[0] writable from SW
//   +0x4000  mtimecmp_lo — 64-bit compare-against-mtime, low word
//   +0x4004  mtimecmp_hi — high word
//   +0xBFF8  mtime_lo   — free-running 64-bit counter, low word (writable)
//   +0xBFFC  mtime_hi   — high word (writable)
//
// Outputs:
//   mti = (mtime >= mtimecmp)
//   msi = msip[0]
//
// Bus semantics match the rest of the dmem fabric: combinational req_ready=1,
// 1-cycle-delayed rsp_valid with rdata, rsp_fault for unmapped offsets.

module clint (
    input  logic        clk,
    input  logic        rst,

    input  logic        req_valid,
    input  logic [31:0] req_addr,
    input  logic        req_wen,
    input  logic [31:0] req_wdata,
    input  logic [3:0]  req_wmask,
    output logic        req_ready,
    output logic        rsp_valid,
    output logic [31:0] rsp_rdata,
    output logic        rsp_fault,

    output logic        mti,
    output logic        msi,

    // Core-visible mtime snapshot. Wired up to the core's CSR file so that
    // unprivileged `rdtime` / `rdtimeh` can read CLINT.mtime without taking
    // an M-mode trap and bouncing through OpenSBI (the kernel's
    // riscv_clocksource_rdtime is on the hot path).
    output logic [63:0] mtime_out
);

    assign mtime_out = mtime_q;


    localparam logic [15:0] OFF_MSIP    = 16'h0000;
    localparam logic [15:0] OFF_TCMP_LO = 16'h4000;
    localparam logic [15:0] OFF_TCMP_HI = 16'h4004;
    localparam logic [15:0] OFF_MTIME_LO= 16'hBFF8;
    localparam logic [15:0] OFF_MTIME_HI= 16'hBFFC;

    logic [63:0] mtime_q;
    logic [63:0] mtimecmp_q;
    logic        msip_q;

    assign mti = (mtime_q >= mtimecmp_q);
    assign msi = msip_q;

    assign req_ready = 1'b1;

    // Byte-mask helper: merge a 32-bit write with per-byte enable from req_wmask.
    function automatic [31:0] apply_wmask (input [31:0] old_val,
                                           input [31:0] new_val,
                                           input [3:0]  mask);
        apply_wmask[ 7: 0] = mask[0] ? new_val[ 7: 0] : old_val[ 7: 0];
        apply_wmask[15: 8] = mask[1] ? new_val[15: 8] : old_val[15: 8];
        apply_wmask[23:16] = mask[2] ? new_val[23:16] : old_val[23:16];
        apply_wmask[31:24] = mask[3] ? new_val[31:24] : old_val[31:24];
    endfunction

    wire [15:0] off = req_addr[15:0];
    wire addr_hit_msip    = (off == OFF_MSIP);
    wire addr_hit_tcmp_lo = (off == OFF_TCMP_LO);
    wire addr_hit_tcmp_hi = (off == OFF_TCMP_HI);
    wire addr_hit_mtime_lo= (off == OFF_MTIME_LO);
    wire addr_hit_mtime_hi= (off == OFF_MTIME_HI);
    wire addr_any_hit     = addr_hit_msip | addr_hit_tcmp_lo | addr_hit_tcmp_hi
                          | addr_hit_mtime_lo | addr_hit_mtime_hi;

    logic        rsp_valid_q;
    logic [31:0] rsp_rdata_q;
    logic        rsp_fault_q;
    assign rsp_valid = rsp_valid_q;
    assign rsp_rdata = rsp_rdata_q;
    assign rsp_fault = rsp_fault_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            mtime_q     <= 64'd0;
            mtimecmp_q  <= 64'hFFFF_FFFF_FFFF_FFFF;  // far future: no timer IRQ until SW arms it
            msip_q      <= 1'b0;
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_fault_q <= 1'b0;
        end else begin
            // Free-running counter, overridable by explicit writes below.
            mtime_q     <= mtime_q + 64'd1;
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_fault_q <= 1'b0;

            if (req_valid) begin
                rsp_valid_q <= 1'b1;
                if (!addr_any_hit) begin
                    rsp_fault_q <= 1'b1;
                end else if (req_wen) begin
                    if (addr_hit_msip)     msip_q             <= req_wmask[0] ? req_wdata[0] : msip_q;
                    if (addr_hit_tcmp_lo)  mtimecmp_q[31:0]   <= apply_wmask(mtimecmp_q[31:0],  req_wdata, req_wmask);
                    if (addr_hit_tcmp_hi)  mtimecmp_q[63:32]  <= apply_wmask(mtimecmp_q[63:32], req_wdata, req_wmask);
                    if (addr_hit_mtime_lo) mtime_q[31:0]      <= apply_wmask(mtime_q[31:0],     req_wdata, req_wmask);
                    if (addr_hit_mtime_hi) mtime_q[63:32]     <= apply_wmask(mtime_q[63:32],    req_wdata, req_wmask);
                end else begin
                    unique case (1'b1)
                        addr_hit_msip:     rsp_rdata_q <= {31'd0, msip_q};
                        addr_hit_tcmp_lo:  rsp_rdata_q <= mtimecmp_q[31:0];
                        addr_hit_tcmp_hi:  rsp_rdata_q <= mtimecmp_q[63:32];
                        addr_hit_mtime_lo: rsp_rdata_q <= mtime_q[31:0];
                        addr_hit_mtime_hi: rsp_rdata_q <= mtime_q[63:32];
                        default:           rsp_rdata_q <= 32'd0;
                    endcase
                end
            end
        end
    end

endmodule
