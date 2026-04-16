# -----------------------------------------------------------------------------
# build_blinky.tcl
# Non-project Vivado build flow for the SP701 blinky smoke test.
#
# Invoked from /home/lain/qianyu/riscv_soc/fpga/blinky/ via:
#   vivado -mode batch -source ../scripts/build_blinky.tcl
#
# All intermediates (checkpoints, reports, log/journal, bitstream) go into
# $repo/fpga/build/blinky/ so that rtl/ stays RTL-only and fpga/blinky/
# stays Makefile-only.
# -----------------------------------------------------------------------------

set blinky_dir [file normalize [pwd]]
set fpga_dir   [file normalize [file join $blinky_dir ..]]
set repo_dir   [file normalize [file join $fpga_dir   ..]]

set src_sv     [file join $repo_dir rtl fpga blinky_top.sv]
set src_xdc    [file join $fpga_dir constraints urbana_blinky.xdc]

set build_dir  [file join $fpga_dir build blinky]

set part       xc7s50csga324-1
set top        blinky_top

file mkdir $build_dir
cd $build_dir

puts "==> build_blinky: repo_dir   = $repo_dir"
puts "==> build_blinky: build_dir  = $build_dir"
puts "==> build_blinky: part       = $part"
puts "==> build_blinky: top        = $top"
puts "==> build_blinky: src_sv     = $src_sv"
puts "==> build_blinky: src_xdc    = $src_xdc"

read_verilog -sv $src_sv
read_xdc         $src_xdc

synth_design -top $top -part $part
write_checkpoint -force post_synth.dcp
report_utilization -file post_synth_util.rpt

opt_design
place_design
route_design

write_checkpoint -force post_route.dcp

report_timing_summary -file timing.rpt
report_utilization    -file util.rpt

write_bitstream -force blinky.bit

puts "==> build_blinky: done. Outputs in $build_dir"
