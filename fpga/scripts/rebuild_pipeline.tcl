# Re-synthesize top + P&R with the pipelined core, reusing already-built IPs.
# Flip via env var USE_PIPELINE_CORE=1 so the same knob works here as in the
# full build script.
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
    [file join $repo_dir rtl soc   axi4_master.sv]    \
    [file join $repo_dir rtl soc   soc_top.sv]        \
    [file join $repo_dir rtl fpga  axi_hello_top.sv]  \
]
set src_xdc [file join $fpga_dir constraints urbana_axi_hello.xdc]
set inc_dir [file join $repo_dir rtl core]

if {[info exists ::env(SRAM_INIT_FILE)]} {
    set init_file [file normalize $::env(SRAM_INIT_FILE)]
} else {
    set init_file [file join $hello_dir hello_axi.mem]
}
if {![file exists $init_file]} {
    puts "ERROR: init file not found: $init_file"
    exit 1
}

cd $build_dir
set_part $part

foreach f $src_list { read_verilog -sv $f }
read_xdc $src_xdc

read_ip [file join $ip_dir axi_uartlite_0           axi_uartlite_0.xci]
read_ip [file join $ip_dir axi_crossbar_0           axi_crossbar_0.xci]
read_ip [file join $ip_dir axi_protocol_converter_0 axi_protocol_converter_0.xci]
read_ip [file join $ip_dir axi_clock_converter_0    axi_clock_converter_0.xci]
read_ip [file join $ip_dir mig_ddr3_0               mig_ddr3_0.xci]

set use_pipeline 0
if {[info exists ::env(USE_PIPELINE_CORE)] && $::env(USE_PIPELINE_CORE) ne "" && $::env(USE_PIPELINE_CORE) ne "0"} {
    set use_pipeline 1
    puts "==> rebuild_pipeline: core = pipeline"
} else {
    puts "==> rebuild_pipeline: core = multicycle"
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
report_utilization -file util.rpt
write_bitstream -force axi_hello.bit

puts "==> rebuild_pipeline: done."
