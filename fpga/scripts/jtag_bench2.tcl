# Bench2: write 256 KB starting from 0x40000000 (same base the real loader uses)
# and report progress every burst, so we see exactly where (if anywhere) the
# JTAG path stalls on the real production address.
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev

catch {set_property PARAM.FREQUENCY 30000000 [current_hw_target]}
catch {set_msg_config -id {Labtoolstcl 44-481} -limit 1}

reset_hw_axi [get_hw_axis hw_axi_1]

set pattern [list]
for {set i 0} {$i < 256} {incr i} {
    lappend pattern [format %08x [expr {0xBEEF0000 | $i}]]
}

set bursts 400
set addr 0x40000000

set t0 [clock milliseconds]
for {set b 0} {$b < $bursts} {incr b} {
    set a [format 0x%08x [expr {$addr + $b*1024}]]
    catch {delete_hw_axi_txn -quiet wr_b}
    create_hw_axi_txn -type WRITE -address $a -len 256 -data $pattern -force wr_b [get_hw_axis hw_axi_1]
    run_hw_axi [get_hw_axi_txns wr_b]
    if {($b+1) % 16 == 0} {
        set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
        puts "burst $b addr $a  cumulative $dt s"
        flush stdout
    }
}
set t1 [clock milliseconds]
puts "==> bench2: [expr {$bursts*1024}] B in [expr {($t1-$t0)/1000.0}] s"

close_hw_target
disconnect_hw_server
