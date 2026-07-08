# MultiCalc

MultiCalc is an 80-column spreadsheet for the 6502 SBC in the spirit of the
1980s classics Multiplan and Lotus 1-2-3. It is a real cc65/cl65 machine-code
PRG with a tiny BASIC loader and hidden machine-code entry at `$1000`: it draws
straight into the VIC 80-column text RAM, reads raw keys from the VIA/PS/2
keyboard path, and loads/saves worksheets through the disk device.

Source lives in [examples/spreadsheet/](../examples/spreadsheet/); its
[README](../examples/spreadsheet/README.md) is the quick source tour. This page
is the user manual.

## Building

```sh
make spreadsheet
```

Outputs `data/disk/spreadsheet.prg`, `data/sdcard/spreadsheet.d64`, the sample
`data/disk/demo.mc`, and staged copies under `bin/data/`.

## Running

MultiCalc targets the FPGA machine configuration (`fpga.ini`).

- **Real FPGA (UART upload):** run
  `D:\Development\6502-sbc-fpga\roms\6502\upload\spreadsheet.bat [COMx]`.
  The monitor parses the PRG, uploads the BASIC loader to `$0301` and the hidden
  machine-code part to `$1000`, then releases back to EhBASIC. `RUN` starts it
  via `CALL 4096`. Add `run` as second argument to start `$1000` immediately.
- **Real FPGA (D64):** mount the D64, `LOAD "SPREADSHEET"`, then `RUN`.
- **Emulator:** drag-and-drop `data/disk/spreadsheet.prg` onto the `fpga.ini`
  window (or pass `--load`).

It opens directly on the worksheet grid; press `?` for on-screen help.
Quit with `/ Q Q`; MultiCalc restores the BASIC screen state and re-enters
EhBASIC.

## The screen

```text
A1: =SUM(B4:D4)                                  MULTICALC  CELLS 35/80    <- status / edit line
           A          B        C        D       [E] ...                    <- column headers (current col marked)
> 4 SALES             12500    13850    15200[  41550]                     <- grid; cursor cell in [brackets]
  ...                                                                       <- 20 scrolling rows over A1..Z60
MESSAGE LINE                                                                <- results / errors
/ MENU   ARROWS MOVE   RET EDIT   TYPE NUMBER/LABEL/=FORMULA                <- key hint
                                                                            <- entry / prompt line
```

The status line shows the current cell's reference and its raw contents (the
formula, not just the value). The character ROM only has upper-case glyphs, so
all text is folded to upper case on the way to the screen.

## Entering data

Just start typing — the first character decides the type (Lotus-style):

| You type | Becomes |
| --- | --- |
| `123`, `12.5`, `-8` | a number (fixed point, 2 decimals; `.` or `,` accepted) |
| `SALES`, any letter | a text label |
| `=A1+B1` | a formula |

`RETURN` re-edits the current cell; `ESC` cancels an entry.

## Formulas

- Operators `+ - * /` with correct precedence and parentheses, e.g.
  `=(A1+A2)*B1`; unary minus `=-A1`.
- Cell references `A1`..`Z60`.
- Functions over a range or list —
  `=SUM(A1:A9)`, `=AVG(...)`, `=MIN(...)`, `=MAX(...)`, `=COUNT(...)`
  (both `SUM(...)` and `@SUM(...)` spellings work).
- Recalculation resolves out-of-order dependency chains automatically; `/ R`
  forces a recalc.

Values are 32-bit fixed point scaled by 100 (two decimal places). Division by
zero and bad references show `ERR` in the cell.

## Commands — press `/`, then the underlined letter

| Key | Command | Action |
| --- | --- | --- |
| G | Goto | jump to a cell reference |
| B | Blank | erase the current cell |
| C | Copy | copy the current cell to a cell or range, adjusting relative references (`A1:A9` replicates a column) |
| W | Width | set the current column width (3–30) |
| F | Format | `G` general, `0/1/2` fixed decimals, `$` currency |
| R | Recalc | recalculate the sheet |
| S | Save | write the worksheet to disk (`<name>.mc`) |
| L | Load | read a worksheet from disk |
| N | New | empty sheet |
| H | Help | on-screen reference |
| Q | Quit | leave MultiCalc |

The command bar underlines each hot-key using the VIC underline text attribute
(see below), the way Multiplan marked its command keys.

## Sample worksheet

The demo budget is not built into the PRG (to save RAM). `make spreadsheet`
generates `data/disk/demo.mc`; open it in MultiCalc with `/ L` then `DEMO`.

## Underline text attribute

MultiCalc enables the VIC underline attribute by writing `$06` to `TEXT_ATTR`
(`$9005`): bit 1 = 80-column mode, bit 2 = underline. With bit 2 set, a
character whose **bit 7** is set is underlined and the glyph index is the low 7
bits. This is how the command hot-keys are underlined without a second
attribute plane (there is no room for one in the 2 KiB text window). The
attribute is implemented in both the emulator ([src/vic_sdl.c](../src/vic_sdl.c),
[docs/VIC.md](./VIC.md)) and the FPGA VIC (`vic_vga.vhd`, `underline_mode`).

## Disk save/load

Save/Load talk to the emulator disk device (host files under `data/disk/`). On
the real FPGA the `$8824` device is the D64 GoDrive and kernel write support is
not yet implemented, so on-hardware persistence is future work; the feature is
fully functional under the emulator.

## Fitting real hardware RAM

The board only has ~24 KB of usable contiguous RAM, `$0000-$5FFF` — `$6000-$7FFF`
is the VIC bitmap-framebuffer window and `$8000+` is VIC/I-O, **not** general
RAM. So [spreadsheet.cfg](../examples/spreadsheet/spreadsheet.cfg) keeps
everything below `$6000`:

```text
$0002-$001B  cc65 zero page
$0200-$0FFF  BSS (worksheet state)
$1000-$55E0  code + data (loaded image)
$5A00-$6000  cc65 C stack
```

The PC emulator has flat SRAM up to `$7FFF`, so an earlier build that put the C
stack at `$8000` ran on the emulator but crashed on hardware.

## Keyboard

Raw key input arrives through the VIA keyboard port (`$8801/$880D`) fed by the
PS/2 keyboard path. MultiCalc deliberately does not poll the serial UART in the
normal UI; UART remains reserved for monitor/upload workflows. PS/2 arrows
(PETSCII `$11/$1D/$91/$9D`) and terminal-style escape sequences injected through
the keyboard path both move the cursor.

## Architecture

The logic is split from the hardware:

- [sheet.c](../examples/spreadsheet/sheet.c) / [sheet.h](../examples/spreadsheet/sheet.h)
  — the portable **engine**: sparse cell store, formula parser/evaluator, number
  formatting, references, relative-copy and the save/load image. No hardware
  access; unit-tested on the host.
- [spreadsheet.c](../examples/spreadsheet/spreadsheet.c) — the UI and hardware
  glue (screen drawing, keyboard, disk). The drawing routines also compile on
  the host so the 80×25 layout can be rendered with `tools/render_sheet.c`.

The grid renderer keeps redraws incremental: simple cursor moves repaint only
the affected rows, while full grid refreshes compose one 80-column line at a
time from the sparse cell pool and write only character positions whose final
value changed.  That avoids clear-then-redraw flicker without turning cursor
movement into a full-screen update.

## Tests

```sh
make test-sheet        # engine: refs, numbers, formulas, functions, recalc, copy, persistence
make test-sheet-disk   # end-to-end disk save/load round-trip through the real disk device
```

Both run as part of `make check`. Render the layout to the terminal without the
emulator:

```sh
gcc -Iexamples/spreadsheet tools/render_sheet.c examples/spreadsheet/sheet.c -o render_sheet
./render_sheet          # demo budget
./render_sheet blank    # empty sheet
./render_sheet menu     # command bar with underlined hot keys
```

## Limits

- Sheet `A1..Z60`; up to 80 non-empty cells (a "sheet full" message appears when
  the pool is exhausted, VisiCalc-style).
- Cell entries up to 27 characters.
- Values are 32-bit fixed point scaled by 100 (two decimals).
