# FPGA UART Monitor and Live ROM Upload

The SD boot bitstream includes a small hardware monitor that can take over the
6502 bus through the board UART. It is meant for bring-up and firmware
development: inspect memory, patch bytes, disassemble small ranges, and upload a
new 16 KB ROM image into the shadow-ROM RAM without rewriting the SD card.

## Hardware Entry

The monitor is instantiated in `rtl/boards/pix16_sbc_sd_boot_top.vhd`.

1. Program the PIX16 with the `pix16_sbc_sd_boot_top` bitstream.
2. Open the board UART at `115200 8N1`.
3. Press hardware button `KEY0`.
4. The monitor holds the T65 through `monitor_hold`, prints:

```text
FPGA MONITOR
H for help
.
```

While the monitor is active, the CPU is stopped and CPU-side UART RX is gated
off. The monitor uses the same UART TX serializer as the boot/debug output and
the 6502 UART, but the board top gives the monitor priority while it is active.

## Commands

Commands are case-insensitive. Hex values may be entered with or without `$`.

| Command | Description |
| --- | --- |
| `H` or `?` | Print help. |
| `M addr [end]` | Hex dump memory. Dumps 16 bytes per line and appends an ASCII column. Non-printable bytes are shown as `.`. |
| `D addr [end]` | Disassemble memory starting at `addr`. If `end` is omitted, a short default range is used. |
| `U addr [end]` | Alias for `D`, following common monitor naming. |
| `E addr byte` | Write one byte to memory. |
| `W addr byte` | Alias for `E`. |
| `: addr byte` | Compact byte-write form, useful for quick patches. |
| `L addr` | Enter hex-loader mode and write sequential bytes starting at `addr`. End the upload with a single `.` line. |
| `G [addr]` | Leave the monitor and resume the 6502. With an address, the reset vector is overridden briefly and the CPU is restarted there. |

Examples:

```text
M 8000 80FF
D C000 C040
E 8050 41
L C000
```

## Accessible Address Ranges

The monitor uses a small memory-master inside `sbc_t65_sdram_boot_top.vhd`.
Currently supported ranges are:

| Range | Target |
| --- | --- |
| `$0000-$7FFF` | Main RAM. `$0000-$01FF` is internal zero-page/stack RAM; the rest is SDRAM-backed. |
| `$8000-$87FF` | VIC text VRAM. Writes are visible immediately on VGA. |
| `$8800-$880F` | VIA 6522 registers. Port B bit 0 is connected to board LED 1 after boot. |
| `$8810-$8813` | UART 6551 registers. |
| `$C000-$FFFF` | 16 KB shadow ROM RAM. This is writable by the monitor for live ROM upload. |

The current top intentionally blocks unmapped/stub video register ranges such as
bitmap, sprites, and blitter RAM because they are not physically implemented in
this hardware path yet.

## Hex Loader Mode

`L addr` switches the monitor into a raw hex-byte input mode:

```text
. L C000
LOAD HEX . END
> A9 20 8D 00 80
> 4C 00 C0
> .
OK
.
```

Rules:

- Each byte is two hex digits.
- Spaces, newlines, commas, and `$` are ignored.
- A single `.` ends the upload.
- If an odd number of hex nibbles was entered, the monitor returns `ERR`.
- Uploads may not cross holes in the monitor-accessible memory map.

For a full 16 KB ROM image, use the Python uploader instead of typing hex by
hand.

## Python Upload Tool

The helper script `tools/upload_monitor_hex.py` automates `L`, streams the image
as hex lines, sends `.`, and optionally starts the CPU with `G`.

Default settings:

| Setting | Value |
| --- | --- |
| Port | `COM15` |
| Baud | `115200` |
| Load address | `$C000` |
| Image | `tools/roms/upload_demo.rom` |

Common workflow:

```sh
python tools/upload_monitor_hex.py --port COM15 --run --verbose
```

Regenerate the bundled demo ROM first:

```sh
python tools/upload_monitor_hex.py --build-demo --port COM15 --run --verbose
```

Upload a custom binary:

```sh
python tools/upload_monitor_hex.py path/to/my.rom --port COM15 --address 0xC000 --run
```

If the upload fails with an access error, another serial terminal still has the
COM port open. Close the terminal and run the command again.

## Demo ROM Generator

`tools/make_upload_demo_rom.py` creates a simple 16 KB ROM at
`tools/roms/upload_demo.rom`. It is hand-assembled by a tiny Python builder so it
has no cc65 dependency.

The ROM is mapped for CPU addresses `$C000-$FFFF` and does the following:

1. Initialize stack and VIA Port B.
2. Clear the 2 KB text VRAM.
3. Write a few status lines to VGA.
4. Print one UART banner.
5. Toggle VIA Port B bit 0 slowly so board LED 1 blinks.

Generate it explicitly:

```sh
python tools/make_upload_demo_rom.py
```

The reset, NMI, and IRQ vectors at `$FFFA-$FFFF` all point to `$C000`, so
`G C000` is enough to start it after upload.

## SD Image vs. Monitor Upload

There are two firmware update paths:

- SD boot image: persistent across FPGA resets. Build with `make sd-boot-image`
  and write the raw image to the SD card.
- UART monitor upload: fast development loop. It modifies the shadow-ROM RAM
  after boot, so it is lost when the FPGA is reset or reprogrammed.

Use the SD image for stable firmware snapshots and the UART monitor for quick
ROM experiments.

## Useful Checks

After upload and `G C000`, the UART should print the demo banner once:

```text
[UPLOAD DEMO] ROM ACTIVE AT $C000
```

On VGA, row 2 and following rows should show the demo text. Board LED 0 is a
boot-status LED and may stay lit. Board LED 1 is driven by VIA Port B bit 0 and
should blink slowly.
