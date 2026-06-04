# FPGA Documentation Index

Welcome to the 6502 SBC FPGA documentation. This directory contains comprehensive guides for understanding, building, and developing the FPGA implementation.

## Quick Links

- **[README](../README.md)** - Project overview and current status
- **[Architecture](./01_ARCHITECTURE.md)** - System design and memory map
- **[Modules Reference](./02_MODULES.md)** - Detailed component documentation
- **[Building & Synthesis](./03_BUILDING.md)** - How to build and synthesize the project
- **[Testing Guide](./04_TESTING.md)** - Test infrastructure and running tests
- **[Component Reference](./05_COMPONENTS.md)** - Detailed specs for major components
- **[Simulation](./06_SIMULATION.md)** - Running and analyzing simulations
- **[Development Guide](./07_DEVELOPMENT.md)** - Contributing and development workflow
- **[Roadmap](./roadmap.md)** - Project roadmap and milestones
- **[PIX16 Build Guide](../BUILD_PIX16.md)** - Xilinx ISE build and programming guide for the PIX16 Spartan-6 board
- **[Hardware Support](../HARDWARE_SUPPORT.md)** - PIX16 board pinout, target device, and VGA smoke-test notes

## Project Structure

```
fpga/
├── docs/                    Documentation files
│   ├── INDEX.md            This file
│   ├── 01_ARCHITECTURE.md  System design
│   ├── 02_MODULES.md       Component documentation
│   ├── 03_BUILDING.md      Build instructions
│   ├── 04_TESTING.md       Test guide
│   ├── 05_COMPONENTS.md    Component reference
│   ├── 06_SIMULATION.md    Simulation guide
│   ├── 07_DEVELOPMENT.md   Development guide
│   └── roadmap.md          Project roadmap
├── rtl/                     VHDL source code
│   ├── cpu/                CPU adapters
│   ├── mem/                Memory (RAM/ROM)
│   └── peripherals/        Device controllers
├── sim/                     Testbenches
├── constraints/            Board-specific pin constraints
├── third_party/            Imported open-source cores
└── tools/                   Build utilities
```

## Key Concepts

### 6502 Architecture Compatibility
The FPGA maintains 100% software compatibility with the C emulator:
- 16-bit address space (0x0000-0xFFFF)
- 8-bit data bus
- Same memory map with peripherals at identical addresses
- IRQ logic combining VIA, UART, and VIC interrupts

### Design Approach
- **Modular components**: Each peripheral is independently testable
- **Synthesizable VHDL**: All RTL is ready for real FPGA targets
- **Incremental development**: Placeholders for incomplete features
- **Deterministic testing**: ROM-scripted tests for repeatability

## Getting Started

### For Users
1. Read [Architecture](./01_ARCHITECTURE.md) to understand the system design
2. Check [Building & Synthesis](./03_BUILDING.md) to compile the project
3. Review [Testing Guide](./04_TESTING.md) to run existing tests

### For Developers
1. Start with [Architecture](./01_ARCHITECTURE.md) for system overview
2. Read [Modules Reference](./02_MODULES.md) for component details
3. Review [Component Reference](./05_COMPONENTS.md) for detailed specs
4. Follow [Development Guide](./07_DEVELOPMENT.md) for contribution process

### For FPGA Synthesis
1. Understand the [Architecture](./01_ARCHITECTURE.md)
2. Review [Building & Synthesis](./03_BUILDING.md) for build flow
3. Check [Components Reference](./05_COMPONENTS.md) for FPGA-specific notes

## Current Status

**Latest Tests Passing**: All 14 smoke tests
- Address decoder verification
- Reset vector fetch from ROM
- SRAM read/write operations
- VIA 6522 timer and GPIO control
- UART 6551 serial communications
- T65 CPU core integration and instruction execution
- Real 6502 ROM boot sequences
- Interrupt handling and servicing

**Completed Milestones**
- ✅ Bus architecture and memory map
- ✅ Basic ROM/SRAM components
- ✅ T65 CPU core integration
- ✅ VIA 6522 partial implementation
- ✅ UART 6551 partial implementation
- ✅ PIX16 ISE project targeting `xc6slx16-ftg256-2`
- ✅ Board-level VGA smoke test with ROM-scripted welcome text
- ✅ Comprehensive documentation

**In Progress**
- VIC video controller expansion
- Complete UART implementation
- Full VIA functionality
- Real T65-driven board boot flow

## Key Files

| File | Purpose |
|------|---------|
| `rtl/sbc_pkg.vhd` | Memory map constants and type definitions |
| `rtl/bus_decode.vhd` | Address decoder |
| `rtl/sbc_top.vhd` | Main system integration (test mode) |
| `rtl/sbc_t65_top.vhd` | System with T65 CPU |
| `rtl/pix16_top.vhd` | PIX16 board top for the ISE project |
| `../fpga/fpga.xise` | Xilinx ISE project for `xc6slx16-ftg256-2` |
| `rtl/peripherals/*.vhd` | Peripheral controllers |
| `rtl/mem/*.vhd` | Memory components |
| `sim/tb_*.vhd` | Testbenches |

## Next Steps

1. **For New Developers**: Start with [Architecture](./01_ARCHITECTURE.md)
2. **For Building**: See [Building & Synthesis](./03_BUILDING.md)
3. **For Contributing**: See [Development Guide](./07_DEVELOPMENT.md)
4. **For Questions**: Check individual documentation files or the main README

---

**Last Updated**: June 2026  
**Status**: Active Development  
**Maintainer**: Rudolf Stepan
