# VIC (Video Interface Controller)

## Summary

The emulator VIC provides a text display, color attributes, and a bitmap framebuffer, all memory-mapped and rendered via SDL.

## Address Map

- Text/Color RAM: `$8000-$87FF` (2 KB)
- VIC registers: `$9000-$900F`
- Bitmap RAM: `$9010-$AF4F` (8000 bytes)

## Text Mode

- Resolution: 40 columns x 25 rows
- Character cell: 8x8 pixels
- Character set: 256 glyph slots in built-in ROM
- Color attributes: packed background/foreground nibble per cell

Text/color layout inside the 2 KB text window:

- `0x000-0x3E7` (1000 bytes): character codes
- `0x400-0x7E7` (1000 bytes): per-cell color attributes

## Register Map

| Address | Name | Description |
|---|---|---|
| `$9000` | MODE | `0=text`, `1=bitmap` |
| `$9001` | CURSOR_X | Cursor column (0-39) |
| `$9002` | CURSOR_Y | Cursor row (0-24) |
| `$9003` | TEXT_COLOR | Foreground color (0-15) |
| `$9004` | BG_COLOR | Background color (0-15) |

## Color Indexes

| Value | Color |
|---|---|
| 0 | black |
| 1 | white |
| 2 | red |
| 3 | cyan |
| 4 | purple |
| 5 | green |
| 6 | blue |
| 7 | yellow |
| 8 | orange |
| 9 | brown |
| 10 | light red |
| 11 | dark gray |
| 12 | gray |
| 13 | light green |
| 14 | light blue |
| 15 | light gray |

## SDL Rendering

The SDL backend opens a `640x400` window (2x scale) and continuously renders VIC state.

- ESC or window close exits emulation
- Keyboard input is injected via VIA keyboard queue

## Basic Usage from 6502

```asm
; Write 'A' to first screen cell
LDA #'A'
STA $8000

; Set text mode
LDA #$00
STA $9000

; Set cursor to x=10, y=5
LDA #10
STA $9001
LDA #5
STA $9002
```

## C API Entry Points

Defined in [src/vic.h](../src/vic.h):

- `vic_init`
- `vic_bus_read` / `vic_bus_write`
- `vic_reg_read` / `vic_reg_write`
- `vic_bitmap_read` / `vic_bitmap_write`
- cursor/color helpers
- text output helpers
