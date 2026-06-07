CA65   = C:/tools/cc65/bin/ca65
LD65   = C:/tools/cc65/bin/ld65
PYTHON = python

ROM_BIN = rom_demo.bin
ROM_HEX = ../sim/rom_welcome.hex

FPGA_EHBASIC_ROM = ../../tools/roms/fpga_ehbasic_16kb.rom

.PHONY: all clean fpga-ehbasic upload-ehbasic

all: $(ROM_HEX)

rom_demo.o: rom_demo.s
	$(CA65) --cpu 6502 -t none -l rom_demo.lst $< -o $@

$(ROM_BIN): rom_demo.o rom_demo.cfg
	$(LD65) -C rom_demo.cfg -o $@ $< -m rom_demo.map

$(ROM_HEX): $(ROM_BIN) bin_to_fpga_hex.py
	$(PYTHON) bin_to_fpga_hex.py $(ROM_BIN) 0xF800 0x0800 $(ROM_HEX)
	@echo "Installed -> $(ROM_HEX)"

# Build the FPGA EhBASIC 16 KB ROM (kernel + EhBASIC, UART I/O)
fpga-ehbasic:
	$(PYTHON) ../../tools/build_fpga_ehbasic.py
	@echo "ROM ready: $(FPGA_EHBASIC_ROM)"

# Build and immediately upload via UART monitor (board must be in monitor mode)
upload-ehbasic:
	$(PYTHON) ../../tools/build_fpga_ehbasic.py --upload --run --verbose

clean:
	-del /Q rom_demo.o $(ROM_BIN) rom_demo.lst rom_demo.map 2>NUL || true
