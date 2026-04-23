#!/usr/bin/env python3
"""UART monitor / logger for the Urbana FPGA's Uartlite port.

Reads /dev/ttyUSB1 (Urbana FTDI UART @ 115200 8N1) and prints what the FPGA
emits to stdout, tee'd into a log file. No local echo; input from the PTY is
forwarded back to the FPGA byte-by-byte for interactive CLI use after Linux
boots.

Invoke in the background while running jtag_load.tcl, e.g.:

  ./uart_monitor.py --log boot.log &
  vivado -mode batch -source fpga/scripts/jtag_load.tcl

or pass `--readonly` for a pure capture with no stdin forwarding.
"""
import argparse
import os
import select
import signal
import sys
import termios
import time
import tty

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--log",  default=None, help="Tee all received bytes to this file")
    ap.add_argument("--readonly", action="store_true", help="Don't forward stdin to UART")
    args = ap.parse_args()

    ser = serial.Serial(
        port=args.port, baudrate=args.baud,
        bytesize=8, parity='N', stopbits=1,
        timeout=0, rtscts=False, xonxoff=False, dsrdtr=False,
    )

    log = open(args.log, "ab", buffering=0) if args.log else None

    # Put stdin in raw mode for interactive use (typed keys go to UART).
    old_tc = None
    if not args.readonly and sys.stdin.isatty():
        old_tc = termios.tcgetattr(sys.stdin.fileno())
        tty.setraw(sys.stdin.fileno())

    stop = False

    def handle_sig(*_):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT,  handle_sig)

    sys.stdout.write(f"[uart_monitor] {args.port} @ {args.baud}\r\n")
    sys.stdout.flush()

    try:
        while not stop:
            # Wait on either UART data or (optionally) stdin.
            rlist = [ser.fileno()]
            if not args.readonly:
                rlist.append(sys.stdin.fileno())
            r, _, _ = select.select(rlist, [], [], 0.1)
            if ser.fileno() in r:
                data = ser.read(4096)
                if data:
                    os.write(1, data)
                    if log is not None:
                        log.write(data)
            if (not args.readonly) and sys.stdin.fileno() in r:
                ch = os.read(sys.stdin.fileno(), 1024)
                if ch:
                    # Ctrl-\ (0x1C) exits the monitor.
                    if b'\x1c' in ch:
                        break
                    ser.write(ch)
    finally:
        if old_tc is not None:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_tc)
        ser.close()
        if log is not None:
            log.close()

if __name__ == "__main__":
    main()
