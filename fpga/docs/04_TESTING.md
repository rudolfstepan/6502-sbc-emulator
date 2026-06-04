# Testing Guide

## Overview

The FPGA project uses GHDL for simulation-based testing. All tests verify hardware behavior without requiring physical FPGA hardware.

## Running Tests

### Run All Tests

```bash
cd fpga/
make test
```

Output will show all tests and their pass/fail status:

```
ghdl -r ... tb_bus_decode ...
sim/tb_bus_decode.vhd:38:5:@16ns:(report note): tb_bus_decode passed
...
ghdl -r ... tb_sbc_t65_kernel_smoke ...
sim/tb_sbc_t65_kernel_smoke.vhd:88:9:@755ns:(report note): tb_sbc_t65_kernel_smoke passed
```

### Run Single Test

Manually run a specific testbench:

```bash
cd fpga/

# Analyze (compile) all source files
ghdl -a --std=08 --ieee=synopsys \
  rtl/sbc_pkg.vhd rtl/bus_decode.vhd \
  rtl/mem/sync_ram.vhd rtl/mem/rom.vhd \
  rtl/peripherals/*.vhd \
  sim/tb_bus_decode.vhd

# Elaborate (link) the testbench
ghdl -e --std=08 --ieee=synopsys tb_bus_decode

# Run the simulation
ghdl -r --std=08 --ieee=synopsys tb_bus_decode --ieee-asserts=disable-at-0
```

### Run Tests with Output

Capture waveforms for analysis:

```bash
ghdl -r tb_bus_decode --wave=tb_bus_decode.ghw
```

Then view in GTKWave:

```bash
gtkwave tb_bus_decode.ghw &
```

## Test Suite

### 14 Current Tests

The project includes comprehensive test coverage:

| Test | Purpose | Status |
|------|---------|--------|
| `tb_bus_decode` | Address decoder verification | ✅ PASS |
| `tb_sbc_reset` | Reset vector fetch from ROM | ✅ PASS |
| `tb_sbc_bus_write` | CPU write to SRAM | ✅ PASS |
| `tb_sbc_sram_readback` | SRAM write/read verify | ✅ PASS |
| `tb_via6522` | VIA 6522 register/timer ops | ✅ PASS |
| `tb_uart6551` | UART TX/RX and status | ✅ PASS |
| `tb_rom_image` | ROM conversion and loading | ✅ PASS |
| `tb_t65_adapter` | T65 CPU core integration | ✅ PASS |
| `tb_sbc_t65_boot` | T65 real ROM execution | ✅ PASS |
| `tb_sbc_t65_uart` | T65 UART transmit test | ✅ PASS |
| `tb_sbc_t65_via` | T65 VIA parallel I/O test | ✅ PASS |
| `tb_sbc_t65_irq` | T65 interrupt handling | ✅ PASS |
| `tb_sbc_t65_kernel_smoke` | T65 kernel startup | ✅ PASS |
| `tb_sbc_t65_indirect_vic` | T65 indirect addressing | ⏸️ SKIP (experimental) |

### Test Categories

#### Unit Tests (Focused Component Testing)

**tb_bus_decode.vhd**
- Verifies address-to-device mapping
- Tests all 16 address regions
- Checks default behavior for unmapped addresses
- Runtime: ~16 ns

**tb_via6522.vhd**
- Port masking with DDR registers
- IER/IFR interrupt flag behavior
- Timer countdown and interrupt assertion
- Timer interrupt clearing
- Runtime: ~216 ns

**tb_uart6551.vhd**
- Status register behavior
- TX write and data appearance
- RX data acceptance
- RDRF flag clearing on read
- Overrun detection
- Programmed reset via status write
- RX interrupt behavior
- Runtime: ~256 ns

**tb_rom_image.vhd**
- ROM file conversion and loading
- Reset vector readback
- Memory access through ROM component
- Runtime: ~16 ns

#### Integration Tests (System-Level)

**tb_sbc_reset.vhd**
- System reset behavior
- ROM addressing at 0xFFFC-0xFFFD
- Reset vector composition (little-endian)
- CPU initial state

**tb_sbc_bus_write.vhd**
- CPU write cycle through bus
- SRAM write enable assertion
- Data propagation
- Address decoding in write context

**tb_sbc_sram_readback.vhd**
- Complete write/read sequence
- Data retention in SRAM
- Read path verification
- Multi-cycle bus operations

#### T65 CPU Tests (Real Instruction Execution)

**tb_t65_adapter.vhd**
- T65 core instantiation and elaboration
- Bus signal verification after reset
- Address/data signal behavior
- Write enable generation

**tb_sbc_t65_boot.vhd**
- T65 CPU execution from ROM
- Real 6502 instruction: `LDA #$42`
- Register write: `STA $0002`
- SRAM memory write verification
- Program counter advancement

**tb_sbc_t65_uart.vhd**
- T65 ROM boot
- UART write operation: `STA $8810`
- UART data latch and TX strobe
- Serial transmit signal behavior

**tb_sbc_t65_via.vhd**
- T65 ROM boot
- VIA port setup: `DDRB=$FF` (all outputs)
- Data write: `ORB=$A5`
- Port B output verification

**tb_sbc_t65_irq.vhd**
- T65 ROM boot
- VIA Timer 1 configuration
- Interrupt enable/flag setup
- IRQ assertion and CPU service
- IRQ handler execution through vector
- Handler writes $99 to SRAM location

**tb_sbc_t65_kernel_smoke.vhd**
- T65 execution of real kernel ROM
- Composed kernel.rom + msbasic.rom
- Reset vector fetch and execution
- Early kernel initialization:
  - VIA DDRA setup
  - Memory bank setup
  - Screen pointer initialization
  - Text RAM clear operation

#### Experimental Tests

**tb_sbc_t65_indirect_vic.vhd** (Not in default test set)
- Experimental indirect addressing test
- `STA ($zp),Y` instruction to VIC text RAM
- Known issue: T65 addressing mode not fully integrated
- Kept separate from main test suite for future work

## Test Structure

### Typical Testbench Pattern

```vhdl
library ieee;
use ieee.std_logic_1164.all;

entity tb_bus_decode is
end entity;

architecture tb of tb_bus_decode is
  -- Signals under test
  signal addr : addr_t;
  signal sel : device_sel_t;

begin
  -- Instantiate device under test (DUT)
  dut : entity work.bus_decode
    port map (
      addr => addr,
      sel => sel
    );

  -- Test process
  process
  begin
    -- Test 1: SRAM address
    addr <= x"0000";
    wait for 1 ns;
    assert sel = DEV_SRAM
      report "SRAM selection failed" severity error;

    -- Test 2: ROM address
    addr <= x"FFFC";
    wait for 1 ns;
    assert sel = DEV_ROM
      report "ROM selection failed" severity error;

    -- Report results
    report "tb_bus_decode passed" severity note;
    wait;  -- End of test
  end process;
end architecture;
```

### Common Assertions

```vhdl
-- Basic assertion
assert condition
  report "Error message" severity error;

-- With timing check
wait for 10 ns;
assert signal = expected_value
  report "Unexpected value" severity error;

-- Multiple conditions
assert (addr >= ADDR_ROM_BASE) and (addr <= ADDR_ROM_LAST)
  report "Address out of ROM range" severity error;
```

## Test Signals

### Standard Signals

Most testbenches use these signals:

```vhdl
signal clk : std_logic := '0';           -- Clock (100 ns period = 10 MHz)
signal reset_n : std_logic := '1';       -- Active-low reset
signal addr : addr_t := (others => '0'); -- CPU address bus
signal data_in : data_t := (others => '0');   -- Data input (reads)
signal data_out : data_t := (others => '0');  -- Data output (writes)
signal we : std_logic := '0';             -- Write enable
```

### Clock Generation

```vhdl
-- 10 MHz clock (100 ns period)
clk <= not clk after 50 ns;

-- Reset sequence
reset_n <= '0';
wait for 100 ns;
reset_n <= '1';
wait for 100 ns;
```

## Waveform Analysis

### Generating Waveforms

```bash
ghdl -r tb_sbc_bus_write --wave=waveform.ghw
```

### Viewing with GTKWave

```bash
gtkwave waveform.ghw &
```

### Waveform Inspection

1. **Time Navigation**: Scroll or zoom to inspect signal behavior
2. **Signal Levels**: High=1, Low=0, X=unknown, Z=high-impedance
3. **Timing Measurements**: Click to set markers and measure delays
4. **Search**: Find signal transitions to locate events

### Key Signals to Monitor

- `clk`: System clock edge alignment
- `reset_n`: Reset sequence and clear timing
- `addr`: Address bus changes
- `data_in` / `data_out`: Data propagation
- `we`: Write enable strobing
- IRQ/interrupt signals: Edge detection and glitch checking

## Debugging Tests

### Add Debug Output

Modify testbench to print diagnostic info:

```vhdl
report "Test starting" severity note;
report "addr = " & to_hstring(addr) severity note;
report "data = " & to_hstring(data_in) severity note;
```

### Reduce Scope

Focus on one operation at a time:

```vhdl
-- Instead of full system, test one module
tb_sbc_bus_write_ONLY_TEST_WRITE <= true;
```

### Increase Verbosity

Add more assertions to catch intermediate states:

```vhdl
wait for 1 ns;
assert we = '1' report "Write enable not asserted" severity error;
wait for 1 ns;
assert addr = x"0002" report "Address incorrect" severity error;
wait for 1 ns;
assert data_out = x"42" report "Data incorrect" severity error;
```

## Performance & Timing

### Test Execution Time

- Full test suite: ~2 seconds
- Individual test: <1 second typically
- T65 integration tests: Longer due to instruction cycles

### Simulation Time (Virtual)

Tests run for varying virtual time:

```
tb_bus_decode:    ~16 ns
tb_sbc_bus_write: ~215 ns
tb_sbc_t65_boot:  ~285 ns
```

This is the simulated time in nanoseconds, not actual wall clock time.

### Timeout Settings

For long-running tests, set timeout:

```bash
ghdl -r tb_sbc_t65_kernel_smoke --stop-time=10ms
```

## Adding New Tests

### Testbench Template

Create `sim/tb_my_feature.vhd`:

```vhdl
library ieee;
use ieee.std_logic_1164.all;
use work.sbc_pkg.all;

entity tb_my_feature is
end entity;

architecture tb of tb_my_feature is
  signal clk : std_logic := '0';
  signal reset_n : std_logic := '1';
  -- Add signals for your test here

begin
  -- Instantiate DUT
  dut : entity work.my_feature
    port map (
      clk => clk,
      reset_n => reset_n
      -- Connect signals
    );

  -- Clock generation
  clk <= not clk after 50 ns;

  -- Test process
  process
  begin
    -- Reset phase
    reset_n <= '0';
    wait for 100 ns;
    reset_n <= '1';
    
    -- Test phase
    -- ... your test here ...
    
    report "tb_my_feature passed" severity note;
    wait;
  end process;

end architecture;
```

### Update Makefile

Add to `Makefile` test targets:

```makefile
test: ... tb_my_feature
	$(GHDL) -r $(GHDL_FLAGS) tb_my_feature $(GHDL_RUN_FLAGS)
```

---

See Also:
- [Building & Synthesis](./03_BUILDING.md) - How to build
- [Simulation Guide](./06_SIMULATION.md) - Advanced simulation
- [Architecture](./01_ARCHITECTURE.md) - System design for context
