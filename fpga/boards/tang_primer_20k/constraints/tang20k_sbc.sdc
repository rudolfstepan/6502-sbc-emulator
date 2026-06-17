# 27 MHz board oscillator
create_clock -name clk_27mhz -period 37.037 [get_ports {clk_27mhz}]

# PS/2 keyboard clock is asynchronous input (~10-16.7 kHz from keyboard).
# Sampled through a 3-FF synchroniser; no setup/hold constraints needed.
