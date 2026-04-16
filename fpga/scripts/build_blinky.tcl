# -----------------------------------------------------------------------------
# build_blinky.tcl
# Non-project Vivado build flow for the SP701 blinky smoke test.
#
# Invoked from /home/lain/qianyu/riscv_soc/fpga/blinky/ via:
#   vivado -mode batch -nojournal -nolog -source ../scripts/build_blinky.tcl
#
# Drops all intermediates (checkpoints, reports, log/journal, bitstream) into
# ./build/ so the tree stays clean and git-friendly.
# -----------------------------------------------------------------------------

# Resolve paths relative to the directory this script is invoked from (expected
# to be .../fpga/blinky). Using absolute paths makes the build re-runnable from
# anywhere and survives the `cd build` below.
set blinky_dir [file normalize [pwd]]
set fpga_dir   [file normalize [file join $blinky_dir ..]]

set src_sv     [file join $blinky_dir    blinky_top.sv]
set src_xdc    [file join $fpga_dir      constraints sp701_blinky.xdc]

set build_dir  [file join $blinky_dir build]

set part       xc7s100fgga676-2
set top        blinky_top

# -----------------------------------------------------------------------------
# Stage intermediates in build/
# -----------------------------------------------------------------------------
file mkdir $build_dir
cd $build_dir

puts "==> build_blinky: blinky_dir = $blinky_dir"
puts "==> build_blinky: build_dir  = $build_dir"
puts "==> build_blinky: part       = $part"
puts "==> build_blinky: top        = $top"
puts "==> build_blinky: src_sv     = $src_sv"
puts "==> build_blinky: src_xdc    = $src_xdc"

# -----------------------------------------------------------------------------
# Read sources
# -----------------------------------------------------------------------------
read_verilog -sv $src_sv
read_xdc         $src_xdc

# -----------------------------------------------------------------------------
# Synthesis
# -----------------------------------------------------------------------------
synth_design -top $top -part $part
write_checkpoint -force post_synth.dcp
report_utilization -file post_synth_util.rpt

# -----------------------------------------------------------------------------
# Implementation
# -----------------------------------------------------------------------------
opt_design
place_design
route_design

write_checkpoint -force post_route.dcp

# -----------------------------------------------------------------------------
# Reports
# -----------------------------------------------------------------------------
report_timing_summary -file timing.rpt
report_utilization    -file util.rpt

# -----------------------------------------------------------------------------
# Bitstream
# -----------------------------------------------------------------------------
write_bitstream -force blinky.bit

puts "==> build_blinky: done. Outputs in $build_dir"
