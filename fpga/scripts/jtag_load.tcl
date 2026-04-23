# -----------------------------------------------------------------------------
# jtag_load.tcl
# Stage OpenSBI + Linux kernel + DTB into DDR via the jtag_axi_0 master, then
# release the BootROM by writing 0xDEADBEEF to the handshake word.
#
# Runs against a live FPGA that already has the axi_hello bitstream programmed.
# Assumes the Vivado hw_server is running (i.e. open_hw_manager + open_hw_target
# succeed) and the jtag_axi_0 IP is present on the chain.
#
# Usage:
#   vivado -mode batch -source fpga/scripts/jtag_load.tcl
#
# Environment overrides (with defaults):
#   FW_JUMP       = buildroot/output/build/opensbi-1.4/build/platform/generic/firmware/fw_jump.bin
#   KERNEL_IMAGE  = buildroot/output/build/linux-6.6.32/arch/riscv/boot/Image
#                   NOT output/images/Image — that one has the EFI-stub MZ
#                   header (first bytes 4d 5a → c.li s4,-13 compressed), which
#                   is illegal on this non-RVC SoC and traps immediately after
#                   OpenSBI mret's to S-mode. Use the plain Image from the
#                   kernel build dir; it starts with `j +0xd40`.
#   DTB           = sw/linux/riscv_soc.dtb
#   INITRAMFS     = buildroot/output/images/rootfs.cpio.gz   (optional)
#
# Address map (DDR is 128 MB at 0x4000_0000):
#   0x4000_0000  OpenSBI fw_jump   (reserved 2 MB per DT)
#   0x4040_0000  Linux Image       (kernel — tens of MB)
#   0x4220_0000  DTB               (matches FW_JUMP_FDT_ADDR in OpenSBI)
#   0x4300_0000  initramfs         (optional; DT chosen's initrd-start points here)
#   0x4700_0000  Handshake word    (BootROM polls)
# -----------------------------------------------------------------------------

proc env_or_default {name default_val} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return [file normalize $::env($name)]
    }
    return $default_val
}

set script_dir [file normalize [file dirname [info script]]]
set repo_dir   [file normalize [file join $script_dir .. ..]]
set br_dir     [file normalize /home/lain/toolchains/buildroot/output]

set fw_jump   [env_or_default FW_JUMP      [file join $br_dir build opensbi-1.4 build platform generic firmware fw_jump.bin]]
set kernel    [env_or_default KERNEL_IMAGE [file join $br_dir build linux-6.6.32 arch riscv boot Image]]
set dtb       [env_or_default DTB          [file join $repo_dir sw linux riscv_soc.dtb]]
set initramfs [env_or_default INITRAMFS    [file join $br_dir images rootfs.cpio]]

# Load addresses (must match bootrom.S and the DTB reserved-memory).
set ADDR_FW         0x40000000
set ADDR_KERNEL     0x40400000
set ADDR_DTB        0x42200000
set ADDR_INITRAMFS  0x43000000
set ADDR_HS_MAGIC   0x47000000
set ADDR_HS_ENTRY   0x47000004
set ADDR_HS_DTB     0x47000008

foreach {name path} [list fw_jump $fw_jump kernel $kernel dtb $dtb] {
    if {![file exists $path]} {
        puts "ERROR: $name not found: $path"
        exit 1
    }
}
set have_initramfs [file exists $initramfs]

proc axi_write_file {addr path name} {
    # Stream a binary file into DDR over jtag_axi in 256-word bursts, formatting
    # each burst's hex list lazily. Avoids materialising a 7.5M-element list in
    # Tcl memory (which is comically slow).
    set fh [open $path rb]
    fconfigure $fh -translation binary -buffersize 65536
    set n [file size $path]
    set word_bytes 4
    set burst_words 256
    set burst_bytes [expr {$burst_words * $word_bytes}]
    set total_words [expr {($n + 3) / 4}]
    puts "==> jtag_load: writing $name — $total_words words ($n B) to [format 0x%08x $addr]"
    flush stdout

    set t0 [clock milliseconds]
    set offs 0
    set bursts_done 0
    while {$offs < $n} {
        set chunk [read $fh $burst_bytes]
        set clen [string length $chunk]
        # Pad trailing partial word with zero bytes so full words are sent.
        set pad [expr {(4 - ($clen % 4)) % 4}]
        if {$pad != 0} { append chunk [string repeat "\x00" $pad] }
        set clen [string length $chunk]
        binary scan $chunk iu* ints
        set words [list]
        foreach v $ints {
            lappend words [format %08x [expr {$v & 0xFFFFFFFF}]]
        }
        set wlen [llength $words]
        set burst_addr [format 0x%08x [expr {$addr + $offs}]]
        catch {delete_hw_axi_txn -quiet wr_$name}
        create_hw_axi_txn -type WRITE -address $burst_addr -len $wlen -data $words \
            -force wr_$name [get_hw_axis hw_axi_1]
        run_hw_axi [get_hw_axi_txns wr_$name]
        set offs [expr {$offs + $clen}]
        incr bursts_done
        if {$bursts_done % 256 == 0} {
            set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
            set mb  [expr {$offs / 1048576.0}]
            set rate [expr {int($offs / $dt)}]
            puts "    ... [format %.2f $mb] MB / [format %.2f [expr {$n/1048576.0}]] MB at $rate B/s"
            flush stdout
        }
    }
    close $fh
    set t1 [clock milliseconds]
    set dt [expr {($t1 - $t0) / 1000.0}]
    puts "    ... $name done in [format %.2f $dt] s ([expr {int($n/$dt)}] B/s)"
    flush stdout
}

proc axi_write_word {addr val_hex} {
    catch {delete_hw_axi_txn -quiet hs_write}
    create_hw_axi_txn -type WRITE -address [format 0x%08x $addr] -len 1 \
        -data [list $val_hex] -force hs_write [get_hw_axis hw_axi_1]
    run_hw_axi [get_hw_axi_txns hs_write]
}

puts "==> jtag_load: opening hw_server"
open_hw_manager
connect_hw_server
open_hw_target

# Make sure the bitstream has been programmed (detect device but don't reprogram).
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev

# Bump JTAG TCK to the maximum the FT2232 can produce (30 MHz nominal).
# Default is 10 MHz — at 32-bit words plus scan overhead that cost ~80 B/s
# through create_hw_axi_txn, which is untenable for a 30 MB kernel.
catch {set_property PARAM.FREQUENCY 30000000 [current_hw_target]}

if {[llength [get_hw_axis]] == 0} {
    puts "ERROR: no hw_axi found. Is the bitstream programmed and the jtag_axi_0 IP present?"
    close_hw_target
    disconnect_hw_server
    exit 1
}

set hw_axi [get_hw_axis hw_axi_1]
puts "==> jtag_load: using hw_axi = $hw_axi"
reset_hw_axi $hw_axi

# Silence the per-burst WRITE DATA spam from Labtoolstcl 44-481 — at 256-word
# bursts the Tcl-side log formatting alone runs the loader several thousand
# times slower than the raw JTAG path. 65 KB took ~14 min with logging on
# (~80 B/s); at ~300 KB/s loading a 30 MB kernel takes ~100 s. Massive win.
catch {set_msg_config -id {Labtoolstcl 44-481} -limit 1}
catch {set_msg_config -id {Labtoolstcl 44-479} -limit 1}
catch {set_msg_config -id {Labtoolstcl 44-485} -limit 1}

# ---- Preload the handshake word to something safe before anything else.
# BootROM is polling 0x47000000 for 0xDEADBEEF; clear first so a stale value
# from a previous run doesn't auto-release the CPU.
puts "==> jtag_load: clearing handshake word"
axi_write_word $ADDR_HS_MAGIC 00000000

# ---- fw_jump (OpenSBI, 260 KB) -> 0x40000000
axi_write_file $ADDR_FW       $fw_jump   opensbi

# ---- Linux Image (30 MB) -> 0x40400000
axi_write_file $ADDR_KERNEL   $kernel    kernel

# ---- DTB (2 KB) -> 0x42200000
axi_write_file $ADDR_DTB      $dtb       dtb

# ---- initramfs (optional) -> 0x43000000
if {$have_initramfs} {
    axi_write_file $ADDR_INITRAMFS $initramfs initramfs
} else {
    puts "==> jtag_load: initramfs not found, skipping"
}

# ---- Finally, set the handshake:
#      [0x47000004] = OpenSBI entry (= ADDR_FW)
#      [0x47000008] = DTB physical address (= ADDR_DTB)
#      [0x47000000] = 0xDEADBEEF   <-- write last so BootROM does not spuriously release
puts "==> jtag_load: arming handshake"
axi_write_word $ADDR_HS_ENTRY [format %08x $ADDR_FW]
axi_write_word $ADDR_HS_DTB   [format %08x $ADDR_DTB]
axi_write_word $ADDR_HS_MAGIC deadbeef

puts "==> jtag_load: done. BootROM should now jump into OpenSBI."
close_hw_target
disconnect_hw_server
