# Read-only ILA data dump. Does not reprogram or reload DDR. Connects to
# hw_server, attaches the current .ltx probes, and uploads the ILA buffer
# as-is (whatever state it's in: armed, triggered, or captured).
#
# Usage:
#   vivado -mode batch -source ila_readback.tcl
#
# Env overrides:
#   ILA_OUT_DIR = ../build/axi_hello/ila_captures
#   LTX_FILE    = ../build/axi_hello/axi_hello.ltx

proc env_or_default {name default_val} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default_val
}

set script_dir [file normalize [file dirname [info script]]]
set repo_dir   [file normalize [file join $script_dir .. ..]]
set build_dir  [file normalize [file join $repo_dir fpga build axi_hello]]
set out_dir    [file normalize [env_or_default ILA_OUT_DIR [file join $build_dir ila_captures]]]
set ltx_file   [file normalize [env_or_default LTX_FILE    [file join $build_dir axi_hello.ltx]]]
file mkdir $out_dir
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
if {[file exists $ltx_file]} {
    set_property PROBES.FILE $ltx_file $dev
    set_property FULL_PROBES.FILE $ltx_file $dev
}
refresh_hw_device -quiet $dev

if {[llength [get_hw_ilas]] == 0} {
    puts "ERROR: no hw_ila visible."
    exit 1
}
set hw_ila [get_hw_ilas hw_ila_1]
puts "==> ila_readback: CORE_STATUS = [get_property CORE_STATUS $hw_ila]"
puts "==> ila_readback: TRIGGER_POSITION = [get_property CONTROL.TRIGGER_POSITION $hw_ila]"
puts "==> ila_readback: DATA_DEPTH = [get_property CONTROL.DATA_DEPTH $hw_ila]"
puts "==> ila_readback: SAMPLES_IN_WINDOW = [get_property CAPTURE.SAMPLES_IN_WINDOW $hw_ila]"

set rc [catch {upload_hw_ila_data $hw_ila} uerr]
if {$rc != 0} {
    puts "ERROR: upload_hw_ila_data failed: $uerr"
    # Try again with wait_on first
    catch {wait_on_hw_ila -timeout 0.05 $hw_ila}
    catch {upload_hw_ila_data $hw_ila} uerr2
    puts "retry: $uerr2"
} else {
    puts "==> ila_readback: data uploaded"
}

set data [current_hw_ila_data]
if {$data eq ""} {
    puts "ERROR: no current data to dump"
    exit 1
}

set csv [file join $out_dir "rb_${stamp}.csv"]
set vcd [file join $out_dir "rb_${stamp}.vcd"]
set ila [file join $out_dir "rb_${stamp}.ila"]
catch {write_hw_ila_data -force -csv_file $csv $data} e1
catch {write_hw_ila_data -force -vcd_file $vcd $data} e2
catch {write_hw_ila_data -force $ila $data} e3
puts "==> ila_readback: wrote $csv $vcd $ila  (errors: $e1 | $e2 | $e3)"

close_hw_target
disconnect_hw_server
