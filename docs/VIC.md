# VIC (Video Interface Controller)

## Summary

The VIC provides a text display, color attributes, a bitmap framebuffer, hardware sprites, a blitter, and an interrupt system — all memory-mapped and rendered via SDL.

## Address Map

| Range | Size | Description |
|---|---|---|
| `$8000-$87FF` | 2 KB | Text/color RAM |
| `$8840-$884F` | 16 B | Blitter registers |
| `$8850-$888F` | 64 B | Sprite registers (8 × 8 bytes) |
| `$8900-$89FF` | 256 B | Sprite pixel data (8 × 32 bytes) |
| `$9000-$900F` | 16 B | VIC control registers |
| `$9010-$AF4F` | 8000 B | Bitmap RAM (320×200) |

---

## Text Mode

- Resolution: 40 columns × 25 rows
- Character cell: 8×8 pixels
- Character set: 256 glyph slots in built-in ROM (includes ASCII 0x20–0x7E plus custom symbols)
- Color attributes: packed `background[7:4] | foreground[3:0]` per cell

Text/color layout inside the 2 KB text window:

| Offset | Size | Content |
|---|---|---|
| `$000-$3E7` | 1000 B | Character codes |
| `$400-$7E7` | 1000 B | Per-cell color attributes |

---

## Bitmap Mode

- Resolution: 320×200 pixels, 1 bit per pixel
- RAM: `$9010-$AF4F` (8000 bytes, directly accessible via PEEK/POKE)
- Pixel formula: `address = $9010 + Y * 40 + INT(X / 8)`, bit position = `7 - (X AND 7)` (MSB-first, C64 convention)
- Color: per-8×8 cell from color RAM at `$8400` (same as text mode), `bg[7:4] | fg[3:0]`
- Activate: write `$01` to MODE register (`$9000`)
- Display: 2× scaled (each bitmap pixel = 2×2 screen pixels on 640×480 VGA)

### BASIC Bitmap Usage

```basic
REM Enable bitmap mode
POKE 36864, 1

REM Clear bitmap (all pixels off)
FOR I=0 TO 7999: POKE 36880+I, 0: NEXT

REM Set pixel at (X, Y)
A=36880+Y*40+INT(X/8)
POKE A, PEEK(A) OR 2^(7-(X AND 7))

REM Clear pixel at (X, Y)
A=36880+Y*40+INT(X/8)
POKE A, PEEK(A) AND (255-2^(7-(X AND 7)))

REM Set color for 8x8 cell at (CX, CY)
POKE 33792+CY*40+CX, BG*16+FG

REM Return to text mode
POKE 36864, 0
```

See [examples/bitmaptest.bas](../examples/bitmaptest.bas) for a full demo.

---

## VIC Control Registers (`$9000-$900F`)

| Address | Reg | R/W | Name | Description |
| --- | --- | --- | --- | --- |
| `$9000` | 0 | R/W | **MODE** | Bit 0 = graphics mode (`0`=text, `1`=bitmap); Bit 1 = sprites enable |
| `$9001` | 1 | R/W | **CURSOR_X** | Cursor column (0–39) |
| `$9002` | 2 | R/W | **CURSOR_Y** | Cursor row (0–24) |
| `$9003` | 3 | R/W | **TEXT_COLOR** | Foreground color (0–15) |
| `$9004` | 4 | R/W | **BG_COLOR** | Background color (0–15) |
| `$9005` | 5 | R | **FRAME_LO** | Frame counter low byte — incremented by renderer each frame |
| `$9006` | 6 | R/W | **ISR** | Interrupt Status Register (see below) |
| `$9007` | 7 | R/W | **IER** | Interrupt Enable Register (see below) |
| `$9008` | 8 | R/W | **RASTER** | Raster compare value (0–199) — triggers RASTER interrupt |
| `$9009` | 9 | R | **RLINE** | Current raster line (0–199), read-only |
| `$900A` | 10 | R/W | **CPL_LO** | Cycles per raster line, low byte (default `100`) |
| `$900B` | 11 | R/W | **CPL_HI** | Cycles per raster line, high byte (default `0`) |

---

## Interrupt System

The VIC raises the CPU's IRQ line whenever any enabled interrupt source is pending. The mechanism mirrors the VIA 6522 pattern: ISR holds flags, IER enables sources, writing to ISR acknowledges (clears) flags.

### ISR — Interrupt Status Register (`$9006`)

| Bit | Name | Description |
|---|---|---|
| 0 | IRST | Raster compare match: raster line reached the value in RASTER |
| 1 | IFRM | New frame: raster counter wrapped to line 0 |
| 2 | ISS | Sprite–sprite collision *(reserved, future)* |
| 3 | ISB | Sprite–background collision *(reserved, future)* |
| 7 | IRQ | Read-only: `1` if any enabled flag is pending (`ISR & IER != 0`) |

**Read:** returns current flags plus bit 7 computed.  
**Write:** writing `1` to a bit clears that flag (interrupt acknowledge). Writing `0` has no effect.

### IER — Interrupt Enable Register (`$9007`)

Bits 0–3 correspond to the same sources as ISR. Write `1` to enable a source, `0` to disable it.

### Raster timing

The VIC advances the raster line counter in `vic_bus_tick()`, which is called after every CPU instruction. One raster line advances every `CPL` CPU cycles:

```text
CPL = CPL_HI * 256 + CPL_LO
```

Default is 100, which matches a 1 MHz CPU at 50 Hz with 200 raster lines.  
At 2 MHz use `CPL = 200`. At 4 MHz use `CPL = 400`.

### Interrupt Handler Example

```asm
; Route IRQ vector
LDA #<irq_handler
STA $FFFE
LDA #>irq_handler
STA $FFFF

; Configure raster interrupt at line 100
LDA #100
STA $9008       ; RASTER compare = 100
LDA #$01        ; enable IRST
STA $9007       ; IER
CLI             ; clear I flag — CPU accepts IRQs

irq_handler:
    PHA
    LDA $9006       ; read ISR
    BIT #$01        ; raster interrupt?
    BEQ not_raster
    ; --- handle raster interrupt ---
    LDA #$01
    STA $9006       ; acknowledge (clear IRST)
not_raster:
    BIT #$02        ; frame interrupt?
    BEQ not_frame
    ; --- handle frame interrupt ---
    LDA #$02
    STA $9006       ; acknowledge (clear IFRM)
not_frame:
    PLA
    RTI
```

### Adjusting CPL for non-default CPU speeds

```asm
; Set CPL = 200  (2 MHz CPU, 50 Hz, 200 lines)
LDA #200
STA $900A       ; CPL_LO
LDA #0
STA $900B       ; CPL_HI
```

---

## Blitter (`$8840-$884F`)

The blitter operates on bitmap RAM (`$9010-$AF4F`). Set up the operand registers, then trigger execution with any write to `$884F`.

### Blitter Registers

| Offset | Address | Name | Description |
| --- | --- | --- | --- |
| 0 | `$8840` | X_LO | Destination X, low byte |
| 1 | `$8841` | X_HI | Destination X, bit 8 only |
| 2 | `$8842` | Y | Destination Y (0–199) |
| 3 | `$8843` | W | Width in pixels (0 = 256) |
| 4 | `$8844` | H | Height in pixels (0 = 256); for LINE/CIRCLE = endpoint or radius |
| 5 | `$8845` | SRC_X_LO | Source X low byte (COPY only) |
| 6 | `$8846` | SRC_X_HI | Source X bit 8 (COPY only) |
| 7 | `$8847` | SRC_Y | Source Y (COPY only) |
| 8 | `$8848` | COLOR | Pixel value (bit 0: `0`=clear, `1`=set) |
| 9 | `$8849` | OP | Operation code (see table below) |
| 15 | `$884F` | TRIGGER | Write any value to execute |

### Blitter Operations (OP codes)

| OP | Name | Description |
|---|---|---|
| 0 | FILL | Fill W×H rectangle at (X, Y) with COLOR |
| 1 | COPY | Copy W×H pixels from (SRC_X, SRC_Y) to (X, Y) |
| 2 | CLEAR | Clear entire bitmap RAM to zero |
| 3 | LINE | Draw line from (X, Y) to (W, H) with COLOR |
| 4 | CIRCLE | Draw circle centered at (X, Y) with radius W and COLOR |
| 5 | SCROLL_UP | Scroll bitmap up by H pixels (rows), fill bottom with zero |
| 6 | FILL_CIRCLE | Draw filled circle centered at (X, Y) with radius W and COLOR |
| 7 | INVERT | Invert all pixels in W×H rectangle at (X, Y) |

### Blitter Example (fill a 40×40 box at (10, 20))

```asm
LDA #10 : STA $8840   ; X_LO
LDA #0  : STA $8841   ; X_HI
LDA #20 : STA $8842   ; Y
LDA #40 : STA $8843   ; W
LDA #40 : STA $8844   ; H
LDA #1  : STA $8848   ; COLOR = set
LDA #0  : STA $8849   ; OP = FILL
STA $884F              ; TRIGGER
```

---

## Sprites (`$8850-$89FF`)

Up to 8 sprites are supported. Enable sprites by setting bit 1 of the MODE register (`$9000`).

### Sprite Registers (`$8850-$888F`, 8 bytes per sprite)

| Byte | Name | Description |
|---|---|---|
| 0 | X | Horizontal position (0–319 with bit 7 of FLAGS as X bit 8) |
| 1 | Y | Vertical position (0–199) |
| 2 | FLAGS | See flags table below |
| 3 | COLOR | Sprite color index (0–15) |
| 4 | DATA_SLOT | Pixel data slot (0–7) — which 32-byte block in sprite data RAM |

### Sprite FLAGS byte

| Bit | Constant | Description |
|---|---|---|
| 0 | `SP_FLAG_ENABLE` | Sprite is visible |
| 1 | `SP_FLAG_SIZE16` | 16×16 pixels instead of 8×8 |
| 3 | `SP_FLAG_FLIPH` | Flip sprite horizontally |
| 4 | `SP_FLAG_FLIPV` | Flip sprite vertically |
| 7 | `SP_FLAG_XHIBIT` | X coordinate bit 8 (for X > 255) |

### Sprite Pixel Data (`$8900-$89FF`, 8 slots × 32 bytes)

Each slot holds an 8×8 sprite (8 bytes) or a 16×16 sprite (32 bytes). Pixels are packed 1 bit per pixel, MSB = leftmost pixel in each byte row.

Slot address: `$8900 + DATA_SLOT * 32`

### Sprite Example

```asm
; Define sprite 0: enable, 8×8, slot 0 at (50, 30)
LDA #50  : STA $8850   ; sprite 0 X
LDA #30  : STA $8851   ; sprite 0 Y
LDA #$01 : STA $8852   ; FLAGS = enable
LDA #7   : STA $8853   ; COLOR = yellow
LDA #0   : STA $8854   ; DATA_SLOT = 0

; Write 8 bytes of pixel data to slot 0
LDA #$3C : STA $8900
LDA #$7E : STA $8901
; ...

; Enable sprites in MODE register
LDA $9000
ORA #$02
STA $9000
```

---

## Color Indexes

| Value | Color | Value | Color |
| --- | --- | --- | --- |
| 0 | black | 8 | orange |
| 1 | white | 9 | brown |
| 2 | red | 10 | light red |
| 3 | cyan | 11 | dark gray |
| 4 | purple | 12 | gray |
| 5 | green | 13 | light green |
| 6 | blue | 14 | light blue |
| 7 | yellow | 15 | light gray |

---

## SDL Rendering

The SDL backend opens a 640×400 window (2× scale) and renders VIC state at the end of each emulation batch (~10 ms at 1 MHz).

- ESC or window close exits emulation
- Keyboard input is injected into the VIA 6522 keyboard queue

---

## FPGA Color Support

The FPGA VIC implements per-cell color attributes, stored in color RAM at `$8400-$87E7` (offset `$400` within the 2 KB VRAM window). Each byte encodes `background[7:4] | foreground[3:0]` using the 16-color C64 palette.

The kernel automatically writes the current color with each character output. Color is controlled via VIC registers:

| Register | Address | BASIC POKE | Description |
|---|---|---|---|
| TEXT_COLOR | `$9003` | `POKE 36867, fg` | Foreground color (0–15) |
| BG_COLOR | `$9004` | `POKE 36868, bg` | Background color (0–15) |

### BASIC Color Examples

```basic
REM Set green text on black background
POKE 36867, 5

REM Set white text on blue background
POKE 36867, 1 : POKE 36868, 6

REM Print colored text
POKE 36867, 2 : PRINT "RED TEXT"
POKE 36867, 7 : PRINT "YELLOW TEXT"
POKE 36867, 1 : POKE 36868, 0 : REM Reset to white on black

REM Direct color RAM write (cell at row 0, col 0)
REM Color byte = bg * 16 + fg
POKE 33792, 6*16+1 : REM White on blue for first cell
```

### Color Palette

| Value | Color | Value | Color |
|---|---|---|---|
| 0 | Black | 8 | Orange |
| 1 | White | 9 | Brown |
| 2 | Red | 10 | Light red |
| 3 | Cyan | 11 | Dark gray |
| 4 | Purple | 12 | Gray |
| 5 | Green | 13 | Light green |
| 6 | Blue | 14 | Light blue |
| 7 | Yellow | 15 | Light gray |

---

## Assembly Usage Examples

```asm
; Write 'A' to first screen cell
LDA #'A'
STA $8000

; Switch to bitmap mode
LDA #$01
STA $9000

; Switch back to text mode
LDA #$00
STA $9000

; Set cursor to column 10, row 5
LDA #10 : STA $9001
LDA #5  : STA $9002

; Set foreground color to white (1), background to blue (6)
LDA #1  : STA $9003
LDA #6  : STA $9004

; Direct color RAM: set cell (0,0) to yellow on blue
LDA #$67         ; bg=6 (blue), fg=7 (yellow)
STA $8400        ; color RAM offset 0
```

---

## C API

Defined in [src/vic.h](../src/vic.h):

### Initialization and Bus Interface

- `vic_init()` — initialize VIC state and RAM
- `vic_bus_read` / `vic_bus_write` — video RAM bus callbacks
- `vic_bus_tick` — raster counter and interrupt generation (called each CPU instruction)
- `vic_reg_read` / `vic_reg_write` — control register bus callbacks
- `vic_bitmap_read` / `vic_bitmap_write` — bitmap RAM bus callbacks

### Interrupt

- `vic_irq()` — returns `true` when any enabled interrupt is pending; wire to the CPU IRQ line

### Text Output

- `vic_write_char(ch)` — write character at cursor, advance cursor
- `vic_write_string(str)` — write null-terminated string
- `vic_clear_screen()` — clear video RAM and reset cursor
- `vic_scroll_up()` — scroll text up one row

### Cursor and Color

- `vic_set_cursor(x, y)` / `vic_get_cursor(x*, y*)`
- `vic_set_text_color(color)` / `vic_get_text_color()`
- `vic_set_background_color(color)` / `vic_get_background_color()`
- `vic_get_graphics_mode()` / `vic_set_graphics_mode(mode)`

### Sprites

- `vic_sprites_enabled()` — true when bit 1 of MODE is set
- `vic_get_sprite(i)` — returns pointer to `VicSprite` descriptor for sprite `i`
- `vic_read_sprite_data(offset)` — read from sprite pixel data buffer

### Blitter and Renderer

- `vic_blitter_read` / `vic_blitter_write` — blitter register bus callbacks
- `vic_sprite_reg_read` / `vic_sprite_reg_write` — sprite register bus callbacks
- `vic_sprite_data_read` / `vic_sprite_data_write` — sprite data bus callbacks
- `vic_increment_frame()` — call from renderer each frame to update FRAME_LO counter
