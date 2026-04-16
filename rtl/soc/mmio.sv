// Minimal MMIO for Stage 0/1:
//   0xD058_0000 (store byte)  -> console TX (emits ASCII byte to host UART).
//   0xD058_0004 (store word)  -> exit register; halts simulation with that code.
//   0xD058_0008 (load)        -> reads 0 (placeholder).
//
// Responds combinationally for loads (1-cycle rsp via pipeline reg) and stores.
//
// For Verilator, the testbench picks off exit_valid/exit_code via hierarchical
// references (or via DPI from a dedicated tap inside this module).  For FPGA,
// console TX drives a real UART.

module mmio (
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

    // simulation/FPGA taps
    output logic        console_valid,
    output logic [7:0]  console_byte,
    output logic        exit_valid,
    output logic [31:0] exit_code
);

    localparam logic [31:0] ADDR_CONSOLE = 32'hD058_0000;
    localparam logic [31:0] ADDR_EXIT    = 32'hD058_0004;
    localparam logic [31:0] ADDR_STATUS  = 32'hD058_0008;

    assign req_ready = 1'b1;

    logic        console_valid_q;
    logic [7:0]  console_byte_q;
    logic        exit_valid_q;
    logic [31:0] exit_code_q;
    logic        rsp_valid_q;
    logic [31:0] rsp_rdata_q;
    logic        rsp_fault_q;

    assign console_valid = console_valid_q;
    assign console_byte  = console_byte_q;
    assign exit_valid    = exit_valid_q;
    assign exit_code     = exit_code_q;
    assign rsp_valid     = rsp_valid_q;
    assign rsp_rdata     = rsp_rdata_q;
    assign rsp_fault     = rsp_fault_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            console_valid_q <= 1'b0;
            console_byte_q  <= 8'd0;
            exit_valid_q    <= 1'b0;
            exit_code_q     <= 32'd0;
            rsp_valid_q     <= 1'b0;
            rsp_rdata_q     <= 32'd0;
            rsp_fault_q     <= 1'b0;
        end else begin
            console_valid_q <= 1'b0;
            // exit_valid is sticky — once raised, stays raised
            rsp_valid_q     <= 1'b0;
            rsp_fault_q     <= 1'b0;

            if (req_valid) begin
                rsp_valid_q <= 1'b1;
                rsp_rdata_q <= 32'd0;
                unique case (req_addr)
                    ADDR_CONSOLE: begin
                        if (req_wen && req_wmask[0]) begin
                            console_valid_q <= 1'b1;
                            console_byte_q  <= req_wdata[7:0];
                        end
                    end
                    ADDR_EXIT: begin
                        if (req_wen) begin
                            exit_valid_q <= 1'b1;
                            exit_code_q  <= req_wdata;
                        end
                    end
                    ADDR_STATUS: begin
                        rsp_rdata_q <= 32'd0;
                    end
                    default: begin
                        rsp_fault_q <= 1'b1;
                    end
                endcase
            end
        end
    end

endmodule
