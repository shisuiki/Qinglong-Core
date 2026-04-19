open_checkpoint /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/post_synth.dcp

set fp [open /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/probe_pins.txt w]

puts $fp "===== Every DDR3 port -> package pin -> IOB site -> CLOCK_REGION ====="
foreach p [lsort [get_ports -filter {NAME =~ ddr3_*}]] {
    set pin [get_property PACKAGE_PIN $p]
    set bank [get_property IOBANK $p]
    set std  [get_property IOSTANDARD $p]
    set sites ""
    catch {set sites [get_sites -of_objects [get_package_pins $pin]]}
    set region ""
    catch {set region [get_property CLOCK_REGION [lindex $sites 0]]}
    puts $fp [format "%-20s pin=%-4s bank=%-4s site=%-12s region=%-6s std=%s" $p $pin $bank [lindex $sites 0] $region $std]
}

puts $fp ""
puts $fp "===== Lane membership: which DDR3 pin is in each IOB_X1Y* in Y25..Y48 ====="
for {set y 24} {$y <= 49} {incr y} {
    set site_name "IOB_X1Y${y}"
    set site [get_sites $site_name]
    if {[llength $site] == 0} { continue }
    set used "(unused/no port)"
    foreach p [get_ports] {
        set pin [get_property PACKAGE_PIN $p]
        if {$pin eq ""} { continue }
        set sites [get_sites -of_objects [get_package_pins $pin]]
        if {[lsearch -exact $sites $site_name] >= 0} {
            set used "$p (pin=$pin)"
            break
        }
    }
    puts $fp [format "%-15s : %s" $site_name $used]
}

puts $fp ""
puts $fp "===== same scan for column X0 in same Y range (for differential pair partner) ====="
for {set y 24} {$y <= 49} {incr y} {
    set site_name "IOB_X0Y${y}"
    set site [get_sites $site_name]
    if {[llength $site] == 0} { continue }
    set used "(unused/no port)"
    foreach p [get_ports] {
        set pin [get_property PACKAGE_PIN $p]
        if {$pin eq ""} { continue }
        set sites [get_sites -of_objects [get_package_pins $pin]]
        if {[lsearch -exact $sites $site_name] >= 0} {
            set used "$p (pin=$pin)"
            break
        }
    }
    puts $fp [format "%-15s : %s" $site_name $used]
}

close $fp
close_design
