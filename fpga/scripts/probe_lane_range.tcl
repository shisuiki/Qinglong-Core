open_checkpoint /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/post_synth.dcp

set fp [open /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/probe_lane_range.txt w]

puts $fp "===== Which IOB sites are in each PHASER's byte-lane group (bank 34) ====="
foreach phaser [get_sites -filter {NAME =~ PHASER_IN_PHY_X1Y*}] {
    set tile [get_tiles -of_objects $phaser]
    puts $fp "PHASER $phaser   TILE=$tile"
}

puts $fp ""
puts $fp "===== Check which Y range each lane is known by MIG ====="
puts $fp "Looking at lane C's byte_group_io / PHASER_OUT_PHY LOC..."
foreach c [get_cells -hier -filter {NAME =~ *byte_lane_C*phaser_out || NAME =~ *byte_lane_C*phaser_in}] {
    set loc [get_property LOC $c]
    set ref [get_property REF_NAME $c]
    puts $fp [format "  %s  REF=%s  LOC=%s" $c $ref $loc]
}
foreach c [get_cells -hier -filter {NAME =~ *byte_lane_D*phaser_out || NAME =~ *byte_lane_D*phaser_in}] {
    set loc [get_property LOC $c]
    set ref [get_property REF_NAME $c]
    puts $fp [format "  %s  REF=%s  LOC=%s" $c $ref $loc]
}

puts $fp ""
puts $fp "===== Every site at IOB_X1Y23..Y49, look up what's in the tile (which byte lane) ====="
for {set y 23} {$y <= 49} {incr y} {
    set site [get_sites IOB_X1Y${y}]
    if {[llength $site] == 0} { continue }
    set tile [get_tiles -of_objects $site]
    puts $fp [format "IOB_X1Y%-3d  tile=%s" $y $tile]
}

close $fp
close_design
