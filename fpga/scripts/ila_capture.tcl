# -----------------------------------------------------------------------------
# ila_capture.tcl
#
# End-to-end ILA capture flow for the S-mode external IRQ path diagnosis on
# Urbana silicon. In one hw_server session:
#
#   1. program axi_hello.bit (optional; skip with BITSTREAM=skip)
#   2. stage OpenSBI + Linux Image + DTB + initramfs into DDR via jtag_axi
#   3. arm the ila_0 core (trigger: uart_irq_i rising, probe0 == 1)
#   4. write the BootROM handshake word (0xDEADBEEF) to release the CPU
#   5. wait for ILA trigger, upload the sample buffer, dump CSV + VCD
#
# Depth = 4096 samples at 50 MHz → ~82 us capture window. Trigger position 512
# gives ~10 us pre-trigger (enough to see PLIC state BEFORE the UART IRQ fires)
# + ~72 us post-trigger (covers trap entry, stvec, handler, claim/complete,
# sret — the whole IRQ round-trip, which at ~1 CPI is ~3500 insns of headroom).
#
# Usage:
#   vivado -mode batch -log ila.log -journal ila.jou -source ila_capture.tcl
#
# Env overrides:
#   BITSTREAM      = ../build/axi_hello/axi_hello.bit | 'skip'
#   FW_JUMP, KERNEL_IMAGE, DTB, INITRAMFS — same as jtag_load.tcl
#   ILA_OUT_DIR    = ../build/axi_hello/ila_captures
#   ILA_TRIG_POS   = 512
#   ILA_WAIT_SEC   = 120
# -----------------------------------------------------------------------------

proc env_or_default {name default_val} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default_val
}

set script_dir [file normalize [file dirname [info script]]]
set repo_dir   [file normalize [file join $script_dir .. ..]]
set br_dir     [file normalize /home/lain/toolchains/buildroot/output]
set build_dir  [file normalize [file join $repo_dir fpga build axi_hello]]

set bitstream  [env_or_default BITSTREAM   [file join $build_dir axi_hello.bit]]
set fw_jump    [file normalize [env_or_default FW_JUMP      [file join $br_dir build opensbi-1.4 build platform generic firmware fw_jump.bin]]]
set kernel     [file normalize [env_or_default KERNEL_IMAGE [file join $br_dir build linux-6.6.32 arch riscv boot Image]]]
set dtb        [file normalize [env_or_default DTB          [file join $repo_dir sw linux riscv_soc.dtb]]]
set initramfs  [file normalize [env_or_default INITRAMFS    [file join $br_dir images rootfs.cpio]]]

set out_dir    [file normalize [env_or_default ILA_OUT_DIR  [file join $build_dir ila_captures]]]
set trig_pos   [env_or_default ILA_TRIG_POS 512]
set wait_sec   [env_or_default ILA_WAIT_SEC 120]
# SKIP_KERNEL_STAGE=1 → assume DDR already holds fw_jump+kernel+initramfs from
# a previous run. Only restage the DTB (small, fast) and the handshake word.
set skip_kernel_stage [env_or_default SKIP_KERNEL_STAGE 0]
# SKIP_INITRAMFS=1 → don't stage the initramfs either (helpful for fast
# iteration when the rootfs contents haven't changed between runs).
set skip_initramfs [env_or_default SKIP_INITRAMFS 0]

file mkdir $out_dir
set stamp  [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set csv    [file join $out_dir "ila_${stamp}.csv"]
set vcd    [file join $out_dir "ila_${stamp}.vcd"]
set ila_dir_out [file join $out_dir "ila_${stamp}.ila"]

# BootROM handshake
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
    set fh [open $path rb]
    fconfigure $fh -translation binary -buffersize 65536
    set n [file size $path]
    set word_bytes 4
    set burst_words 256
    set burst_bytes [expr {$burst_words * $word_bytes}]
    set total_words [expr {($n + 3) / 4}]
    puts "==> ila_capture: writing $name — $total_words words ($n B) to [format 0x%08x $addr]"
    flush stdout
    set t0 [clock milliseconds]
    set offs 0
    set bursts_done 0
    while {$offs < $n} {
        set chunk [read $fh $burst_bytes]
        set clen [string length $chunk]
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
    set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
    puts "    ... $name done in [format %.2f $dt] s ([expr {int($n/$dt)}] B/s)"
    flush stdout
}

proc axi_write_word {addr val_hex} {
    catch {delete_hw_axi_txn -quiet ww_tmp}
    create_hw_axi_txn -type WRITE -address [format 0x%08x $addr] -len 1 \
        -data [list $val_hex] -force ww_tmp [get_hw_axis hw_axi_1]
    run_hw_axi [get_hw_axi_txns ww_tmp]
}

puts "==> ila_capture: opening hw_manager"
open_hw_manager
connect_hw_server
open_hw_target

set all_devs [get_hw_devices]
set dev ""
foreach d $all_devs {
    if {[string match "xc7s50*" [get_property PART $d]]} { set dev $d; break }
}
if {$dev eq ""} {
    puts "ERROR: no xc7s50 device on JTAG chain"
    exit 1
}
current_hw_device $dev

set ltx_file [file normalize [file join $build_dir axi_hello.ltx]]
if {[file exists $ltx_file]} {
    puts "==> ila_capture: attaching probe definitions from $ltx_file"
    set_property PROBES.FILE $ltx_file $dev
    set_property FULL_PROBES.FILE $ltx_file $dev
} else {
    puts "WARNING: $ltx_file not found — probe names won't be available"
}

if {$bitstream ne "skip"} {
    set bitstream [file normalize $bitstream]
    if {![file exists $bitstream]} {
        puts "ERROR: bitstream not found: $bitstream"
        exit 1
    }
    puts "==> ila_capture: programming $dev with $bitstream"
    set_property PROGRAM.FILE $bitstream $dev
    program_hw_devices $dev
} else {
    puts "==> ila_capture: BITSTREAM=skip — assuming device already programmed"
}
refresh_hw_device -quiet $dev

# Bump JTAG TCK (default 10 MHz is painfully slow for a 30 MB kernel load).
catch {set_property PARAM.FREQUENCY 30000000 [current_hw_target]}

if {[llength [get_hw_axis]] == 0} {
    puts "ERROR: no hw_axi_1 visible. Bitstream programmed but jtag_axi IP not detected."
    exit 1
}
if {[llength [get_hw_ilas]] == 0} {
    puts "ERROR: no hw_ila visible. Bitstream may be the non-ILA variant."
    exit 1
}
set hw_axi [get_hw_axis hw_axi_1]
set hw_ila [get_hw_ilas hw_ila_1]
puts "==> ila_capture: hw_axi=$hw_axi  hw_ila=$hw_ila"

# Silence per-burst Labtool message spam (see jtag_load.tcl).
catch {set_msg_config -id {Labtoolstcl 44-481} -limit 1}
catch {set_msg_config -id {Labtoolstcl 44-479} -limit 1}
catch {set_msg_config -id {Labtoolstcl 44-485} -limit 1}

reset_hw_axi $hw_axi

# ---- Preload handshake-magic to 0 so a stale value can't auto-release the CPU
puts "==> ila_capture: clearing handshake word"
axi_write_word $ADDR_HS_MAGIC 00000000

# ---- Stage OpenSBI, kernel, DTB, initramfs into DDR ----
# DTB is always re-staged (it's small, and we often tweak it between runs).
if {$skip_kernel_stage} {
    puts "==> ila_capture: SKIP_KERNEL_STAGE=1 — reusing DDR-resident OpenSBI+kernel"
} else {
    axi_write_file $ADDR_FW      $fw_jump  opensbi
    axi_write_file $ADDR_KERNEL  $kernel   kernel
}
axi_write_file $ADDR_DTB     $dtb      dtb
if {$skip_initramfs} {
    puts "==> ila_capture: SKIP_INITRAMFS=1 — reusing DDR-resident initramfs"
} elseif {$have_initramfs} {
    axi_write_file $ADDR_INITRAMFS $initramfs initramfs
} else {
    puts "==> ila_capture: no initramfs, skipping"
}

# ---- Arm the ILA ----
puts "==> ila_capture: configuring ILA core"
set_property CONTROL.DATA_DEPTH        4096                       $hw_ila
set_property CONTROL.TRIGGER_POSITION  $trig_pos                  $hw_ila
set_property CONTROL.TRIGGER_MODE      BASIC_ONLY                 $hw_ila
set_property CONTROL.CAPTURE_MODE      ALWAYS                     $hw_ila
set_property CONTROL.WINDOW_COUNT      1                          $hw_ila

# Print available probes for sanity.
set probes [get_hw_probes -of_objects $hw_ila]
puts "==> ila_capture: probes available:"
foreach p $probes {
    puts "      [get_property NAME $p]  width=[get_property WIDTH $p]"
}

# Find the probe wired to uart_irq_i. With the .ltx loaded, probe names
# reflect the signal-net names from soc_ila_probes.sv (e.g. 'uart_irq_i'),
# NOT the IP port names ('probe0'). Match by port-name suffix.
set probe_name "u_soc/u_ila/uart_irq_i"
set p0 [get_hw_probes $probe_name -of_objects $hw_ila]
if {[llength $p0] == 0} {
    # Try a relaxed match in case instance hierarchy differs.
    set p0 [get_hw_probes -of_objects $hw_ila -filter {NAME =~ *uart_irq_i}]
}
if {[llength $p0] == 0} {
    puts "ERROR: uart_irq_i probe not found on ILA. Available probes above."
    exit 1
}
puts "==> ila_capture: trigger probe = [get_property NAME $p0]  width=[get_property WIDTH $p0]"

# Set compare: eq 1'b1 (rising edge in practice since IRQ is level-high during delivery)
set_property TRIGGER_COMPARE_VALUE eq1'b1 $p0

run_hw_ila $hw_ila
puts "==> ila_capture: ILA armed, trigger = uart_irq_i == 1'b1, pos=$trig_pos depth=4096"

# ---- Release BootROM handshake ----
puts "==> ila_capture: arming BootROM handshake"
axi_write_word $ADDR_HS_ENTRY [format %08x $ADDR_FW]
axi_write_word $ADDR_HS_DTB   [format %08x $ADDR_DTB]
axi_write_word $ADDR_HS_MAGIC deadbeef
puts "==> ila_capture: handshake released — BootROM → OpenSBI → Linux"

# ---- Wait for trigger + capture ----
puts "==> ila_capture: waiting for ILA trigger (timeout ${wait_sec}s)"
set rc [catch {wait_on_hw_ila -timeout [expr {$wait_sec / 60.0}] $hw_ila} errmsg]
if {$rc != 0} {
    puts "==> ila_capture: wait_on_hw_ila raised: $errmsg (continuing to upload current state)"
}

set data [upload_hw_ila_data $hw_ila]
puts "==> ila_capture: ILA status after wait:"
puts "      CORE_STATUS = [get_property CORE_STATUS $hw_ila]"
puts "      WINDOW      = [get_property CAPTURE.SAMPLES_IN_WINDOW $hw_ila]"
puts "      TRIGGER_POS = [get_property CONTROL.TRIGGER_POSITION $hw_ila]"

puts "==> ila_capture: writing CSV → $csv"
catch {write_hw_ila_data -force -csv_file $csv $data} werr1
if {$werr1 ne ""} { puts "      csv write note: $werr1" }
puts "==> ila_capture: writing VCD → $vcd"
catch {write_hw_ila_data -force -vcd_file $vcd $data} werr2
if {$werr2 ne ""} { puts "      vcd write note: $werr2" }
puts "==> ila_capture: writing .ila (archive) → $ila_dir_out"
catch {write_hw_ila_data -force $ila_dir_out $data} werr3

close_hw_target
disconnect_hw_server
puts "==> ila_capture: done."
