CA65   = C:/tools/cc65/bin/ca65
LD65   = C:/tools/cc65/bin/ld65
PYTHON = python

ROM_BIN = rom_demo.bin
ROM_HEX = ../sim/rom_welcome.hex

FPGA_EHBASIC_ROM = ../../tools/roms/fpga_ehbasic_16kb.rom
FPGA_EHBASIC_IMG = ../../tools/roms/fpga_ehbasic_16kb.img
KERNEL_S   = ../../tools/kernel/kernel.s
KERNEL_CFG = ../../tools/kernel/kernel.cfg
KERNEL_O   = ../../tools/kernel/kernel.o
KERNEL_ROM = ../../roms/kernel.rom

.PHONY: all clean fpga-ehbasic upload-ehbasic upload-demo sd-ehbasic kernel

all: $(ROM_HEX)

rom_demo.o: rom_demo.s
	$(CA65) --cpu 6502 -t none -l rom_demo.lst $< -o $@

$(ROM_BIN): rom_demo.o rom_demo.cfg
	$(LD65) -C rom_demo.cfg -o $@ $< -m rom_demo.map

$(ROM_HEX): $(ROM_BIN) bin_to_fpga_hex.py
	$(PYTHON) bin_to_fpga_hex.py $(ROM_BIN) 0xF800 0x0800 $(ROM_HEX)
	@echo "Installed -> $(ROM_HEX)"

# Build the 4 KB kernel ROM from source
kernel: $(KERNEL_ROM)

$(KERNEL_O): $(KERNEL_S)
	$(CA65) --cpu 6502 -o $(KERNEL_O) $(KERNEL_S)

$(KERNEL_ROM): $(KERNEL_O) $(KERNEL_CFG)
	$(LD65) -C $(KERNEL_CFG) -o $(KERNEL_ROM) $(KERNEL_O)
	@echo "Kernel ROM ready: $(KERNEL_ROM)"

# Build the FPGA EhBASIC 16 KB ROM (kernel + EhBASIC, UART I/O)
fpga-ehbasic: $(KERNEL_ROM)
	$(PYTHON) ../../tools/build_fpga_ehbasic.py
	@echo "ROM ready: $(FPGA_EHBASIC_ROM)"

# Build and immediately upload via UART monitor (board must be in monitor mode)
upload-ehbasic: $(KERNEL_ROM)
	$(PYTHON) ../../tools/build_fpga_ehbasic.py --upload --run --verbose

# Build 16 KB ROM + raw SD card boot image (.img)
sd-ehbasic: $(KERNEL_ROM)
	$(PYTHON) ../../tools/build_fpga_ehbasic.py --sd-image
	@echo "SD image ready: $(FPGA_EHBASIC_IMG)"

# Build and upload rom_demo via UART monitor (board must be in monitor mode)
upload-demo: $(ROM_BIN)
	$(PYTHON) upload_rom_demo.py --run --verbose

clean:
	-del /Q rom_demo.o $(ROM_BIN) rom_demo.lst rom_demo.map 2>NUL || true
