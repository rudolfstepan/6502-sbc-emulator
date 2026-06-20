# FPGA Roadmap

## Compatibility Target

The FPGA design should boot software built for the emulator and preserve the same
programmer-visible interfaces:

- 16-bit 6502 address space
- 8-bit data bus
- active memory-mapped devices at the emulator addresses
- IRQ OR of VIA, UART, and VIC
- reset vector fetched from ROM at `$FFFC-$FFFD`

## Component Strategy

| Component | First FPGA target | Later refinements |
|---|---|---|
| CPU | imported T65 core with local adapter | system-top integration and ROM boot tests |
| SRAM | block RAM or external SRAM bridge | wait states for slower memory |
| ROM | initialized block RAM and emulator-ROM conversion | board/vendor memory initialization formats |
| VIA 6522 | register file, GPIO, basic timers, IRQ flags | shift register, handshake pins, precise cycle timing |
| UART 6551 | basic TX/RX register interface, status, RX IRQ | baud generator and serial pin timing |
| DISK MVP | stub or SPI/SD-card bridge | FAT/raw block protocol |
| VIC | text/color RAM and VGA timing | bitmap, sprites, blitter, raster IRQ |
| Sound | ✅ large 4-voice chip (5 waveforms + ADSR + duration + mixer) wired into the Tang Primer 20K board on the PT8211 DAC; bring-up single voice kept as alternative | tune levels / per-voice features on hardware |

## Verification Plan

Start small and keep each device independently testable:

- unit test the address decoder
- unit test register read/write behavior for each peripheral
- run a ROM smoke test that writes known bytes to memory-mapped registers
- run 6502 functional tests once the CPU is integrated
- compare selected emulator traces against FPGA simulation waveforms

## Completed Smoke Tests

- `tb_bus_decode`: verifies the fixed memory map decoder.
- `tb_sbc_reset`: loads a ROM image and verifies the reset-vector path.
- `tb_sbc_bus_write`: executes a ROM-scripted write cycle to `$0002`.
- `tb_sbc_sram_readback`: writes `$42` to SRAM and reads it back through the
  system bus.
- `tb_via6522`: verifies VIA port masking, IER reads, T1 IRQ assertion, and
  T1 interrupt clearing.
- `tb_uart6551`: verifies UART reset status, TX writes, RX reads, RDRF clearing,
  overrun, programmed reset, and RX IRQ behavior.
- `tb_rom_image`: converts `roms/chess.rom` into VHDL hex and verifies the reset
  vector through the ROM component.
- `tb_t65_adapter`: analyzes/elaborates the imported T65 core through the local
  adapter and checks defined bus outputs after reset.
- `tb_sbc_t65_boot`: boots T65 through `sbc_t65_top`, executes a tiny real 6502
  ROM (`LDA #$42; STA $0002; JMP $C005`), and verifies the SRAM write cycle.
- `tb_sbc_t65_uart`: boots T65 through `sbc_t65_top`, executes a tiny real 6502
  ROM (`LDA #$41; STA $8810; JMP $C005`), and verifies the UART TX pulse/data.
- `tb_sbc_t65_via`: boots T65 through `sbc_t65_top`, executes a tiny real 6502
  ROM that writes `DDRB=$FF` and `ORB=$A5`, then verifies VIA Port B output.
- `tb_sbc_t65_irq`: boots T65 through `sbc_t65_top`, configures VIA Timer 1,
  enables IRQs, services the IRQ through `$FFFE-$FFFF`, and verifies the handler
  writes `$99` to SRAM.
- `tb_sbc_t65_kernel_smoke`: composes `kernel.rom + msbasic.rom`, boots T65, and
  verifies early kernel activity: reset fetch, VIA DDRA initialization, and
  screen-pointer setup for `$8000`.

## Imported CPU Core

T65(b) is imported under `third_party/t65/rtl` and wrapped by
`rtl/cpu/t65_adapter.vhd`. The project still uses `cpu6502_slot` in `sbc_top.vhd`
for deterministic smoke tests. `rtl/sbc_t65_top.vhd` instantiates the T65 adapter
and verifies real instruction fetch/write behavior through the existing SRAM bus.

The next CPU milestone is to resolve the larger ROM path beyond early kernel init:
the current smoke test reaches `CLRSCR`, but `STA ($zp),Y` screen writes still need
focused T65 integration work before full VIC text clear/welcome rendering can be
tested. `sim/tb_sbc_t65_indirect_vic.vhd` captures that failing path outside the
default test target.
