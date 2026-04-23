# Minimal loader: write a tiny DDR-resident hello binary and fire the BootROM
# handshake. Proves the boot chain (JTAG→AXI→DDR→ifetch→UART) without paying
# the 30 MB Linux-image cost.

set script_dir [file normalize [file dirname [info script]]]
set repo_dir   [file normalize [file join $script_dir .. ..]]
set bin        [file join $repo_dir sw ddr-hello ddr_hello.bin]

if {![file exists $bin]} {
    puts "ERROR: $bin not found. Run `make -C sw/ddr-hello` first."
    exit 1
}

proc read_file_hex {path} {
    set fh [open $path rb]
    fconfigure $fh -translation binary
    set data [read $fh]
    close $fh
    set n [string length $data]
    set words [list]
    for {set i 0} {$i < $n} {incr i 4} {
        set b0 0; set b1 0; set b2 0; set b3 0
        if {$i   < $n} { binary scan [string index $data $i]       c b0 }
        if {$i+1 < $n} { binary scan [string index $data [expr {$i+1}]] c b1 }
        if {$i+2 < $n} { binary scan [string index $data [expr {$i+2}]] c b2 }
        if {$i+3 < $n} { binary scan [string index $data [expr {$i+3}]] c b3 }
        set w [expr { (($b3 & 0xFF) << 24) | (($b2 & 0xFF) << 16) | (($b1 & 0xFF) << 8) | ($b0 & 0xFF) }]
        lappend words [format %08x [expr {$w & 0xFFFFFFFF}]]
    }
    return $words
}

proc axi_write {addr words name} {
    set total [llength $words]
    puts "==> jtag_load_hello: writing $name ($total words) to [format 0x%08x $addr]"
    catch {delete_hw_axi_txn -quiet wr_$name}
    create_hw_axi_txn -type WRITE -address [format 0x%08x $addr] -len $total \
        -data $words -force wr_$name [get_hw_axis hw_axi_1]
    run_hw_axi [get_hw_axi_txns wr_$name]
}

puts "==> jtag_load_hello: opening hw_server"
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev

catch {set_property PARAM.FREQUENCY 30000000 [current_hw_target]}
catch {set_msg_config -id {Labtoolstcl 44-481} -limit 1}

if {[llength [get_hw_axis]] == 0} {
    puts "ERROR: no hw_axi found on JTAG"
    exit 1
}
reset_hw_axi [get_hw_axis hw_axi_1]

# Clear handshake first so BootROM doesn't spuriously re-release.
axi_write 0x47000000 [list 00000000] clr_magic

# Load the tiny hello at 0x40000000.
axi_write 0x40000000 [read_file_hex $bin] hello

# Arm: entry=0x40000000, dtb=0 (unused by ddr_hello), magic=0xDEADBEEF.
axi_write 0x47000004 [list 40000000] entry
axi_write 0x47000008 [list 00000000] dtb
axi_write 0x47000000 [list deadbeef] magic

puts "==> jtag_load_hello: armed. BootROM should release and the UART should print the banner."
close_hw_target
disconnect_hw_server
