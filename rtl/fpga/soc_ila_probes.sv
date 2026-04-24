// ILA probe wrapper for the S-mode external IRQ path diagnosis on Urbana
// silicon. Instantiated only when `FPGA_DEBUG_ILA is defined — sim builds
// skip this module entirely. Wraps Vivado's ila_0 IP with a fixed probe
// layout so all debug-signal wiring lives in one place.
//
// Signal groups (probes are numbered in the order they appear in ila_0.xci):
//   p0..p2   : UART/PLIC boundary (uart_irq_i, plic_sources, plic_irq)
//   p3..p7   : PLIC internal state (pending, inflight, enable[S],
//              threshold[S], claimed_src[S])
//   p8..p13  : PLIC bus activity (req_valid/wen/addr/wdata, rsp_valid/rdata)
//   p14..p18 : Core view (commit_valid, commit_pc, commit_trap,
//              commit_cause[5:0], priv_mode)
//
// Default trigger (set in Vivado): rising edge of uart_irq_i — captures the
// first UartLite IRQ that fires after ulite_startup enables CTRL.IE.

`timescale 1ns/1ps

module soc_ila_probes (
    input  logic        clk,

    // UART/PLIC boundary
    input  logic        uart_irq_i,
    input  logic [3:0]  plic_sources,
    input  logic [1:0]  plic_irq,

    // PLIC internal state
    input  logic [3:0]  plic_pending,
    input  logic [3:0]  plic_inflight,
    input  logic [3:0]  plic_enable_s,
    input  logic [2:0]  plic_threshold_s,
    input  logic [2:0]  plic_claimed_src_s,

    // PLIC bus (for observing kernel claim/complete/enable writes)
    input  logic        plic_req_valid,
    input  logic        plic_req_wen,
    input  logic [15:0] plic_req_addr,
    input  logic [31:0] plic_req_wdata,
    input  logic        plic_rsp_valid,
    input  logic [31:0] plic_rsp_rdata,

    // Core view (retire tap)
    input  logic        commit_valid,
    input  logic [31:0] commit_pc,
    input  logic        commit_trap,
    input  logic [5:0]  commit_cause,
    input  logic [1:0]  priv_mode
);

    ila_0 u_ila (
        .clk    (clk),
        .probe0 (uart_irq_i),
        .probe1 (plic_sources),
        .probe2 (plic_irq),
        .probe3 (plic_pending),
        .probe4 (plic_inflight),
        .probe5 (plic_enable_s),
        .probe6 (plic_threshold_s),
        .probe7 (plic_claimed_src_s),
        .probe8 (plic_req_valid),
        .probe9 (plic_req_wen),
        .probe10(plic_req_addr),
        .probe11(plic_req_wdata),
        .probe12(plic_rsp_valid),
        .probe13(plic_rsp_rdata),
        .probe14(commit_valid),
        .probe15(commit_pc),
        .probe16(commit_trap),
        .probe17(commit_cause),
        .probe18(priv_mode)
    );

endmodule
