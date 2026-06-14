# SD Bootloader Plan

Goal: keep the FPGA bitstream stable and load the SBC firmware image from an
SD card into a writable 16 KB shadow-ROM RAM at power-up.

## Board Pins

### PIX16

The vendor demo `pix16/demo/20_2_sd_sdram_an430_lcd` confirms the SD socket pins:

| Signal | FPGA Pin | SD Pin | SPI Role |
|--------|----------|--------|----------|
| `sd_dclk` | `M3` | `CLK`  | SCK |
| `sd_ncs`  | `N3` | `DAT3` | CS, active low |
| `sd_miso` | `L4` | `CMD`  | controller output to card |
| `sd_mosi` | `L5` | `DAT0` | controller input from card |

The existing names follow the vendor demo. Note that `sd_miso`/`sd_mosi` are named
from the demo controller's perspective, not the SD card label.

### Tang Primer 20K

The Tang Primer 20K has an on-board microSD/SDIO slot. The current boot path uses
it in SPI mode:

| SBC signal | FPGA Pin | SDIO signal | SPI Role |
|------------|----------|-------------|----------|
| `sd_dclk` | `N10` | CLK  | SCK |
| `sd_ncs`  | `N11` | DAT3 | CS, active low |
| `sd_mosi` | `R14` | CMD  | controller output to card |
| `sd_miso` | `M8`  | DAT0 | controller input from card |

Unused SDIO pins in this SPI-mode path are `DAT1=M7`, `DAT2=M10`, and card-detect
`DET_A=D15`.

These are dual-purpose pins on the Gowin device. The Tang GowinEDA project must
enable the `SSPI` dual-purpose option, otherwise P&R reports errors such as
`PR2017` for `sd_miso=M8`.

## Vendor SD Core

The demo provides a sector-level SD SPI controller. The needed files are copied
into `fpga/third_party/alinx_sd/` so the FPGA project does not depend on a demo
directory outside the normal RTL tree:

| File | Purpose |
|------|---------|
| `third_party/alinx_sd/sd_card_top.v` | Top wrapper: init, sector read/write, SPI master |
| `third_party/alinx_sd/sd_card_sec_read_write.v` | SD init sequence plus CMD17/CMD24 sector access |
| `third_party/alinx_sd/sd_card_cmd.v` | Command/response and 512-byte data token handling |
| `third_party/alinx_sd/spi_master.v` | SPI byte engine |

The useful interface for our loader is:

```verilog
sd_init_done
sd_sec_read
sd_sec_read_addr
sd_sec_read_data
sd_sec_read_data_valid
sd_sec_read_end
```

## First Boot Format

Keep the first milestone raw-sector based, without FAT:

```text
Sector 0:
  offset 0x00: "SBCROM01"
  offset 0x08: little-endian load address, expected $C000
  offset 0x0A: little-endian length, expected 16384
  offset 0x0C: little-endian checksum or CRC32

Sector 1..32:
  16 KB firmware image for CPU address range $C000-$FFFF
```

This lets a host-side tool write an SD image directly and avoids a FAT parser in
the first FPGA boot path.

## Hardware Flow

```text
reset_n low/high
  -> keep T65 held in reset or RDY=0
  -> initialize SD card
  -> read sector 0 and validate header
  -> read sectors 1..32
  -> write bytes into shadow ROM address 0..16383
  -> set boot_done=1
  -> release T65
  -> CPU reads reset vector from loaded image offset $3FFC/$3FFD
```

## Required Project Modules

| Module | Responsibility |
|--------|----------------|
| `rtl/mem/boot_shadow_rom.vhd` | 16 KB RAM, loader-write port, CPU-read port |
| `rtl/boot/sd_rom_loader.v` | Requests sectors and writes valid bytes to shadow ROM |
| `rtl/sbc_t65_boot_top.vhd` | T65 SBC core with boot-loaded ROM at `$C000-$FFFF` |
| `rtl/sbc_t65_sdram_boot_top.vhd` | Current SBC core with SDRAM main RAM, shadow ROM, VGA, and monitor bus master |
| `rtl/sbc_t65_boot_monitor_top.vhd` | Tang bring-up core with internal BSRAM main RAM, shadow ROM, VGA, and monitor bus master |
| `rtl/boards/pix16_sbc_sd_boot_top.vhd` | PIX16 board top with SD pins, boot VGA, UART monitor, and CPU gated by boot/RAM-test status |
| `boards/tang_primer_20k/rtl/tang20k_sbc_top.vhd` | Tang board top with HDMI, CH340 UART, on-board SD pins, boot VGA, and KEY1 monitor |
| `rtl/boot/boot_vga_debug.vhd` | VGA boot/status screen for SD, loader, and RAM-test state |
| `rtl/boot/boot_sdram_test.vhd` | SDRAM self-test before CPU release |
| `rtl/boot/uart_debug_monitor.vhd` | Hardware monitor that can patch the loaded shadow ROM after boot |
| `tools/make_sd_boot_image.py` | Creates raw SD boot image from `kernel.rom + ehbasic.rom` |
| `tools/upload_monitor_hex.py` | Streams a binary into shadow ROM through the UART monitor |

## Integration Notes

- The current PIX16 minimal top uses a 2 KB ROM at `$F800-$FFFF`; the SD boot path
  should move hardware to the full 16 KB ROM decode used by the emulator:
  `$C000-$FFFF`.
- Use the existing `bus_decode.vhd` ROM range, but replace synthesis-time `rom.vhd`
  with `boot_shadow_rom.vhd` in the board build.
- Keep a small fallback built-in ROM or LED/UART error status for SD init/header
  failures. Without a fallback, a bad card leaves the CPU permanently held.

## Build Artifacts

Create the raw SD image:

```sh
cd fpga
make sd-boot-image
```

Create the ISE project:

```sh
cd fpga
xtclsh scripts/create_sd_boot_ise_project.tcl
```

After synthesis, program the FPGA bitstream once. For ROM updates, regenerate
`sim/generated/sbc_ehbasic_sd.img` and write that raw image to the SD card.

For fast development, the same shadow-ROM RAM can be rewritten after boot through
the UART monitor:

```sh
python tools/upload_monitor_hex.py --build-demo --port COM15 --run --verbose
```

This upload path is volatile: reset or reprogramming reloads the SD-card image.
See `UART_MONITOR.md` for the command set and loader protocol.

## Current Verification

The shadow-ROM boot core has a focused GHDL test:

```sh
cd fpga
make test-sd-boot-shadow
```

This test writes a tiny ROM image through the loader port, sets `boot_done`, and
checks that the T65 executes from the loaded `$C000` reset vector path.

The full SD card path uses the copied vendor Verilog SD core and is intended for
mixed-language synthesis in Xilinx ISE and GowinEDA.

Tang bring-up has verified the boot/status screen, CH340 UART, and KEY1 monitor.
With no card in the on-board microSD slot, the expected boot debug behavior is a
repeating SD init/read failure status on UART and HDMI while the CPU remains held.
