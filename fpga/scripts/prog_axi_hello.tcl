# -----------------------------------------------------------------------------
# prog_axi_hello.tcl
# Program the Urbana (xc7s50) with axi_hello.bit over JTAG.
# -----------------------------------------------------------------------------

if {[info exists ::env(BITSTREAM)]} {
    set bitstream [file normalize $::env(BITSTREAM)]
} else {
    set script_dir [file normalize [file dirname [info script]]]
    set bitstream  [file normalize [file join $script_dir .. build axi_hello axi_hello.bit]]
}

if {![file exists $bitstream]} {
    puts "ERROR: bitstream not found: $bitstream"
    puts "       run `make synth` first or set BITSTREAM=/path/to/axi_hello.bit"
    exit 1
}

puts "==> prog_axi_hello: bitstream = $bitstream"

open_hw_manager
connect_hw_server
open_hw_target

set all_devices [get_hw_devices]
set target_dev  ""
foreach dev $all_devices {
    set dev_name [get_property PART $dev]
    puts "==> prog_axi_hello: found device: $dev  (part=$dev_name)"
    if {[string match "xc7s50*" $dev_name]} {
        set target_dev $dev
        break
    }
}

if {$target_dev eq ""} {
    puts "ERROR: no xc7s50 device found on the JTAG chain"
    close_hw_target
    disconnect_hw_server
    exit 1
}

puts "==> prog_axi_hello: programming $target_dev with $bitstream"

current_hw_device $target_dev
set_property PROGRAM.FILE $bitstream $target_dev
program_hw_devices $target_dev

puts "==> prog_axi_hello: done"

close_hw_target
disconnect_hw_server
