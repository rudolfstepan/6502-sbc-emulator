# Feature 3: Complete UART Implementation

## Status
Starting Feature 3 of Tier 1 Plan
- Feature 1 (Fix T65 Indirect Addressing): ✓ COMPLETE
- Feature 2 (VIC Text Mode Display): Not started
- Feature 3 (Complete UART): Starting now

## Current State Analysis

### What Works
- Basic register interface (data, status, command, control)
- RX/TX data registers
- Status flags (TDRE, RDRF, OVR)
- Interrupt generation (on RX data available)
- External interface signals (rx_data, rx_valid, tx_data, tx_valid)

### What's Missing
1. **Baud Rate Generation** (CRITICAL)
   - No clock divider for serial timing
   - Can't set baud rate - stuck at whatever external interface provides
   - Needed: Support 300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200

2. **Data Format Configuration**
   - Currently hardcoded to 8 bits (assumed)
   - Need: 5, 6, 7, 8 bit options

3. **Stop Bits**
   - Currently hardcoded to 1 stop bit
   - Need: 1 or 2 stop bits option

4. **Parity**
   - Parity bits defined but not implemented
   - Need: None, Odd, Even parity generation/checking

## Architecture

```
System Clock
      |
      v
[Baud Rate Generator]  ← New! Clock divider
      |
      v
   Baud Clock (16x)
      |
      +----> [TX Path]
      |      - Shift register
      |      - Parallel→Serial
      |      - Parity generation
      |
      +----> [RX Path]
             - Shift register
             - Serial→Parallel
             - Parity checking
```

## Implementation Status

### Phase 1: Baud Rate Generator ✅ COMPLETE
- ✅ Clock divider for 300-115200 baud
- ✅ 16x oversampling for serial timing
- ✅ Baud selection via CTRL[3:0]
- ✅ All standard baud rates supported
- ✅ Default 9600 baud

### Phase 2: Data Format Configuration ✅ COMPLETE
- ✅ Support for 5/6/7/8 bit data formats
- ✅ Data length selection via CTRL[1:0]
- ✅ Helper function for format calculation
- ✅ Combined configuration (baud + data format)
- ✅ All format combinations tested

### Phase 3: Parity Support (In Progress)
- ⏳ Odd/even parity generation
- ⏳ Parity error detection
- ⏳ Stop bits configuration (1 or 2)

## Implementation Plan

### Phase 1: Baud Rate Generator (2-3 days)

**Goal**: Create configurable baud rate clock for 300-115200 baud

**File**: `rtl/peripherals/uart6551.vhd` (extend existing)

**Key Logic**:
```vhdl
-- Add baud rate constants
constant BAUD_300     : natural := 16000000 / (300 * 16);    -- Clock divider value
constant BAUD_1200    : natural := 16000000 / (1200 * 16);
constant BAUD_9600    : natural := 16000000 / (9600 * 16);
constant BAUD_115200  : natural := 16000000 / (115200 * 16);

-- Add baud rate generator
process(clk)
  variable div_count : natural range 0 to 65535;
  variable baud_select : std_logic_vector(3 downto 0);
begin
  if rising_edge(clk) then
    -- Select divider based on CTRL register bits [3:0]
    case ctrl_reg(3 downto 0) is
      when x"0" => baud_select := BAUD_300;
      when x"1" => baud_select := BAUD_600;
      -- ... etc
    end case;
    
    -- Generate baud clock (16x oversampling)
    if div_count = 0 then
      baud_clock <= not baud_clock;
      div_count := baud_select - 1;
    else
      div_count := div_count - 1;
    end if;
  end if;
end process;
```

**Assumption**: System clock is 16 MHz (standard for 6502 systems)

### Phase 2: Data Format Configuration (2-3 days)

**Goal**: Support configurable data width (5/6/7/8 bits)

**Register Mapping** (CTRL register bits):
- CTRL[1:0] = Data length: 00=5bits, 01=6bits, 10=7bits, 11=8bits
- CTRL[3:2] = Reserved for baud rate
- CTRL[4] = Stop bits: 0=1 stop, 1=2 stop
- CTRL[5] = Parity enable
- CTRL[6:7] = Parity type: 00=odd, 01=even

**TX Path Change**:
```vhdl
-- Variable length TX shift register
signal tx_shift_reg : std_logic_vector(9 downto 0);  -- 10 bits max (data + parity + stop)
signal tx_bit_count : natural range 0 to 10;

-- Shift out bits based on configured data length
process(baud_clock)
begin
  if rising_edge(baud_clock) then
    if tx_enable = '1' then
      tx_serial <= tx_shift_reg(0);
      tx_shift_reg <= '1' & tx_shift_reg(9 downto 1);  -- Shift, prepend stop bit
      tx_bit_count <= tx_bit_count - 1;
    end if;
  end if;
end process;
```

**RX Path Change**:
```vhdl
-- Variable length RX shift register
signal rx_shift_reg : std_logic_vector(9 downto 0);
signal rx_bit_count : natural range 0 to 10;
signal rx_data_valid : std_logic;

-- Receive bits based on configured data length
-- When rx_bit_count = 0, extract data from rx_shift_reg
```

### Phase 3: Parity Support (1-2 days)

**Goal**: Generate/check parity bits for data integrity

**TX Parity Generation**:
```vhdl
function calc_parity(data : std_logic_vector; parity_mode : std_logic_vector) return std_logic is
  variable parity : std_logic;
begin
  -- Calculate even parity (XOR of all bits)
  parity := '0';
  for i in data'range loop
    parity := parity xor data(i);
  end loop;
  
  -- Adjust for odd/even mode
  case parity_mode is
    when "00" =>  -- Odd parity
      return not parity;
    when "01" =>  -- Even parity
      return parity;
    when others =>
      return '0';  -- No parity
  end case;
end function;
```

**RX Parity Checking**:
```vhdl
-- After receiving all bits, check parity
if parity_enable = '1' then
  parity_received := rx_shift_reg(...);  -- Extract parity bit
  parity_calculated := calc_parity(rx_data, parity_mode);
  
  if parity_received /= parity_calculated then
    status_reg(ST_PE) <= '1';  -- Set parity error flag
  end if;
end if;
```

### Phase 4: Integration & Testing (2-3 days)

**Create Testbench**: `sim/tb_uart6551_complete.vhd`

**Test Cases**:
1. Baud rate generation (verify clock divider)
2. Data format variations (5/6/7/8 bit data)
3. Stop bit configuration (1 vs 2 stop bits)
4. Parity generation (odd/even) and detection
5. Full TX/RX sequence with various configurations
6. Error handling (framing errors, parity errors)

**Integration Test**: `sim/tb_sbc_t65_uart_advanced.vhd`
- Boot kernel with UART enabled
- Transmit/receive with different baud rates
- Verify console output works correctly

## Register Layout

### Control Register (0x8813)
```
Bits 7-6: Parity Type (00=odd, 01=even, 10=none, 11=reserved)
Bit 5:    Parity Enable (1=parity, 0=no parity)
Bit 4:    Stop Bits (1=2 stop bits, 0=1 stop bit)
Bits 3-0: Baud Rate Select
  0x0: 300 baud
  0x1: 600 baud
  0x2: 1200 baud
  0x3: 2400 baud
  0x4: 4800 baud
  0x5: 9600 baud
  0x6: 19200 baud
  0x7: 38400 baud
  0x8: 57600 baud
  0x9: 115200 baud
  0xA-0xF: Reserved
```

### Data Format Selection
Based on bits 1:0 (when baud select not using these bits):

Actually, better approach: Use bits 6:4 for data format
```
Bits 6:4: Data Length
  000: 5 bits
  001: 6 bits
  010: 7 bits
  011: 8 bits (default)
  100-111: Reserved
```

## Success Criteria

✅ Baud rate generator produces correct clock divider values  
✅ Data can be transmitted/received with 5, 6, 7, 8 bit formats  
✅ Stop bits configurable (1 or 2)  
✅ Parity generated correctly (odd/even)  
✅ Parity errors detected and flagged  
✅ All existing UART tests still pass  
✅ New UART tests pass with various configurations  
✅ Console I/O works at 115200 baud (common terminal speed)

## Timeline: 1-2 weeks

Priority: HIGH - Serial console is essential for debugging and user I/O

## Risks & Mitigation

**Risk**: Complex state management with multiple configuration options  
**Mitigation**: Incremental approach - baud rate first, then data format, then parity

**Risk**: Timing closure with high baud rates (115200)  
**Mitigation**: Use registered outputs, pipeline stages as needed

**Risk**: Breaking existing functionality  
**Mitigation**: Backward compatible - defaults match current behavior

---

*Ready to begin Phase 1: Baud Rate Generator*
