# VHDL Modules Reference

This document provides an overview of all VHDL modules in the project and their relationships.

## Module Hierarchy

```
rtl/
├── sbc_pkg.vhd              ◄─── All modules depend on this package
├── bus_decode.vhd           ◄─── Used by all top-level modules
├── sbc_top.vhd              ◄─── Test mode system integration
├── sbc_t65_top.vhd          ◄─── T65 CPU mode integration
│
├── cpu/
│   └── t65_adapter.vhd      ◄─── Wraps T65 CPU core
│       └── third_party/t65/ ◄─── External T65 implementation
│
├── mem/
│   ├── sync_ram.vhd         ◄─── SRAM component
│   └── rom.vhd              ◄─── ROM component (file-based init)
│
└── peripherals/
    ├── reg_stub.vhd         ◄─── Generic register file (stubs)
    ├── via6522.vhd          ◄─── VIA parallel I/O + timers
    └── uart6551.vhd         ◄─── UART serial interface
```

## Core Modules

### sbc_pkg.vhd - Package Definition

**Purpose**: Central definitions for types, constants, and utility functions

**Key Contents**:

```vhdl
-- Types
subtype addr_t is std_logic_vector(15 downto 0);  -- 16-bit address
subtype data_t is std_logic_vector(7 downto 0);   -- 8-bit data

-- Memory map constants
ADDR_SRAM_BASE / ADDR_SRAM_LAST       -- 0x0000-0x7FFF
ADDR_ROM_BASE / ADDR_ROM_LAST         -- 0xC000-0xFFFF
-- ... (all other device address ranges)

-- Device enumeration
type device_sel_t is (
  DEV_NONE, DEV_SRAM, DEV_ROM, DEV_VIA,
  DEV_UART, DEV_DISK, DEV_VIC_TEXT, DEV_VIC_BMP,
  -- ... (all device types)
);

-- Utility functions
function in_range(addr, first, last) return boolean;
```

**Used By**: All other modules

**Features**:
- Centralized memory map (easy to edit/extend)
- Reusable address/data types
- Device selection enumeration
- Address range checking function

---

### bus_decode.vhd - Address Decoder

**Purpose**: Map CPU address bus to device selection signal

**Port Interface**:
```vhdl
entity bus_decode is
  port (
    addr : in  addr_t;           -- 16-bit CPU address
    sel  : out device_sel_t       -- Which device is active
  );
end entity;
```

**Behavior**:
- Purely combinational logic
- Evaluates CPU address against all address range constants
- Sets device selection output based on address match
- Default: DEV_NONE if address is unmapped

**Example**:
```vhdl
if in_range(addr, ADDR_SRAM_BASE, ADDR_SRAM_LAST) then
  sel <= DEV_SRAM;
elsif in_range(addr, ADDR_ROM_BASE, ADDR_ROM_LAST) then
  sel <= DEV_ROM;
-- ... etc for all devices
else
  sel <= DEV_NONE;
end if;
```

**Performance**: Zero propagation delay (combinational)

---

## Top-Level System

### sbc_top.vhd - Test Mode System

**Purpose**: Complete 6502 SBC with ROM-scripted test CPU

**Characteristics**:
- Uses `cpu6502_slot` instead of real T65 CPU
- Deterministic ROM-scripted sequences for testing
- All peripherals connected and functional
- Debug outputs for waveform analysis

**Key Instantiations**:
```
cpu6502_slot ──► SRAM ──┐
                 ROM  ──├──► bus_decode
                 VIA  ──┤
                 UART ──┤
                 VIC  ──┤
                 Disk ──┤
                 Sound ┘
```

**Generics**:
- `ROM_INIT_FILE`: Path to ROM hex file

**Debug Outputs**:
- `dbg_cpu_addr`: CPU address bus
- `dbg_cpu_data`: CPU data output
- `dbg_cpu_we`: Write enable signal
- `dbg_read_data`: Latched read data
- `dbg_read_valid`: Read strobe

**Testing**: Used for all non-T65 smoke tests

---

### sbc_t65_top.vhd - T65 CPU Mode

**Purpose**: Complete 6502 SBC with real T65 CPU core

**Characteristics**:
- Uses `t65_adapter` to integrate T65 CPU
- Clock divider (T65 runs at 2x system frequency)
- Real 6502 ROM execution capability
- Extended debug outputs

**Key Instantiations**:
```
t65_adapter ──► (same peripherals as sbc_top)
```

**Generics**:
- `ROM_INIT_FILE`: Path to ROM hex file

**Debug Outputs** (extended):
- All from `sbc_top` plus:
- `dbg_cpu_din`: CPU read data bus
- `dbg_cpu_sync`: Instruction sync signal
- `dbg_uart_tx_data`: UART transmit data
- `dbg_uart_tx_valid`: UART TX strobe
- `dbg_via_portb_out`: VIA Port B output

**Testing**: Used for T65 integration tests

---

## CPU Integration

### t65_adapter.vhd - T65 Integration Wrapper

**Purpose**: Adapt T65's 24-bit bus to system's 16-bit bus

**Port Interface**:
```vhdl
entity t65_adapter is
  port (
    -- System clock and control
    clk, reset_n : in std_logic;
    enable : in std_logic;
    
    -- Interrupt inputs
    irq_n, nmi_n : in std_logic;
    
    -- System bus interface
    data_in : in data_t;
    addr : out addr_t;              -- 16-bit (from T65's 24-bit)
    data_out : out data_t;
    we : out std_logic;             -- Write enable
    sync : out std_logic            -- Instruction sync
  );
end entity;
```

**Translation Mapping**:
- T65 address [23:0] → System address [15:0] (lower 16 bits)
- T65 R/W_n + VDA → System we (write enable)
- T65 DI ← System data_in (directly)
- T65 DO → System data_out (directly)

**Control Signals**:
- `enable`: Clock enable for T65 (gating)
- `irq_n`: Active-low interrupt
- `nmi_n`: Active-low NMI

**Features**:
- Direct instantiation of T65 core
- Minimal translation logic
- All T65 debug signals available via generics

---

## Memory Modules

### sync_ram.vhd - Synchronous RAM

**Purpose**: Configurable block RAM for SRAM

**Port Interface**:
```vhdl
entity sync_ram is
  generic (
    ADDR_WIDTH : positive := 15;   -- Log2 of capacity
    ASYNC_READ : boolean := false   -- Async reads?
  );
  port (
    clk  : in  std_logic;
    we   : in  std_logic;           -- Write enable
    addr : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    din  : in  data_t;              -- Data in (write data)
    dout : out data_t               -- Data out (read data)
  );
end entity;
```

**Behavior**:
- **Synchronous Write**: Data stored on rising clock edge when we=1
- **Synchronous Read** (default): Output latched on rising clock edge
- **Asynchronous Read** (optional): Combinational read path
- **Write-Through**: In async mode, new data appears on output immediately

**Memory Capacity**:
- ADDR_WIDTH=15: 32KB (as in sbc_top)
- ADDR_WIDTH=14: 16KB
- ADDR_WIDTH=16: 64KB

**Initialization**:
- Automatically cleared to zeros at startup
- No initialization file support

**Usage in sbc_top**:
```vhdl
sram_i : entity work.sync_ram
  generic map (ADDR_WIDTH => 15)      -- 32KB
  port map (
    clk  => clk,
    we   => sram_we,
    addr => cpu_addr(14 downto 0),    -- Lower 15 bits
    din  => cpu_dout,
    dout => sram_dout
  );
```

---

### rom.vhd - Read-Only Memory

**Purpose**: Boot firmware and system code

**Port Interface**:
```vhdl
entity rom is
  generic (
    ADDR_WIDTH : positive := 14;   -- Log2 of capacity
    INIT_FILE  : string := "";      -- Hex file path
    ASYNC_READ : boolean := false   -- Async reads?
  );
  port (
    clk  : in  std_logic;
    addr : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    dout : out data_t               -- Read-only output
  );
end entity;
```

**File Format**:
Text file with lines: `offset byte_value` (both hex, space-separated)

Example:
```
0000 A9
0001 42
0002 8D
0003 02
```

**Capacity**:
- ADDR_WIDTH=14: 16KB (as in sbc_top)
- ADDR_WIDTH=13: 8KB
- ADDR_WIDTH=15: 32KB

**Initialization**:
- Loaded from hex file at synthesis time
- Default fill: NOP instruction (0xEA)
- Supports multiple source files with offset mapping

**ROM Composition** (via build script):
```bash
# Convert two ROM files and compose at different offsets
python tools/bin_to_vhdl_hex.py --size 0x4000 \
  --output rom.hex \
  kernel.rom@0x0000 \
  msbasic.rom@0x1000
```

**Reading Modes**:
- **Synchronous** (default): Output latched on rising clock
- **Asynchronous**: Combinational read (faster but uses more FPGA resources)

---

## Peripheral Modules

### reg_stub.vhd - Generic Register File

**Purpose**: Placeholder for devices not yet fully implemented

**Port Interface**:
```vhdl
entity reg_stub is
  generic (
    REG_COUNT : positive := 16      -- Number of registers
  );
  port (
    clk, reset_n : in std_logic;
    cs : in std_logic;              -- Chip select
    we : in std_logic;              -- Write enable
    addr : in addr_t;               -- Address (all bits used)
    din : in data_t;                -- Data input
    dout : out data_t;              -- Data output
    irq : out std_logic             -- Interrupt (hardwired to 0)
  );
end entity;
```

**Behavior**:
- Stores writes in register array
- Returns writes on subsequent reads (write-through)
- Address wraparound: `index = addr mod REG_COUNT`
- Reset: All registers cleared to 0x00
- IRQ always disabled (hardwired '0')

**Used For**:
- **VIC Controller** (8192 registers): Video memory and control
- **Disk Controller** (16 registers): Future disk interface
- **Sound Synthesizer** (40 registers): Future audio channels

**Characteristics**:
- Allows address probing before full implementation
- Single-cycle read/write
- No special behavior (just storage)

---

### via6522.vhd - VIA 6522 Parallel I/O + Timers

**Port Interface**:
```vhdl
entity via6522 is
  port (
    clk, reset_n : in std_logic;
    cs : in std_logic;              -- Chip select
    we : in std_logic;              -- Write enable
    addr : in addr_t;               -- Register address
    din : in data_t;                -- Data input
    dout : out data_t;              -- Data output
    porta_in, portb_in : in data_t; -- External inputs
    porta_out, portb_out : out data_t;  -- Outputs
    irq : out std_logic             -- Interrupt request
  );
end entity;
```

**Register Map** (address bits [3:0]):

| Offset | Name | R/W | Function |
|--------|------|-----|----------|
| 0x0 | ORB | R/W | Output Register B |
| 0x1 | ORA | R/W | Output Register A |
| 0x2 | DDRB | R/W | Data Direction B (1=output) |
| 0x3 | DDRA | R/W | Data Direction A (1=output) |
| 0x4 | T1CL | R | Timer 1 Counter Low |
| 0x5 | T1CH | R/W | Timer 1 Counter High (write starts timer) |
| 0x6 | T1LL | R/W | Timer 1 Latch Low |
| 0x7 | T1LH | R/W | Timer 1 Latch High |
| 0x8 | T2CL | R | Timer 2 Counter Low |
| 0x9 | T2CH | R/W | Timer 2 Counter High (write starts timer) |
| 0xA | SR | R/W | Shift Register |
| 0xB | ACR | R/W | Auxiliary Control (timer modes) |
| 0xC | PCR | R/W | Peripheral Control (handshakes) |
| 0xD | IFR | R/W | Interrupt Flag Register |
| 0xE | IER | R/W | Interrupt Enable Register |
| 0xF | ORA2 | R/W | Output Register A (alternate) |

**Features**:
- 2 parallel ports (8 bits each)
- Port direction control (DDR registers)
- 2 independent 16-bit timers
- Interrupt flag and enable registers
- Timer 1 can operate in continuous or one-shot mode
- Interrupt generation on timer expiry or GPIO edges

**Interrupts**:
- Bit 6: Timer 1 timeout
- Bit 5: Timer 2 timeout
- Bits 4-0: Handshake interrupts

---

### uart6551.vhd - UART 6551 Serial Interface

**Port Interface**:
```vhdl
entity uart6551 is
  port (
    clk, reset_n : in std_logic;
    cs : in std_logic;              -- Chip select
    we : in std_logic;              -- Write enable
    addr : in addr_t;               -- Register address
    din : in data_t;                -- Data input
    dout : out data_t;              -- Data output
    rx_data : in data_t;            -- External RX data
    rx_valid : in std_logic;        -- External RX strobe
    tx_data : out data_t;           -- External TX data
    tx_valid : out std_logic;       -- External TX strobe
    irq : out std_logic             -- Interrupt request
  );
end entity;
```

**Register Map** (address bits [1:0]):

| Offset | Name | R/W | Function |
|--------|------|-----|----------|
| 0x0 | DATA | R/W | RX data (read), TX data (write) |
| 0x1 | STATUS | R/W | Status flags (read-only except write resets) |
| 0x2 | CMD | W | Command register (RX IRQ enable, reset) |
| 0x3 | CTRL | W | Control register (baud, format - stub) |

**Status Register Bits**:
- Bit 7: IRQ pending
- Bit 6: DSR (not used)
- Bit 5: DCD (not used)
- Bit 4: TDRE (transmitter data register empty)
- Bit 3: RDRF (receiver data register full)
- Bit 2: OVR (overrun error)
- Bit 1: FE (framing error - stub)
- Bit 0: PE (parity error - stub)

**Behavior**:
- **TX**: CPU writes to DATA register, tx_valid pulses, tx_data updated
- **RX**: External rx_valid strobes new data, rx_data latched, RDRF set
- **Overrun**: RX data arrives when RDRF already set (OVR flag)
- **IRQ**: Asserted when RDRF=1 and CMD bit 0 (RX IRQ enable) is set
- **Reset**: Write any value to STATUS register clears flags

---

## Testbench Modules

### sim/tb_*.vhd - Test Benches

**Purpose**: Unit and integration testing via simulation

**Naming Convention**:
- `tb_bus_decode.vhd` - Address decoder verification
- `tb_sbc_*.vhd` - System integration tests
- `tb_peripheral_*.vhd` - Peripheral-specific tests

**Common Test Pattern**:
1. Initialize clocks and signals
2. Assert reset for N cycles
3. Release reset
4. Apply test stimulus (reads/writes)
5. Check response against expected values
6. Report PASS or FAIL

**Example Test Structure**:
```vhdl
process
begin
  -- Reset phase
  reset_n <= '0';
  wait for 100 ns;
  reset_n <= '1';
  
  -- Test phase
  addr <= x"0000";
  wait for 10 ns;
  assert sel = DEV_SRAM report "SRAM not selected" severity error;
  
  wait;  -- End of test
end process;
```

---

## Module Dependencies

### Dependency Graph

```
sbc_pkg.vhd
    ▲
    │ (used by all below)
    │
    ├─── bus_decode.vhd
    │        ▲
    │        │
    ├─── sbc_top.vhd ◄──────┐
    │        │               │
    │        ├── cpu6502_slot.vhd
    │        ├── sync_ram.vhd
    │        ├── rom.vhd
    │        ├── via6522.vhd
    │        ├── uart6551.vhd
    │        └── reg_stub.vhd (×3 for VIC/Disk/Sound)
    │
    └─── sbc_t65_top.vhd ◄──┤
             │               │
             ├── t65_adapter.vhd
             │        │
             │        └── T65 core (external)
             │
             └── (same peripherals as sbc_top)
```

---

See Also:
- [Component Reference](./05_COMPONENTS.md) - Detailed specs
- [Simulation Guide](./06_SIMULATION.md) - Running tests
- [Development Guide](./07_DEVELOPMENT.md) - Contributing code
