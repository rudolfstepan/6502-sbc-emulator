# VHDL Modules Reference

This document covers all VHDL modules in the project. The current board bring-up
targets are `pix16_sbc_sd_boot_top` -> `sbc_t65_sdram_boot_top` and
`tang20k_sbc_top` -> `sbc_t65_boot_monitor_top`. The smaller
`pix16_sbc_minimal_top` -> `sbc_minimal_top` path remains a useful smoke test.
Modules marked *(inactive)* are present for reference or simulation but are not
included in the current SD boot build.

---

## Module Hierarchy

### Active SD Boot Build (PIX16 board)

```text
boards/pix16/rtl/
└── pix16_sbc_sd_boot_top.vhd     — PIX16 SD/SDRAM/VGA/UART board wrapper

rtl/core/
├── sbc_pkg.vhd                    — shared types, memory map, constants
├── bus_decode.vhd                 — address → device selection
├── sbc_t65_sdram_boot_top.vhd    — SBC core with SDRAM + shadow ROM
│   ├── boot/boot_debug_uart.vhd   — serial boot-status output
│   ├── boot/boot_vga_debug.vhd    — VGA boot/status/RAM-test screen
│   ├── boot/boot_sdram_test.vhd   — SDRAM self-test before CPU release
│   ├── boot/sd_rom_loader.v       — SD-sector loader into shadow ROM
│   ├── boot/uart_debug_monitor.vhd — UART machine monitor and hex loader
│   ├── cpu/t65_adapter.vhd        — T65 CPU wrapper (+ RDY bus-steal port)
│   │   └── third_party/t65/       — external T65 6502 core
│   ├── mem/sync_ram.vhd           — ZP/stack RAM and text VRAM
│   ├── mem/boot_shadow_rom.vhd    — writable 16 KB ROM window at $C000-$FFFF
│   ├── mem/sdram_if.vhd           — byte interface to board SDRAM controller
│   ├── mem/sdram_ctrl.vhd         — board SDRAM command/data controller
│   ├── mem/char_rom.vhd           — 8×8 character patterns
│   ├── peripherals/via6522.vhd    — VIA 6522: Timer 1 IRQ + Port B
│   ├── peripherals/uart6551.vhd   — UART 6551: CPU TX/RX registers
│   └── peripherals/vic_vga.vhd    — VIC: bus stealing + VGA output

third_party/alinx_sd/              — vendor SD-card SPI sector core
```

### Active SD Boot Build (Tang Primer 20K board)

```text
boards/tang_primer_20k/rtl/
├── tang20k_sbc_top.vhd            — Tang HDMI/CH340/on-board-SD board wrapper
└── tang20k_hdmi_tx.vhd            — Gowin rPLL + TMDS output wrapper

rtl/core/
├── sbc_pkg.vhd                    — shared types, memory map, constants
├── bus_decode.vhd                 — address → device selection
├── sbc_t65_boot_monitor_top.vhd  — SBC core with internal BSRAM + shadow ROM
│   ├── boot/boot_debug_uart.vhd   — serial boot-status output
│   ├── boot/boot_vga_debug.vhd    — HDMI boot/status screen
│   ├── boot/sd_rom_loader.v       — SD-sector loader into shadow ROM
│   ├── boot/uart_debug_monitor.vhd — UART machine monitor and hex loader
│   ├── cpu/t65_adapter.vhd        — T65 CPU wrapper
│   ├── mem/sync_ram.vhd           — ZP/stack RAM, main RAM, and text VRAM
│   ├── mem/boot_shadow_rom.vhd    — writable 16 KB ROM window at $C000-$FFFF
│   ├── mem/char_rom.vhd           — 8×8 character patterns
│   ├── peripherals/via6522.vhd    — VIA 6522: Timer 1 IRQ + Port B
│   ├── peripherals/uart6551.vhd   — UART 6551: CPU TX/RX registers
│   ├── peripherals/vic_vga.vhd    — VIC: bus stealing + VGA/HDMI pixel output
│   ├── peripherals/sound_voice.vhd — single-voice synth (channel 0, $8830)
│   └── peripherals/pt8211_dac.vhd  — PT8211 audio DAC I2S serializer

third_party/alinx_sd/              — vendor SD-card SPI sector core
```

### Minimal VGA Smoke Test

```text
rtl/core/
└── sbc_minimal_top.vhd            — compact T65/VGA core

boards/pix16/rtl/
└── pix16_sbc_minimal_top.vhd     — PIX16 wrapper for the minimal top
```

### Assembly toolchain

```text
fpga/sw/
├── rom_demo.s           — ca65 6502 assembly source (kernel + ISR + strings)
├── rom_demo.cfg         — ld65 linker config: 2 KB ROM at $F800
├── bin_to_fpga_hex.py   — binary → FPGA sim hex converter (skips 0xEA fill)
├── upload_rom_demo.py   — UART monitor upload script for rom_demo.bin
└── Makefile             — make all → installs ../sim/hex/rom_welcome.hex
                           make upload-demo → uploads rom_demo.bin via UART
                           make sd-ehbasic  → builds 16 KB EhBASIC ROM + SD image
```

### EhBASIC ROM toolchain

```text
fpga/tools/
├── build_fpga_ehbasic.py         — patches + assembles EhBASIC; links with kernel
│                                   --sd-image  also produces SD card boot image
└── upload_monitor_hex.py         — UART monitor upload for any .rom file

fpga/roms/
├── fpga_ehbasic_16kb.rom         — 16 KB output: kernel ($C000) + EhBASIC ($D000)
└── fpga_ehbasic_16kb.img         — raw SD boot image (512 B header + 16 KB payload)

tools/kernel/
└── kernel.s                      — 4 KB kernel ROM ($C000-$CFFF)
                                    jump table, CHROUT/CHRIN, CLRSCR, SCROLL
                                    to_upper: a-z → A-Z in CHRIN_NB and CHROUT
```

Build commands (from project root):

```bash
python fpga/tools/build_fpga_ehbasic.py            # ROM only
python fpga/tools/build_fpga_ehbasic.py --sd-image # ROM + SD boot image
python fpga/tools/build_fpga_ehbasic.py --upload --run --verbose  # ROM + UART upload
make -C fpga/sw sd-ehbasic                         # same as --sd-image via make
```

### Character ROM generator

```text
fpga/tools/
└── gen_petscii_char_rom.py  — regenerates rtl/mem/char_rom.vhd from Python
                               Reads existing ROM, replaces $60-$7F with
                               PETSCII-style block/line graphics, writes
                               the full VHDL file back.
```

Run: `python fpga/tools/gen_petscii_char_rom.py`

### Inactive (reference / simulation only)

```text
rtl/core/
├── sbc_t65_top.vhd                — full SBC (VIA + UART + VIC core)
├── sbc_top.vhd                    — test-mode SBC (ROM-scripted CPU slot)
├── peripherals/vic_core.vhd       — old dual-port VIC (replaced by vic_vga)
├── peripherals/vic_pixel_gen.vhd  — old pixel generator (replaced by vic_vga)
└── peripherals/reg_stub.vhd       — generic register placeholder

boards/pix16/rtl/
├── pix16_top.vhd                  — old PIX16 top (test_runner + vic_core)
└── pix16_board.vhd                — old board integration
```

---

## Package

### `sbc_pkg.vhd`

Central definitions used by every other module.

```vhdl
subtype addr_t is std_logic_vector(15 downto 0);
subtype data_t is std_logic_vector(7 downto 0);

type device_sel_t is (
  DEV_NONE, DEV_SRAM, DEV_VIC_TEXT, DEV_VIA, DEV_UART,
  DEV_DISK, DEV_VIC_BLIT, DEV_VIC_SPR, DEV_SOUND0..3,
  DEV_VIC_SPD, DEV_VIC_REG, DEV_VIC_BMP, DEV_ROM
);

function in_range(addr, first, last) return boolean;
```

---

## Top-Level Modules

### `sbc_minimal_top.vhd` — Minimal SBC Core

The complete minimal system: CPU, internal zero-page/stack RAM, SRAM, VRAM,
ROM, VIA, UART, VIC, and VGA output.

**Ports:**

```vhdl
entity sbc_minimal_top is
  generic (ROM_INIT_FILE : string := "");
  port (
    clk, reset_n  : in  std_logic;
    vga_r         : out std_logic_vector(4 downto 0);
    vga_g         : out std_logic_vector(5 downto 0);
    vga_b         : out std_logic_vector(4 downto 0);
    vga_hs, vga_vs : out std_logic;
    dbg_cpu_addr  : out addr_t;
    dbg_cpu_data  : out data_t;
    dbg_cpu_din   : out data_t;
    dbg_cpu_we    : out std_logic;
    dbg_cpu_sync  : out std_logic
  );
end entity;
```

**Key signals:**

| Signal | Description |
| --- | --- |
| `cpu_enable` | Toggles every clock — T65 effective half-speed |
| `cpu_bus_we` | `cpu_we AND NOT cpu_enable` — write on stable half-cycle |
| `cpu_rdy` | `NOT vic_stealing` — CPU halted during VIC bus steal |
| `vic_stealing` | High for 41 cycles during each H-blank |
| `vram_addr` | Mux: `vic_addr[10:0]` during steal, else `cpu_addr[10:0]` |
| `vram_we_mux` | Zero during steal (VIC only reads), else `vram_we` |
| `zp_cs` | Selects internal FPGA RAM for `$0000-$01FF` |
| `zp_we` | Write enable for zero-page/stack RAM |

**Memory instances:**

| Instance | Module | Generic | Address |
| --- | --- | --- | --- |
| `zp_ram_i` | `sync_ram` | ADDR_WIDTH=9, ASYNC_READ=true | $0000–$01FF |
| `sram_i` | `sync_ram` | ADDR_WIDTH=12, ASYNC_READ=true | $0200–$0FFF |
| `vram_i` | `sync_ram` | ADDR_WIDTH=11, ASYNC_READ=true | $8000–$87FF |
| `rom_i` | `rom` | ADDR_WIDTH=11, ASYNC_READ=true | $F800–$FFFF |

`bus_decode` still maps `$0000-$7FFF` to `DEV_SRAM`; `sbc_minimal_top` splits
that logical selection internally so zero-page and stack traffic use `zp_ram_i`
while the rest of the minimal RAM range uses `sram_i`.

---

### `boards/pix16_sbc_minimal_top.vhd` — PIX16 Board Wrapper

Thin wrapper that exposes the exact ports required by `pix16.ucf`. Instantiates
`sbc_minimal_top` and passes VGA signals through. SDRAM pins are absent (not in UCF).

```vhdl
entity pix16_sbc_minimal_top is
  generic (ROM_INIT_FILE : string := "../../../sim/hex/rom_welcome.hex");
  port (
    clk, reset_n             : in  std_logic;
    vga_out_r                : out std_logic_vector(4 downto 0);
    vga_out_g                : out std_logic_vector(5 downto 0);
    vga_out_b                : out std_logic_vector(4 downto 0);
    vga_out_hs, vga_out_vs   : out std_logic;
    key                      : in  std_logic_vector(3 downto 0);
    led                      : out std_logic_vector(1 downto 0)
  );
end entity;
```

`led(0)` is hardwired high (power indicator). `led(1)` mirrors `NOT key(0)`.

---

## CPU

### `cpu/t65_adapter.vhd` — T65 CPU Wrapper

Adapts the T65 24-bit bus to the 16-bit system bus and exposes the `RDY` pin for
bus stealing.

```vhdl
entity t65_adapter is
  port (
    clk, reset_n : in  std_logic;
    enable       : in  std_logic;          -- clock gate (div-2)
    rdy          : in  std_logic := '1';   -- '0' halts CPU (bus steal)
    irq_n, nmi_n : in  std_logic;
    data_in      : in  data_t;
    addr         : out addr_t;
    data_out     : out data_t;
    we           : out std_logic;
    sync         : out std_logic
  );
end entity;
```

`rdy` defaults to `'1'` so existing instantiations without the port remain valid.

The T65 advances only when both `enable = '1'` AND `rdy = '1'`.

Write enable derivation: `we = (NOT t65_r_w_n) AND t65_vda`.

---

## Memory

### `mem/sync_ram.vhd` — Synchronous RAM

Single-port block RAM. Used for zero-page/stack RAM, CPU SRAM, and VRAM.

```vhdl
entity sync_ram is
  generic (
    ADDR_WIDTH : positive := 15;
    ASYNC_READ : boolean  := false
  );
  port (
    clk  : in  std_logic;
    we   : in  std_logic;
    addr : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    din  : in  data_t;
    dout : out data_t
  );
end entity;
```

With `ASYNC_READ = true` the read path is combinational (write-through on `we = '1'`).
The current SD boot top uses synchronous VRAM (`ASYNC_READ = false`) so XST can
infer a compact RAM structure. `vic_vga` therefore includes a one-cycle read
latency pipeline during bus stealing.

### `mem/boot_shadow_rom.vhd` — SD/Monitor-Loaded ROM RAM

16 KB RAM for the CPU ROM window `$C000-$FFFF`.

Two write sources share the load port in `sbc_t65_sdram_boot_top`:

- SD boot loader during reset,
- UART monitor when the CPU is held.

The CPU sees it as ROM, but the monitor can patch it live for development.

### `mem/rom.vhd` — Kernel ROM

Loaded at synthesis from a hex file. Format: one `XXXX YY` entry per line
(4-digit hex offset, 2-digit hex byte, no comments — comments cause synthesis errors).

Default fill: `0xEA` (NOP). Reset vector placed at the last two entries of the 2 KB window:

```text
07FC 00   ; reset vector low  → $F800
07FD F8   ; reset vector high
```

### `mem/char_rom.vhd` — Character ROM

1 KB combinational ROM. 128 characters × 8 rows of 8 pixels.
Address: `char_code[6:0] & row[2:0]`. Output: 8-bit pixel row (bit 7 = leftmost pixel).

| Range | Content |
| --- | --- |
| `$00–$1F` | PETSCII screen-code letters (A–Z mapped to codes 1–26) |
| `$20–$5F` | ASCII punctuation, digits, uppercase A–Z |
| `$60–$7F` | PETSCII block/line graphics: horizontal/vertical bars, corners, T-pieces, cross, diagonals, checkerboard, quadrants, diamond, ball, disk, arrows, full block |

Bit 7 of the character code selects reverse-video rendering in both `vic_vga` and
`boot_vga_debug`. `$80–$FF` display as inverted versions of `$00–$7F`.

**Important — lowercase conflict:** Standard ASCII lowercase letters a–z occupy codes
`$61–$7A`, which overlap the PETSCII block-graphics range. Writing a lowercase code
to VRAM intentionally renders a block graphic instead of a letter. The kernel keeps
normal text readable by converting characters a–z → A–Z in `CHRIN_NB` and `CHROUT`.
BASIC programs that need raw PETSCII graphics write `$60-$7F` directly to VRAM.

The checked-in PETSCII BASIC demo at `examples/petscii_gfx.bas` follows that rule:
it writes labels and glyphs directly to `$8000` text VRAM with short `POKE` lines,
instead of relying on `PRINT CHR$()` or string slicing. This also makes the demo a
stress test for CPU writes to the shared VRAM while the VGA/HDMI scanout is active.

The VHDL source is generated by `fpga/tools/gen_petscii_char_rom.py`. Run the
script after modifying any character pattern to regenerate `char_rom.vhd`.

---

## VIC

### `peripherals/vic_vga.vhd` — VIC with Bus Stealing and VGA Output *(new)*

Replaces the old `vic_core` + `vic_pixel_gen` pair. Handles video timing, bus stealing,
character rendering, and VGA signal generation in a single module.

**Ports:**

```vhdl
entity vic_vga is
  port (
    clk, reset_n : in  std_logic;
    -- Bus steal interface
    vic_addr     : out addr_t;          -- VRAM address to read
    vram_data    : in  data_t;          -- synchronous VRAM output, 1-cycle latency
    vic_stealing : out std_logic;       -- '1' = CPU halted, VIC has bus
    -- Character ROM
    char_addr    : out std_logic_vector(9 downto 0);
    char_data    : in  data_t;
    -- VGA output
    vga_hs, vga_vs : out std_logic;
    vga_r        : out std_logic_vector(4 downto 0);
    vga_g        : out std_logic_vector(5 downto 0);
    vga_b        : out std_logic_vector(4 downto 0)
  );
end entity;
```

**Internal state:**

| Signal | Description |
| --- | --- |
| `pce` | Pixel clock enable — toggles every system clock (25 MHz effective) |
| `hc`, `vc` | Horizontal / vertical scan counters (pixel clock units) |
| `linebuf` | 40-byte register array — one char code per column |
| `fetching` | High during the 41-cycle bus steal window |
| `fetch_col` | Current VRAM address column being presented (0–39) |
| `fetch_store_col` | Current line-buffer column being filled from the previous cycle's VRAM data |
| `fetch_valid` | Low for the first setup cycle, high while returned VRAM data is valid |
| `fetch_row` | Character row being prefetched for the next scan line |

**Bus steal timing:**

The steal begins on the pixel clock edge where `hc = H_VISIBLE - 1 = 639` (last visible pixel).
The first stolen cycle presents the address for column 0. Each following cycle
stores the previous cycle's synchronous VRAM data and presents the next address.

1. `vic_stealing` asserted → CPU halted via `RDY`.
2. `vic_addr` driven to `$8000 + fetch_row × 40 + fetch_col`.
3. On the next clock, `vram_data` is stored into `linebuf(fetch_store_col)`.
4. The steal ends after column 39 has been stored.

**CPU VRAM writes during bus steal:**

The active boot cores use single-port text VRAM, so a CPU write can collide with a
VIC prefetch. `vram_we_mux` is still forced low while `vic_stealing = '1'`, but a
CPU write pulse in that window is now captured into `vram_wr_pending`,
`vram_wr_addr`, and `vram_wr_data`. When the steal ends, the mux selects the
latched address/data for one clock and asserts `vram_we_mux`; `cpu_rdy` remains low
for that commit cycle. This fixes the previously observed symptom where repeated
BASIC `POKE` runs left random stale PETSCII characters in the box demo.

**Display pipeline (combinational from scan counters):**

```text
hc, vc → col, char_row, char_line, char_px → linebuf(col) → char_addr
       → char_rom_data → pixel_bit → vga_r/g/b
```

All combinational — no additional pipeline latency on top of the line-buffer prefetch.

### `boot/boot_vga_debug.vhd` — VGA Boot Status Screen

Combinational VGA text renderer active during SD load and SDRAM self-test.
Displays a fixed 40×25 character grid using the same `char_rom` as `vic_vga`.

**Screen layout:**

| Row | Content |
| --- | --- |
| 1 | PETSCII block/line graphics `$60–$7F` (32 glyphs, cols 4–35) |
| 2 | `**** 6502 SINGLE BOARD COMPUTER ****` |
| 4 | `SD BOOT` or `SD ERR` + SDRAM test status |
| 6 | `BEREIT.` |
| 8 | `VIA-T1: XX` (live tick counter) |
| 22 | `GFX:` label + all 32 block-graphics glyphs (`$60–$7F`, cols 6–37) |

Character assignment is fully combinational over the `crow`/`col` scan-counter
signals using a `case crow is` structure. Each character row is a separate `when`
branch; the `put_str` helper writes a string literal into consecutive columns.

Bit 7 of any character code selects reverse video.

---

### `boot/uart_debug_monitor.vhd` — Hardware Monitor

UART monitor entered by the board button. It stops the CPU, accepts machine
monitor commands, and issues single-byte memory transactions through
`monitor_mem_*`.

Core command set:

| Command | Purpose |
| --- | --- |
| `M addr [end]` | Hex dump with ASCII column |
| `D addr [end]`, `U addr [end]` | Disassemble |
| `E addr byte`, `W addr byte`, `: addr byte` | Write one byte |
| `L addr` | Hex loader for sequential bytes |
| `G [addr]` | Resume or restart at address |
| `H`, `?` | Help |

See [UART Monitor](./UART_MONITOR.md) for the operator workflow and upload tool.

**VGA timing constants (640×480 @ ~60 Hz, 50 MHz clock):**

| Parameter | Value |
| --- | --- |
| H_TOTAL | 800 pixel clocks |
| V_TOTAL | 525 lines |
| H_SYNC pulse | clocks 656–751 (active low) |
| V_SYNC pulse | lines 490–491 (active low) |
| Text area V | lines 40–439 (40 px top/bottom border) |
| Char size | 16×16 screen pixels (2× scaled 8×8) |

---

## Address Decoder

### `bus_decode.vhd`

Purely combinational. Maps a 16-bit CPU address to `device_sel_t`.

```vhdl
entity bus_decode is
  port (addr : in addr_t; sel : out device_sel_t);
end entity;
```

Used by `sbc_minimal_top` to gate SRAM writes, VRAM writes, and ROM reads.
During a VIC bus steal, `cpu_addr` is stable (CPU halted), so `dev_sel` is also stable.

---

## Inactive Modules (reference)

### `peripherals/vic_core.vhd` *(inactive)*

Original VIC with dual-port text RAM (CPU write port + pixel generator read port).
Replaced by `vic_vga` because the Spartan-6 dual-port block RAM inference produced
no VGA signal in hardware.

### `peripherals/vic_pixel_gen.vhd` *(inactive)*

Standalone pixel generator that consumed the text RAM read port of `vic_core`.
Merged into `vic_vga`.

### `peripherals/via6522.vhd`

VIA 6522 — parallel I/O + dual 16-bit timers + interrupt flags.
Used by `sbc_minimal_top` for Timer 1 IRQ and Port B (LED blink).

Key registers used by the demo kernel:

| Register | Offset | Purpose |
| --- | --- | --- |
| ORB | $00 | Port B output latch (bit 0 → LED) |
| DDRB | $02 | Port B direction ($FF = all output) |
| T1CL | $04 | Counter low — **read clears T1 IRQ flag** |
| T1CH | $05 | Counter high — write loads latches and starts timer |
| T1LL/T1LH | $06/$07 | Timer 1 latches (auto-reload value) |
| ACR | $0B | Bit 6 = 1 → free-running mode |
| IER | $0E | Bit 7 = set/clear, bit 6 = T1 enable |

### `peripherals/uart6551.vhd`

UART 6551 — TX/RX data path, status register (TDRE/RDRF/OVR), RX interrupt.
Used by `sbc_minimal_top` for TX-only in the demo (RX tied to zero).
Writing to the DATA register ($8810) pulses `tx_valid` and updates `tx_data`.
The board wrapper feeds the serializer `busy` signal back to `tx_busy`, so TDRE
is clear while a byte is actively being transmitted and firmware can safely emit
multi-line reset diagnostics.

### `peripherals/sound_voice.vhd`

Single-voice sound synthesizer (channel 0, `$8830`–`$8839`). A 24-bit
phase-accumulator oscillator produces square and noise (16-bit Galois LFSR)
waveforms; frequency (direct in Hz) and 8-bit volume are honoured, with the note
gated by CONTROL bit 0. The duration and ADSR registers are accepted (so 6502
code writing the full 10-register block does not error) but are not yet acted on.
The register layout mirrors `src/soundchip.h`, so it is software-compatible with
the C emulator's sound chip. Output is a signed 16-bit sample. Verified by
`sim/tb/tb_sound_voice.vhd`.

### `peripherals/pt8211_dac.vhd`

I2S serializer for the dock board's PT8211 (TM8211) audio DAC. A 1:1 VHDL port of
Sipeed's proven `pt8211_drive.v`: a free-running ~1.5 MHz BCK, MSB-first data with
the PT8211's right-justified WS alignment, fed the signed 16-bit sample from
`sound_voice` on both channels. Pins on the Tang Primer 20K dock are
`dac_bck`=N15, `dac_ws`=P16, `dac_din`=P15, plus the amplifier-enable `pa_en`=R16
(tied high in `tang20k_sbc_top.vhd`). See [Sound Chip](./SOUND.md) for the full
register map, usage, and wiring.

---

## Reset ROM Diagnostics

`rom_demo.s` prints reset-time state over UART before interrupts are enabled:

```text
[RESET] 6502 SBC DEBUG
...
SYS CHECK
  ZP   OK
  STK  OK
  RAM  OK
  VRAM OK
  VIA  OK
  UART OK
CHECK DONE, CLI NEXT
```

The memory probes write `$AA` and `$55` to one representative byte in each
region, verify the readback, and then restore the original byte. The check runs
before `CLI`, so VIA Timer 1 cannot interrupt the probe sequence.

---

## Testbenches

### `sim/tb_sbc_minimal.vhd`

Verifies that the T65 CPU executes the kernel and writes the expected 24 ASCII bytes
of `"WILLKOMMEN ZUM 6502 SBC!"` to VRAM addresses $8000–$8017 via the CPU debug bus.
Times out with failure if not all characters arrive within 5000 clock cycles.

---

**See Also:**

- [Architecture Overview](./01_ARCHITECTURE.md)
- [Build Instructions](../boards/pix16/README.md)
- [Simulation Guide](./06_SIMULATION.md)
