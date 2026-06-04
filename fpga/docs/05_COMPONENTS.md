# Component Reference

Detailed specifications for major FPGA components.

## VIA 6522: Versatile Interface Adapter

### Overview

The VIA 6522 is a parallel I/O controller with built-in interval timers. The FPGA implementation supports the essential features needed for keyboard input, interrupt generation, and timing control.

### Memory-Mapped Address Space

```
0x8800-0x880F (16 bytes in system address space)
```

**Register Addressing** (offset from 0x8800):

| Addr | Name | R/W | Reset | Function |
|------|------|-----|-------|----------|
| 0x0 | ORB | RW | $00 | Output Register B |
| 0x1 | ORA | RW | $00 | Output Register A |
| 0x2 | DDRB | RW | $00 | Data Direction B |
| 0x3 | DDRA | RW | $00 | Data Direction A |
| 0x4 | T1CL | R | $00 | Timer 1 Counter Low (read-only) |
| 0x5 | T1CH | RW | $00 | Timer 1 Counter High |
| 0x6 | T1LL | RW | $00 | Timer 1 Latch Low |
| 0x7 | T1LH | RW | $00 | Timer 1 Latch High |
| 0x8 | T2CL | R | $00 | Timer 2 Counter Low (read-only) |
| 0x9 | T2CH | RW | $00 | Timer 2 Counter High |
| 0xA | SR | RW | $00 | Shift Register (stub) |
| 0xB | ACR | RW | $00 | Auxiliary Control Register |
| 0xC | PCR | RW | $00 | Peripheral Control Register |
| 0xD | IFR | RW | $00 | Interrupt Flag Register |
| 0xE | IER | RW | $00 | Interrupt Enable Register |
| 0xF | ORA2 | RW | $00 | Output Register A (no strobe) |

### Port A & B Operation

#### Data Direction Register (DDRA/DDRB)

Controls whether port pins are inputs or outputs:

```
Bit | 1 = Output | 0 = Input
 7  |            |
 6  |            |
 ... |            |
 0  |            |
```

#### Output Register (ORA/ORB)

When pin is configured as output (DDR=1):
- CPU writes to OR → pin driven to that value
- Read returns latched output value

When pin is configured as input (DDR=0):
- Pin driven externally
- Read returns external input value (mixed_port logic)

#### Mixed Port Read

The VIA implements mixed I/O where each pin can be input or output:

```vhdl
read_value = (output_reg AND ddr) OR (input_pins AND NOT ddr)
```

**Example**: DDRB=$FF (all outputs), ORB=$A5
- Port B drives 0xA5 on all pins
- Read returns 0xA5

**Example**: DDRB=$0F (lower nibble output), ORB=$3C
- Pins 0-3 drive 0x0C (lower nibble of 0x3C)
- Pins 4-7 read external inputs
- Read returns (external AND 0xF0) OR 0x0C

### Timers

#### Timer 1 (16-bit Interval Timer)

**Registers**:
- T1CL (0x04): Counter low byte (read-only)
- T1CH (0x05): Counter high byte (write starts timer)
- T1LL (0x06): Latch low byte
- T1LH (0x07): Latch high byte

**Write Operation** (Start Timer):
1. Write low byte to T1LL
2. Write high byte to T1CH → Timer starts with value in T1LL:T1CH
3. Counter decrements every clock cycle
4. When counter=0, IFR bit 6 asserts and timer stops (or reloads)

**Read Operation**:
- Read T1CL returns current low byte
- Read T1CH returns current high byte
- Reading T1CL clears interrupt flag bit 6

**Modes** (controlled by ACR bit 6):
- **0 = One-Shot**: Timer counts down once, stops at zero
- **1 = Continuous**: Timer reloads from latch and continues counting

**Interrupt**:
- IFR bit 6 asserts when counter reaches 0
- IER bit 6 gates this to IRQ output

#### Timer 2 (16-bit Interval Timer)

**Registers**:
- T2CL (0x08): Counter low byte (read-only)
- T2CH (0x09): Counter high byte (write starts timer)
- T2LO (latched): Low byte latch (written via T2CL)

**Write Operation** (Start Timer):
1. Write low byte to T2CL → latched in T2LO
2. Write high byte to T2CH → Timer starts with value T2CH:T2LO
3. Counter decrements every clock cycle
4. When counter=0, IFR bit 5 asserts and timer stops

**Characteristics**:
- Single-shot only (no continuous mode)
- Lower 8 bits latched, full 16-bit timer
- Always stops after reaching zero

**Interrupt**:
- IFR bit 5 asserts when counter reaches 0
- IER bit 5 gates this to IRQ output

### Interrupt Control

#### Interrupt Flag Register (IFR, offset 0x0D)

```
Bit 7: Interrupt Status (1 if any enabled interrupt pending)
Bit 6: Timer 1
Bit 5: Timer 2
Bit 4: CB1 Interrupt
Bit 3: CB2 Interrupt
Bit 2: Shift Register
Bit 1: CA1 Interrupt
Bit 0: CA2 Interrupt
```

**Reading IFR**:
- Returns current flag state
- Bit 7 = 1 if (IFR AND IER) != 0

**Writing to IFR**:
- Write 1 to clear that flag
- Write 0 has no effect (can't set flags via write)

#### Interrupt Enable Register (IER, offset 0x0E)

```
Bit 7: Set/Clear control (1=set, 0=clear)
Bit 6: Timer 1 enable
Bit 5: Timer 2 enable
Bit 4: CB1 enable
Bit 3: CB2 enable
Bit 2: Shift Register enable
Bit 1: CA1 enable
Bit 0: CA2 enable
```

**Write Behavior**:
- If bit 7 = 1: Enable interrupts (OR with existing IER)
- If bit 7 = 0: Disable interrupts (AND NOT with existing IER)

**Example**:
```
Write 0x40 to IER → Enable Timer 1: IER = IER OR 0x40
Write 0xC0 to IER → Set Timer 1 enable bit
Write 0x40 to IER → Disable Timer 1: IER = IER AND NOT 0x40
```

### Typical Usage

**Initialize Timer 1 for 1ms interrupt** (at 1 MHz clock):
```asm
LDA #$E8          ; 1000 cycles low byte
STA $8806         ; Store to T1LL
LDA #$03          ; 1000 cycles high byte (1000 = 0x03E8)
STA $8807         ; Store to T1CH (starts timer)

; Enable Timer 1 interrupt
LDA #$C0          ; Set bit 7 (set mode) and bit 6 (Timer 1)
STA $880E         ; Store to IER
```

---

## UART 6551: Asynchronous Serial Interface

### Overview

The UART 6551 provides serial communications (RS-232 style). The FPGA implementation supports basic TX/RX with no baud rate generation (external frequency assumed).

### Memory-Mapped Address Space

```
0x8810-0x8813 (4 bytes in system address space)
```

**Register Addressing** (offset from 0x8810):

| Addr | Name | Type | Reset | Function |
|------|------|------|-------|----------|
| 0x0 | DATA | R/W | $00 | Transmit/Receive data |
| 0x1 | STATUS | R/W | $10 | Status flags |
| 0x2 | CMD | W | $00 | Command register |
| 0x3 | CTRL | W | $00 | Control register (stub) |

### Data Register (0x8810)

**Write (Transmit)**:
```
$8810 = data_byte

Behavior:
- Store byte in TX register
- Set tx_valid pulse (external circuit sends byte)
- TDRE flag remains set
- No flow control (always ready)
```

**Read (Receive)**:
```
data = $8810

Behavior:
- Return data from RX buffer
- Clear RDRF flag
- No error flags in read value
```

### Status Register (0x8811)

**Bit Layout**:
```
Bit 7: IRQ      - Interrupt pending (1 if RX available and enabled)
Bit 6: DSR      - Data Set Ready (not used)
Bit 5: DCD      - Data Carrier Detect (not used)
Bit 4: TDRE     - TX Data Register Empty (always 1 = ready)
Bit 3: RDRF     - RX Data Register Full (1 = data available)
Bit 2: OVR      - Overrun (1 = data was lost)
Bit 1: FE       - Framing Error (stub)
Bit 0: PE       - Parity Error (stub)
```

**Read Status**:
```
status = $8811

Returns current flags. Bit 7 indicates:
- Bit 7 = 1 if: (RDRF AND CMD bit 0)
```

**Write to Status**:
```
$8811 = any_value

Behavior:
- Clear all status flags to default ($10)
- Clear command register
- Clear control register
- Used for programmed reset
```

### Command Register (0x8812)

**Bit Layout**:
```
Bit 7: DTR       - Data Terminal Ready (not used)
Bit 6: IRQ Dis   - Disable IRQ (not fully used)
Bit 5: RTS       - Request To Send (not used)
Bit 4: Echo      - Echo mode (not used)
Bit 3: Parity    - Parity type (stub)
Bit 2: Parity    - Parity control (stub)
Bit 1: RX Enable - (stub)
Bit 0: RX IRQ    - RX Interrupt Enable (1 = enable IRQ on RX)
```

**Typical Use**:
```
$8812 = $01    ; Enable RX interrupt (bit 0)
$8812 = $00    ; Disable RX interrupt
```

### Control Register (0x8813)

Not fully implemented. Intended for baud rate and format control.

**Would contain** (stub):
- Baud rate selection
- Data format (8/7 bits, stop bits, parity)

### RX Interrupt Behavior

**Condition for IRQ**:
```
IRQ = RDRF AND (CMD bit 0)
```

**Sequence**:
1. External circuit presents data with rx_valid strobe
2. UART latches data, sets RDRF flag
3. If CMD bit 0 = 1, IRQ asserts (IRQ output = 1)
4. CPU reads DATA register
5. RDRF clears (IRQ deasserts)

### Overrun Detection

**Condition**:
- New rx_valid strobe arrives while RDRF already = 1
- Incoming data is lost
- OVR flag asserts

**Recovery**:
- Write any value to STATUS (programmed reset)
- Clears OVR and other flags

### Typical Usage

**Initialize for RX interrupts**:
```asm
LDA #$01         ; Enable RX interrupt
STA $8812        ; Write to CMD
```

**RX Interrupt Handler**:
```asm
; IRQ service routine
LDA $8811        ; Read status
AND #$08         ; Check RDRF
BEQ no_data
LDA $8810        ; Read data byte
STA $0200        ; Store in buffer
no_data:
RTI
```

---

## Memory Components

### SRAM (sync_ram.vhd)

**Configuration** (in sbc_top.vhd):
```vhdl
ADDR_WIDTH => 15    -- 2^15 = 32KB
```

**Address Mapping**:
```
CPU address 0x0000-0x7FFF → SRAM[0x0000-0x7FFF]
```

**Timing**:
- **Write**: Data latched on rising clock edge
- **Read** (default): Output latched on rising clock edge
- **Read** (async mode): Combinational output (not used in sbc_top)

**Initialization**: All zeros at reset

### ROM (rom.vhd)

**Configuration** (in sbc_top.vhd):
```vhdl
ADDR_WIDTH => 14,               -- 2^14 = 16KB
INIT_FILE  => ROM_INIT_FILE     -- Hex file path
```

**Address Mapping**:
```
CPU address 0xC000-0xFFFF → ROM[0x0000-0x3FFF]
```

**Reset Vector** (CPU startup):
- CPU reads address 0xFFFC-0xFFFD on reset
- ROM[0x3FFC] = reset vector low byte
- ROM[0x3FFD] = reset vector high byte
- Typically contains jump to kernel code

**File Format**:
```
0000 A9    ; NOP at offset 0000
0001 42    ; Opcode 42 at offset 0001
```

---

See Also:
- [Architecture](./01_ARCHITECTURE.md) - System design
- [Modules Reference](./02_MODULES.md) - Component overview
- [Testing Guide](./04_TESTING.md) - Test coverage
