# -----------------------------------------------------------------------------
# prog_blinky.tcl
# Program the SP701 (xc7s100) with blinky.bit over JTAG.
#
# Expects the bitstream at ../blinky/build/blinky.bit relative to this script,
# or resolves it via the BITSTREAM environment variable if set.
# -----------------------------------------------------------------------------

# Locate the bitstream
if {[info exists ::env(BITSTREAM)]} {
    set bitstream [file normalize $::env(BITSTREAM)]
} else {
    set script_dir [file normalize [file dirname [info script]]]
    set bitstream  [file normalize [file join $script_dir .. build blinky blinky.bit]]
}

if {![file exists $bitstream]} {
    puts "ERROR: bitstream not found: $bitstream"
    puts "       run `make synth` first or set BITSTREAM=/path/to/blinky.bit"
    exit 1
}

puts "==> prog_blinky: bitstream = $bitstream"

# -----------------------------------------------------------------------------
# Connect to hw_server and open the target
# -----------------------------------------------------------------------------
open_hw_manager
connect_hw_server
open_hw_target

# -----------------------------------------------------------------------------
# Locate the first xc7s100 device on the chain
# -----------------------------------------------------------------------------
set all_devices [get_hw_devices]
set target_dev  ""
foreach dev $all_devices {
    set dev_name [get_property PART $dev]
    puts "==> prog_blinky: found device: $dev  (part=$dev_name)"
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

puts "==> prog_blinky: programming $target_dev with $bitstream"

current_hw_device      $target_dev
set_property PROGRAM.FILE $bitstream $target_dev
program_hw_devices     $target_dev

puts "==> prog_blinky: done"

close_hw_target
disconnect_hw_server
