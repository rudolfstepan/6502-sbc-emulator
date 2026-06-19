# FPGA Architecture Overview

## System Design

The 6502 SBC FPGA is a synthesizable hardware implementation of a 6502-based single-board computer targeting real FPGA boards. The active PIX16 path is `pix16_sbc_sd_boot_top`: T65 CPU, SDRAM-backed RAM, SD-loaded 16 KB shadow ROM, VGA text output, VIA, UART, boot status screen, RAM self-test, and a UART hardware monitor. The active Tang Primer 20K bring-up path is `tang20k_sbc_top`: HDMI boot/status output, CH340 UART, KEY1 monitor entry, on-board microSD ROM loading, and an internal-BSRAM main RAM core for now. The older `sbc_minimal_top` remains useful as a compact VGA/T65 smoke-test design.

---

## SD Boot SBC — Active Board Bring-Up Paths

`pix16_sbc_sd_boot_top` wraps the current hardware workflow:

```text
PIX16 board
  -> SD card SPI core reads raw boot image
  -> sd_rom_loader validates sector 0 and streams sectors 1..32
  -> boot_shadow_rom stores the 16 KB ROM window for $C000-$FFFF
  -> boot_sdram_test verifies the SDRAM-backed main RAM path
  -> T65 is released and fetches reset vector from loaded shadow ROM
```

The board top also multiplexes the VGA output:

- during SD load and RAM test: `boot_vga_debug` shows status and errors,
- after successful boot: the SBC's `vic_vga` output is shown.

The UART output is priority-multiplexed:

1. hardware monitor while active,
2. boot debug text while boot debug is active,
3. 6502 UART output.

Pressing `KEY0` enters `uart_debug_monitor`, holds the CPU, and grants the
monitor direct read/write access to RAM, VRAM, VIA, UART, and shadow ROM. See
[UART Monitor](./UART_MONITOR.md) for commands and the live ROM upload workflow.

`tang20k_sbc_top` uses the same SD loader, boot/status renderers, UART monitor,
and shadow-ROM concept with Tang-specific board glue:

```text
Tang Primer 20K board
  -> HDMI/DVI output through tang20k_hdmi_tx
  -> CH340 UART at 230400 8N1
  -> on-board microSD/SDIO slot in SPI mode on N10/N11/R14/M8
  -> sd_rom_loader writes the 16 KB ROM window into boot_shadow_rom
  -> sbc_t65_boot_monitor_top uses internal BSRAM main RAM during bring-up
  -> KEY1 enters the UART monitor and holds the CPU
```

Without a card in the on-board microSD slot, the expected Tang behavior is a
visible boot/status screen plus UART boot debug text reporting SD init/read
failure while the CPU remains held.

### Active Memory Map

| Address Range | Size | Device | Notes |
| --- | --- | --- | --- |
| $0000-$01FF | 512 B | Internal FPGA RAM | Zero page and stack, no external wait states |
| $0200-$7FFF | ~31.5 KB | Main RAM | PIX16 uses SDRAM-backed RAM; current Tang bring-up uses internal BSRAM |
| $8000-$87FF | 2 KB | VIC text/color VRAM | $8000–$83E7 chars, $8400–$87E7 colors; shared by CPU/monitor/VIC |
| $8800-$880F | 16 B | VIA 6522 | Port B bit 0 -> board LED 1 after boot |
| $8810-$8813 | 4 B | UART 6551 | CPU UART registers |
| $8830-$8839 | 10 B | Sound channel 0 | Single-voice synth → PT8211 DAC (Tang dock); see [Sound Chip](./SOUND.md) |
| $C000-$FFFF | 16 KB | Shadow ROM RAM | Loaded from SD or patched by UART monitor |

---

## Minimal SBC — Active Implementation

### Block Diagram

```
                 pix16_sbc_minimal_top (board top)
┌────────────────────────────────────────────────────────────────┐
│                      sbc_minimal_top                           │
│                                                                │
│  ┌──────────────┐   RDY=0 when VIC steals                     │
│  │  T65 CPU     │◄──────────────────────────────┐             │
│  │  (t65_adapter│                               │             │
│  │   + T65 core)│                               │             │
│  └──────┬───────┘                               │             │
│         │  cpu_addr / cpu_dout / cpu_bus_we      │             │
│         ▼                                        │             │
│  ┌─────────────┐    ┌──────────┐   ┌──────────┐ │             │
│  │ bus_decode  │    │ CPU SRAM │   │   ROM    │ │             │
│  │             │    │  4 KB    │   │  2 KB    │ │             │
│  │ DEV_SRAM    │───►│$0000-0FFF│   │$F800-FFFF│ │             │
│  │ DEV_VIC_TEXT│    └──────────┘   └──────────┘ │             │
│  │ DEV_VIA     │───►VIA 6522 ($8800) IRQ─────────┤             │
│  │ DEV_UART    │───►UART 6551 ($8810)             │             │
│  │ DEV_ROM     │                                 │             │
│  └──────┬──────┘                                 │             │
│         │                                        │             │
│         ▼  (bus mux: CPU addr OR vic_addr)        │             │
│  ┌──────────────┐  ◄── vic_addr (during steal)   │             │
│  │   VRAM       │                                │             │
│  │  2 KB        │──────────────────────────┐     │             │
│  │ $8000-$87FF  │  vram_dout (async)        │     │             │
│  └──────────────┘                           │     │             │
│                                             ▼     │             │
│                               ┌────────────────────────────┐   │
│                               │       vic_vga              │   │
│                               │  - VGA timing (h/v counters│   │
│                               │  - Char line buffer (40 B) │   │
│                               │  - Color line buffer (40 B)│   │
│                               │  - 2-phase bus steal FSM   │──►│ vic_stealing
│                               │  - char_rom lookup         │   │
│                               │  - 16-color C64 palette    │   │
│                               │  - VGA RGB + sync output   │   │
│                               └────────────┬───────────────┘   │
│                                            │                    │
└────────────────────────────────────────────┼────────────────────┘
                                             │ vga_r/g/b, vga_hs/vs
                                             ▼
                                        VGA Monitor
```

### Bus Stealing — C64-Style Shared Bus

The VIC and CPU share a single-port VRAM via a bus multiplexer. During each horizontal blanking interval the VIC takes control of the bus in two phases to prefetch one complete row of character codes and color attributes into internal line buffers. Phase 0 fetches 40 character bytes from `$8000+`, phase 1 fetches 40 color bytes from `$8400+`. Each phase takes 41 clock cycles (1 setup + 40 reads). The CPU is halted during this time via the T65 `RDY` pin.

```
One scan line = 1600 system clock cycles (800 pixel clocks × 2)

├── H-Visible (1280 cycles) ─────────────────────────────────────┤
│   CPU runs freely                                               │
│   VIC displays from line buffer (no bus access)                 │
│                                                                 │
├── H-Blank (320 cycles) ──────────────────────────────────────┤
│   ├── 82 stolen cycles ──────────────────────────────────────┤ │
│   │   Phase 0: 1 setup + 40 char reads into linebuf          │ │
│   │   Phase 1: 1 setup + 40 color reads into colorbuf        │ │
│   │   CPU held (RDY=0) while the VIC owns the VRAM bus.      │ │
│   ├── 238 remaining cycles ──────────────────────────────────┤ │
│   │   CPU runs freely                                         │ │
```

**CPU overhead:** 82 stolen out of 1600 = about 5.1% per scan line.

CPU writes to `$8000-$87FF` are never discarded while the VIC owns VRAM. The
active SD boot cores (`sbc_t65_boot_monitor_top` and `sbc_t65_sdram_boot_top`)
latch a single pending CPU VRAM write (`vram_wr_pending`, address, data) if the
write pulse overlaps `vic_stealing`. The CPU remains held through `RDY` until
the pending write is committed on the first non-steal clock. This prevents
random stale characters when BASIC or firmware rapidly `POKE`s text VRAM while
the display is active.

### Memory Map (Minimal SBC)

| Address Range | Size | Device | Notes |
| --- | --- | --- | --- |
| $0000–$01FF | 512 B | Internal FPGA RAM | Zero page and stack, no external wait states |
| $0200–$0FFF | 3.5 KB | CPU SRAM | General RAM for the minimal build |
| $8000–$87FF | 2 KB | VRAM | Chars at $8000+, colors at $8400+; shared single-port |
| $8800–$880F | 16 B | VIA 6522 | Timer 1 → IRQ; Port B → board LEDs |
| $8810–$8813 | 4 B | UART 6551 | TX byte stream |
| $F800–$FFFF | 2 KB | ROM | Kernel + reset vector at $FFFC |

The ROM is mirrored across the full $C000–$FFFF range via `cpu_addr[10:0]` indexing.

The bus decoder still reports `$0000-$7FFF` as `DEV_SRAM`. The active top-levels
physically intercept `$0000-$01FF` and route it to a small internal RAM before the
main RAM path. This keeps 6502 zero-page, stack, IRQ entry, `JSR/RTS`, and
read-modify-write traffic off SDRAM and away from external wait states.

IRQ sources are OR-combined: `cpu_irq_n = NOT (via_irq OR uart_irq)`.

### VGA Output

640×480 @ ~60 Hz, pixel clock 25 MHz (50 MHz ÷ 2 via clock enable).  
Text mode: 40×25 characters, each rendered 2× scaled (16×16 screen pixels).  
Border: 40 px top and bottom. Character patterns from `char_rom.vhd` (8×8 pixels,
bit 7 = reverse video).

`char_rom` layout: `$00–$1F` PETSCII screen codes, `$20–$5F` ASCII uppercase/digits/punctuation,
`$60–$7F` PETSCII block/line graphics. Lowercase ASCII `$61–$7A` falls in the PETSCII
range, so keyboard/UART input is mapped to A–Z in `CHRIN_NB` before BASIC sees it,
and `CHROUT` also maps lowercase output to uppercase text. Programs that need raw
PETSCII graphics write those character codes directly to VRAM.

### Color Support

The VIC supports per-cell foreground and background colors using the C64 16-color
palette. Color attributes are stored in color RAM at `$8400–$87E7`, parallel to the
character codes at `$8000–$83E7`. Each color byte is packed as `bg[7:4] | fg[3:0]`.
Color attributes apply to both text and bitmap modes.

The VIC fetches both character and color data via two-phase bus stealing during
H-blank. The 16-color palette is implemented as constant RGB565 lookup tables
(Pepto-style C64 colors) in `vic_vga.vhd`.

**VIC color registers** (active in all top-level modules):

| Address | Register | Default | Description |
| --- | --- | --- | --- |
| `$9003` | TEXT_COLOR | 1 (white) | Foreground color index 0–15 |
| `$9004` | BG_COLOR | 0 (black) | Background color index 0–15 |

The kernel reads these registers and writes the composed color byte (`bg<<4 | fg`)
to color RAM with every character output. `CLRSCR` fills color RAM with the current
color, and `SCROLL` scrolls color RAM alongside character data.

**BASIC usage:**

```basic
POKE 36867, 5           : REM green text
POKE 36868, 6           : REM blue background
PRINT "HELLO"           : REM green on blue
POKE 33792+offset, color: REM direct color RAM write
```

See [examples/colortest.bas](../../examples/colortest.bas) for a full demo of all
16 colors with PETSCII art, and [docs/VIC.md](../../docs/VIC.md) for the complete
color palette reference.

### Bitmap Mode

The VIC supports a 320×200 pixel bitmap mode (1 bit per pixel, 2× scaled to
640×400 on VGA). Bitmap data is stored in a dedicated 8 KB block RAM mapped at
`$9010–$AF4F`. Bitmap mode is activated by writing `$01` to the MODE register
(`$9000`).

During bitmap mode, the bus-stealing FSM fetches 40 bitmap bytes per scanline
(from `$9010 + bmp_line*40`) in phase 0, and 40 color bytes (from `$8400 +
color_row*40`) in phase 1. The bitmap byte is used directly as the pixel pattern
— no char ROM lookup or reverse-video processing. Each 8×8 pixel cell shares one
color attribute from color RAM, providing 16-color foreground/background per cell.

**Pixel formula:** `address = $9010 + Y*40 + INT(X/8)`, bit = `7 - (X AND 7)`
(MSB-first, C64 convention).

**BASIC usage:**

```basic
POKE 36864, 1                          : REM bitmap mode on
A=36880+Y*40+INT(X/8)                  : REM pixel address
POKE A, PEEK(A) OR 2^(7-(X AND 7))    : REM set pixel
POKE 36864, 0                          : REM back to text
```

See [examples/bitmaptest.bas](../../examples/bitmaptest.bas) for a full demo.

The FPGA BASIC example [examples/petscii_gfx.bas](../../examples/petscii_gfx.bas)
is intentionally a pure VRAM `POKE` demo. It avoids `PRINT CHR$(96)` for graphics
because `CHROUT` is kept text-safe, and it avoids dense multi-statement BASIC
lines so it can be uploaded reliably over the UART input path.

### Kernel ROM

Source: `fpga/sw/rom_demo.s` (ca65 assembly) — built with the cc65 toolchain.

```bash
cd fpga/sw && make        # assembles, links, installs fpga/sim/hex/rom_welcome.hex
```

The kernel initialises VIA Timer 1 in free-running mode (period $FFFF ≈ 1.3 ms),
prints reset diagnostics over UART, runs a quick power-on system check, enables
the T1 interrupt, and idles. The system check probes zero page, stack RAM, main
RAM, VRAM, VIA configuration, and UART status, printing `OK` or `FAIL` for each
line before `CLI`.

The ISR fires ~750 Hz; every 256th call (~330 ms) it:

- increments a tick counter and writes two hex digits to VIC row 8,
- toggles VIA Port B bit 0 (LED blink, visible on board).

```text
Row 1:  ←↑→↓ (PETSCII block/line graphics $60–$7F, cols 4–35)
Row 2:  **** 6502 SINGLE BOARD COMPUTER ****
Row 4:  4096 BYTES RAM     2048 BYTES ROM
Row 6:  BEREIT.
Row 8:  VIA-T1:  XX    (live counter, ~3 Hz)
```

Build and upload:

```bash
cd fpga/sw
make all                                    # assemble + install sim hex
python upload_rom_demo.py --run --verbose   # upload via UART monitor
# or: make upload-demo
```

ROM hex format: `XXXX YY` (4-digit ROM offset, 2-digit byte, no comments —
the hex loader uses raw `hread`; comments cause read errors).

---

## Full SBC — Reference Implementation

`sbc_t65_top.vhd` is the full-featured integration including VIA 6522 and UART 6551.  
It is present in the project but not synthesized for the PIX16 board (Implementation seqID = 0).

### High-Level Block Diagram (Full SBC)

```
┌────────────────────────────────────────────────────────────┐
│                    sbc_t65_top                             │
│                                                            │
│  T65 CPU ──► bus_decode ──► SRAM (4 KB)                   │
│                         ──► ROM  (2 KB)                   │
│                         ──► VIA 6522  ($8800)             │
│                         ──► UART 6551 ($8810)             │
│                         ──► VIC core  ($8000, $9000)      │
│                                                            │
│  IRQ: VIA ─┐                                              │
│  IRQ: UART ├──► OR ──► CPU IRQ_N                          │
│  IRQ: VIC ─┘                                              │
└────────────────────────────────────────────────────────────┘
```

### Full Memory Map

| Address Range | Size | Device |
| --- | --- | --- |
| $0000–$7FFF | 32 KB | SRAM |
| $8000–$87FF | 2 KB | VIC Text RAM |
| $8800–$880F | 16 B | VIA 6522 |
| $8810–$8813 | 4 B | UART 6551 |
| $8820–$882F | 16 B | Disk (stub) |
| $8830–$88AD | 40 B | Sound ch 0–3 (stub) |
| $8850–$888F | 64 B | VIC Sprites (stub) |
| $8900–$89FF | 256 B | VIC Sprite Data (stub) |
| $9000–$900F | 16 B | VIC Control Regs |
| $9010–$AF4F | 40 KB | VIC Bitmap (stub) |
| $C000–$FFFF | 16 KB | ROM |

---

## Clocking

All designs use a single 50 MHz clock input.

The T65 CPU runs at effective half-speed through a toggling `cpu_enable` signal:

- `cpu_enable` toggles every system clock → T65 advances every other clock.
- Writes committed on the `cpu_enable = '0'` half-cycle (`cpu_bus_we = cpu_we AND NOT cpu_enable`).
- In the minimal SBC, `vic_stealing` additionally holds the CPU via `RDY`.

The VGA pixel clock is 25 MHz, derived from a `pixel_ce` toggle inside `vic_vga`.

## Reset Sequence

1. `reset_n` asserted low — all state cleared.
2. `reset_n` released — CPU starts reset sequence (7 internal cycles).
3. CPU reads reset vector from $FFFC–$FFFD (ROM).
4. CPU jumps to reset address ($F800 in kernel ROM).
5. Kernel initialises stack and writes welcome text to VRAM.
6. Kernel prints reset diagnostics and the system check result over UART.
7. Kernel enables interrupts and enters the UART keyboard polling loop.

---

**See Also:**

- [Modules Reference](./02_MODULES.md)
- [UART Monitor](./UART_MONITOR.md)
- [Build Instructions](../boards/pix16/README.md)
- [Simulation Guide](./06_SIMULATION.md)
