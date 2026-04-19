# Generates the Stage 7b IP cores only — useful for checking the produced
# Verilog wrappers / port lists before wiring the top.
#
# Run from /home/lain/qianyu/riscv_soc/fpga/axi_hello/ with:
#   vivado -mode batch -source ../scripts/gen_ip_only.tcl

set hello_dir [file normalize [pwd]]
set fpga_dir  [file normalize [file join $hello_dir ..]]
set repo_dir  [file normalize [file join $fpga_dir  ..]]

set build_dir [file join $fpga_dir build axi_hello]
set ip_dir    [file join $build_dir ip]
set part      xc7s50csga324-1
set mig_prj_file [file join $fpga_dir ip mig_urbana.prj]

file mkdir $ip_dir
cd $build_dir

set_part $part

create_ip -vlnv xilinx.com:ip:axi_uartlite:2.0 -module_name axi_uartlite_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.C_BAUDRATE           {115200} \
    CONFIG.C_S_AXI_ACLK_FREQ_HZ {166666667} \
    CONFIG.C_DATA_BITS          {8} \
    CONFIG.C_USE_PARITY         {0} \
    CONFIG.C_ODD_PARITY         {0} \
] [get_ips axi_uartlite_0]
generate_target {synthesis simulation} [get_ips axi_uartlite_0]

create_ip -vlnv xilinx.com:ip:axi_crossbar:2.1 -module_name axi_crossbar_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.NUM_SI             {1} \
    CONFIG.NUM_MI             {2} \
    CONFIG.PROTOCOL           {AXI4} \
    CONFIG.DATA_WIDTH         {32} \
    CONFIG.ADDR_WIDTH         {32} \
    CONFIG.ID_WIDTH           {4} \
    CONFIG.STRATEGY           {1} \
    CONFIG.R_REGISTER         {1} \
    CONFIG.S00_SINGLE_THREAD  {1} \
    CONFIG.M00_A00_BASE_ADDR  {0x0000000040000000} \
    CONFIG.M00_A00_ADDR_WIDTH {27} \
    CONFIG.M01_A00_BASE_ADDR  {0x00000000C0000000} \
    CONFIG.M01_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]
generate_target {synthesis simulation} [get_ips axi_crossbar_0]

create_ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 -module_name axi_protocol_converter_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.SI_PROTOCOL     {AXI4} \
    CONFIG.MI_PROTOCOL     {AXI4LITE} \
    CONFIG.DATA_WIDTH      {32} \
    CONFIG.ADDR_WIDTH      {32} \
    CONFIG.ID_WIDTH        {4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
] [get_ips axi_protocol_converter_0]
generate_target {synthesis simulation} [get_ips axi_protocol_converter_0]

create_ip -vlnv xilinx.com:ip:mig_7series:4.2 -module_name mig_ddr3_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.XML_INPUT_FILE        $mig_prj_file \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM  {Custom} \
    CONFIG.BOARD_MIG_PARAM       {Custom} \
] [get_ips mig_ddr3_0]
generate_target {synthesis simulation} [get_ips mig_ddr3_0]

puts "==> gen_ip_only: done. IPs under $ip_dir"
