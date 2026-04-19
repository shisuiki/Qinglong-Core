# Rebuild after patching PHY_0_BITLANES in mig_ddr3_0_mig.v.
# Reuses pre-generated IPs, just re-synthesizes and re-P&Rs.

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

set init_file [file join $hello_dir hello_axi.mem]
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
read_ip [file join $ip_dir mig_ddr3_0               mig_ddr3_0.xci]

# Force re-synth of mig_ddr3_0 so the patched PHY_0_BITLANES takes effect.
# MIG 4.2 spuriously marks bit 36 of PHY_0_BITLANES = 1 for Urbana, treating
# ddr3_reset_n's IOB as a DQ slot and emitting an unplaceable ISERDES/OSERDES
# in byte_lane_D. Clearing that bit makes MIG skip slot 0 generation.
reset_target {synthesis} [get_ips mig_ddr3_0]
generate_target {synthesis} [get_ips mig_ddr3_0]

set mig_rtl [file join $ip_dir mig_ddr3_0 mig_ddr3_0 user_design rtl mig_ddr3_0_mig.v]
set fh [open $mig_rtl r]; set content [read $fh]; close $fh
set patched [regsub {PHY_0_BITLANES(\s+)=(\s+)48'h3FF_3FE_FFF_B7B} $content {PHY_0_BITLANES\1=\2 48'h3FE_3FE_FFF_B7B} content]
if {$patched > 0} {
    set fh [open $mig_rtl w]; puts -nonewline $fh $content; close $fh
    puts "==> rebuild: patched PHY_0_BITLANES (cleared bit 36, Urbana ddr3_reset_n workaround)"
} else {
    puts "==> rebuild: WARNING — PHY_0_BITLANES pattern not matched; mig_ddr3_0_mig.v may have been regenerated to a different value"
}

synth_ip [get_ips mig_ddr3_0]

synth_design -top $top -part $part -include_dirs $inc_dir \
             -generic SRAM_INIT_FILE=$init_file
write_checkpoint -force post_synth.dcp
report_utilization -file post_synth_util.rpt

opt_design
place_design
route_design

write_checkpoint -force post_route.dcp
report_timing_summary -file timing.rpt
report_utilization -file util.rpt
write_bitstream -force axi_hello.bit

puts "==> rebuild_after_patch: done."
