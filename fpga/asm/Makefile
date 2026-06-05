CA65   = C:/tools/cc65/bin/ca65
LD65   = C:/tools/cc65/bin/ld65
PYTHON = python

ROM_BIN = rom_demo.bin
ROM_HEX = ../sim/rom_welcome.hex

.PHONY: all clean

all: $(ROM_HEX)

rom_demo.o: rom_demo.s
	$(CA65) --cpu 6502 -t none -l rom_demo.lst $< -o $@

$(ROM_BIN): rom_demo.o rom_demo.cfg
	$(LD65) -C rom_demo.cfg -o $@ $< -m rom_demo.map

$(ROM_HEX): $(ROM_BIN) bin_to_fpga_hex.py
	$(PYTHON) bin_to_fpga_hex.py $(ROM_BIN) 0xF800 0x0800 $(ROM_HEX)
	@echo "Installed -> $(ROM_HEX)"

clean:
	-del /Q rom_demo.o $(ROM_BIN) rom_demo.lst rom_demo.map 2>NUL || true
