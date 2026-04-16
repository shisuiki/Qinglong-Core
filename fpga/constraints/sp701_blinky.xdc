# -----------------------------------------------------------------------------
# sp701_blinky.xdc
# Constraints for the SP701 (AMD Spartan-7 Evaluation Kit, xc7s100fgga676-2)
# blinky smoke test.
#
# Pin assignments sourced from the Vivado board file at
#   /opt/Xilinx/2025.2/Vivado/data/xhub/boards/XilinxBoardStore/boards/Xilinx/sp701/1.1/
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Configuration bank voltage (7-series default for a 3.3 V config bank)
# -----------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# -----------------------------------------------------------------------------
# 200 MHz differential system clock (bank 33, LVDS_25)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN AE8 [get_ports sysclk_p]
set_property PACKAGE_PIN AE7 [get_ports sysclk_n]
set_property IOSTANDARD LVDS_25 [get_ports sysclk_p]
set_property IOSTANDARD LVDS_25 [get_ports sysclk_n]

create_clock -period 5.000 -name sysclk [get_ports sysclk_p]

# -----------------------------------------------------------------------------
# CPU_RESET push button (active-high, LVCMOS18)
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN AE15 [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS18 [get_ports cpu_reset]

# -----------------------------------------------------------------------------
# User LEDs (LVCMOS33)
#   LED0=J25, LED1=M24, LED2=L24, LED3=K25,
#   LED4=K26, LED5=M25, LED6=L25, LED7=H22
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN J25 [get_ports {led[0]}]
set_property PACKAGE_PIN M24 [get_ports {led[1]}]
set_property PACKAGE_PIN L24 [get_ports {led[2]}]
set_property PACKAGE_PIN K25 [get_ports {led[3]}]
set_property PACKAGE_PIN K26 [get_ports {led[4]}]
set_property PACKAGE_PIN M25 [get_ports {led[5]}]
set_property PACKAGE_PIN L25 [get_ports {led[6]}]
set_property PACKAGE_PIN H22 [get_ports {led[7]}]

set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[7]}]
