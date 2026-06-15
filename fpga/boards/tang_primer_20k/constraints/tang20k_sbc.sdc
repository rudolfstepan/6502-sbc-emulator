create_clock -name ulpi_clk -period 16.667 -waveform {0 5.75} [get_ports {ulpi_clk}]
# Source-clock latency models the PHY->FPGA clock arrival delay.  Value taken
# from the proven Sipeed Tang Primer 20K usb_example.sdc reference design.
set_clock_latency -source 0.4 [get_clocks {ulpi_clk}]

# ULPI is a source-synchronous interface: the PHY drives ulpi_clk and all signals
# change relative to its rising edge.
#
# Inputs (PHY -> FPGA): DIR, NXT, DATA change after the PHY's rising edge.
# USB3317 output delay from clock: Tpd_max=8ns, Tpd_min=2ns.
set_input_delay -clock ulpi_clk -max 8.0 [get_ports {ulpi_dir ulpi_nxt ulpi_data[*]}]
set_input_delay -clock ulpi_clk -min 2.0 [get_ports {ulpi_dir ulpi_nxt ulpi_data[*]}]

# Outputs (FPGA -> PHY): DATA and STP must be stable at the PHY before its next
# rising edge.  USB3317 setup time: Tsu=3ns; assume 1ns PCB trace each way.
# set_output_delay -max N means the data must arrive N ns before the clock edge.
set_output_delay -clock ulpi_clk -max 3.0 [get_ports {ulpi_data[*] ulpi_stp}]
set_output_delay -clock ulpi_clk -min -2.0 [get_ports {ulpi_data[*] ulpi_stp}]

