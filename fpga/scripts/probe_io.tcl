open_checkpoint /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/post_synth.dcp

set fp [open /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/probe_io.txt w]

puts $fp "===== lane_D ISERDES/OSERDES/IDELAY placements (expected X1 column) ====="
foreach c [get_cells -hier -filter {NAME =~ *byte_lane_D*iserdes* || NAME =~ *byte_lane_D*oserdes* || NAME =~ *byte_lane_D*idelay*}] {
    set loc [get_property LOC $c]
    set bel [get_property BEL $c]
    set ref [get_property REF_NAME $c]
    puts $fp [format "%-120s REF=%-15s LOC=%-20s BEL=%s" $c $ref $loc $bel]
}

puts $fp ""
puts $fp "===== M5 (ddr3_reset_n) IOB ====="
set m5_sites [get_sites -of_objects [get_package_pins M5]]
foreach s $m5_sites {
    set reg ""
    catch {set reg [get_property CLOCK_REGION $s]}
    puts $fp "M5 site: $s  REGION=$reg"
}

puts $fp ""
puts $fp "===== all ddr3_reset_n / unplaced iserdes/oserdes for lane D ====="
foreach c [get_cells -hier -filter {NAME =~ *ddr3_reset_n* || NAME =~ *byte_lane_D*output_\[0\]* || NAME =~ *byte_lane_D*input_\[0\]*}] {
    set loc [get_property LOC $c]
    set bel [get_property BEL $c]
    set ref [get_property REF_NAME $c]
    puts $fp [format "%-130s REF=%-15s LOC=%-20s BEL=%s" $c $ref $loc $bel]
}

puts $fp ""
puts $fp "===== nets driven by PHASER_*_PHY_X1Y3 ====="
foreach c [get_cells -hier -filter {LOC =~ PHASER_*_X1Y3}] {
    set loc [get_property LOC $c]
    set ref [get_property REF_NAME $c]
    puts $fp [format "%-110s REF=%-15s LOC=%s" $c $ref $loc]
}

close $fp
close_design
