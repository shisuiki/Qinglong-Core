# -----------------------------------------------------------------------------
# build_axi_hello.tcl
# Non-project Vivado build flow for the Stage 5 AXI-UART hello SoC on Urbana.
#
# Invoked from /home/lain/qianyu/riscv_soc/fpga/axi_hello/ via:
#   vivado -mode batch -source ../scripts/build_axi_hello.tcl
#
# Differences vs build_hello.tcl:
#   - targets `axi_hello_top` (which exposes the soc_top AXI-Lite master port)
#   - creates AMD `axi_uartlite` IP (module axi_uartlite_0) in the Vivado
#     managed-IP cache under $build/ip, synthesises it OOC, and links it
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
    [file join $repo_dir rtl mem  sram_dp.sv]         \
    [file join $repo_dir rtl soc  mmio.sv]            \
    [file join $repo_dir rtl soc  clint.sv]           \
    [file join $repo_dir rtl soc  axi_lite_master.sv] \
    [file join $repo_dir rtl soc  soc_top.sv]         \
    [file join $repo_dir rtl fpga axi_hello_top.sv]   \
]
set src_xdc [file join $fpga_dir constraints urbana_axi_hello.xdc]
set inc_dir [file join $repo_dir rtl core]

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

# -----------------------------------------------------------------------------
# Managed-IP project (just to carry the IP generation). Non-project flow below
# consumes the generated IP synthesis outputs.
# -----------------------------------------------------------------------------
set_part $part

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
# Source RTL
# -----------------------------------------------------------------------------
foreach f $src_list {
    puts "==> build_axi_hello: read_verilog -sv $f"
    read_verilog -sv $f
}
read_xdc $src_xdc

# Bring the IP's synthesized checkpoint and wrapper into the design.
read_ip [file join $ip_dir axi_uartlite_0 axi_uartlite_0.xci]

set use_pipeline 0
if {[info exists ::env(USE_PIPELINE_CORE)] && $::env(USE_PIPELINE_CORE) ne "" && $::env(USE_PIPELINE_CORE) ne "0"} {
    set use_pipeline 1
    puts "==> build_axi_hello: core       = pipeline (USE_PIPELINE_CORE)"
} else {
    puts "==> build_axi_hello: core       = multicycle (default)"
}

if {$use_pipeline} {
    synth_design -top $top -part $part -include_dirs $inc_dir \
                 -generic SRAM_INIT_FILE=$init_file \
                 -verilog_define USE_PIPELINE_CORE
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
