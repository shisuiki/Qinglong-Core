# -----------------------------------------------------------------------------
# build_hello.tcl
# Non-project Vivado build flow for the SP701 hello-world SoC.
#
# Invoked from /home/lain/qianyu/riscv_soc/fpga/hello/ via:
#   vivado -mode batch -source ../scripts/build_hello.tcl
#
# Reads every core/mem/soc RTL file plus the FPGA top + XDC, passes
# SRAM_INIT_FILE down to soc_top so hello.mem gets baked into the BRAM at
# bitgen time.  All outputs in $repo/fpga/build/hello/.
# -----------------------------------------------------------------------------

set hello_dir [file normalize [pwd]]
set fpga_dir  [file normalize [file join $hello_dir ..]]
set repo_dir  [file normalize [file join $fpga_dir  ..]]

set build_dir [file join $fpga_dir build hello]
set part      xc7s50csga324-1
set top       hello_top

# Core + mem + soc RTL (order doesn't matter for Vivado, but we keep it
# consistent with sim/Makefile for grep-ability).
set src_list [list \
    [file join $repo_dir rtl core alu.sv]             \
    [file join $repo_dir rtl core imm_gen.sv]         \
    [file join $repo_dir rtl core regfile.sv]         \
    [file join $repo_dir rtl core csr.sv]             \
    [file join $repo_dir rtl core mul_unit.sv]        \
    [file join $repo_dir rtl core div_unit.sv]        \
    [file join $repo_dir rtl core core_multicycle.sv] \
    [file join $repo_dir rtl mem  sram_dp.sv]         \
    [file join $repo_dir rtl soc  mmio.sv]            \
    [file join $repo_dir rtl soc  uart_tx.sv]         \
    [file join $repo_dir rtl soc  soc_top.sv]         \
    [file join $repo_dir rtl fpga hello_top.sv]       \
]
set src_xdc [file join $fpga_dir constraints urbana_hello.xdc]
set inc_dir [file join $repo_dir rtl core]

# BRAM init image — passed to `synth_design -generic SRAM_INIT_FILE=...`.
if {[info exists ::env(SRAM_INIT_FILE)]} {
    set init_file [file normalize $::env(SRAM_INIT_FILE)]
} else {
    set init_file [file join $hello_dir hello.mem]
}
if {![file exists $init_file]} {
    puts "ERROR: SRAM init file not found: $init_file"
    puts "       run `make hello.mem` first (or set SRAM_INIT_FILE)"
    exit 1
}

file mkdir $build_dir
cd $build_dir

puts "==> build_hello: repo_dir   = $repo_dir"
puts "==> build_hello: build_dir  = $build_dir"
puts "==> build_hello: part       = $part"
puts "==> build_hello: top        = $top"
puts "==> build_hello: init_file  = $init_file"

foreach f $src_list {
    puts "==> build_hello: read_verilog -sv $f"
    read_verilog -sv $f
}
read_xdc $src_xdc

# Pass the init file down via generic.  sram_dp.sv has `parameter INIT_FILE ""`;
# soc_top forwards it as SRAM_INIT_FILE.
synth_design -top $top -part $part -include_dirs $inc_dir \
             -generic SRAM_INIT_FILE=$init_file
write_checkpoint -force post_synth.dcp
report_utilization -file post_synth_util.rpt

opt_design
place_design
route_design

write_checkpoint -force post_route.dcp

report_timing_summary -file timing.rpt
report_utilization    -file util.rpt

write_bitstream -force hello.bit

puts "==> build_hello: done. Outputs in $build_dir"
