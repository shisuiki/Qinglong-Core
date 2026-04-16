// 32 x 32 register file, 2 async read ports + 1 sync write port.
// Intended for LUTRAM on 7-series (inferred by the Vivado synthesizer from this style).
// x0 reads as 0 regardless of any write.

module regfile (
    input  logic        clk,
    input  logic [4:0]  rs1_addr,
    output logic [31:0] rs1_data,
    input  logic [4:0]  rs2_addr,
    output logic [31:0] rs2_data,
    input  logic        wen,
    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data
);

    logic [31:0] regs [1:31];

    // Async reads, x0 hardwired to 0.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    always_ff @(posedge clk) begin
        if (wen && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

`ifdef VERILATOR
    // Initialize to a clear value so uninitialized-read bugs are visible.
    integer i;
    initial begin
        for (i = 1; i <= 31; i = i + 1) regs[i] = 32'h0;
    end
`endif

endmodule
