# -----------------------------------------------------------------------------
# urbana_blinky.xdc
# Constraints for the RealDigital Urbana board (xc7s50csga324-1) blinky test.
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
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS25} [get_ports rst_n]

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
