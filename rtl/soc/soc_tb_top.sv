// Thin Verilator testbench wrapper: pins out only the signals the C++ harness
// needs to observe directly.  (Verilator treats this as the `top` module.)

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

    soc_top u_soc (
        .clk(clk), .rst(rst),
        .console_valid(console_valid), .console_byte(console_byte),
        .console_ready(1'b1),                                        // sim: UART is infinitely fast
        .exit_valid(exit_valid), .exit_code(exit_code),
        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_insn(commit_insn),
        .commit_rd_wen(commit_rd_wen), .commit_rd_addr(commit_rd_addr), .commit_rd_data(commit_rd_data),
        .commit_trap(commit_trap), .commit_cause(commit_cause)
    );

endmodule
