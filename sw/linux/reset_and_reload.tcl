# Reset the FPGA (reprogram same bitstream) then stage OpenSBI + kernel + DTB +
# initramfs and release the BootROM handshake. One-shot: use this when the
# running kernel has wedged and we want a clean restart without touching RTL.

set script_dir [file normalize /home/lain/qianyu/riscv_soc/fpga/scripts]
set bit        /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/axi_hello.bit
set probes     /home/lain/qianyu/riscv_soc/fpga/build/axi_hello/axi_hello.ltx

puts "==> reset_and_reload: opening hw_manager"
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev

puts "==> reset_and_reload: programming $bit"
set_property PROGRAM.FILE $bit $dev
if {[file exists $probes]} {
    set_property PROBES.FILE $probes $dev
    set_property FULL_PROBES.FILE $probes $dev
}
program_hw_devices $dev
refresh_hw_device -quiet $dev
puts "==> reset_and_reload: bitstream reloaded"

# Close so jtag_load.tcl can re-open cleanly (Labtoolstcl 44-586 otherwise).
close_hw_target
disconnect_hw_server
close_hw_manager

# Now delegate to jtag_load for staging.
source [file join $script_dir jtag_load.tcl]
