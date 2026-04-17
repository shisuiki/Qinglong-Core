# -----------------------------------------------------------------------------
# urbana_axi_hello.xdc
# Constraints for the RealDigital Urbana (xc7s50csga324-1) Stage 5 AXI bringup.
#
# Differences vs urbana_hello.xdc:
#   - adds uart_rx_pin on B16 (host TX → FPGA input) for axi_uartlite's .rx
# -----------------------------------------------------------------------------

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.Config.SPI_buswidth 4 [current_design]

# -----------------------------------------------------------------------------
# 100 MHz single-ended oscillator (N15, LVCMOS33)
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 10.000 -name sysclk [get_ports clk]

# -----------------------------------------------------------------------------
# Reset push-button (btn[0], J2, LVCMOS25, ACTIVE-LOW).
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS25 PULLUP true} [get_ports rst_n]

# -----------------------------------------------------------------------------
# UART (to on-board USB bridge, FTDI)
#   Board pin names are from the HOST's perspective:
#     uart_rxd = A16 = host RX (FPGA OUTPUT) — we drive this with uartlite.tx
#     uart_txd = B16 = host TX (FPGA INPUT ) — we feed this into uartlite.rx
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports uart_tx_pin]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33 PULLUP true} [get_ports uart_rx_pin]

# -----------------------------------------------------------------------------
# First 8 user LEDs (LVCMOS33)
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
