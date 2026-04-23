# Benchmark: write 256 KB to DDR in 256-word bursts, report throughput.
# Prints every 64 bursts so we can watch progress.
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev

catch {set_property PARAM.FREQUENCY 30000000 [current_hw_target]}
catch {set_msg_config -id {Labtoolstcl 44-481} -limit 1}
catch {set_msg_config -id {Labtoolstcl 44-479} -limit 1}
catch {set_msg_config -id {Labtoolstcl 44-485} -limit 1}

reset_hw_axi [get_hw_axis hw_axi_1]

# Build a 256-word pattern list once.
set pattern [list]
for {set i 0} {$i < 256} {incr i} {
    lappend pattern [format %08x [expr {0xCAFE0000 | $i}]]
}

set burst 256
set bursts 256   ;# 256 bursts × 256 words × 4 B = 256 KB
set addr 0x40100000

puts "==> bench: writing [expr {$bursts*$burst}] words = [expr {$bursts*$burst*4}] B"
set t0 [clock milliseconds]
for {set b 0} {$b < $bursts} {incr b} {
    set a [format 0x%08x [expr {$addr + $b*$burst*4}]]
    catch {delete_hw_axi_txn -quiet wr_b}
    create_hw_axi_txn -type WRITE -address $a -len $burst -data $pattern -force wr_b [get_hw_axis hw_axi_1]
    run_hw_axi [get_hw_axi_txns wr_b]
    if {($b+1) % 32 == 0} {
        set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
        set words [expr {($b+1) * $burst}]
        puts "    burst $b/$bursts — $words words in $dt s  = [expr {int($words*4.0/$dt)}] B/s"
    }
}
set t1 [clock milliseconds]
set dt [expr {($t1 - $t0) / 1000.0}]
set total_b [expr {$bursts * $burst * 4}]
puts "==> bench: $total_b B in $dt s  = [expr {int($total_b/$dt)}] B/s"

close_hw_target
disconnect_hw_server
