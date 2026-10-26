# Pin assignments for the "Altera Cyclone IV FPGA C406" board (EP4CE6F17C8N + W9825G6KH).
# Mapped with ../pinfinder over JTAG; every SDRAM pin was confirmed with a multimeter.
# Source this from a project's .qsf or Tcl script:  source <path>/c406_pins.tcl
#
# Header pins are printed on the bottom silkscreen and are not listed here.
# Do not drive F5 or L12 low: something on the board holds them high.
# M15 (clock input) is not connected and floats.

set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE6F17C8
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED WITH WEAK PULL-UP"
# SDRAM DQ12 is on F16, the nCEO pin.
set_global_assignment -name CYCLONEII_RESERVE_NCEO_AFTER_CONFIGURATION "USE AS REGULAR IO"

# Clock, key, LED
set_location_assignment PIN_M16 -to clk_50m
set_location_assignment PIN_R8  -to key_n
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to key_n
set_location_assignment PIN_E10 -to led

# SDRAM W9825G6KH (4 banks x 8192 rows x 512 columns x 16 bit)
set_location_assignment PIN_A14 -to sdr_clk
set_location_assignment PIN_A15 -to sdr_cke
set_location_assignment PIN_P15 -to sdr_cs_n
set_location_assignment PIN_P16 -to sdr_ras_n
set_location_assignment PIN_N14 -to sdr_cas_n
set_location_assignment PIN_G15 -to sdr_we_n
set_location_assignment PIN_R16 -to sdr_ba[0]
set_location_assignment PIN_R14 -to sdr_ba[1]
set_location_assignment PIN_G16 -to sdr_dqm[0]
set_location_assignment PIN_B16 -to sdr_dqm[1]

set i 0
foreach p {N12 L14 L13 J13 J14 F14 F13 E11 D14 C11 P14 D11 B14} {
    set_location_assignment PIN_$p -to "sdr_a\[$i\]"
    incr i
}
set i 0
foreach p {N16 N15 L15 L16 K15 K16 J15 J16 C15 C16 D15 D16 F16 F15 D12 C14} {
    set_location_assignment PIN_$p -to "sdr_dq\[$i\]"
    incr i
}
