# Simulation Guide

Advanced simulation techniques and analysis tools.

## GHDL Overview

GHDL is an open-source VHDL compiler and simulator. It provides:

- **Analysis**: Syntax checking and compilation
- **Elaboration**: Design linking and instantiation
- **Simulation**: Event-driven waveform simulation
- **Waveform Export**: VCD, GHW formats for analysis

### GHDL Command Reference

```bash
# Analyze (compile) source files
ghdl -a [options] file1.vhd file2.vhd

# Elaborate (link design)
ghdl -e [options] entity_name

# Simulate (run)
ghdl -r [options] entity_name [runtime options]
```

### Common Options

```
--std=08              Use VHDL-2008 standard
--ieee=synopsys       Enable Synopsys extensions
-fsynopsys            (deprecated, use --ieee=synopsys)
--wave=file.ghw       Export waveforms in GHW format
--stop-time=10ms      Stop simulation after 10ms
--vcd=file.vcd        Export waveforms in VCD format
```

## Waveform Analysis

### Generating Waveforms

**GHW Format** (native GHDL):
```bash
ghdl -r tb_sbc_bus_write --wave=tb_sbc_bus_write.ghw
```

**VCD Format** (standard, portable):
```bash
ghdl -r tb_sbc_bus_write --vcd=tb_sbc_bus_write.vcd
```

**Both Formats**:
```bash
ghdl -r tb_sbc_bus_write --wave=wave.ghw --vcd=wave.vcd
```

### GTKWave Viewer

View waveforms with GTKWave (separate tool):

```bash
gtkwave tb_sbc_bus_write.ghw &
```

**GTKWave Features**:
- Pan/zoom along time axis
- Add/remove signals to display
- Search for signal transitions
- Measure timing between events
- Save/load views as .gtkw files

### Key Signals to Monitor

**Bus Signals**:
- `addr`: CPU address bus (when it changes, which device is selected)
- `data_out`: CPU output data (during writes)
- `data_in` / `cpu_din`: Read data from peripherals

**Control Signals**:
- `clk`: System clock (verify edges align with data stability)
- `reset_n`: Reset sequence (should be low then high)
- `we`: Write enable (strobes for writes)

**Peripheral Signals**:
- VIA: `via_cs`, `via_dout`, `via_irq`, `porta_out`, `portb_out`
- UART: `uart_cs`, `uart_dout`, `uart_tx_valid`, `uart_tx_data`

## Debugging Techniques

### Add Debug Reports

Insert `report` statements in testbenches:

```vhdl
process
begin
  report "Test starting" severity note;
  
  addr <= x"0000";
  wait for 1 ns;
  report "addr = " & to_hstring(addr) severity note;
  
  if sel /= DEV_SRAM then
    report "ERROR: Expected DEV_SRAM, got " & device_sel_t'image(sel)
      severity error;
  end if;
  
  wait;
end process;
```

### Scope Reduction

Test one component at a time:

```vhdl
-- Instead of full sbc_top, test just bus_decode
test_only_bus_decode: if true generate
  dut: entity work.bus_decode ...
end generate;
```

### Timing Analysis

Measure propagation delays:

```vhdl
-- Measure delay from address change to output change
addr <= x"0000";
wait for 0 ns;  -- Combinational logic settles
assert sel = DEV_SRAM report "Delay too long?" severity warning;
```

### Signal Tracing

Print signal values at key times:

```vhdl
wait for 100 ns;
report "t=100ns: addr=" & to_hstring(addr) &
        " sel=" & device_sel_t'image(sel) severity note;
```

## Simulation Performance

### Execution Time

Full test suite on typical machine:
- Analysis (compilation): ~1-2 seconds
- Elaboration (linking): <1 second per testbench
- Simulation: <1 second per test (300-1000 ns virtual time)

### Memory Usage

GHDL simulation typically uses:
- Simple testbenches: 50-100 MB
- Full system simulation: 100-200 MB
- Increase available memory if simulations crash

### Speedup Techniques

**Reduce verbosity**:
```vhdl
-- Remove report statements in loops
-- Keep only essential assertions
```

**Shorter test sequences**:
```vhdl
-- Test only the failing condition, not entire flow
-- Use targeted stimulus instead of comprehensive tests
```

**Disable unused components**:
```vhdl
-- Comment out instantiation of unused peripherals
-- Reduces elaboration and simulation time
```

## Advanced Simulation Scenarios

### Clock Domain Testing

Test synchronous vs asynchronous behavior:

```vhdl
-- Synchronous: data valid at clock edge
wait until rising_edge(clk);
assert data_out = expected_value
  report "Data not ready at clock edge" severity error;

-- Asynchronous: data valid combinationally
wait for 0 ns;  -- Allow combinational logic to settle
assert data_out = expected_value
  report "Combinational path failed" severity error;
```

### Reset Sequence Verification

Test proper reset behavior:

```vhdl
-- Reset assertion
reset_n <= '0';
wait for 100 ns;

-- Verify all outputs are reset
assert counter = 0 report "Counter not cleared" severity error;
assert output = (others => '0') report "Output not cleared" severity error;

-- Reset release
reset_n <= '1';
wait for 100 ns;

-- Verify system is ready
assert ready = '1' report "System not ready after reset" severity error;
```

### Multi-Cycle Operations

Test operations spanning multiple clock cycles:

```vhdl
-- Cycle 1: Issue command
cmd_valid <= '1';
cmd_data <= x"42";
wait until rising_edge(clk);

-- Cycle 2: Command accepted
cmd_valid <= '0';
assert busy = '1' report "Device not busy" severity error;
wait until rising_edge(clk);

-- Cycle 3: Result ready
assert busy = '0' report "Device still busy" severity error;
assert result = x"84" report "Incorrect result" severity error;
```

### Interrupt Testing

Test interrupt assertion and servicing:

```vhdl
-- Wait for interrupt assertion
wait until irq = '1' report "IRQ never asserted" severity error;

-- Service interrupt
acknowledge <= '1';
wait until rising_edge(clk);
acknowledge <= '0';

-- Verify IRQ deasserts
wait for 10 ns;
assert irq = '0' report "IRQ not cleared" severity error;
```

## Waveform Best Practices

### Navigation

1. **Time Scale**: Set appropriate resolution
   - For nanosecond timing, use ns unit
   - For microsecond processes, use us unit

2. **Zoom Levels**:
   - Zoom out (ns/div) to see overall flow
   - Zoom in (ps/div) for detailed timing

3. **Cursor Markers**:
   - Set markers at key events
   - Measure timing between markers

### Signal Selection

1. **Hierarchy**: Expand to see all signals
2. **Filter**: Search for signals by name
3. **Grouping**: Organize related signals
4. **Bus Display**: Show bus values in decimal/hex

### Annotation

Add text notes to waveform to document:
- Expected vs actual behavior
- Timing violations
- Anomalies or interesting events

## Continuous Integration

### Running Tests Locally

Before committing:

```bash
cd fpga/
make clean
make test
```

All tests must PASS.

### Automated Testing (GitHub Actions)

Example workflow:

```yaml
name: GHDL Simulation Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Install GHDL
        run: sudo apt-get install ghdl
      - name: Run simulation tests
        run: cd fpga && make test
```

## Troubleshooting

### Simulation Hangs

**Cause**: Unbounded loop or missing `wait`

**Solution**:
1. Check testbench for `while true` without `wait`
2. Use `--stop-time` to force termination
3. Add timeout conditions

```bash
ghdl -r tb_test --stop-time=1ms
```

### Signal Sensitivity

**Issue**: Process triggers spuriously

**Solution**: Ensure sensitivity list matches variable dependencies

```vhdl
-- Wrong: only a in sensitivity list
process(a)
begin
  c <= a and b;  -- Misses b changes
end process;

-- Correct: all inputs in sensitivity list
process(a, b)
begin
  c <= a and b;  -- Triggers on a or b change
end process;
```

### Waveform Export Issues

**Problem**: Waveform file too large

**Solution**:
1. Reduce simulation time: `--stop-time=1ms`
2. Use binary format: `--wave=wave.ghw` (smaller than VCD)
3. Filter signals: Export only needed signals

### Assertion Failures

**Debug multi-condition failures**:

```vhdl
-- Instead of:
assert (a = 1) and (b = 2) and (c = 3)
  report "Complex assertion failed" severity error;

-- Use:
assert a = 1 report "a is not 1" severity error;
assert b = 2 report "b is not 2" severity error;
assert c = 3 report "c is not 3" severity error;
```

---

See Also:
- [Testing Guide](./04_TESTING.md) - Test structure
- [Building & Synthesis](./03_BUILDING.md) - Compilation
- [Development Guide](./07_DEVELOPMENT.md) - Contributing
