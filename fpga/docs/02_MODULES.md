# VHDL Modules Reference

This document covers all VHDL modules in the project. The **active synthesis target** is
`pix16_sbc_minimal_top` → `sbc_minimal_top`. Modules marked *(inactive)* are present in the
project for reference or simulation but are not included in the current build.

---

## Module Hierarchy

### Active (synthesized for PIX16 board)

```text
rtl/
├── sbc_pkg.vhd                    — shared types, memory map, constants
├── bus_decode.vhd                 — address → device selection
├── sbc_minimal_top.vhd            — minimal SBC core with VGA output
│   ├── cpu/t65_adapter.vhd        — T65 CPU wrapper (+ RDY bus-steal port)
│   │   └── third_party/t65/       — external T65 6502 core
│   ├── mem/sync_ram.vhd           — CPU SRAM and VRAM (single-port)
│   ├── mem/rom.vhd                — kernel ROM
│   ├── mem/char_rom.vhd           — 8×8 character patterns
│   ├── peripherals/via6522.vhd   — VIA 6522: Timer 1 IRQ + Port B
│   ├── peripherals/uart6551.vhd  — UART 6551: TX byte stream
│   └── peripherals/vic_vga.vhd   — VIC: bus stealing + VGA output
│
└── boards/pix16_sbc_minimal_top.vhd  — PIX16 board wrapper (UCF ports)
```

### Assembly toolchain

```text
fpga/asm/
├── rom_demo.s           — ca65 6502 assembly source (kernel + ISR + strings)
├── rom_demo.cfg         — ld65 linker config: 2 KB ROM at $F800
├── bin_to_fpga_hex.py   — binary → FPGA sim hex converter (skips 0xEA fill)
└── Makefile             — make all  →  installs ../sim/rom_welcome.hex
```

### Inactive (reference / simulation only)

```text
rtl/
├── sbc_t65_top.vhd                — full SBC (VIA + UART + VIC core)
├── sbc_top.vhd                    — test-mode SBC (ROM-scripted CPU slot)
├── pix16_top.vhd                  — old PIX16 top (test_runner + vic_core)
├── boards/pix16_board.vhd         — old board integration
├── peripherals/vic_core.vhd       — old dual-port VIC (replaced by vic_vga)
├── peripherals/vic_pixel_gen.vhd  — old pixel generator (replaced by vic_vga)
└── peripherals/reg_stub.vhd       — generic register placeholder
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

The complete minimal system: CPU, SRAM, VRAM, ROM, VIC, VGA output.

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
| `vic_stealing` | High for 40 cycles during each H-blank |
| `vram_addr` | Mux: `vic_addr[10:0]` during steal, else `cpu_addr[10:0]` |
| `vram_we_mux` | Zero during steal (VIC only reads), else `vram_we` |

**Memory instances:**

| Instance | Module | Generic | Address |
| --- | --- | --- | --- |
| `sram_i` | `sync_ram` | ADDR_WIDTH=12, ASYNC_READ=true | $0000–$0FFF |
| `vram_i` | `sync_ram` | ADDR_WIDTH=11, ASYNC_READ=true | $8000–$87FF |
| `rom_i` | `rom` | ADDR_WIDTH=11, ASYNC_READ=true | $F800–$FFFF |

---

### `boards/pix16_sbc_minimal_top.vhd` — PIX16 Board Wrapper

Thin wrapper that exposes the exact ports required by `pix16.ucf`. Instantiates
`sbc_minimal_top` and passes VGA signals through. SDRAM pins are absent (not in UCF).

```vhdl
entity pix16_sbc_minimal_top is
  generic (ROM_INIT_FILE : string := "../sim/rom_welcome.hex");
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

Single-port block RAM. Used for both CPU SRAM and VRAM.

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
This is required for the VIC's single-cycle bus steal reads.

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
    vram_data    : in  data_t;          -- async VRAM output
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
| `fetching` | High during the 40-cycle bus steal window |
| `fetch_col` | Current column being fetched (0–39) |
| `fetch_row` | Character row being prefetched for the next scan line |

**Bus steal timing:**

The steal begins on the pixel clock edge where `hc = H_VISIBLE - 1 = 639` (last visible pixel).
For each of the 40 steal cycles:

1. `vic_stealing` asserted → CPU halted via `RDY`.
2. `vic_addr` driven to `$8000 + fetch_row × 40 + fetch_col`.
3. VRAM (async read) immediately outputs the character code.
4. `linebuf(fetch_col)` latched on the rising clock edge.
5. `fetch_col` incremented; steal ends after column 39.

**Display pipeline (combinational from scan counters):**

```text
hc, vc → col, char_row, char_line, char_px → linebuf(col) → char_addr
       → char_rom_data → pixel_bit → vga_r/g/b
```

All combinational — no additional pipeline latency on top of the line-buffer prefetch.

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

---

## Testbenches

### `sim/tb_sbc_minimal.vhd`

Verifies that the T65 CPU executes the kernel and writes the expected 24 ASCII bytes
of `"WILLKOMMEN ZUM 6502 SBC!"` to VRAM addresses $8000–$8017 via the CPU debug bus.
Times out with failure if not all characters arrive within 5000 clock cycles.

---

**See Also:**

- [Architecture Overview](./01_ARCHITECTURE.md)
- [Build Instructions](../BUILD_PIX16.md)
- [Simulation Guide](./06_SIMULATION.md)
