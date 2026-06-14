-- VIA 6522 Versatile Interface Adapter: Parallel I/O controller with dual timers
-- Emulates the classic 6522 chip for retro computing. Provides:
--   - 2 parallel I/O ports (A and B) with individual direction control (DDR)
--   - 2 independent 16-bit interval timers (T1 and T2) with interrupt generation
--   - Shift register for serial data (basic support)
--   - Control lines for edge-sensitive interrupt inputs
-- This is a key peripheral for legacy 6502 systems requiring parallel I/O and timing
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity via6522 is
  port (
    clk        : in  std_logic;      -- System clock
    reset_n    : in  std_logic;      -- Active-low synchronous reset
    cs         : in  std_logic;      -- Chip Select: device active when high
    we         : in  std_logic;      -- Write Enable: 1=write, 0=read
    addr       : in  addr_t;         -- Register address (lower 4 bits select register)
    din        : in  data_t;         -- Data input for register writes
    dout       : out data_t;         -- Data output for register reads
    porta_in   : in  data_t;         -- External input on Port A (for input pins)
    portb_in   : in  data_t;         -- External input on Port B (for input pins)
    porta_out  : out data_t;         -- Output on Port A (driven by ORA and DDRA)
    portb_out  : out data_t;         -- Output on Port B (driven by ORB and DDRB)
    irq        : out std_logic       -- Interrupt Request output to CPU
  );
end entity;

architecture rtl of via6522 is
  -- Register address map (offset within VIA address space)
  constant REG_ORB  : natural := 16#0#;  -- Output Register B (port B output latch)
  constant REG_ORA  : natural := 16#1#;  -- Output Register A (port A output latch)
  constant REG_DDRB : natural := 16#2#;  -- Data Direction Register B (1=output, 0=input)
  constant REG_DDRA : natural := 16#3#;  -- Data Direction Register A (1=output, 0=input)
  constant REG_T1CL : natural := 16#4#;  -- Timer 1 Counter Low byte (read)
  constant REG_T1CH : natural := 16#5#;  -- Timer 1 Counter High byte (read/write starts timer)
  constant REG_T1LL : natural := 16#6#;  -- Timer 1 Latch Low byte (latches counter)
  constant REG_T1LH : natural := 16#7#;  -- Timer 1 Latch High byte (latches counter)
  constant REG_T2CL : natural := 16#8#;  -- Timer 2 Counter Low byte (read)
  constant REG_T2CH : natural := 16#9#;  -- Timer 2 Counter High byte (read/write starts timer)
  constant REG_SR   : natural := 16#A#;  -- Shift Register (serial I/O)
  constant REG_ACR  : natural := 16#B#;  -- Auxiliary Control Register (timer modes, etc)
  constant REG_PCR  : natural := 16#C#;  -- Peripheral Control Register (edge detection control)
  constant REG_IFR  : natural := 16#D#;  -- Interrupt Flag Register (interrupt status)
  constant REG_IER  : natural := 16#E#;  -- Interrupt Enable Register (interrupt enables)
  constant REG_ORA2 : natural := 16#F#;  -- Output Register A (alternate address, no handshake)

  -- IRQ flag bit positions in Interrupt Flag Register (IFR) and Interrupt Enable Register (IER)
  constant IRQ_CA2 : natural := 0;  -- Port A Handshake CA2 interrupt
  constant IRQ_CA1 : natural := 1;  -- Port A Handshake CA1 interrupt
  constant IRQ_SR  : natural := 2;  -- Shift Register interrupt (serial transfer complete)
  constant IRQ_CB2 : natural := 3;  -- Port B Handshake CB2 interrupt
  constant IRQ_CB1 : natural := 4;  -- Port B Handshake CB1 interrupt
  constant IRQ_T2  : natural := 5;  -- Timer 2 interrupt (time-out)
  constant IRQ_T1  : natural := 6;  -- Timer 1 interrupt (time-out)

  -- Port I/O registers: Store CPU writes and provide read values
  signal orb       : data_t := (others => '0');      -- Output Register B (port B output data)
  signal ora       : data_t := (others => '0');      -- Output Register A (port A output data)
  signal ddrb      : data_t := (others => '0');      -- Data Direction Register B (1=output)
  signal ddra      : data_t := (others => '0');      -- Data Direction Register A (1=output)

  -- Timer 1: 16-bit interval timer with automatic reload capability
  signal t1_counter : unsigned(15 downto 0) := (others => '0');  -- Current count value
  signal t1_latch   : unsigned(15 downto 0) := (others => '0');  -- Reload value for auto-mode
  signal t1_running : std_logic := '0';                          -- Timer active flag

  -- Timer 2: Single-shot 16-bit timer
  signal t2_counter : unsigned(15 downto 0) := (others => '0');  -- Current count value
  signal t2_latch_lo : data_t := (others => '0');                -- Latched low byte of reload
  signal t2_running : std_logic := '0';                          -- Timer active flag

  -- Control and status registers
  signal sr        : data_t := (others => '0');      -- Shift Register (serial I/O data)
  signal acr       : data_t := (others => '0');      -- Auxiliary Control Register (timer modes)
  signal pcr       : data_t := (others => '0');      -- Peripheral Control Register (handshake modes)
  signal ifr_flags : std_logic_vector(6 downto 0) := (others => '0');  -- Interrupt flags
  signal ier       : std_logic_vector(6 downto 0) := (others => '0');  -- Interrupt enables
  signal dout_reg  : data_t := (others => '0');      -- Data output register
  signal irq_active : std_logic := '0';              -- Final IRQ output to CPU

  -- Helper function: Multiplex port output based on data direction register
  -- For each bit: if DDR bit=1 use output register, if DDR bit=0 use input register
  -- This implements tri-state logic where DDR controls output driver enable
  function mixed_port(out_reg : data_t; ddr : data_t; in_reg : data_t) return data_t is
  begin
    -- Bit-wise: (output AND direction) OR (input AND NOT direction)
    return (out_reg and ddr) or (in_reg and not ddr);
  end function;

  -- Helper function: Format Interrupt Flag Register for CPU read
  -- Bit 7 is set if any enabled interrupt is pending
  -- Bits 6-0 contain the individual interrupt flags
  function ifr_read(flags : std_logic_vector(6 downto 0); enables : std_logic_vector(6 downto 0))
    return data_t is
    variable result : data_t;
  begin
    -- Bits 6-0 contain the flags as-is
    result := '0' & flags;
    -- Bit 7 is set if any flag AND its corresponding enable is true
    if (flags and enables) /= "0000000" then
      result(7) := '1';
    end if;
    return result;
  end function;

begin
  -- Combinational output assignments
  dout <= dout_reg;                                    -- Register read data to output
  irq <= irq_active;                                   -- IRQ status to CPU
  irq_active <= '1' when (ifr_flags and ier) /= "0000000" else '0';  -- IRQ triggered if any flag is enabled
  porta_out <= ora and ddra;                           -- Port A: only drive when DDR=1
  portb_out <= orb and ddrb;                           -- Port B: only drive when DDR=1

  -- Main control process: Handles timer decrements and register read/write operations
  process(clk)
    variable reg_index : natural;                    -- Decoded register address
    variable next_ifr  : std_logic_vector(6 downto 0);  -- Next interrupt flag value
    variable next_ier  : std_logic_vector(6 downto 0);  -- Next interrupt enable value
  begin
    if rising_edge(clk) then
      -- Reset: Clear all registers and state on active-low reset
      if reset_n = '0' then
        orb <= (others => '0');
        ora <= (others => '0');
        ddrb <= (others => '0');
        ddra <= (others => '0');
        t1_counter <= (others => '0');
        t1_latch <= (others => '0');
        t1_running <= '0';
        t2_counter <= (others => '0');
        t2_latch_lo <= (others => '0');
        t2_running <= '0';
        sr <= (others => '0');
        acr <= (others => '0');
        pcr <= (others => '0');
        ifr_flags <= (others => '0');
        ier <= (others => '0');
        dout_reg <= (others => '0');
      else
        -- Prepare for potential flag updates during register access
        next_ifr := ifr_flags;
        next_ier := ier;

        -- Timer 1: 16-bit interval timer with automatic reload
        -- Decrements every clock cycle when running
        if t1_running = '1' then
          if t1_counter = 0 then
            -- Timer expired: Set interrupt flag
            next_ifr(IRQ_T1) := '1';
            -- Check ACR bit 6 for continuous mode (auto-reload)
            if acr(6) = '1' then
              t1_counter <= t1_latch;  -- Reload from latch and continue
            else
              t1_running <= '0';       -- Single-shot: stop timer
            end if;
          else
            t1_counter <= t1_counter - 1;  -- Decrement counter
          end if;
        end if;

        -- Timer 2: Single-shot 16-bit timer (no auto-reload)
        -- Decrements every clock cycle when running and pulse mode disabled
        if t2_running = '1' and acr(5) = '0' then
          if t2_counter = 0 then
            -- Timer expired: Set interrupt flag and stop
            next_ifr(IRQ_T2) := '1';
            t2_running <= '0';
          else
            t2_counter <= t2_counter - 1;  -- Decrement counter
          end if;
        end if;

        -- Register access: Read or write operations when chip selected
        if cs = '1' then
          -- Extract register address from lower 4 address bits
          reg_index := to_integer(unsigned(addr(3 downto 0)));

          -- Write operations: CPU is storing data to a register
          if we = '1' then
            -- Write case: CPU is writing data to the selected register
            case reg_index is
              -- Port B Output Register: Store output data and clear handshake flags
              when REG_ORB =>
                orb <= din;                   -- Store CPU output data
                next_ifr(IRQ_CB1) := '0';    -- Clear CB1 interrupt on write
                next_ifr(IRQ_CB2) := '0';    -- Clear CB2 interrupt on write

              -- Port A Output Register: Store output data and clear handshake flags
              -- REG_ORA2 is alternate address (same function, no handshake clear)
              when REG_ORA | REG_ORA2 =>
                ora <= din;                   -- Store CPU output data
                next_ifr(IRQ_CA1) := '0';    -- Clear CA1 interrupt on write
                next_ifr(IRQ_CA2) := '0';    -- Clear CA2 interrupt on write

              -- Data Direction Register B: Configure port B pins as inputs (0) or outputs (1)
              when REG_DDRB =>
                ddrb <= din;                  -- 1=output driver enabled, 0=input mode

              -- Data Direction Register A: Configure port A pins as inputs (0) or outputs (1)
              when REG_DDRA =>
                ddra <= din;                  -- 1=output driver enabled, 0=input mode

              -- Timer 1 Latch Low Byte / Counter Low Byte (write to counter also starts timer)
              when REG_T1CL | REG_T1LL =>
                t1_latch(7 downto 0) <= unsigned(din);  -- Store low byte of reload value

              -- Timer 1 Counter/Latch High Byte (write here starts the timer)
              when REG_T1CH =>
                t1_latch(15 downto 8) <= unsigned(din);                           -- Store high byte of latch
                t1_counter <= unsigned(din) & t1_latch(7 downto 0);               -- Load counter from latch+new high byte
                t1_running <= '1';                                               -- Start timer
                next_ifr(IRQ_T1) := '0';                                         -- Clear any pending T1 interrupt

              -- Timer 1 Latch High Byte (write doesn't start timer, only updates reload value)
              when REG_T1LH =>
                t1_latch(15 downto 8) <= unsigned(din);  -- Store high byte of reload value only

              -- Timer 2 Counter/Latch Low Byte (latched to low byte, counter starts on high byte write)
              when REG_T2CL =>
                t2_latch_lo <= din;           -- Latch low byte (counter starts on T2CH write)

              -- Timer 2 Counter/Latch High Byte (write here loads counter and starts timer)
              when REG_T2CH =>
                t2_counter <= unsigned(din) & unsigned(t2_latch_lo);             -- Load 16-bit counter from high byte + latched low byte
                t2_running <= '1';                                               -- Start Timer 2
                next_ifr(IRQ_T2) := '0';                                         -- Clear any pending T2 interrupt

              -- Shift Register: Store serial I/O data
              when REG_SR =>
                sr <= din;                    -- Store shift register data

              -- Auxiliary Control Register: Configure timer modes and shift register
              when REG_ACR =>
                acr <= din;                   -- Bit 6: Timer 1 mode (0=one-shot, 1=free-run)
                                              -- Bit 5: Timer 2 mode (0=interval, 1=pulse)

              -- Peripheral Control Register: Configure handshake pin behavior
              when REG_PCR =>
                pcr <= din;                   -- Configures CA1/CA2 and CB1/CB2 edge detection

              -- Interrupt Flag Register: Write to clear interrupt flags
              when REG_IFR =>
                next_ifr := next_ifr and not din(6 downto 0);  -- Clear flags where CPU wrote 1

              -- Interrupt Enable Register: Enable or disable interrupt sources
              when REG_IER =>
                if din(7) = '1' then
                  next_ier := next_ier or din(6 downto 0);     -- Bit 7=1: Set enables for bits in din
                else
                  next_ier := next_ier and not din(6 downto 0);  -- Bit 7=0: Clear enables for bits in din
                end if;

              when others =>
                null;  -- Undefined registers: no action
            end case;
          -- Read operations: CPU is reading data from a register
          else
            -- Read case: CPU is reading data from the selected register
            case reg_index is
              -- Port B: Return mix of output and input data based on direction bits
              when REG_ORB =>
                dout_reg <= mixed_port(orb, ddrb, portb_in);  -- Output where DDR=1, input where DDR=0
                next_ifr(IRQ_CB1) := '0';                     -- Clear CB1 interrupt on read
                next_ifr(IRQ_CB2) := '0';                     -- Clear CB2 interrupt on read

              -- Port A: Return mix of output and input data based on direction bits
              -- REG_ORA2 is alternate address (same function)
              when REG_ORA | REG_ORA2 =>
                dout_reg <= mixed_port(ora, ddra, porta_in);  -- Output where DDR=1, input where DDR=0
                next_ifr(IRQ_CA1) := '0';                     -- Clear CA1 interrupt on read
                next_ifr(IRQ_CA2) := '0';                     -- Clear CA2 interrupt on read

              -- Data Direction Register B: Return the DDR configuration
              when REG_DDRB =>
                dout_reg <= ddrb;                              -- 1=output driver, 0=input

              -- Data Direction Register A: Return the DDR configuration
              when REG_DDRA =>
                dout_reg <= ddra;                              -- 1=output driver, 0=input

              -- Timer 1 Counter Low Byte: Return current count (and clear T1 interrupt)
              when REG_T1CL =>
                dout_reg <= std_logic_vector(t1_counter(7 downto 0));
                next_ifr(IRQ_T1) := '0';                       -- Clear T1 interrupt flag on read

              -- Timer 1 Counter High Byte: Return upper 8 bits of counter
              when REG_T1CH =>
                dout_reg <= std_logic_vector(t1_counter(15 downto 8));

              -- Timer 1 Latch Low Byte: Return reload value low byte
              when REG_T1LL =>
                dout_reg <= std_logic_vector(t1_latch(7 downto 0));

              -- Timer 1 Latch High Byte: Return reload value high byte
              when REG_T1LH =>
                dout_reg <= std_logic_vector(t1_latch(15 downto 8));

              -- Timer 2 Counter Low Byte: Return current count (and clear T2 interrupt)
              when REG_T2CL =>
                dout_reg <= std_logic_vector(t2_counter(7 downto 0));
                next_ifr(IRQ_T2) := '0';                       -- Clear T2 interrupt flag on read

              -- Timer 2 Counter High Byte: Return upper 8 bits of counter
              when REG_T2CH =>
                dout_reg <= std_logic_vector(t2_counter(15 downto 8));

              -- Shift Register: Return serial I/O data
              when REG_SR =>
                dout_reg <= sr;

              -- Auxiliary Control Register: Return timer mode and SR configuration
              when REG_ACR =>
                dout_reg <= acr;

              -- Peripheral Control Register: Return handshake control settings
              when REG_PCR =>
                dout_reg <= pcr;

              -- Interrupt Flag Register: Return formatted flags with interrupt pending bit
              when REG_IFR =>
                dout_reg <= ifr_read(next_ifr, next_ier);

              -- Interrupt Enable Register: Return enables with enable bit set
              when REG_IER =>
                dout_reg <= '1' & next_ier;                    -- Bit 7 always 1 on read

              -- Undefined registers: Return all 1s
              when others =>
                dout_reg <= x"FF";
            end case;
          end if;
        else
          -- Chip not selected: Output zeros (tri-state)
          dout_reg <= (others => '0');
        end if;

        -- Latch the updated flag and enable values for next cycle
        ifr_flags <= next_ifr;
        ier <= next_ier;
      end if;
    end if;
  end process;
end architecture;
