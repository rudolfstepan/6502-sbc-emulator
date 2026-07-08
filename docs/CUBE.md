# Rotating 3D Cube Demo (`cube.s`)

A real-time, flicker-free wireframe cube for the FPGA high-resolution
framebuffer. The whole 3D pipeline — rotation, perspective projection and line
drawing — is computed on the 6502 every frame; nothing is precomputed into
tables. It runs as a PRG loaded at `$1000` under `fpga.ini`.

- Source: [examples/cube.s](../examples/cube.s)
- Linker config: [examples/cube.cfg](../examples/cube.cfg)
- Build script: [tools/make_cube_prg.sh](../tools/make_cube_prg.sh)

## Build and run

```
make cube-prg                     # assembles + links -> data/disk/cube.prg
make cube                         # build the emulator and run the demo
```

Or manually, then drag-and-drop / `--load` the PRG:

```
bash tools/make_cube_prg.sh
cd bin
./sbc6502 fpga.ini --load data/disk/cube.prg
```

From EhBASIC under `fpga.ini`: `LOAD "CUBE"` then `CALL 4096` (`$1000`).

## Video mode and registers

The demo uses the FPGA high-resolution framebuffer (see [VIC.md](VIC.md)):

| Register | Address | Use in this demo |
|---|---|---|
| MODE    | `$9000` | write `$20` to select 640×400 RGB332 (1 byte/pixel) |
| BANK    | `$9006` | CPU framebuffer bank (0–63); each bank is an 8 KB window at `$6000-$7FFF` |
| ISR     | `$9007` | bit 1 = new-frame (vblank) flag; write-1-to-clear |
| PAGE    | `$900F` | visible framebuffer page (0/1) |

A page is 640×400 = 256,000 bytes = 32 banks. **Page 0** is banks 0–31,
**page 1** is banks 32–63, so the visible page and the CPU's write window are
chosen independently — the basis for double buffering. A pixel at `(x, y)` on a
page lives at linear offset `y*640 + x`; the bank is `offset >> 13` (plus the
page's bank base) and the pointer into the window is `$6000 + (offset & $1FFF)`.

## The pipeline

Everything is fixed-point integer math (the 6502 has no multiply or divide, so
both are done in software; the routines were cross-checked exhaustively against
a reference before being committed).

### 1. Model — 8 vertices, 12 edges

The cube is eight corners at `(±R, ±R, ±R)` with `R = 60`, stored as signed
bytes in `vx_tab / vy_tab / vz_tab`, plus 12 edges as `(from, to)` index pairs
in `edge_from / edge_to`. `R = 60` is chosen so a corner's magnitude
`R·√3 ≈ 104` stays inside a signed byte (±127) after rotation — that keeps every
rotation multiply an 8×8 operation.

### 2. Rotation — sin/cos table + signed 8×8 multiply

`sintab` holds `round(sin(2π·i/256) · 64)` as signed bytes (−64…+64);
`cos(a) = sintab[a+64]`. The cube rotates about the Y axis then the X axis:

```
; rotate about Y
x1 = (x·cosA + z·sinA) >> 6
z1 = (z·cosA − x·sinA) >> 6 ,  y1 = y
; rotate about X
y2 = (y1·cosB − z1·sinB) >> 6
z2 = (z1·cosB + y1·sinB) >> 6 ,  x2 = x1
```

Each term is a signed 8×8→16 multiply (`smul8`), summed as 16-bit, then
arithmetically shifted right by 6 (`asr6_acc`) to undo the ×64 scaling of the
trig table. The two angles advance by +2 and +1 per frame for a steady tumble.

### 3. Perspective projection — signed 16-bit divide

```
denom = z2 + VIEW_DIST                       ; VIEW_DIST = 210, always > 0
sx = CENTER_X + 3·(x2·FOCAL / denom)         ; FOCAL = 110, CENTER = (320, 200)
sy = CENTER_Y − 3·(y2·FOCAL / denom)
```

Dividing by the depth is what makes near corners larger than far ones. The
numerator is a signed 16-bit product; the divide (`div_signed` → `divide16`) is
a restoring 16/16 division with the sign handled separately. The ×3 screen
scale is a shift-and-add. `R`, `FOCAL`, `VIEW_DIST` and the scale were chosen so
the cube stays fully on the 640×400 screen at every rotation angle, so no
clipping is needed.

### 4. Double buffering — hardware page flip locked to vblank

Each frame is drawn into the **hidden** page while the other page is shown, then
`$900F` is flipped during vertical blank, so the visible image is always a
finished frame — no flicker, no tearing. `wait_frame` first clears any pending
frame flag and then waits for the *next* real vblank edge, so the flip lands in
the blanking interval.

Clearing a whole 256 KB page every frame would be far too slow, so instead each
page remembers the twelve edges it last drew (`SAVE0` / `SAVE1`) and erases only
those (drawing them in black) before drawing the new cube in white. Because
each page holds every other frame, its saved geometry is exactly what must be
erased.

### 5. Rasterizer — axis-split Bresenham with an incremental pointer

Line drawing is the hot loop, so it is kept lean:

- The framebuffer byte address is computed **once per line**. Each step then
  nudges the pointer by ±1 (x) or ±640 (y) and only touches the bank register
  when the pointer crosses an 8 KB window edge (rare) — no per-pixel address
  recomputation.
- An **axis-split** Bresenham steps the major axis every pixel and the minor
  axis only when the decision value turns non-negative, i.e. a single sign test
  per pixel instead of two 16-bit comparisons. The four pointer-step sequences
  are ca65 macros (`STEP_XP/XN/YP/YN`) so they stay inlined.

Edges always run exactly between the projected vertices, so there are no gaps,
jitter or false crossings.

## Performance

Measured against the emulator's cycle-accurate core (which models the FPGA's
27 MHz CPU / 59.94 Hz frame cadence — one frame = 450,400 CPU cycles), averaged
over a full rotation:

| | cycles / frame | frame periods |
|---|---|---|
| worst frame | ≈ 429,000 | 0.95 |
| average     | ≈ 407,000 | 0.90 |

Every frame fits inside one vblank, so `wait_frame` pads the remainder and the
animation runs at a locked, even **60 fps**. Roughly 95 % of a frame is line
drawing and only ~4 % is the 3D math.

## Memory map

Loaded at `$1000`; code, the sin/cos table and the row-offset tables occupy a
few KB below `~$2000`. Scratch vertex sets live at `$4000-$405F`. Everything is
well below `$6000`, so it fits the real board's `$0000-$5FFF` RAM; the
`$6000-$7FFF` framebuffer window is separate banked memory.
