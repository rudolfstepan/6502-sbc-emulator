# Tier 1 Implementation Plan

Detailed plan for implementing Tier 1 features (Critical Path).

## Overview

**Tier 1 consists of 3 major features:**
1. Fix T65 Indirect Addressing
2. Implement VIC Text Mode Display  
3. Complete UART Implementation

**Total Estimated Effort**: 4-6 weeks  
**Priority Order**: Sequential (each unblocks the next)

---

## Feature 1: Fix T65 Indirect Addressing

### Problem Statement

**Current Issue**:
- T65 CPU indirect addressing mode (`STA ($zp),Y`) not working correctly
- Test `tb_sbc_t65_indirect_vic.vhd` is SKIPPED (not in main test suite)
- Blocks kernel `CLRSCR` (screen clear) which uses indirect writes to VIC text RAM
- Prevents full kernel boot sequence from completing

**Test Case**:
- Expected: Write 0x20 (space character) to VIC text RAM at 0x8000
- Actual: Write doesn't occur within expected cycle count
- Location: `sim/tb_sbc_t65_indirect_vic.vhd`

### Root Cause Analysis

**Suspected Issue**:
The T65 core implements indirect-Y addressing, but the integration may have:
1. Incorrect address bus mapping (24-bit T65 → 16-bit system)
2. Timing issue with read-modify-write cycle
3. VDA (Valid Data Address) signal handling during indirect fetch
4. Data setup/hold timing misalignment

**Investigation Steps**:
1. Generate waveform for failing test
2. Inspect T65 address/data/we signals during indirect instruction
3. Compare expected vs actual bus cycles
4. Verify VDA signal timing aligns with instruction phases

### Implementation Steps

#### Step 1: Analyze T65 Behavior (2-3 days)

**Task**: Run test with waveform capture

```bash
cd fpga/
ghdl -a --std=08 --ieee=synopsys \
  rtl/sbc_pkg.vhd rtl/bus_decode.vhd \
  rtl/mem/sync_ram.vhd rtl/mem/rom.vhd \
  rtl/peripherals/*.vhd rtl/cpu/t65_adapter.vhd \
  rtl/sbc_t65_top.vhd sim/tb_sbc_t65_indirect_vic.vhd

ghdl -e --std=08 --ieee=synopsys tb_sbc_t65_indirect_vic

ghdl -r tb_sbc_t65_indirect_vic --wave=indirect_vic.ghw --stop-time=50us
```

**Waveform Analysis** (in GTKWave):
1. Watch `dbg_cpu_addr` during indirect instruction
2. Check `dbg_cpu_we` strobes at correct cycle
3. Verify `dbg_cpu_data` contains 0x20
4. Look for address fetch vs data fetch phases
5. Inspect internal T65 signals (via debug ports if available)

**Key Signals to Monitor**:
- `clk`: Main system clock
- `dbg_cpu_addr`: CPU address bus (should show intermediate address fetches)
- `dbg_cpu_we`: Write strobe
- `dbg_cpu_data`: Write data (expect 0x20)
- `dbg_cpu_din`: Data returned from memory
- Internal T65 signals: `A` (24-bit address), `DO` (data out), `DI` (data in)

#### Step 2: Review T65 Instruction Cycle (1 day)

**Task**: Understand `STA ($zp),Y` cycle sequence

The instruction `STA ($zp),Y` performs:
1. Fetch opcode (STA indirect-Y = 0x91)
2. Fetch zero-page address low byte
3. Fetch zero-page address high byte (or assume page 0)
4. Fetch address from zero page (gets effective address low)
5. Fetch address high or increment low byte
6. Add Y register to address
7. Write accumulator to final address

**Expected Cycle Count**: 6-7 cycles (depending on page boundary)

**T65 Documentation**:
- Review T65 cycle-accurate timing
- Check if indirect addressing is fully implemented
- Look for known limitations or quirks

#### Step 3: Diagnose Adapter Issue (2-3 days)

**File**: `rtl/cpu/t65_adapter.vhd`

**Potential Problems**:

a) **Address Width Mismatch**
```vhdl
-- Current code
addr <= t65_addr(15 downto 0);  -- Takes lower 16 bits

-- Potential issue: If T65 generates address on bits [23:16] during
-- indirect addressing intermediate steps, we'd miss them
```

b) **VDA Signal Timing**
```vhdl
-- Current code
we <= (not t65_r_w_n) and t65_vda;

-- Potential issue: VDA might not align with data phase
-- T65 might assert VDA during address fetch too
```

c) **Read Data Path**
```vhdl
-- Current code
t65_din <= data_in;  -- Direct pass-through

-- Potential issue: Data might not be ready at expected cycle
-- May need pipeline delay for ROM/peripheral response
```

**Diagnosis Steps**:
1. Add debug outputs to adapter showing all T65 signals
2. Compare actual T65 bus activity with expected sequence
3. Check T65 core documentation for any known quirks
4. Verify read data is stable when T65 expects it

#### Step 4: Implement Fix (3-5 days)

**Likely Fixes**:

**Option A: Pipeline Read Data**
```vhdl
-- If peripheral response is too slow, add pipeline stage
process(clk)
begin
  if rising_edge(clk) then
    t65_din <= data_in;  -- Sample read data
  end if;
end process;
```

**Option B: Adjust VDA Logic**
```vhdl
-- Only assert writes during valid data address + write
we <= (not t65_r_w_n) and t65_vda and clock_enable;
```

**Option C: Extend Address Capture**
```vhdl
-- Ensure full 24-bit address is properly mapped
-- May need intermediate address latch for indirect addressing
```

**Option D: Check T65 Configuration**
- Verify T65 is in correct mode (65C02 vs 6502)
- Check internal state initialization
- Look for timing configuration options

### Verification

**Success Criteria**:
- ✅ `tb_sbc_t65_indirect_vic` passes
- ✅ Write of 0x20 to address 0x8000 occurs
- ✅ Waveform shows correct indirect addressing sequence
- ✅ Can enable test in main `make test` suite

**Test After Fix**:
```bash
ghdl -r tb_sbc_t65_indirect_vic --stop-time=50us
# Should output: "tb_sbc_t65_indirect_vic passed"
```

### Timeline: 2 weeks

---

## Feature 2: VIC Text Mode Display

### Problem Statement

**Current State**:
- VIC exists as stub with generic register file (8192 registers)
- No actual video display generation
- No character-to-pixel rendering
- No timing control

**Goal**:
- Implement 40×25 character display
- Text RAM read from CPU writes
- Character ROM for pixel data
- VGA timing output (optional for FPGA version)
- Interrupt generation on raster events

### Architecture

```
┌─────────────────────────────────────┐
│   CPU (via bus)                     │
│   Writes to 0x8000-0x87FF (text)   │
└──────────────┬──────────────────────┘
               │
          ┌────▼─────┐
          │ VIC Core │
          └────┬─────┘
              │
    ┌─────────┼─────────┐
    │         │         │
┌───▼──┐ ┌───▼──┐ ┌───▼────┐
│Text  │ │Color │ │Charset │
│RAM   │ │RAM   │ │ROM     │
└──┬───┘ └──┬───┘ └───┬────┘
   │        │        │
   └────────┼────────┘
            │
       ┌────▼────┐
       │Pixel    │
       │Renderer │
       └────┬────┘
            │
       ┌────▼──────┐
       │Video Out  │
       │(VGA/HDMI) │
       └───────────┘
```

### Implementation Steps

#### Step 1: Create VIC Core Module (3-4 days)

**File**: `rtl/peripherals/vic_core.vhd`

**Purpose**: Replace the generic `reg_stub` with real VIC implementation

**Functionality**:
```vhdl
entity vic_core is
  port (
    -- System interface
    clk       : in std_logic;
    reset_n   : in std_logic;
    
    -- CPU bus interface
    cs        : in std_logic;        -- Chip select
    we        : in std_logic;        -- Write enable
    addr      : in addr_t;           -- CPU address
    din       : in data_t;           -- Data from CPU
    dout      : out data_t;          -- Data to CPU
    
    -- Interrupt
    irq       : out std_logic;       -- Raster interrupt
    
    -- Video output (to optional display module)
    pixel_x   : out integer range 0 to 319;  -- Current X position
    pixel_y   : out integer range 0 to 199;  -- Current Y position
    pixel_out : out data_t;          -- RGB data (or palette index)
    pixel_valid : out std_logic      -- Pixel valid strobe
  );
end entity;
```

**Memory Layout** (within 0x8000-0xAF4F):
```
0x8000-0x87FF: Text RAM (40×25 = 1000 bytes)
0x8800-0x88FF: Color RAM (40×25 = 1000 bytes)
0x9000-0x900F: Control registers
0x9010-0xAF4F: Bitmap/sprite RAM (reserved, will expand)
```

**Text RAM Structure**:
- Byte = ASCII character code (0x20-0x7F)
- Row-major order (row 0 = bytes 0-39, row 1 = bytes 40-79, etc.)
- Wraps to next line automatically

**Control Registers** (address 0x9000-0x900F):
- 0x00: Horizontal scroll
- 0x01: Vertical scroll
- 0x02: Raster line compare (for interrupt)
- 0x03-0x0F: Reserved for expansion

#### Step 2: Create Character ROM (2-3 days)

**File**: `rtl/mem/char_rom.vhd`

**Purpose**: Store 8×8 pixel patterns for ASCII characters

**Source Options**:
1. Use standard C64 character ROM (PETSCII compatible)
2. Create 8×8 bitmap for each character
3. Synthesize from ASCII font data

**Implementation**:
```vhdl
entity char_rom is
  port (
    -- Address: char_code(6:0) & pixel_y(2:0)
    -- 7-bit character code (128 characters)
    -- 3-bit pixel Y (8 pixels per character)
    addr : in std_logic_vector(9 downto 0);
    
    -- Output: 8-bit pixel data (one row of 8×1 character)
    dout : out data_t
  );
end entity;
```

**Addressing Scheme**:
```
For character 'A' (0x41) at pixel line 3:
  addr = '0' & 0x41 & "011" = 0x083 (binary: 0000 1000 0011)
  dout = 0xAA (8 pixels: 10101010 = the pattern at line 3 of 'A')
```

**Character Set**: ASCII 0x00-0x7F (128 characters)

**Storage**: 128 chars × 8 lines × 1 byte = 1KB ROM

#### Step 3: Create Pixel Generator (4-5 days)

**File**: `rtl/peripherals/vic_pixel_gen.vhd`

**Purpose**: Convert text RAM + character ROM to pixel stream

**Process**:
1. Timing generator: Horizontal/vertical counters
2. Calculate row, column from current position
3. Read character code from text RAM
4. Read character line from character ROM
5. Read color from color RAM
6. Generate pixel with color

**Implementation Logic**:
```vhdl
-- Calculate character grid position
char_row := pixel_y / 8;      -- Which text row (0-24)
char_col := pixel_x / 8;      -- Which text column (0-39)
char_line := pixel_y mod 8;   -- Which line in character (0-7)
char_pixel := pixel_x mod 8;  -- Which pixel in line (0-7)

-- Address into text and color RAM
text_addr := char_row * 40 + char_col;

-- Read character code
char_code := text_ram[text_addr];

-- Read character pattern
char_rom_addr := char_code(6 downto 0) & char_line;
pattern_byte := char_rom[char_rom_addr];

-- Extract pixel
pixel_bit := pattern_byte[7 - char_pixel];

-- Read color
color := color_ram[text_addr];

-- Output colored pixel
output_pixel := pixel_bit ? color : background_color;
```

**Timing Generation**:
```vhdl
-- Generate horizontal and vertical sync for VGA/HDMI
-- Standard timing: 640×480 @ 60Hz

-- Timing constants
HPIXELS = 640;      -- Visible pixels per line
VLINES = 480;       -- Visible lines per frame
HTOTAL = 800;       -- Total pixels per line (including blanking)
VTOTAL = 525;       -- Total lines per frame

-- Counters
always @(posedge clk)
  if h_count == HTOTAL - 1 then
    h_count <= 0;
    if v_count == VTOTAL - 1 then
      v_count <= 0;
    else
      v_count <= v_count + 1;
    end if;
  else
    h_count <= h_count + 1;
  end if;

-- Output pixel when in visible range
pixel_valid <= (h_count < HPIXELS) and (v_count < VLINES);
h_sync <= (h_count >= HSYNC_START) and (h_count < HSYNC_END);
v_sync <= (v_count >= VSYNC_START) and (v_count < VSYNC_END);
```

#### Step 4: Implement Raster Interrupt (1-2 days)

**Purpose**: Generate CPU interrupt at specific raster line

**Mechanism**:
```vhdl
-- Compare raster counter to configured line
if raster_y == raster_compare then
  raster_irq_flag <= '1';
end if;

-- IRQ output (active high if interrupt enabled)
irq <= raster_irq_flag and raster_irq_enable;

-- Clear flag when CPU reads status register
if cpu_reads_status_register then
  raster_irq_flag <= '0';
end if;
```

**Used For**:
- Kernel can set up effects to trigger at specific screen position
- Enables raster effects and interrupt-driven refresh
- Essential for game timing and animation

#### Step 5: Integration Tests (2-3 days)

**Create**: `sim/tb_vic_core.vhd`

**Test Cases**:
1. Text RAM write and read
2. Color RAM access
3. Character ROM lookup
4. Pixel generation sequence
5. Raster interrupt generation
6. Timing verification (H/V sync)

**Integration Test**: `sim/tb_sbc_vic_display.vhd`
- Boot kernel with full VIC
- Verify text appears on "display"
- Check screen clearing works
- Verify raster interrupts fire

### Verification

**Success Criteria**:
- ✅ Text can be written via CPU bus
- ✅ Text appears in correct screen positions
- ✅ Colors display correctly
- ✅ Raster interrupt fires at configured line
- ✅ `tb_sbc_t65_kernel_smoke` completes full CLRSCR
- ✅ Character rendering is legible

### Timeline: 3-4 weeks

---

## Feature 3: Complete UART Implementation

### Problem Statement

**Current State**:
- Basic TX/RX register interface working
- Status flags (RDRF, TDRE, OVR) functional
- Baud rate generation NOT implemented (stub)
- No configurable data format

**Goal**:
- Implement baud rate clock generation
- Support 300-115200 baud
- Configurable data format (5/6/7/8 bits, 1/2 stop bits)
- Optional parity (none/odd/even)
- Flow control (optional)

### Architecture

```
     Baud Rate Generator
              │
    ┌─────────▼──────────┐
    │ Clock Division     │
    │ (select by rate)   │
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │ TX Shift Register  │
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │ Serial Output (TX) │
    └────────────────────┘
    
    ┌────────────────────┐
    │ Serial Input (RX)  │
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │ RX Shift Register  │
    │ (with sampling)    │
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │ RX Data Register   │
    └────────────────────┘
```

### Implementation Steps

#### Step 1: Baud Rate Generator (2-3 days)

**File**: Add to `rtl/peripherals/uart6551.vhd`

**Concept**: Divide system clock to get bit clock at desired baud rate

**Baud Rates & Dividers** (assuming 10 MHz clock):
```
Baud   | Divider | Clock Cycles
-------|---------|---------------
300    | 33333   | 33333
600    | 16667   | 16667
1200   | 8333    | 8333
2400   | 4167    | 4167
4800   | 2083    | 2083
9600   | 1042    | 1042
19200  | 521     | 521
38400  | 260     | 260
57600  | 173     | 173
115200 | 87      | 87
```

**Implementation**:
```vhdl
-- Baud rate control register bits
CTRL[1:0] = baud rate select:
  00 = 300 baud
  01 = 1200 baud
  10 = 9600 baud
  11 = 38400 baud

-- Baud clock generator
process(clk)
begin
  if rising_edge(clk) then
    case ctrl_reg(1 downto 0) is
      when "00" => baud_divider := 33333;  -- 300 baud
      when "01" => baud_divider := 8333;   -- 1200 baud
      when "10" => baud_divider := 1042;   -- 9600 baud
      when "11" => baud_divider := 260;    -- 38400 baud
    end case;
    
    -- Count down to generate baud clock
    if baud_count = 0 then
      baud_count <= baud_divider;
      baud_clk <= '1';  -- Pulse baud clock
    else
      baud_count <= baud_count - 1;
      baud_clk <= '0';
    end if;
  end if;
end process;
```

#### Step 2: Expand Data Format Support (2-3 days)

**File**: Modify `rtl/peripherals/uart6551.vhd`

**CTRL Register Expansion**:
```
Bit 7: DTR (Data Terminal Ready) - not used
Bit 6: IRQ Disable - not used
Bit 5: RTS (Request To Send) - not used
Bit 4: Echo - not used
Bit 3-2: Parity Type
  00 = No parity
  01 = Odd parity
  10 = Even parity
  11 = Reserved
Bit 1-0: Data/Stop Bits
  00 = 8 data bits, 1 stop bit
  01 = 8 data bits, 2 stop bits
  10 = 7 data bits, 1 stop bit
  11 = 7 data bits, 2 stop bits
```

**Implementation**:
```vhdl
-- Transmit shift register (with configurable bits)
process(baud_clk)
  variable bit_count : integer range 0 to 11;
  variable data_bits : integer range 7 to 8;
  variable stop_bits : integer range 1 to 2;
begin
  if rising_edge(baud_clk) then
    case ctrl_reg(1 downto 0) is
      when "00" => data_bits := 8; stop_bits := 1;  -- 8 data, 1 stop
      when "01" => data_bits := 8; stop_bits := 2;  -- 8 data, 2 stop
      when "10" => data_bits := 7; stop_bits := 1;  -- 7 data, 1 stop
      when "11" => data_bits := 7; stop_bits := 2;  -- 7 data, 2 stop
    end case;
    
    if tx_valid = '1' then
      -- Load TX register with format
      tx_shift_reg <= din;
      bit_count := 0;  -- Start bit
    elsif bit_count < (1 + data_bits + 1 + stop_bits) then
      -- Shift out bits
      tx_output <= tx_shift_reg(0);
      tx_shift_reg <= '1' & tx_shift_reg(7 downto 1);  -- Stop bit = 1
      bit_count := bit_count + 1;
    else
      tx_output <= '1';  -- Idle
    end if;
  end if;
end process;
```

#### Step 3: RX Oversampling & Filtering (2-3 days)

**Purpose**: Properly sample RX bits despite timing jitter

**Technique**: Sample RX line at 16x baud rate, majority voting

```vhdl
process(clk)
  variable rx_samples : std_logic_vector(15 downto 0);
  variable sample_count : integer range 0 to 15;
begin
  if rising_edge(clk) then
    -- Oversample at 16x baud rate
    if sample_count = 15 then
      sample_count := 0;
      
      -- Shift in new sample
      rx_samples := rx_samples(14 downto 0) & uart_rx;
      
      -- Majority voting: if 8+ samples are 1, it's a 1
      if count_ones(rx_samples) >= 8 then
        rx_sampled <= '1';
      else
        rx_sampled <= '0';
      end if;
    else
      sample_count := sample_count + 1;
    end if;
  end if;
end process;
```

#### Step 4: Implement RX State Machine (2-3 days)

**States**:
```
IDLE → START → DATA0 → DATA1 → ... → DATAn → PARITY → STOP → IDLE
```

**Implementation**:
```vhdl
process(baud_clk)
  type rx_state_t is (IDLE, START, DATA_BITS, PARITY, STOP);
  variable state : rx_state_t;
  variable bit_index : integer range 0 to 7;
  variable rx_data : data_t;
  variable parity_bit : std_logic;
begin
  if rising_edge(baud_clk) then
    case state is
      when IDLE =>
        if rx_sampled = '0' then  -- Start bit detected
          state := START;
          bit_index := 0;
          rx_data := (others => '0');
        end if;
      
      when START =>
        -- Wait for middle of start bit
        state := DATA_BITS;
      
      when DATA_BITS =>
        if bit_index < data_bits then
          rx_data(bit_index) := rx_sampled;
          bit_index := bit_index + 1;
        else
          if parity_enabled then
            state := PARITY;
          else
            state := STOP;
          end if;
        end if;
      
      when PARITY =>
        parity_bit := rx_sampled;
        state := STOP;
      
      when STOP =>
        if stop_bit_count = 1 or bit_index = stop_bits then
          rx_register <= rx_data;
          rx_valid_flag <= '1';
          state := IDLE;
        end if;
    end case;
  end if;
end process;
```

#### Step 5: Error Detection (1-2 days)

**Errors to Detect**:
- **Framing Error**: Stop bit not detected (missing)
- **Parity Error**: Received parity doesn't match expected
- **Overrun**: New data received before old data read

**Implementation**:
```vhdl
-- Framing error: stop bit should be 1
if state = STOP and rx_sampled = '0' then
  framing_error <= '1';
end if;

-- Parity error: check parity of received bits
if parity_enabled then
  if parity_expected /= parity_received then
    parity_error <= '1';
  end if;
end if;

-- Overrun: new data while RDRF still set
if new_data_received and rdrf_flag = '1' then
  overrun_error <= '1';
end if;
```

#### Step 6: Integration Testing (2-3 days)

**Create**: `sim/tb_uart6551_full.vhd`

**Test Cases**:
1. Baud rate selection (verify clock divider)
2. Data format variations (5/6/7/8 bits, stop bits)
3. Parity calculation (odd/even)
4. TX transmission of various formats
5. RX reception with correct sampling
6. Error detection (framing, parity, overrun)
7. Flow control (if implemented)

**Integration**: Update `tb_sbc_t65_uart.vhd` to verify with real timing

### Verification

**Success Criteria**:
- ✅ All baud rates 300-115200 generate correct clock
- ✅ TX outputs correct bit sequence with configurable format
- ✅ RX correctly samples and reconstructs data
- ✅ Parity calculation is accurate
- ✅ Framing/parity/overrun errors detected
- ✅ Integration test `tb_uart6551_full` passes

### Timeline: 2-3 weeks

---

## Implementation Schedule

```
Week 1-2:   T65 Indirect Addressing Fix
├─ Day 1-2: Problem analysis & waveform capture
├─ Day 3-4: T65 documentation review
├─ Day 5-7: Diagnosis & root cause identification
└─ Day 8-10: Implementation & verification

Week 3-6:   VIC Text Mode Display
├─ Day 1-3:   VIC core module
├─ Day 4-6:   Character ROM
├─ Day 7-11:  Pixel generator
├─ Day 12-13: Raster interrupt
└─ Day 14-15: Integration & testing

Week 7-9:   UART Complete Implementation
├─ Day 1-3:   Baud rate generator
├─ Day 4-5:   Data format support
├─ Day 6-8:   RX sampling & filtering
├─ Day 9-10:  RX state machine
├─ Day 11-12: Error detection
└─ Day 13-14: Testing & verification

Week 10:    Buffer / Final Testing
├─ All three features integrated
├─ Full system test
└─ Documentation updates
```

---

## Success Metrics

**Tier 1 Complete When**:
1. ✅ T65 indirect addressing works
   - `tb_sbc_t65_indirect_vic` added to main test suite and PASSES
   
2. ✅ VIC displays text
   - Text appears on simulated "screen"
   - Full kernel boot completes with CLRSCR
   
3. ✅ UART fully functional
   - All baud rates supported
   - All data formats work
   - No data corruption
   - Errors properly detected

**Final Deliverable**:
- Updated `rtl/peripherals/` with complete implementations
- New testbenches all passing
- Updated documentation
- Ready for Tier 2 (additional features)

---

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|-----------|
| T65 issue is in core (can't fix) | HIGH | May need alternative CPU core or patch T65 |
| VIC rendering is complex | MEDIUM | Use simplified text-only version first, expand later |
| UART timing issues | MEDIUM | Extensive waveform analysis, start with lower baud rates |
| Integration conflicts | MEDIUM | Incremental testing, integration after each feature |

---

## Next Steps

1. **Immediately**: Start with T65 analysis (Week 1)
2. **Parallel**: Plan VIC implementation details
3. **Prepare**: Gather character ROM data (C64 font)
4. **Ready**: Set up UART test harness

Would you like me to:
- Start the T65 analysis right now?
- Create the VIC core module template?
- Set up the UART testing framework?
- Create detailed pseudocode for any component?

