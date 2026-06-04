-- Test-Mode CPU Controller: Placeholder 6502-compatible bus master for testing
-- This is NOT a real 6502 - instead, it's a state machine that replays pre-programmed
-- memory access sequences from ROM. Used for automated testing of the SBC without a real CPU.
--
-- This controller interprets a simple test program format:
--   0x01 = Write command: next 3 bytes are (addr_lo, addr_hi, data)
--   0x02 = Read command: next 3 bytes are (addr_lo, addr_hi, expected_data)
--   0x00 = Halt: end of test program
--
-- The state machine strictly controls timing with explicit wait states to ensure
-- proper bus synchronization with the rest of the system.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity cpu6502_slot is
  port (
    clk      : in  std_logic;          -- System clock
    reset_n  : in  std_logic;          -- Active-low synchronous reset
    irq_n    : in  std_logic;          -- Interrupt input (not used in this version)
    data_in  : in  data_t;             -- Data from memory/peripherals
    addr     : out addr_t;             -- Address bus to memory/peripherals
    data_out : out data_t;             -- Data output to memory/peripherals
    we       : out std_logic;          -- Write Enable: 1=write, 0=read
    dbg_read_data  : out data_t;       -- Debug output: data read from memory
    dbg_read_valid : out std_logic     -- Debug output: valid read strobe
  );
end entity;

architecture placeholder of cpu6502_slot is
  -- State machine enumeration: Each state controls one step of CPU operation
  -- Multi-step sequences (SET -> WAIT -> CAPTURE) allow synchronization with external memory
  type state_t is (
    -- Initialization: Read reset vector from 0xFFFC-0xFFFD and jump to start address
    SET_RESET_LO,          -- Set address to 0xFFFC to read reset vector low byte
    WAIT_RESET_LO,         -- Wait for memory to respond with data
    CAPTURE_RESET_LO,      -- Latch the low byte, advance to 0xFFFD for high byte
    WAIT_RESET_HI,         -- Wait for memory to respond with high byte
    CAPTURE_RESET_HI,      -- Latch high byte and form 16-bit program counter

    -- Main instruction fetch loop: Read opcode from ROM/RAM at current PC
    FETCH_OPCODE_SET,      -- Set address to current PC location
    FETCH_OPCODE_WAIT,     -- Wait for instruction fetch from memory
    FETCH_OPCODE_CAPTURE,  -- Latch opcode and dispatch to handler based on opcode value

    -- Write operation: Execute "write" test command (opcode 0x01)
    -- Fetch 3 bytes from test program: addr_lo, addr_hi, data
    FETCH_WR_LO_SET,       -- Fetch write address low byte
    FETCH_WR_LO_WAIT,      -- Wait for data
    FETCH_WR_LO_CAPTURE,   -- Latch, advance PC to next byte
    FETCH_WR_HI_SET,       -- Fetch write address high byte
    FETCH_WR_HI_WAIT,      -- Wait for data
    FETCH_WR_HI_CAPTURE,   -- Latch, advance PC to next byte
    FETCH_WR_DATA_SET,     -- Fetch data byte to write
    FETCH_WR_DATA_WAIT,    -- Wait for data
    FETCH_WR_DATA_CAPTURE, -- Latch data, advance PC, go to write phase
    WRITE_ASSERT,          -- Assert write signal on system bus for one cycle

    -- Read operation: Execute "read" test command (opcode 0x02)
    -- Fetch 3 bytes from test program: addr_lo, addr_hi, expected_data
    FETCH_RD_LO_SET,       -- Fetch read address low byte
    FETCH_RD_LO_WAIT,      -- Wait for data
    FETCH_RD_LO_CAPTURE,   -- Latch, advance PC to next byte
    FETCH_RD_HI_SET,       -- Fetch read address high byte
    FETCH_RD_HI_WAIT,      -- Wait for data
    FETCH_RD_HI_CAPTURE,   -- Latch, advance PC to next byte
    FETCH_RD_EXPECT_SET,   -- Fetch expected data value (for verification)
    FETCH_RD_EXPECT_WAIT,  -- Wait for data
    FETCH_RD_EXPECT_CAPTURE,  -- Latch expected value, advance PC, go to read phase
    READ_SET,              -- Set address for read operation
    READ_WAIT,             -- Wait for memory to return data
    READ_CAPTURE,          -- Latch read data and strobe read_valid signal

    -- Program termination
    HALT                   -- Halt state machine (test complete or invalid opcode)
  );

  -- State machine register and working storage
  signal state        : state_t := SET_RESET_LO;            -- Current execution state
  signal reset_vec_lo : data_t := (others => '0');          -- Latched reset vector low byte
  signal pc           : unsigned(15 downto 0) := (others => '0');  -- Program counter (16-bit)
  signal wr_addr_lo   : data_t := (others => '0');          -- Latched write address low byte
  signal wr_addr_hi   : data_t := (others => '0');          -- Latched write address high byte
  signal wr_data      : data_t := (others => '0');          -- Latched data to write
  signal rd_addr_lo   : data_t := (others => '0');          -- Latched read address low byte
  signal rd_addr_hi   : data_t := (others => '0');          -- Latched read address high byte
  signal rd_expect    : data_t := (others => '0');          -- Latched expected read value
  signal addr_reg     : addr_t := x"FFFC";                  -- Current address bus output
  signal data_out_reg : data_t := (others => '0');          -- Current data bus output
  signal we_reg       : std_logic := '0';                   -- Current write enable signal
  signal read_data_reg : data_t := (others => '0');         -- Latched read data (for debug output)
  signal read_valid_reg : std_logic := '0';                 -- Read valid strobe

begin
  -- Output assignments: Drive external bus signals from latches
  addr <= addr_reg;                  -- Address bus
  data_out <= data_out_reg;          -- Data output bus
  we <= we_reg;                      -- Write enable signal
  dbg_read_data <= read_data_reg;    -- Debug: Last data read from memory
  dbg_read_valid <= read_valid_reg;  -- Debug: Strobe for valid read data

  -- Main state machine process: Implements CPU-like instruction execution
  -- Each state controls bus signals for one clock cycle, implementing standard
  -- memory read/write sequences with proper synchronization timing.
  process(clk)
  begin
    if rising_edge(clk) then
      -- Reset: Initialize state machine and program counter to reset vector
      if reset_n = '0' then
        addr_reg <= x"FFFC";           -- Point to reset vector address
        state <= SET_RESET_LO;         -- Begin reset sequence
        reset_vec_lo <= (others => '0');
        pc <= (others => '0');         -- Clear program counter
        wr_addr_lo <= (others => '0');
        wr_addr_hi <= (others => '0');
        wr_data <= (others => '0');
        rd_addr_lo <= (others => '0');
        rd_addr_hi <= (others => '0');
        rd_expect <= (others => '0');
        read_data_reg <= (others => '0');
        read_valid_reg <= '0';

      -- Normal operation: Execute instruction sequence based on state
      else
        case state is
          -- Reset Vector Fetch Sequence: Read 16-bit reset vector from ROM
          -- The 6502 reset vector is at 0xFFFC-0xFFFD (little-endian)
          when SET_RESET_LO =>
            addr_reg <= x"FFFC";       -- Set address to reset vector low byte location
            state <= WAIT_RESET_LO;    -- Advance to next state after bus setup

          when WAIT_RESET_LO =>
            addr_reg <= x"FFFC";       -- Hold address for one more cycle (setup time for ROM)
            state <= CAPTURE_RESET_LO; -- Ready to capture on next cycle

          when CAPTURE_RESET_LO =>
            reset_vec_lo <= data_in;   -- Latch the low byte of reset vector
            addr_reg <= x"FFFD";       -- Switch address to high byte location
            state <= WAIT_RESET_HI;    -- Wait for memory to respond with high byte

          when WAIT_RESET_HI =>
            addr_reg <= x"FFFD";       -- Hold address for ROM setup time
            state <= CAPTURE_RESET_HI; -- Ready to capture on next cycle

          when CAPTURE_RESET_HI =>
            -- Form 16-bit program counter from reset vector (little-endian)
            pc <= unsigned(data_in & reset_vec_lo);  -- High byte in upper 8 bits
            addr_reg <= data_in & reset_vec_lo;     -- Prefetch first instruction at start address
            state <= FETCH_OPCODE_SET;

          -- Instruction Fetch Sequence: Read opcode from program memory
          -- Opcode format:
          --   0x01 = Write command (followed by addr_lo, addr_hi, data)
          --   0x02 = Read command (followed by addr_lo, addr_hi, expected_data)
          --   0x00 = Halt execution
          when FETCH_OPCODE_SET =>
            addr_reg <= std_logic_vector(pc);  -- Set address to current PC
            state <= FETCH_OPCODE_WAIT;        -- Wait for ROM data

          when FETCH_OPCODE_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup time
            state <= FETCH_OPCODE_CAPTURE;     -- Ready to capture opcode

          when FETCH_OPCODE_CAPTURE =>
            pc <= pc + 1;                      -- Advance program counter for next fetch
            -- Dispatch based on opcode value
            if data_in = x"01" then
              state <= FETCH_WR_LO_SET;        -- Write command: fetch address low byte
            elsif data_in = x"02" then
              state <= FETCH_RD_LO_SET;        -- Read command: fetch address low byte
            elsif data_in = x"00" then
              state <= HALT;                   -- Halt code: end of test
            else
              state <= HALT;                   -- Unknown opcode: halt with error
            end if;

          -- Write Operation: Execute "write to memory" command
          -- Fetch three parameter bytes: target address (16-bit little-endian) and data byte
          when FETCH_WR_LO_SET =>
            addr_reg <= std_logic_vector(pc);  -- Point to write address low byte in program
            state <= FETCH_WR_LO_WAIT;

          when FETCH_WR_LO_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup
            state <= FETCH_WR_LO_CAPTURE;

          when FETCH_WR_LO_CAPTURE =>
            wr_addr_lo <= data_in;             -- Latch low byte of target address
            pc <= pc + 1;                      -- Advance to next program byte
            state <= FETCH_WR_HI_SET;

          when FETCH_WR_HI_SET =>
            addr_reg <= std_logic_vector(pc);  -- Point to write address high byte
            state <= FETCH_WR_HI_WAIT;

          when FETCH_WR_HI_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup
            state <= FETCH_WR_HI_CAPTURE;

          when FETCH_WR_HI_CAPTURE =>
            wr_addr_hi <= data_in;             -- Latch high byte of target address
            pc <= pc + 1;                      -- Advance to data byte
            state <= FETCH_WR_DATA_SET;

          when FETCH_WR_DATA_SET =>
            addr_reg <= std_logic_vector(pc);  -- Point to data byte in program
            state <= FETCH_WR_DATA_WAIT;

          when FETCH_WR_DATA_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup
            state <= FETCH_WR_DATA_CAPTURE;

          when FETCH_WR_DATA_CAPTURE =>
            wr_data <= data_in;                -- Latch data byte to write
            pc <= pc + 1;                      -- Advance program counter past this test
            state <= WRITE_ASSERT;             -- Execute the write operation next

          when WRITE_ASSERT =>
            -- Drive address and data buses and assert write signal for one cycle
            addr_reg <= wr_addr_hi & wr_addr_lo;  -- Address to target location
            data_out_reg <= wr_data;                -- Data to write
            we_reg <= '1';                          -- Assert write enable signal
            state <= FETCH_OPCODE_SET;              -- Back to instruction fetch after write

          -- Read Operation: Execute "read from memory" command
          -- Fetch three parameter bytes: source address (16-bit little-endian) and expected data byte
          -- The expected value is captured for test verification (real 6502 would just read)
          when FETCH_RD_LO_SET =>
            addr_reg <= std_logic_vector(pc);  -- Point to read address low byte in program
            state <= FETCH_RD_LO_WAIT;

          when FETCH_RD_LO_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup
            state <= FETCH_RD_LO_CAPTURE;

          when FETCH_RD_LO_CAPTURE =>
            rd_addr_lo <= data_in;             -- Latch low byte of source address
            pc <= pc + 1;                      -- Advance to next program byte
            state <= FETCH_RD_HI_SET;

          when FETCH_RD_HI_SET =>
            addr_reg <= std_logic_vector(pc);  -- Point to read address high byte
            state <= FETCH_RD_HI_WAIT;

          when FETCH_RD_HI_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup
            state <= FETCH_RD_HI_CAPTURE;

          when FETCH_RD_HI_CAPTURE =>
            rd_addr_hi <= data_in;             -- Latch high byte of source address
            pc <= pc + 1;                      -- Advance to expected data byte
            state <= FETCH_RD_EXPECT_SET;

          when FETCH_RD_EXPECT_SET =>
            addr_reg <= std_logic_vector(pc);  -- Point to expected data value in program
            state <= FETCH_RD_EXPECT_WAIT;

          when FETCH_RD_EXPECT_WAIT =>
            addr_reg <= std_logic_vector(pc);  -- Hold address for ROM setup
            state <= FETCH_RD_EXPECT_CAPTURE;

          when FETCH_RD_EXPECT_CAPTURE =>
            rd_expect <= data_in;              -- Latch expected value (for test verification)
            pc <= pc + 1;                      -- Advance program counter past this test
            state <= READ_SET;                 -- Execute the read operation next

          when READ_SET =>
            -- Set address bus to source location and initiate read
            addr_reg <= rd_addr_hi & rd_addr_lo;  -- Address of memory to read
            state <= READ_WAIT;                    -- Wait for memory response

          when READ_WAIT =>
            -- Hold address for memory access time
            addr_reg <= rd_addr_hi & rd_addr_lo;  -- Keep address stable
            state <= READ_CAPTURE;                 -- Ready to capture data on next cycle

          when READ_CAPTURE =>
            -- Capture read data and return to instruction fetch
            read_data_reg <= data_in;              -- Latch data from memory
            read_valid_reg <= '1';                 -- Strobe to indicate valid read data
            state <= FETCH_OPCODE_SET;             -- Back to instruction fetch

          -- Halt: Execution complete (end of test sequence or error)
          when HALT =>
            addr_reg <= addr_reg;              -- Hold current address (idle)
        end case;
      end if;

      -- Clear write signals when not in WRITE_ASSERT state (ensures clean edges)
      if state /= WRITE_ASSERT then
        data_out_reg <= (others => '0');   -- Clear data bus
        we_reg <= '0';                     -- Disable write
      end if;

      -- Clear read strobe after READ_CAPTURE state (pulse signal)
      if state /= READ_CAPTURE then
        read_valid_reg <= '0';             -- Clear valid signal for next cycle
      end if;
    end if;
  end process;
end architecture;
