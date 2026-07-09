# BASIC Examples

BASIC programs for the 6502 SBC emulator and FPGA system. Most examples are plain text sources you can upload via UART or type in directly at the BASIC prompt; some also have Makefile targets that build tokenized disk `.prg` files.

## Programs

### mandelbrot.bas — Mandelbrot (Text Mode)

Classic Mandelbrot set rendered as 39x23 ASCII art using `PRINT CHR$()`. Uses characters `. * O @ #` to represent iteration depth. Runs in standard text mode, finishes in a few minutes.

```
POKE 36867,5 : REM optional: green text
RUN
```

### mandelbrot2.bas — Mandelbrot (Bitmap Mode)

Full 320x200 pixel Mandelbrot set in 16-color bitmap mode. Uses a rainbow color gradient (blue, cyan, green, yellow, red, purple) mapped to iteration count. The Mandelbrot set itself is black.

Takes approximately 20 minutes at 1 MHz — watch it draw line by line, classic 8-bit style.

```
RUN
```

### mandelbrot3.bas — Mandelbrot (Bitmap Mode)

Full 320x200 pixel Mandelbrot set in 16-color bitmap mode. Uses a rainbow color gradient (blue, cyan, green, yellow, red, purple) mapped to iteration count. The Mandelbrot set itself is black.

Optimized code — watch it draw line by line, classic 8-bit style.

```
RUN
```

Press any key to return to text mode when finished.

### colortest.bas — Color Palette Test

Demonstrates all 16 C64 colors in text mode:

- Full-width title bar (white on blue)
- 16-color palette display with labels
- Text color demo (colored words)
- Background color demo (text on colored backgrounds)
- PETSCII rainbow art frame (diamonds and blocks via direct VRAM POKE)

Shows the POKE commands for setting colors at the end.

### bitmaptest.bas — Bitmap Graphics Test

Tests the 320x200 bitmap mode with basic drawing operations:

- Screen border (full pixel frame)
- Diagonal lines (corner to corner)
- Filled rectangle
- Four colored quadrants (red, green, cyan, yellow via color RAM)
- White-on-purple box overlay

Press any key to return to text mode.

### cube.s — Real-Time 3D Rotating Wireframe Cube

FPGA-runtime PRG that shows a rotating 3D wireframe cube in 640x400 RGB332
mode. The full 3D pipeline runs live on the 6502 every frame — no baked
tables: eight vertices are rotated about two axes with a sin/cos table and a
signed 8×8 multiply, perspective-projected with a signed 16-bit divide, and
drawn with an axis-split Bresenham rasterizer. Hardware page flipping (`$900F`,
banks 0–31 / 32–63 in the `$6000-$7FFF` window selected by `$9006`) gives
flicker-free, tear-free double buffering locked to vertical blank at 60 fps.

See [docs/CUBE.md](../docs/CUBE.md) for the full walk-through of the math,
fixed-point conventions, double buffering and the rasterizer.

```
make cube-prg
cd bin
./sbc6502 fpga.ini --load data/disk/cube.prg
```

From EhBASIC under `fpga.ini`, load it from the disk folder with `LOAD "CUBE"`
and start it with `CALL 4096`.

### fireworks.s — Hardware Blitter Pixel Fireworks

FPGA-runtime PRG that drives the VIC framebuffer blitter directly. It switches
to 640x400 RGB332 mode, clears the page with a blitter fill, then animates
expanding colored bursts by issuing many tiny blitter fill commands through
`$8840-$884F`. No blitter line command is used; the trails are made from
sprayed 2x2 pixel sparks.

```
make fireworks-prg
D:\Development\6502-sbc-fpga\roms\6502\upload\fireworks.bat COM15
```

### water.s - Hardware Blitter Liquid Water

FPGA-runtime PRG that fills a dark blue base and animates hundreds of tiny,
offset droplets with the VIC framebuffer blitter. It uses only 1x1 and small
rectangle fill commands through `$8840-$884F`, plus small bright glints, to
make the screen feel like moving liquid instead of regular bars.

```
make water-prg
D:\Development\6502-sbc-fpga\roms\6502\upload\water.bat COM15
```

### petscii_gfx.bas — PETSCII Graphics Demo

Direct VRAM POKE demo that writes PETSCII block and line-drawing characters to the 40x25 text screen. Bypasses `CHROUT` to place raw character codes (`$60`-`$7F`) that would otherwise be converted by the kernel's `to_upper` routine.

### adventure.bas — Crypt of the 6502

Text adventure game with room exploration, item collection, and puzzle solving. Navigate with `N/S/E/W`, interact with `TAKE`, `DROP`, `USE`, `LOOK`, `INV`.

### spreadsheet/ — Sheet64

Small spreadsheet built as a real cc65/cl65 machine-code PRG. It provides an
A1-H16 grid, labels, numbers, cell references, and one-operator formulas such as
`=A1+B1`, `=A1-B1`, `=A1*B1`, and `=A1/B1`.

Build the virtual SD-card D64 image and load the program:

```
make spreadsheet
LOAD "!"
LOAD "SPREADSHEET"
```

`make spreadsheet` creates `data/disk/spreadsheet.prg` and
`data/sdcard/spreadsheet.d64`. The source lives in `examples/spreadsheet/` and
is linked at `$1000` with a normal two-byte PRG load header. It is not BASIC;
drag and drop of `data/disk/spreadsheet.prg` starts the machine program
directly in the emulator.

When running the FPGA ROM with `sbc6502 fpga.ini`, the mount menu is the ROM's
own command:

```
LOAD "!"
LOAD "$"
```

## Quick Reference

### Text Mode Colors

```
POKE 36867, fg           foreground color (0-15)
POKE 36868, bg           background color (0-15)
```

### Bitmap Mode

```
POKE 36864, 1            enable bitmap mode (320x200)
POKE 36864, 0            return to text mode

Set pixel at (X, Y):
A = 36880 + Y*40 + INT(X/8)
POKE A, PEEK(A) OR 2^(7-(X AND 7))

Set cell color (8x8 block at CX, CY):
POKE 33792 + CY*40 + CX, BG*16 + FG
```

### Color Palette

| Index | Color       | Index | Color       |
|-------|-------------|-------|-------------|
| 0     | Black       | 8     | Orange      |
| 1     | White       | 9     | Brown       |
| 2     | Red         | 10    | Light Red   |
| 3     | Cyan        | 11    | Dark Gray   |
| 4     | Purple      | 12    | Gray        |
| 5     | Green       | 13    | Light Green |
| 6     | Blue        | 14    | Light Blue  |
| 7     | Yellow      | 15    | Light Gray  |

### Memory Map

| Address | Decimal | Description             |
|---------|---------|-------------------------|
| $8000   | 32768   | Text/char RAM (1000 B)  |
| $8400   | 33792   | Color RAM (1000 B)      |
| $9000   | 36864   | VIC MODE register       |
| $9001   | 36865   | Cursor X (0-39)         |
| $9002   | 36866   | Cursor Y (0-24)         |
| $9003   | 36867   | Text color (0-15)       |
| $9004   | 36868   | Background color (0-15) |
| $9010   | 36880   | Bitmap RAM (8000 B)     |
