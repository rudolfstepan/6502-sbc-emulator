# MultiCalc

An 80-column spreadsheet for the 6502 SBC (FPGA build) in the spirit of the
80s classics Multiplan and Lotus 1-2-3.  It is a real cc65/cl65 machine-code
PRG with a C64-style BASIC loader: `LIST` shows only `10 CALL 4096`, while the
machine-code image remains hidden and linked at `$1000`.  It draws straight into
the VIC 80-column text RAM, reads raw keys from the VIA keyboard port, and
loads/saves worksheets through the disk device.

## Building

From the repository root:

```sh
make spreadsheet
```

Outputs:

- `data/disk/spreadsheet.prg`
- `data/sdcard/spreadsheet.d64`
- staged copies below `bin/data/`

## Running

MultiCalc targets the **FPGA machine configuration** (`fpga.ini`).

- **Real FPGA:** mount the D64, `LOAD "SPREADSHEET"`, then start it with
  **`RUN`**.  The visible BASIC loader calls the cc65 entry at `$1000`.
- **UART monitor upload:** parse the PRG, upload the BASIC loader to `$0301`
  and the hidden machine-code part to `$1000`, then release back to EhBASIC:
  `D:\Development\6502-sbc-fpga\roms\6502\upload\spreadsheet.bat [COMx]`.
  `RUN` then executes the uploaded loader's `CALL 4096`. Add `run` as second
  argument to start `$1000` immediately.
- **Emulator:** drag-and-drop `data/disk/spreadsheet.prg` onto the `fpga.ini`
  window (or `--load`).

Quit with `/ Q Q`; MultiCalc restores the 80-column BASIC screen state and
re-enters EhBASIC.

### Fitting real hardware RAM

The board only has ~24 KB of usable contiguous RAM, `$0000-$5FFF` — `$6000-$7FFF`
is the VIC bitmap-framebuffer window and `$8000+` is VIC/I-O, **not** general
RAM.  So the linker script [`spreadsheet.cfg`](spreadsheet.cfg) keeps everything
below `$6000`:

```text
$0002-$001B  cc65 zero page
$0200-$0FFF  BSS (worksheet state)
$1000-$55E0  code + data (loaded image)
$5A00-$6000  cc65 C stack
```

(The PC emulator has flat SRAM up to `$7FFF`, so an earlier build that put the C
stack at `$8000` ran on the emulator but crashed on hardware.)

## Screen

```text
A1: =SUM(B4:D4)                                  MULTICALC  CELLS 35/150   <- status/edit line
           A          B        C        D       [E] ...                    <- column headers (current col marked)
> 4 SALES             12500    13850    15200[  41550]                     <- grid; cursor cell in [brackets]
  ...                                                                       <- 20 scrolling rows, A1..Z60
MESSAGE LINE                                                                <- results / errors
/ MENU   ARROWS MOVE   RET EDIT   TYPE NUMBER/LABEL/=FORMULA                <- key hint
                                                                            <- entry / prompt line
```

The character ROM only has upper-case glyphs, so all text is folded to
upper case on the way to the screen.

## Entering data

Just start typing — the first character decides the type (Lotus style):

- `123`, `12.5`, `-8`  → a **number** (fixed point, 2 decimals; `.` or `,` accepted)
- `SALES`, any letter  → a **text label**
- `=A1+B1`             → a **formula**
- `RETURN`             → re-edit the current cell; `ESC` cancels an entry

## Formulas

- Operators `+  -  *  /` with correct precedence and parentheses, e.g.
  `=(A1+A2)*B1`, unary minus `=-A1`.
- Cell references `A1`..`Z60`.
- Functions over a range or list:
  `=SUM(A1:A9)`, `=AVG(...)`, `=MIN(...)`, `=MAX(...)`, `=COUNT(...)`.
  Both `SUM(...)` and `@SUM(...)` spellings work.
- Recalculation resolves out-of-order dependency chains automatically; press
  `/ R` to force a recalc.

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

## Sample worksheet

The demo budget is **not** built into the PRG (to save RAM).  `make spreadsheet`
generates `data/disk/demo.mc`; open it in MultiCalc with `/ L` then `DEMO`.

## Disk save/load

Save/Load talk to the emulator disk device (host files under `data/disk/`).  On
the **real FPGA** the `$8824` device is the D64 GoDrive and kernel write support
is not yet implemented, so on-hardware persistence is future work; the feature is
fully functional under the emulator.

## Limits

- Sheet `A1..Z60`; up to 80 non-empty cells (a "sheet full" message appears
  when the pool is exhausted, VisiCalc-style).
- Values are 32-bit fixed point scaled by 100 (two decimals).
- Cell entries up to 27 characters.

## Source files

- `sheet.h` / `sheet.c` — the portable spreadsheet **engine**: sparse cell
  store, formula parser/evaluator, number formatting, references, relative-copy
  and the save/load image.  Contains no hardware access and is unit-tested on
  the host (`make test-sheet`, `make test-sheet-disk`).
- `spreadsheet.c` — the UI and hardware glue (screen drawing, keyboard, disk).
  The drawing code also compiles on the host so the 80×25 layout can be
  rendered and reviewed with `tools/render_sheet.c`.
- `sbc6502_io.s` — VIA keyboard/character wrappers.
- `prg_header.s` — two-byte PRG load header.
- `spreadsheet.cfg` — cc65/ld65 memory layout.

## Tests

```sh
make test-sheet        # engine: refs, numbers, formulas, functions, recalc, copy, persistence
make test-sheet-disk   # end-to-end disk save/load round-trip through the real disk device
```

Render the layout to the terminal without the emulator:

```sh
gcc -Iexamples/spreadsheet tools/render_sheet.c examples/spreadsheet/sheet.c -o render_sheet
./render_sheet          # demo budget
./render_sheet blank    # empty sheet
./render_sheet menu     # command bar with underlined hot keys
```
