open_checkpoint /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/post_synth.dcp

set fp [open /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/probe_lane_c.txt w]

puts $fp "===== ALL byte_lane_C cells (ISERDES/OSERDES/IDELAY/IOB) with placement ====="
foreach c [lsort [get_cells -hier -filter {NAME =~ *byte_lane_C*}]] {
    set loc [get_property LOC $c]
    set bel [get_property BEL $c]
    set ref [get_property REF_NAME $c]
    if {$ref == "LUT1" || $ref == "LUT2" || $ref == "LUT3" || $ref == "LUT4" || $ref == "LUT5" || $ref == "LUT6"} { continue }
    if {$ref == "FDRE" || $ref == "FDCE" || $ref == "FDPE" || $ref == "FDSE"} { continue }
    puts $fp [format "%-140s REF=%-15s LOC=%-20s BEL=%s" $c $ref $loc $bel]
}

puts $fp ""
puts $fp "===== ALL byte_lane_D cells (excluding LUTs/FFs) ====="
foreach c [lsort [get_cells -hier -filter {NAME =~ *byte_lane_D*}]] {
    set loc [get_property LOC $c]
    set bel [get_property BEL $c]
    set ref [get_property REF_NAME $c]
    if {$ref == "LUT1" || $ref == "LUT2" || $ref == "LUT3" || $ref == "LUT4" || $ref == "LUT5" || $ref == "LUT6"} { continue }
    if {$ref == "FDRE" || $ref == "FDCE" || $ref == "FDPE" || $ref == "FDSE"} { continue }
    puts $fp [format "%-140s REF=%-15s LOC=%-20s BEL=%s" $c $ref $loc $bel]
}

close $fp
close_design
