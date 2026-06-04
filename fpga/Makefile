GHDL ?= C:\Users\oe3sr\AppData\Local\ghdl\bin\ghdl.exe
PYTHON ?= python
GHDL_FLAGS ?= --std=08 --ieee=synopsys
GHDL_RUN_FLAGS ?= --ieee-asserts=disable-at-0
CHESS_ROM_HEX = sim/generated/chess_rom.hex
SBC_ROM_HEX = sim/generated/sbc_rom.hex
T65_RTL = third_party/t65/rtl/T65_Pack.vhd third_party/t65/rtl/T65_ALU.vhd \
          third_party/t65/rtl/T65_MCode.vhd third_party/t65/rtl/T65.vhd
RTL = rtl/sbc_pkg.vhd rtl/bus_decode.vhd rtl/mem/sync_ram.vhd rtl/mem/rom.vhd \
      rtl/mem/char_rom.vhd rtl/peripherals/reg_stub.vhd rtl/peripherals/via6522.vhd \
      rtl/peripherals/uart6551.vhd rtl/peripherals/vic_core.vhd \
      rtl/peripherals/vic_pixel_gen.vhd \
      rtl/cpu/t65_adapter.vhd rtl/cpu6502_slot.vhd rtl/sbc_top.vhd \
      rtl/sbc_t65_top.vhd
SIM = sim/tb_bus_decode.vhd sim/tb_sbc_reset.vhd sim/tb_sbc_bus_write.vhd \
      sim/tb_sbc_sram_readback.vhd sim/tb_via6522.vhd sim/tb_uart6551.vhd \
      sim/tb_rom_image.vhd sim/tb_t65_adapter.vhd sim/tb_sbc_t65_boot.vhd \
      sim/tb_sbc_t65_uart.vhd sim/tb_sbc_t65_via.vhd sim/tb_sbc_t65_irq.vhd \
      sim/tb_sbc_t65_kernel_smoke.vhd sim/tb_vic_core.vhd sim/tb_char_rom.vhd \
      sim/tb_vic_pixel_gen.vhd sim/tb_vic_raster_irq.vhd sim/tb_sbc_vic_display.vhd

.PHONY: analyze roms test clean hardware_analyze hardware_synth

analyze:
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL)

roms:
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(CHESS_ROM_HEX) ../roms/chess.rom
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(SBC_ROM_HEX) ../roms/kernel.rom@0x0000 ../roms/msbasic.rom@0x1000

test: roms
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL) $(SIM)
	$(GHDL) -e $(GHDL_FLAGS) tb_bus_decode
	$(GHDL) -r $(GHDL_FLAGS) tb_bus_decode $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_reset
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_reset $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_bus_write
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_bus_write $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_sram_readback
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_sram_readback $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_via6522
	$(GHDL) -r $(GHDL_FLAGS) tb_via6522 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_uart6551
	$(GHDL) -r $(GHDL_FLAGS) tb_uart6551 $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_core
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_core $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_char_rom
	$(GHDL) -r $(GHDL_FLAGS) tb_char_rom $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_pixel_gen
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_pixel_gen $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vic_raster_irq
	$(GHDL) -r $(GHDL_FLAGS) tb_vic_raster_irq $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_vic_display
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_vic_display $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_rom_image
	$(GHDL) -r $(GHDL_FLAGS) tb_rom_image $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_t65_adapter
	$(GHDL) -r $(GHDL_FLAGS) tb_t65_adapter $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_boot
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_boot $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_uart
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_uart $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_via
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_via $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_irq
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_irq $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_kernel_smoke
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_kernel_smoke $(GHDL_RUN_FLAGS)

clean:
	$(GHDL) --clean

## ============================================================================
## Hardware Build Targets (PIX16 Spartan-6 Board)
## ============================================================================

HARDWARE_RTL = rtl/sbc_pkg.vhd \
               rtl/mem/char_rom.vhd rtl/peripherals/vic_core.vhd \
               rtl/peripherals/vic_pixel_gen.vhd \
               rtl/boards/pix16_board.vhd rtl/pix16_top.vhd

hardware_analyze:
	$(GHDL) -a $(GHDL_FLAGS) $(HARDWARE_RTL)
	@echo "Hardware design analysis complete"

hardware_synth:
	@echo "To synthesize for PIX16 board, use Xilinx ISE:"
	@echo "  1. ise pix16_display.ise"
	@echo "  2. Process > Run All"
	@echo "  3. Program FPGA with pix16_top.bit"
	@echo ""
	@echo "Or create project with:"
	@echo "  xtclsh scripts/create_ise_project.tcl"

hardware_build: hardware_analyze hardware_synth
	@echo "Hardware build setup complete. See BUILD_PIX16.md for details."
