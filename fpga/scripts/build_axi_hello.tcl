# -----------------------------------------------------------------------------
# build_axi_hello.tcl
# Non-project Vivado build flow for the Stage 7b AXI-UART + DDR3 SoC on Urbana.
#
# Invoked from /home/lain/qianyu/riscv_soc/fpga/axi_hello/ via:
#   vivado -mode batch -source ../scripts/build_axi_hello.tcl
#
# Differences vs the Stage 7a TCL:
#   - drops the standalone axi_protocol_converter (the crossbar handles that
#     inline for the UartLite master)
#   - adds AMD `axi_crossbar` (1 SI, 2 MI: MIG @ 0x4000_0000, Uart @ 0xC000_0000)
#   - adds AMD `mig_7series` configured from $repo/fpga/ip/mig_urbana.prj
# -----------------------------------------------------------------------------

set hello_dir [file normalize [pwd]]
set fpga_dir  [file normalize [file join $hello_dir ..]]
set repo_dir  [file normalize [file join $fpga_dir  ..]]

set build_dir [file join $fpga_dir build axi_hello]
set ip_dir    [file join $build_dir ip]
set part      xc7s50csga324-1
set top       axi_hello_top

set src_list [list \
    [file join $repo_dir rtl core alu.sv]             \
    [file join $repo_dir rtl core imm_gen.sv]         \
    [file join $repo_dir rtl core regfile.sv]         \
    [file join $repo_dir rtl core csr.sv]             \
    [file join $repo_dir rtl core mul_unit.sv]        \
    [file join $repo_dir rtl core div_unit.sv]        \
    [file join $repo_dir rtl core core_multicycle.sv] \
    [file join $repo_dir rtl core core_pipeline.sv]   \
    [file join $repo_dir rtl core mmu.sv]             \
    [file join $repo_dir rtl core pmp.sv]             \
    [file join $repo_dir rtl mem   sram_dp.sv]        \
    [file join $repo_dir rtl cache icache.sv]         \
    [file join $repo_dir rtl cache dcache.sv]         \
    [file join $repo_dir rtl soc   mmio.sv]           \
    [file join $repo_dir rtl soc   clint.sv]          \
    [file join $repo_dir rtl soc   plic.sv]           \
    [file join $repo_dir rtl soc   axi4_master.sv]    \
    [file join $repo_dir rtl soc   soc_top.sv]        \
    [file join $repo_dir rtl fpga  axi_hello_top.sv]  \
]
set src_xdc      [file join $fpga_dir constraints urbana_axi_hello.xdc]
set inc_dir      [file join $repo_dir rtl core]
set mig_prj_file [file join $fpga_dir ip mig_urbana.prj]

if {[info exists ::env(SRAM_INIT_FILE)]} {
    set init_file [file normalize $::env(SRAM_INIT_FILE)]
} else {
    set init_file [file join $hello_dir hello_axi.mem]
}
if {![file exists $init_file]} {
    puts "ERROR: SRAM init file not found: $init_file"
    puts "       run `make hello_axi.mem` first (or set SRAM_INIT_FILE)"
    exit 1
}

file mkdir $build_dir
file mkdir $ip_dir
cd $build_dir

puts "==> build_axi_hello: repo_dir   = $repo_dir"
puts "==> build_axi_hello: build_dir  = $build_dir"
puts "==> build_axi_hello: part       = $part"
puts "==> build_axi_hello: top        = $top"
puts "==> build_axi_hello: init_file  = $init_file"
puts "==> build_axi_hello: mig_prj    = $mig_prj_file"

set_part $part

# -----------------------------------------------------------------------------
# axi_uartlite — 115200 8N1 on soc_clk (50 MHz).
# -----------------------------------------------------------------------------
create_ip -vlnv xilinx.com:ip:axi_uartlite:2.0 -module_name axi_uartlite_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.C_BAUDRATE           {115200} \
    CONFIG.C_S_AXI_ACLK_FREQ_HZ {50000000} \
    CONFIG.C_DATA_BITS          {8} \
    CONFIG.C_USE_PARITY         {0} \
    CONFIG.C_ODD_PARITY         {0} \
] [get_ips axi_uartlite_0]
generate_target {synthesis simulation} [get_ips axi_uartlite_0]
synth_ip [get_ips axi_uartlite_0]

# -----------------------------------------------------------------------------
# axi_crossbar — 2 slaves (S00 = soc_top AXI master, S01 = JTAG-to-AXI master)
#                2 masters (M00 = MIG, M01 = UartLite).
# PROTOCOL = AXI4 on both sides; UartLite is downgraded by a downstream
# axi_protocol_converter on the M01 path.
#   M00 → MIG  @ 0x4000_0000 / 128 MB
#   M01 → Uart @ 0xC000_0000 / 4 KB
# -----------------------------------------------------------------------------
create_ip -vlnv xilinx.com:ip:axi_crossbar:2.1 -module_name axi_crossbar_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.NUM_SI             {2} \
    CONFIG.NUM_MI             {2} \
    CONFIG.PROTOCOL           {AXI4} \
    CONFIG.DATA_WIDTH         {32} \
    CONFIG.ADDR_WIDTH         {32} \
    CONFIG.ID_WIDTH           {4} \
    CONFIG.STRATEGY           {1} \
    CONFIG.R_REGISTER         {1} \
    CONFIG.S00_SINGLE_THREAD  {1} \
    CONFIG.S01_SINGLE_THREAD  {1} \
    CONFIG.M00_A00_BASE_ADDR  {0x0000000040000000} \
    CONFIG.M00_A00_ADDR_WIDTH {27} \
    CONFIG.M01_A00_BASE_ADDR  {0x00000000C0000000} \
    CONFIG.M01_A00_ADDR_WIDTH {12} \
] [get_ips axi_crossbar_0]
generate_target {synthesis simulation} [get_ips axi_crossbar_0]
synth_ip [get_ips axi_crossbar_0]

# -----------------------------------------------------------------------------
# JTAG-to-AXI Master — lets Vivado (or vivado_lab) push 32-bit words into the
# AXI fabric over JTAG, used to stage OpenSBI + kernel + DTB into DDR before
# kicking the BootROM. AXI4, 32-bit data, 32-bit addr, ID width matches the
# crossbar (4). Runs on soc_clk (its BSCAN CDC is internal).
# -----------------------------------------------------------------------------
create_ip -vlnv xilinx.com:ip:jtag_axi:1.2 -module_name jtag_axi_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.PROTOCOL         {0} \
    CONFIG.M_AXI_DATA_WIDTH {32} \
    CONFIG.M_AXI_ADDR_WIDTH {32} \
    CONFIG.M_AXI_ID_WIDTH   {1} \
    CONFIG.M_HAS_BURST      {1} \
] [get_ips jtag_axi_0]
generate_target {synthesis simulation} [get_ips jtag_axi_0]
synth_ip [get_ips jtag_axi_0]

# -----------------------------------------------------------------------------
# axi_protocol_converter — sits between the crossbar's M01 (AXI4) and the
# axi_uartlite (AXI4-Lite-only) slave.
# -----------------------------------------------------------------------------
create_ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 -module_name axi_protocol_converter_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.SI_PROTOCOL    {AXI4} \
    CONFIG.MI_PROTOCOL    {AXI4LITE} \
    CONFIG.DATA_WIDTH     {32} \
    CONFIG.ADDR_WIDTH     {32} \
    CONFIG.ID_WIDTH       {4} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} \
] [get_ips axi_protocol_converter_0]
generate_target {synthesis simulation} [get_ips axi_protocol_converter_0]
synth_ip [get_ips axi_protocol_converter_0]

# -----------------------------------------------------------------------------
# axi_clock_converter — crosses xbar M00 (soc_clk, 50 MHz) → MIG s_axi
# (ui_clk, ~166.7 MHz). AXI4-full, 32-bit data, 27-bit addr to match MIG, ID=0
# because the crossbar drops IDs (NUM_SI=1).
# -----------------------------------------------------------------------------
create_ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 -module_name axi_clock_converter_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.PROTOCOL   {AXI4} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.ID_WIDTH   {0} \
    CONFIG.ACLK_ASYNC {1} \
] [get_ips axi_clock_converter_0]
generate_target {synthesis simulation} [get_ips axi_clock_converter_0]
synth_ip [get_ips axi_clock_converter_0]

# -----------------------------------------------------------------------------
# MIG7 DDR3L controller — config in fpga/ip/mig_urbana.prj
# -----------------------------------------------------------------------------
create_ip -vlnv xilinx.com:ip:mig_7series:4.2 -module_name mig_ddr3_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.XML_INPUT_FILE     $mig_prj_file \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM  {Custom} \
    CONFIG.BOARD_MIG_PARAM       {Custom} \
] [get_ips mig_ddr3_0]
generate_target {synthesis simulation} [get_ips mig_ddr3_0]

# MIG 4.2 spuriously marks bit 36 of PHY_0_BITLANES = 1 for the Urbana pinout,
# treating ddr3_reset_n's IOB (M5 = IOB_X1Y37) as a DQ slot and emitting an
# unplaceable ISERDES/OSERDES pair in byte_lane_D slot 0. Clear that bit in
# the generated RTL before synth_ip so the SERDES are never instantiated.
set mig_rtl [file join $ip_dir mig_ddr3_0 mig_ddr3_0 user_design rtl mig_ddr3_0_mig.v]
if {[file exists $mig_rtl]} {
    set fh [open $mig_rtl r]; set content [read $fh]; close $fh
    set patched [regsub {PHY_0_BITLANES(\s+)=(\s+)48'h3FF_3FE_FFF_B7B} $content {PHY_0_BITLANES\1=\2 48'h3FE_3FE_FFF_B7B} content]
    if {$patched > 0} {
        set fh [open $mig_rtl w]; puts -nonewline $fh $content; close $fh
        puts "==> build_axi_hello: patched PHY_0_BITLANES (cleared bit 36, Urbana ddr3_reset_n workaround)"
    } else {
        puts "==> build_axi_hello: WARNING — PHY_0_BITLANES pattern not matched in $mig_rtl"
    }
} else {
    puts "==> build_axi_hello: WARNING — $mig_rtl missing; BITLANES patch skipped"
}

synth_ip [get_ips mig_ddr3_0]

# -----------------------------------------------------------------------------
# Source RTL
# -----------------------------------------------------------------------------
foreach f $src_list {
    puts "==> build_axi_hello: read_verilog -sv $f"
    read_verilog -sv $f
}
read_xdc $src_xdc

read_ip [file join $ip_dir axi_uartlite_0           axi_uartlite_0.xci]
read_ip [file join $ip_dir axi_crossbar_0           axi_crossbar_0.xci]
read_ip [file join $ip_dir jtag_axi_0               jtag_axi_0.xci]
read_ip [file join $ip_dir axi_protocol_converter_0 axi_protocol_converter_0.xci]
read_ip [file join $ip_dir axi_clock_converter_0    axi_clock_converter_0.xci]
read_ip [file join $ip_dir mig_ddr3_0               mig_ddr3_0.xci]

set use_pipeline 0
if {[info exists ::env(USE_PIPELINE_CORE)] && $::env(USE_PIPELINE_CORE) ne "" && $::env(USE_PIPELINE_CORE) ne "0"} {
    set use_pipeline 1
    puts "==> build_axi_hello: core       = pipeline (USE_PIPELINE_CORE)"
} else {
    puts "==> build_axi_hello: core       = multicycle (default)"
}

set use_icache 0
if {[info exists ::env(USE_ICACHE)] && $::env(USE_ICACHE) ne "" && $::env(USE_ICACHE) ne "0"} {
    set use_icache 1
    puts "==> build_axi_hello: icache     = on (USE_ICACHE)"
}
set use_dcache 0
if {[info exists ::env(USE_DCACHE)] && $::env(USE_DCACHE) ne "" && $::env(USE_DCACHE) ne "0"} {
    set use_dcache 1
    puts "==> build_axi_hello: dcache     = on (USE_DCACHE)"
}

set verilog_defines [list]
if {$use_pipeline} { lappend verilog_defines USE_PIPELINE_CORE }
if {$use_icache}   { lappend verilog_defines USE_ICACHE }
if {$use_dcache}   { lappend verilog_defines USE_DCACHE }

if {[llength $verilog_defines] > 0} {
    set verilog_define_args [list]
    foreach d $verilog_defines { lappend verilog_define_args -verilog_define $d }
    synth_design -top $top -part $part -include_dirs $inc_dir \
                 -generic SRAM_INIT_FILE=$init_file \
                 {*}$verilog_define_args
} else {
    synth_design -top $top -part $part -include_dirs $inc_dir \
                 -generic SRAM_INIT_FILE=$init_file
}
write_checkpoint -force post_synth.dcp
report_utilization -file post_synth_util.rpt

opt_design
place_design
route_design

write_checkpoint -force post_route.dcp

report_timing_summary -file timing.rpt
report_utilization    -file util.rpt

write_bitstream -force axi_hello.bit

puts "==> build_axi_hello: done. Outputs in $build_dir"
