create_clock -name clk_50m -period 20.000 [get_ports clk_50m]
derive_pll_clocks
derive_clock_uncertainty

# Host requests cross from JTAG into the PLL domain through synchronizers, and the
# status probes are only read while the design is idle.
set_clock_groups -asynchronous -group [get_clocks altera_reserved_tck] -group [get_clocks {clk_50m *pll1|clk[*]}]

# The SDRAM I/O window is found by sweeping the SDRAM clock phase, not by STA.
set_false_path -to [get_ports {sdr_*}]
set_false_path -from [get_ports {sdr_dq[*]}]
