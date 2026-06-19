GHDL          ?= C:\Users\oe3sr\AppData\Local\ghdl\bin\ghdl.exe
PYTHON        ?= python
GHDL_FLAGS    ?= --std=08 --ieee=synopsys
GHDL_RUN_FLAGS ?= --ieee-asserts=disable-at-0

CHESS_ROM_HEX        = sim/generated/chess_rom.hex
SBC_ROM_HEX          = sim/generated/sbc_rom.hex
SBC_EHBASIC_ROM_HEX  = sim/generated/sbc_ehbasic_rom.hex
SBC_EHBASIC_SD_IMG   = sim/generated/sbc_ehbasic_sd.img
SBC_TEST_SD_IMG      = sim/generated/sbc_test_sd.img

T65_RTL = third_party/t65/rtl/T65_Pack.vhd third_party/t65/rtl/T65_ALU.vhd \
          third_party/t65/rtl/T65_MCode.vhd third_party/t65/rtl/T65.vhd

RTL = rtl/core/sbc_pkg.vhd rtl/core/bus_decode.vhd \
      rtl/core/mem/sync_ram.vhd rtl/core/mem/rom.vhd \
      rtl/core/mem/boot_shadow_rom.vhd \
      rtl/core/mem/sdram_if.vhd rtl/core/mem/sdram_ctrl.vhd \
      rtl/core/mem/char_rom.vhd \
      rtl/core/peripherals/reg_stub.vhd rtl/core/peripherals/via6522.vhd \
      rtl/core/peripherals/uart6551.vhd rtl/core/peripherals/vic_core.vhd \
      rtl/core/peripherals/uart_rx_ser.vhd rtl/core/peripherals/uart_tx_ser.vhd \
      rtl/core/peripherals/vic_pixel_gen.vhd rtl/core/peripherals/vic_vga.vhd \
      rtl/core/peripherals/sound_voice.vhd rtl/core/peripherals/pt8211_dac.vhd \
      rtl/core/boot/boot_debug_uart.vhd rtl/core/boot/boot_vga_debug.vhd \
      rtl/core/boot/boot_sdram_test.vhd rtl/core/boot/uart_debug_monitor.vhd \
      rtl/core/cpu/t65_adapter.vhd rtl/core/cpu6502_slot.vhd rtl/core/sbc_top.vhd \
      rtl/core/sbc_t65_top.vhd rtl/core/sbc_t65_boot_top.vhd \
      rtl/core/sbc_t65_sdram_boot_top.vhd

SIM = sim/tb/tb_bus_decode.vhd sim/tb/tb_sbc_reset.vhd sim/tb/tb_sbc_bus_write.vhd \
      sim/tb/tb_sbc_sram_readback.vhd sim/tb/tb_via6522.vhd sim/tb/tb_uart6551.vhd \
      sim/tb/tb_rom_image.vhd sim/tb/tb_t65_adapter.vhd sim/tb/tb_sbc_t65_boot.vhd \
      sim/tb/tb_sbc_t65_uart.vhd sim/tb/tb_sbc_t65_via.vhd sim/tb/tb_sbc_t65_irq.vhd \
      sim/tb/tb_sbc_t65_kernel_smoke.vhd sim/tb/tb_vic_core.vhd sim/tb/tb_char_rom.vhd \
      sim/tb/tb_sbc_t65_boot_shadow.vhd sim/tb/tb_vic_pixel_gen.vhd \
      sim/tb/tb_vic_raster_irq.vhd sim/tb/tb_sbc_vic_display.vhd \
      sim/tb/tb_sound_voice.vhd sim/tb/tb_vram_steal_race.vhd \
      sim/tb/tb_vram_read_steal.vhd

.PHONY: analyze roms sd-boot-image sd-boot-test-image test test-sd-boot-shadow \
        clean pix16 tang_primer_20k

## ============================================================================
## Simulation targets
## ============================================================================

analyze:
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL)

roms:
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(CHESS_ROM_HEX) ../roms/chess.rom
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(SBC_ROM_HEX) ../roms/kernel.rom@0x0000 ../roms/msbasic.rom@0x1000
	$(PYTHON) tools/bin_to_vhdl_hex.py --size 0x4000 --output $(SBC_EHBASIC_ROM_HEX) ../roms/kernel.rom@0x0000 ../roms/ehbasic.rom@0x1000

sd-boot-image:
	$(PYTHON) tools/make_sd_boot_image.py --output $(SBC_EHBASIC_SD_IMG) ../roms/kernel.rom@0x0000 ../roms/ehbasic.rom@0x1000

sd-boot-test-image:
	$(PYTHON) tools/make_sd_boot_image.py --output $(SBC_TEST_SD_IMG) sim/hex/rom_welcome.hex@0x3800

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
	$(GHDL) -e $(GHDL_FLAGS) tb_sound_voice
	$(GHDL) -r $(GHDL_FLAGS) tb_sound_voice $(GHDL_RUN_FLAGS) --stop-time=5ms
	$(GHDL) -e $(GHDL_FLAGS) tb_vram_steal_race
	$(GHDL) -r $(GHDL_FLAGS) tb_vram_steal_race $(GHDL_RUN_FLAGS)
	$(GHDL) -e $(GHDL_FLAGS) tb_vram_read_steal
	$(GHDL) -r $(GHDL_FLAGS) tb_vram_read_steal $(GHDL_RUN_FLAGS) -gREAD_LATENCY_FIX=true
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
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_boot_shadow
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_boot_shadow $(GHDL_RUN_FLAGS)

test-sd-boot-shadow:
	$(GHDL) -a $(GHDL_FLAGS) $(T65_RTL) $(RTL) sim/tb/tb_sbc_t65_boot_shadow.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_sbc_t65_boot_shadow
	$(GHDL) -r $(GHDL_FLAGS) tb_sbc_t65_boot_shadow $(GHDL_RUN_FLAGS)

clean:
	$(GHDL) --clean

## ============================================================================
## Hardware build targets — delegate to each board's Makefile
## ============================================================================

pix16:
	$(MAKE) -C boards/pix16

tang_primer_20k:
	$(MAKE) -C boards/tang_primer_20k
