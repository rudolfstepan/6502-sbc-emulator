# VIC Graphics Test

Comprehensive test program for the VIC bitmap mode (320x200 pixels).

## Quick Start

```bash
# Program is already in data/disk/basic.prg
./sbc6502
```

In the emulator:
```
BASIC
LOAD
RUN
```

## What the Program Tests

The program runs 6 different graphics tests:

1. **Horizontal Lines** — Draws horizontal lines spaced 20 pixels apart
2. **Vertical Lines** — Draws vertical lines spaced 32 pixels apart
3. **Checkerboard Pattern** — Draws a checkerboard pattern
4. **Rectangle** — Draws a rectangle from (50,40) to (270,160)
5. **Diagonal Line** — Draws a diagonal from top-left to bottom-right
6. **Full Screen** — Fills the entire screen with white pixels

Each test is displayed for about 2 seconds, then the screen is cleared and the next test starts.

## Technical Details

**Memory Map:**
- VIC Control Register: `$9000` (36864)
  - Value `0`: Text mode (40x25)
  - Value `1`: Bitmap mode (320x200)
- Bitmap RAM: `$9010-$AF4F` (36880-44879, 8000 bytes)

**Pixel Formula:**
```basic
X = 0-319  (horizontal)
Y = 0-199  (vertical)
BYTE_OFFSET = Y * 40 + INT(X / 8)
BIT_POSITION = 7 - (X AND 7)
ADDRESS = 36880 + BYTE_OFFSET
```

**Set pixel:**
```basic
POKE ADDRESS, PEEK(ADDRESS) OR (2^BIT_POSITION)
```

**Clear pixel:**
```basic
POKE ADDRESS, PEEK(ADDRESS) AND (255 - 2^BIT_POSITION)
```

## Creating Your Own Programs

**From a text file:**
```bash
# Create program in examples/mygfx.txt
nano examples/mygfx.txt

# Convert
python3 tools/basic_convert.py examples/mygfx.txt data/disk/basic.prg

# Load in emulator
./sbc6502
BASIC
LOAD
RUN
```

**Minimal example:**
```basic
10 REM Switch to graphics
20 POKE 36864,1
30 REM Draw pixel at (100,50)
40 A=36880+(50*40+INT(100/8))
50 POKE A,PEEK(A) OR 2^(7-(100 AND 7))
60 REM Wait for key
70 GET K$: IF K$="" THEN 70
80 REM Back to text mode
90 POKE 36864,0
100 END
```

## More Examples

- `examples/hello.txt` — Simple Hello World
- `examples/graphics.txt` — Interactive graphics demo
- `examples/gfxtest.txt` — This automated test (154 lines)

## Performance Notes

- Drawing many pixels is slow (BASIC is interpreted)
- Delay loops (`FOR W=1 TO 2000: NEXT W`) are approximate, not exact
- For faster graphics: use assembly routines via `SYS`
