# FPGA Architecture Overview

## System Design

The 6502 SBC FPGA is a synthesizable hardware implementation of a 6502-based single-board computer. The design maintains complete software compatibility with the C emulator while providing a path to real FPGA implementations.

### High-Level Block Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        6502 SBC System                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐        ┌─────────────────────────────┐       │
│  │   T65 CPU    │        │   Bus Decode & Control      │       │
│  │  6502 Core   │◄──────►│   (Address Decoder)         │       │
│  └──────────────┘        └─────────────────────────────┘       │
│        ▲                         ▲                              │
│        │                         │                              │
│        └─────────────────────────┘                              │
│                 Bus Interface                                   │
│         16-bit Address / 8-bit Data                             │
│                                                                 │
│  ┌──────────┬───────────┬──────────┬──────────┬────────────┐   │
│  │   SRAM   │    ROM    │   VIA    │   UART   │   VIC/    │   │
│  │  32KB    │   16KB    │  6522    │  6551    │  Disk/    │   │
│  │          │           │          │          │  Sound    │   │
│  └──────────┴───────────┴──────────┴──────────┴────────────┘   │
│                                                                 │
│  IRQ ◄────────────────────────────────────────────────────     │
│                 (Combined from VIA/UART/VIC)                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Memory Map

The 16-bit address space is divided into 8 regions:

| Address Range | Size | Device | Purpose |
|---------------|------|--------|---------|
| 0x0000-0x7FFF | 32KB | SRAM | Program and data memory |
| 0x8000-0x87FF | 2KB | VIC Text RAM | Text display memory |
| 0x8800-0x880F | 16B | VIA 6522 | Parallel I/O and timers |
| 0x8810-0x8813 | 4B | UART 6551 | Serial communications |
| 0x8820-0x882F | 16B | Disk | Disk controller (stub) |
| 0x8830-0x8839 | 10B | Sound 0 | Audio channel 0 |
| 0x8840-0x884F | 16B | VIC Blit | Graphics blitter |
| 0x8850-0x888F | 64B | VIC Sprites | Sprite registers |
| 0x8890-0x88FF | 112B | Sound 1-3 | Audio channels 1-3 |
| 0x8900-0x89FF | 256B | VIC Sprite Data | Sprite pixel storage |
| 0x9000-0x900F | 16B | VIC Control | Video control registers |
| 0x9010-0xAF4F | 40KB | VIC Bitmap | Frame buffer/video RAM |
| 0xC000-0xFFFF | 16KB | ROM | Firmware and system code |

## Component Overview

### CPU: T65 6502 Core
- **Type**: Cycle-accurate VHDL 6502 implementation
- **Location**: `third_party/t65/`
- **Integration**: Via `rtl/cpu/t65_adapter.vhd`
- **Features**:
  - Full 6502 instruction set support
  - BCD arithmetic mode
  - IRQ/NMI interrupt handling
  - Synchronous operation at system clock frequency

### Memory: SRAM (32KB)
- **Type**: Synchronous RAM (block RAM)
- **Location**: `rtl/mem/sync_ram.vhd`
- **Features**:
  - Configurable read mode (synchronous or asynchronous)
  - Single-cycle read/write
  - Initialized to zeros at startup
- **Address**: 0x0000-0x7FFF
- **Access**: Read and write enabled when CPU selects SRAM

### Memory: ROM (16KB)
- **Type**: Read-only memory (block RAM)
- **Location**: `rtl/mem/rom.vhd`
- **Features**:
  - Initialized from hex file at synthesis time
  - File format: offset byte (text format)
  - Supports ROM composition (multiple files at different offsets)
  - Configurable read mode (synchronous or asynchronous)
- **Address**: 0xC000-0xFFFF
- **Reset Behavior**: CPU reads reset vector from 0xFFFC-0xFFFD

### Bus Decoder
- **Type**: Combinational address decoder
- **Location**: `rtl/bus_decode.vhd`
- **Function**: Maps 16-bit address to device selection
- **Output**: `device_sel_t` enumeration with 16 device options
- **Speed**: Combinational (zero propagation delay)

### VIA 6522: Parallel I/O + Timers
- **Type**: Versatile Interface Adapter
- **Location**: `rtl/peripherals/via6522.vhd`
- **Address**: 0x8800-0x880F
- **Features**:
  - 2 parallel ports (A & B) with 8 bidirectional lines each
  - Data direction registers (DDRA, DDRB) for pin control
  - 2 independent 16-bit interval timers
  - Timer 1: Free-running or one-shot with auto-reload
  - Timer 2: Single-shot timer
  - Interrupt flags and enables for timers and handshakes
  - Output registers: ORA, ORB
  - Input masking based on DDR values
- **Interrupts**: IRQ output when enabled interrupt fires
- **Register Set**: 16 memory-mapped registers (0x00-0x0F)

### UART 6551: Serial Communications
- **Type**: Asynchronous serial interface
- **Location**: `rtl/peripherals/uart6551.vhd`
- **Address**: 0x8810-0x8813
- **Features**:
  - TX register for transmitting bytes
  - RX buffer for receiving bytes
  - Status register (TDRE, RDRF, OVR, PE, FE)
  - Command register (RX interrupt enable, reset)
  - Control register (baud rate, format - stub)
  - Overrun detection (data lost when RX buffer full)
  - Programmable reset (write to status register)
- **Interrupts**: IRQ when RX data available (if enabled)
- **Register Set**: 4 memory-mapped registers (0x00-0x03)

### Stub Devices
Placeholder controllers for future expansion:
- **Disk Controller** (0x8820-0x882F): 16 registers via `reg_stub`
- **VIC Video Controller** (0x8000-0xAF4F): 8192 registers via `reg_stub`
- **Sound Synthesizer** (0x8830-0x88AD): 40 registers via `reg_stub`

The stubs use a generic register file that stores CPU writes and returns them on reads, allowing software to probe device addresses before full implementation.

## System Clocking

### Single Clock Domain
- **System Clock**: Single clock input to all components
- **Synchronous Operation**: All state changes on rising clock edge
- **Reset**: Active-low asynchronous reset signal

### Clock Division (T65 Version)
In `sbc_t65_top.vhd`, an internal clock divider:
- **T65 Runs At**: 2x system frequency internally
- **Bus Access**: Every other system clock cycle
- **Purpose**: Synchronization between fast CPU core and system bus
- **Data Latching**: Read data sampled during stable bus phase

## Reset Sequence

1. **Active-Low Reset**: `reset_n` asserted
2. **Global Clear**: All state cleared (registers, memory, counters)
3. **Reset Release**: `reset_n` released
4. **Vector Fetch**: CPU reads reset vector from 0xFFFC-0xFFFD
5. **PC Load**: Reset vector loaded into program counter
6. **Execution**: First instruction from reset address

### Reset Vector
The reset vector is a 16-bit address stored at 0xFFFC-0xFFFD in ROM:
- **0xFFFC**: Low byte of reset address
- **0xFFFD**: High byte of reset address
- **Little-Endian**: Low byte first, high byte second
- **Typical Value**: Kernel ROM start (e.g., 0xC000)

## Interrupt System

### IRQ Logic
```
VIA IRQ ──┐
UART IRQ ├──► OR ──► IRQ_N (to CPU, active-low)
VIC IRQ ──┘
```

### Interrupt Handling
- **Type**: Maskable interrupt (IRQ)
- **Active**: Low (IRQ_N = 0 when interrupt pending)
- **Vector**: CPU fetches interrupt handler from 0xFFFE-0xFFFF
- **Sources**: VIA timers/GPIO, UART RX, VIC raster interrupt
- **Clearing**: Peripheral-specific (read/write registers)

### VIA Interrupt Flags (IFR)
Bit 7: Interrupt pending (any enabled flag set)
Bit 6: Timer 1 timeout
Bit 5: Timer 2 timeout
Bits 4-0: Handshake flags (CA1, CA2, CB1, CB2, SR)

## Design Patterns

### Address Decoding
- **Centralized**: Single `bus_decode` module evaluates CPU address
- **Outputs**: Device selection enum used throughout system
- **Chip Selects**: Generated from device selection (combinational logic)
- **Multiplexing**: CPU input data selected based on device selection

### Read/Write Operations
**Write Path**:
1. CPU asserts address and write data
2. CPU asserts write enable (we=1)
3. Bus decoder selects target device
4. Device stores input data on rising clock edge

**Read Path**:
1. CPU asserts address
2. Bus decoder selects source device
3. Device outputs data combinationally
4. CPU latches data at end of cycle

### Clock Synchronization
- **Setup/Hold**: All inputs stable relative to clock edges
- **Propagation**: Address → Decoding → Chip Select → Output → Read Data
- **Pipelining**: Minimal to reduce latency (1-2 cycle paths typical)

## Synthesizability Notes

### FPGA-Compatible Features
- ✅ Synchronous design with single clock
- ✅ Block RAM primitives (SRAM/ROM)
- ✅ Combinational address decoding
- ✅ Simple state machines (no complex logic)
- ✅ No asynchronous logic (except reset)
- ✅ All signals bounded (no unbounded loops)

### Device Requirements
- **Block RAM**: Minimum 64KB (32KB SRAM + 16KB ROM)
- **Logic Cells**: ~5,000-10,000 LUTs (estimate)
- **Clock Frequency**: 50-100 MHz typical
- **External**: Optional UART level shifter, crystal oscillator

## Verification Strategy

### Unit Testing
Each module has focused testbench:
- `tb_bus_decode`: Address mapping
- `tb_sbc_reset`: Reset vector fetch
- `tb_via6522`: Port masking and timers
- `tb_uart6551`: TX/RX register operations

### Integration Testing
System-level tests verify components working together:
- `tb_sbc_bus_write`: CPU write to SRAM via bus
- `tb_sbc_sram_readback`: Write and read back verification
- `tb_sbc_t65_boot`: Real 6502 ROM execution
- `tb_sbc_t65_kernel_smoke`: Real kernel startup sequence

### Simulation
All tests run under GHDL (open-source VHDL simulator):
```bash
make test    # Run all tests
```

---

**See Also**:
- [Modules Reference](./02_MODULES.md) - Component documentation
- [Component Reference](./05_COMPONENTS.md) - Detailed specs
- [Simulation Guide](./06_SIMULATION.md) - Running tests
