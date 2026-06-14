# Building & Synthesis Guide

## System Requirements

### Software Dependencies

- **GHDL** (version 0.35+): VHDL simulator and analyzer
  - Windows: https://github.com/ghdl/ghdl/releases
  - Linux: `sudo apt-get install ghdl`
  - macOS: `brew install ghdl`

- **GNU Make**: Build automation
  - Windows: MinGW-w64 or equivalent
  - Linux/macOS: Usually pre-installed

- **Python 3.6+**: ROM conversion utility
  - Windows/Linux/macOS: https://www.python.org/downloads/

### FPGA Synthesis Tools (Optional)

For actual FPGA implementation, you'll need vendor tools:

- **Xilinx Vivado** (Xilinx FPGA targets)
- **Intel Quartus** (Intel Altera FPGA targets)
- **Lattice Diamond** (Lattice FPGA targets)
- **GowinEDA / GOWIN FPGA Designer** (Tang Primer 20K / GW2A targets)
- **Open Source**: Project Trellis, nextpnr (for open source flows)

## Building the Project

### Step 1: Install GHDL

**Windows**:
1. Download GHDL installer from GitHub releases
2. Run installer and follow prompts
3. Add GHDL to system PATH

**Linux**:
```bash
sudo apt-get install ghdl ghdl-mcode
```

**macOS**:
```bash
brew install ghdl
```

### Step 2: Verify Installation

```bash
ghdl --version
```

Should output something like:
```
GHDL 0.35 (tarball) [Dunoon edition]
```

### Step 3: Build the Project

Navigate to the FPGA directory:

```bash
cd fpga/
make test
```

This will:
1. Compile all VHDL modules
2. Elaborate testbenches
3. Run each test simulation
4. Report pass/fail status

### Detailed Build Steps

If you want to build individual components:

```bash
# Analyze only (check syntax)
ghdl -a --std=08 --ieee=synopsys rtl/sbc_pkg.vhd
ghdl -a --std=08 --ieee=synopsys rtl/bus_decode.vhd

# Elaborate (link)
ghdl -e --std=08 --ieee=synopsys tb_bus_decode

# Run simulation
ghdl -r --std=08 --ieee=synopsys tb_bus_decode --ieee-asserts=disable-at-0
```

## ROM Files

### ROM Conversion Tool

Convert binary ROM files to VHDL hex format:

```bash
python tools/bin_to_vhdl_hex.py [OPTIONS] [ROM_FILES]
```

### Options

```
--size SIZE          ROM size in bytes (hex, e.g., 0x4000)
--output FILE        Output hex file path
ROM_FILE[@OFFSET]    ROM file with optional offset
```

### Examples

**Single ROM file**:
```bash
python tools/bin_to_vhdl_hex.py --size 0x4000 \
  --output rom.hex \
  ../roms/chess.rom
```

**Multiple ROM files at different offsets**:
```bash
python tools/bin_to_vhdl_hex.py --size 0x4000 \
  --output rom.hex \
  ../roms/kernel.rom@0x0000 \
  ../roms/msbasic.rom@0x1000
```

**Kernel + EhBASIC system image**:
```bash
python tools/bin_to_vhdl_hex.py --size 0x4000 \
  --output rom.hex \
  ../roms/kernel.rom@0x0000 \
  ../roms/ehbasic.rom@0x1000
```

**Output format** (text file, space-separated):
```
0000 A9
0001 42
0002 8D
0003 02
0004 00
```

### ROM File Format Details

- **Input**: Raw binary files
- **Output**: Text format (offset byte, both hex)
- **Composition**: Multiple files combined at different offsets
- **Size**: Padded with 0xEA (NOP) up to specified size
- **Endianness**: Big-endian in output (matches 6502 reset vector convention)

## Makefile Targets

The project includes a Makefile with standard targets:

```bash
make test       # Run all tests (default)
make clean      # Remove generated files
make help       # Show available targets
```

### Makefile Variables

Override variables when running make:

```bash
make test GHDL=/path/to/ghdl     # Specify GHDL path
make clean                        # Clean working directory
```

## VHDL Compilation Flags

The project uses these GHDL flags:

```
--std=08            IEEE 1076-2008 standard (modern VHDL)
--ieee=synopsys     Enable Synopsys extensions (std_logic_unsigned, etc.)
```

The `--ieee=synopsys` flag is required for the T65 CPU core compatibility.

## Synthesis for FPGA

### General Flow

1. **RTL Preparation**
   ```bash
   # Copy all RTL files to synthesis project
   cp -r rtl/ /path/to/vivado/project/
   ```

2. **Testbench Integration** (optional)
   - Some vendors support RTL simulation
   - Use GHDL for pre-synthesis verification
   - Keep testbenches separate from synthesis

3. **Constraints File**
   - Check `constraints/` directory for board-specific files
   - Map port names to physical FPGA pins
   - Define timing constraints (clock period, setup/hold)

4. **Synthesis & Implementation**
   - Follow vendor-specific flow
   - Target block RAM for sram_i and rom_i
   - Ensure synchronous design constraints

5. **Timing Analysis**
   - Verify clock frequency meets requirements (50-100 MHz typical)
   - Check setup/hold margins
   - Ensure no critical timing paths

### Vendor-Specific Notes

**PIX16 Spartan-6 / Xilinx ISE**:
- Use the Xilinx ISE tools, not Vivado, for the Spartan-6 board.
- Create the SD-boot project from an ISE Command Prompt if `xtclsh` is not in PATH:
  ```bash
  cd fpga
  xtclsh scripts/create_sd_boot_ise_project.tcl
  ```
- Create the SD card image with:
  ```bash
  cd fpga
  make sd-boot-image
  ```
- Program the FPGA bitstream once, then update ROM contents by rewriting
  `sim/generated/sbc_ehbasic_sd.img` to the SD card.

**Tang Primer 20K / GowinEDA**:
- Open `fpga/boards/tang_primer_20k/project/tang_sbc.gprj` in GowinEDA.
- The active top is `tang20k_sbc_top`.
- The current bring-up path uses HDMI boot/status output, CH340 UART at
  `115200 8N1`, KEY1 for the FPGA monitor, and an external SPI microSD module
  on `R16/P15/P16/N15`.
- If place-and-route reports stale object errors from
  `project/impl/gwsynthesis/tang_sbc.vg`, force a full resynthesis or clean the
  generated implementation directory. The `.vg` file is a generated netlist from
  the previous synthesis run.

**Xilinx Vivado**:
- Block RAM configured for:
  - Synchronous reads (default sync_ram mode)
  - Asynchronous reads (optional ASYNC_READ mode)
- Create IP core for ROM initialization from hex
- Use `INIT_FILE` generic to specify hex file path

**Intel Quartus**:
- Use ALTERA_RAM_EMBEDDED_FIFO primitive
- Configure with synchronous mode
- Use MIF (Memory Initialization File) format for ROM

**Lattice**:
- Use ECP5 or MachXO primitives
- Memory configuration differs by family
- Refer to Lattice design guides

## Troubleshooting

### GHDL Not Found

**Error**: `ghdl: command not found`

**Solution**:
1. Verify GHDL installation: `ghdl --version`
2. Check PATH environment variable includes GHDL bin directory
3. On Windows, ensure installer added to PATH during installation

### Compilation Errors

**Error**: `unknown option '-fsynopsys'`

**Solution**: Use `--ieee=synopsys` flag instead:
```bash
ghdl -a --std=08 --ieee=synopsys rtl/sbc_pkg.vhd
```

### ROM File Not Found

**Error**: `could not open ROM init file: sim/generated/chess_rom.hex`

**Solution**:
1. Verify ROM file exists: `ls -la sim/generated/`
2. Run ROM generation: `make test` (generates ROM files automatically)
3. Check file permissions

### Simulation Hangs

**Cause**: Unbounded loops, missing wait statements

**Solution**:
1. Set timeout in GHDL: `ghdl -r ... --stop-time=10ms`
2. Check for `wait;` without timeout in testbenches
3. Look for loops without `wait` statements inside

## Continuous Integration

### Local Testing

Run full test suite before committing:

```bash
cd fpga/
make test
```

All tests should PASS.

### GitHub Actions (Optional)

Create `.github/workflows/ghdl-test.yml`:

```yaml
name: GHDL Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install GHDL
        run: sudo apt-get install ghdl
      - name: Run tests
        run: cd fpga && make test
```

## Performance Tuning

### Simulation Speed

- **Synchronous reads**: Faster simulation (pipelined with CPU)
- **Asynchronous reads**: Slower but required for T65 core
- Reduce verbosity: Remove `report` statements in loops

### Synthesis Speed

- **Incremental build**: Reuse previous results when possible
- **Parallel compilation**: Use `-j` flag (if supported)
- **Block RAM optimization**: Vendor tools optimize automatically

## Memory Usage

### Simulation Memory

- GHDL uses ~100-200 MB for full system simulation
- Increase available memory if simulations crash
- Reduce stimulus size for memory-constrained systems

### FPGA Resources

Estimated resource usage:

| Resource | Count | Notes |
|----------|-------|-------|
| Block RAM | 48KB | 32KB SRAM + 16KB ROM |
| LUTs | 5K-10K | CPU adapter + peripherals |
| Registers | 5K | State and data registers |
| Clock Freq | 50-100 MHz | Target frequency |

---

See Also:
- [Testing Guide](./04_TESTING.md) - Running individual tests
- [Architecture](./01_ARCHITECTURE.md) - System design
- [Development Guide](./07_DEVELOPMENT.md) - Contributing code
