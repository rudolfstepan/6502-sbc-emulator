# Development Guide

Contributing code and developing new features for the FPGA project.

## Getting Started

### Project Setup

1. **Fork/Clone Repository**
```bash
git clone https://github.com/yourfork/6502-sbc-emulator.git
cd 6502-sbc-emulator/fpga
```

2. **Install Dependencies**
```bash
# Linux/macOS
sudo apt-get install ghdl ghdl-mcode

# Windows
# Download from: https://github.com/ghdl/ghdl/releases
```

3. **Verify Setup**
```bash
make test    # Should pass all 14 tests
```

## Code Style Guide

### VHDL Conventions

**Entity Declaration**:
```vhdl
entity my_component is
  generic (
    PARAM_A : positive := 16;      -- Uppercase parameter names
    PARAM_B : string := ""
  );
  port (
    clk     : in  std_logic;       -- Lowercase port names
    reset_n : in  std_logic;       -- Trailing _n for active-low
    addr    : in  addr_t;
    dout    : out data_t;
    irq     : out std_logic        -- No comma after last port
  );
end entity;
```

**Naming Conventions**:
- Entities: `lowercase_with_underscores`
- Packages: `lowercase_with_underscores`
- Signals/Variables: `lowercase_with_underscores`
- Constants: `UPPERCASE_WITH_UNDERSCORES`
- Generics: `UPPERCASE_WITH_UNDERSCORES`

**Comments**:
```vhdl
-- Single-line comments for inline documentation
-- Use multiple lines for longer explanations

architecture rtl of my_component is
  -- Signal declarations with comments describing purpose
  signal counter : unsigned(15 downto 0);  -- 16-bit counter
  
begin
  -- Main implementation
  
  process(clk)
  begin
    if rising_edge(clk) then
      counter <= counter + 1;  -- Increment each cycle
    end if;
  end process;
  
end architecture;
```

**Port Alignment**:
```vhdl
-- Align ports for readability
port (
  clk         : in  std_logic;
  reset_n     : in  std_logic;
  enable      : in  std_logic;
  data_in     : in  data_t;
  data_out    : out data_t;
  valid_out   : out std_logic
);
```

### File Organization

```vhdl
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

-- Entity declaration (as above)
entity my_component is
  -- ...
end entity;

-- Architecture (single entity per file is preferred)
architecture rtl of my_component is
  -- Internal type declarations
  type state_t is (IDLE, ACTIVE, DONE);
  
  -- Signal declarations (group by purpose)
  signal clk_i    : std_logic;
  signal reset_i  : std_logic;
  
  signal state    : state_t;
  signal counter  : unsigned(15 downto 0);
  
begin
  -- Concurrent statements first (assignments, instantiations)
  
  -- Process blocks last
  process(clk_i)
  begin
    -- ...
  end process;
  
end architecture;
```

## Development Workflow

### 1. Create Feature Branch

```bash
git checkout -b feature/new-component
git checkout -b bugfix/address-decoder
```

### 2. Develop & Test

Write code following the style guide:

**Add VHDL module** (e.g., `rtl/peripherals/new_chip.vhd`):
- Follow entity/architecture template
- Use consistent naming
- Add inline documentation

**Write testbench** (e.g., `sim/tb_new_chip.vhd`):
- Test one component/feature at a time
- Include both positive and negative tests
- Report PASS/FAIL at end

**Run tests locally**:
```bash
make test          # Run all tests
ghdl -r tb_new_chip   # Run single test
ghdl -r tb_new_chip --wave=test.ghw  # Generate waveform
```

### 3. Commit Changes

Write clear commit messages:

```bash
git add rtl/peripherals/new_chip.vhd
git add sim/tb_new_chip.vhd
git commit -m "feat: add new peripheral controller

Implements XYZ functionality:
- Feature 1
- Feature 2

Tests:
- tb_new_chip verifies register operations
- tb_sbc_top_new integration test

All tests passing."
```

### 4. Create Pull Request

Push to your fork and create PR:

```bash
git push origin feature/new-component
```

Add PR description:
- Summary of changes
- Why this change is needed
- Test results
- Related issues

### 5. Code Review & Merge

- Address review comments
- Update code as suggested
- Merge when approved

## Adding New Components

### Template: New Peripheral

**File**: `rtl/peripherals/new_device.vhd`

```vhdl
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

-- New device controller
entity new_device is
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    cs      : in  std_logic;        -- Chip select
    we      : in  std_logic;        -- Write enable
    addr    : in  addr_t;           -- Register address
    din     : in  data_t;           -- Data input (write)
    dout    : out data_t;           -- Data output (read)
    irq     : out std_logic         -- Interrupt request
  );
end entity;

architecture rtl of new_device is
  -- Register storage
  signal reg0 : data_t := (others => '0');
  signal reg1 : data_t := (others => '0');
  
  -- Output latch
  signal dout_reg : data_t := (others => '0');
  
begin
  dout <= dout_reg;
  irq <= '0';  -- No interrupts for this device
  
  -- Main process: Handle reads and writes
  process(clk)
    variable reg_index : natural;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        reg0 <= (others => '0');
        reg1 <= (others => '0');
        dout_reg <= (others => '0');
      elsif cs = '1' then
        reg_index := to_integer(unsigned(addr(1 downto 0)));
        
        if we = '1' then
          -- Write operation
          case reg_index is
            when 0 => reg0 <= din;
            when 1 => reg1 <= din;
            when others => null;
          end case;
        else
          -- Read operation
          case reg_index is
            when 0 => dout_reg <= reg0;
            when 1 => dout_reg <= reg1;
            when others => dout_reg <= (others => '0');
          end case;
        end if;
      else
        dout_reg <= (others => '0');
      end if;
    end if;
  end process;
  
end architecture;
```

**File**: `sim/tb_new_device.vhd`

```vhdl
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

entity tb_new_device is
end entity;

architecture tb of tb_new_device is
  signal clk : std_logic := '0';
  signal reset_n : std_logic := '1';
  signal cs : std_logic := '0';
  signal we : std_logic := '0';
  signal addr : addr_t := (others => '0');
  signal din : data_t := (others => '0');
  signal dout : data_t;
  signal irq : std_logic;
  
begin
  -- DUT instantiation
  dut : entity work.new_device
    port map (
      clk => clk,
      reset_n => reset_n,
      cs => cs,
      we => we,
      addr => addr,
      din => din,
      dout => dout,
      irq => irq
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
    
    -- Test 1: Write to register 0
    cs <= '1';
    we <= '1';
    addr <= x"0000";
    din <= x"42";
    wait for 100 ns;
    
    -- Test 2: Read from register 0
    we <= '0';
    wait for 100 ns;
    assert dout = x"42"
      report "Read incorrect value" severity error;
    
    -- Test 3: Write to register 1
    we <= '1';
    addr <= x"0001";
    din <= x"55";
    wait for 100 ns;
    
    -- Test 4: Read from register 1
    we <= '0';
    wait for 100 ns;
    assert dout = x"55"
      report "Read incorrect value" severity error;
    
    report "tb_new_device passed" severity note;
    wait;
  end process;
  
end architecture;
```

### Template: Testbench Integration

After creating new component, integrate into system:

**Modify**: `rtl/sbc_top.vhd`

```vhdl
-- Add port to entity (if external connection needed)
-- entity sbc_top is
--   port (
--     -- ... existing ports ...
--     new_device_output : out data_t;  -- If needed
--   );
-- end entity;

architecture rtl of sbc_top is
  -- Add signals for new device
  signal new_device_dout : data_t;
  signal new_device_cs   : std_logic;
  signal new_device_irq  : std_logic;
  
begin
  -- Add chip select generation
  new_device_cs <= '1' when dev_sel = DEV_NEW_DEVICE else '0';
  
  -- Instantiate new device
  new_device_i : entity work.new_device
    port map (
      clk     => clk,
      reset_n => reset_n,
      cs      => new_device_cs,
      we      => cpu_we,
      addr    => cpu_addr,
      din     => cpu_dout,
      dout    => new_device_dout,
      irq     => new_device_irq
    );
  
  -- Add to data multiplexer
  with dev_sel select cpu_din <=
    sram_dout      when DEV_SRAM,
    rom_dout       when DEV_ROM,
    via_dout       when DEV_VIA,
    uart_dout      when DEV_UART,
    new_device_dout when DEV_NEW_DEVICE,  -- Add this line
    -- ... other devices ...
    x"FF"          when others;
  
  -- Add to IRQ combining (if device has interrupts)
  irq_comb <= via_irq or uart_irq or vic_irq or new_device_irq;
  
end architecture;
```

**Modify**: `rtl/sbc_pkg.vhd`

```vhdl
-- Add to device_sel_t enumeration
type device_sel_t is (
  DEV_NONE,
  DEV_SRAM,
  DEV_ROM,
  DEV_VIA,
  DEV_UART,
  DEV_NEW_DEVICE,    -- Add this line
  -- ... other devices ...
);

-- Add address range constants
constant ADDR_NEW_DEVICE_BASE : unsigned(15 downto 0) := x"9100";
constant ADDR_NEW_DEVICE_LAST : unsigned(15 downto 0) := x"910F";
```

**Modify**: `rtl/bus_decode.vhd`

```vhdl
-- Add to address decoder
when FETCH_OPCODE_CAPTURE =>
  pc <= pc + 1;
  if data_in = x"01" then
    -- ... existing opcodes ...
  elsif in_range(addr, ADDR_NEW_DEVICE_BASE, ADDR_NEW_DEVICE_LAST) then
    sel <= DEV_NEW_DEVICE;
  elsif in_range(addr, ADDR_ROM_BASE, ADDR_ROM_LAST) then
    sel <= DEV_ROM;
  end if;
```

**Update**: `Makefile`

Add testbench to test target:
```makefile
test: ... tb_new_device
	$(GHDL) -r $(GHDL_FLAGS) tb_new_device $(GHDL_RUN_FLAGS)
```

## Testing New Code

### Unit Test Checklist

- [ ] Reset behavior (all signals clear)
- [ ] Write operation (data stored)
- [ ] Read operation (stored data returned)
- [ ] Chip select (responds only when selected)
- [ ] Edge cases (boundary addresses, all 0x00/0xFF data)
- [ ] Interrupts (if applicable)

### Integration Test Checklist

- [ ] Component accessible from CPU bus
- [ ] Correct address decoding
- [ ] Data multiplexing works
- [ ] Interrupt combining (if applicable)
- [ ] No conflicts with other devices

### Code Review Checklist

- [ ] Follows style guide
- [ ] Proper VHDL syntax
- [ ] Clear variable names
- [ ] Inline comments for non-obvious code
- [ ] All tests pass
- [ ] No warnings during compilation

## Documentation Updates

When adding new features:

1. **Update MODULES.md**: Add component description
2. **Update ARCHITECTURE.md**: Update memory map or system diagram
3. **Update COMPONENTS.md**: Detailed register descriptions
4. **Update roadmap.md**: Mark completed features

## Debugging Tips

### Simulation Debugging

```vhdl
-- Add report statements
report "addr = " & to_hstring(addr) severity note;
report "expected = " & to_hstring(expected) severity note;

-- Use assertions with detailed messages
assert actual = expected
  report "Expected: " & to_hstring(expected) &
         " Got: " & to_hstring(actual)
  severity error;
```

### Waveform Analysis

```bash
ghdl -r tb_my_test --wave=debug.ghw
gtkwave debug.ghw &
```

Look for:
- Signal transitions at wrong times
- Data not appearing on read
- Write enable strobing incorrectly

### Incremental Testing

Test smallest piece first:
1. Test single register read/write
2. Test with chip select
3. Test in simple testbench
4. Test in integrated system
5. Test with real ROM

## Performance Considerations

### FPGA Synthesis

For components intended for FPGA:

- Avoid unbounded loops
- Use synchronous design (not latches)
- Keep logic levels shallow (~8 LUTs per stage)
- Use block RAM for memory (not distributed)

### Simulation Performance

- Reduce clocks in test (shorter waits)
- Eliminate unused report statements in loops
- Use `--stop-time` to limit simulation duration

## Getting Help

### Documentation

1. Check this Development Guide
2. Review similar existing components
3. Check testbenches for usage examples
4. Read VHDL language references

### Discussion

- Open an issue for questions/discussion
- Ask in pull request comments
- Check project README for contacts

---

See Also:
- [Architecture](./01_ARCHITECTURE.md) - System design context
- [Modules Reference](./02_MODULES.md) - Component documentation
- [Building & Synthesis](./03_BUILDING.md) - Compilation
- [Testing Guide](./04_TESTING.md) - Test structure
