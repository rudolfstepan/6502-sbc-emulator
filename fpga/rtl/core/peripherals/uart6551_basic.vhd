-- UART 6551: Serial communications interface controller
-- Provides asynchronous serial I/O (RS-232) for console and modem communication
-- Simplified model: focuses on basic transmit/receive with interrupt capability
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

entity uart6551 is
  port (
    clk          : in  std_logic;      -- System clock
    reset_n      : in  std_logic;      -- Active-low synchronous reset
    cs           : in  std_logic;      -- Chip Select: device active when high
    we           : in  std_logic;      -- Write Enable: 1=write, 0=read
    addr         : in  addr_t;         -- Register address (lower 2 bits select register)
    din          : in  data_t;         -- Data input for register writes
    dout         : out data_t;         -- Data output for register reads
    rx_data      : in  data_t;         -- External receiver: serial input data byte
    rx_valid     : in  std_logic;      -- External receiver: data valid signal
    tx_data      : out data_t;         -- External transmitter: serial output data byte
    tx_valid     : out std_logic;      -- External transmitter: request to transmit this byte
    irq          : out std_logic       -- Interrupt Request to CPU
  );
end entity;

architecture rtl of uart6551 is
  -- Register address map (lower 2 address bits)
  constant REG_DATA   : std_logic_vector(1 downto 0) := "00";  -- Data register (R/W)
  constant REG_STATUS : std_logic_vector(1 downto 0) := "01";  -- Status register (read-only)
  constant REG_CMD    : std_logic_vector(1 downto 0) := "10";  -- Command register (write-only)
  constant REG_CTRL   : std_logic_vector(1 downto 0) := "11";  -- Control register (write-only)

  -- Status register bit definitions
  constant ST_IRQ  : natural := 7;  -- Interrupt Request (1=interrupt pending)
  constant ST_DSR  : natural := 6;  -- Data Set Ready (not used)
  constant ST_DCD  : natural := 5;  -- Data Carrier Detect (not used)
  constant ST_TDRE : natural := 4;  -- Transmit Data Register Empty (1=ready for new data)
  constant ST_RDRF : natural := 3;  -- Receive Data Register Full (1=data available)
  constant ST_OVR  : natural := 2;  -- Overrun error (1=data lost)
  constant ST_FE   : natural := 1;  -- Framing error (not fully implemented)
  constant ST_PE   : natural := 0;  -- Parity error (not fully implemented)

  -- Internal registers for UART state
  signal rx_reg       : data_t := (others => '0');      -- Received data latch
  signal tx_reg       : data_t := (others => '0');      -- Transmit data register
  signal status_reg   : data_t := x"10";                -- Status flags (TDRE=1 at reset)
  signal cmd_reg      : data_t := (others => '0');      -- Command register settings
  signal ctrl_reg     : data_t := (others => '0');      -- Control register settings
  signal dout_reg     : data_t := (others => '0');      -- Data output register latch
  signal tx_valid_reg : std_logic := '0';               -- Transmit strobe signal
begin
  -- Output assignments: Connect internal latches to output ports
  dout <= dout_reg;                     -- Register read data
  tx_data <= tx_reg;                    -- Transmit data to external interface
  tx_valid <= tx_valid_reg;             -- Transmit strobe to external interface
  irq <= status_reg(ST_IRQ);            -- Interrupt to CPU

  -- Main UART control process: Handle RX, TX, and register access
  process(clk)
    variable next_status : data_t;  -- Next status register value
  begin
    if rising_edge(clk) then
      -- Clear transmit strobe every cycle (pulse signal)
      tx_valid_reg <= '0';

      -- Reset: Initialize all registers to known state
      if reset_n = '0' then
        rx_reg <= (others => '0');     -- Clear RX data buffer
        tx_reg <= (others => '0');     -- Clear TX data register
        status_reg <= x"10";           -- Status: TDRE=1 (transmitter ready)
        cmd_reg <= (others => '0');    -- Clear command settings
        ctrl_reg <= (others => '0');   -- Clear control settings
        dout_reg <= (others => '0');   -- Clear output latch

      else
        -- Start each cycle with current status, mark transmitter ready
        next_status := status_reg;
        next_status(ST_TDRE) := '1';   -- Always mark transmitter ready (simplified model)

        -- Check for incoming serial data from external receiver
        if rx_valid = '1' then
          -- If receive buffer already has data, this is an overrun error
          if status_reg(ST_RDRF) = '1' then
            next_status(ST_OVR) := '1';  -- Set overrun error flag
          else
            -- Store new received byte in RX register
            rx_reg <= rx_data;
            next_status(ST_RDRF) := '1';  -- Set data-available flag
          end if;
        end if;

        -- Register access: Handle CPU reads and writes
        if cs = '1' then
          -- Write operations: CPU storing data to a register
          if we = '1' then
            case addr(1 downto 0) is
              -- Data Register Write: Queue byte for transmission
              when REG_DATA =>
                tx_reg <= din;               -- Store transmit data byte
                tx_valid_reg <= '1';         -- Signal external transmitter to send this byte
                next_status(ST_TDRE) := '1'; -- Mark transmitter ready

              -- Status Register Write: Clear status flags and reset device
              when REG_STATUS =>
                next_status := x"10";        -- Reset status to TDRE only
                cmd_reg <= (others => '0');  -- Clear command register
                ctrl_reg <= (others => '0'); -- Clear control register

              -- Command Register Write: Configure interrupt behavior
              when REG_CMD =>
                cmd_reg <= din;              -- Store command register (Bit 0: RX interrupt enable)

              -- Control Register Write: Configure serial parameters (not fully used)
              when REG_CTRL =>
                ctrl_reg <= din;             -- Store control settings

              when others =>
                null;  -- Undefined registers: no action
            end case;

          -- Read operations: CPU retrieving data from a register
          else
            case addr(1 downto 0) is
              -- Data Register Read: Return received byte and clear flag
              when REG_DATA =>
                dout_reg <= rx_reg;         -- Output received data byte
                next_status(ST_RDRF) := '0'; -- Clear data-available flag after read

              -- Status Register Read: Return current status
              when REG_STATUS =>
                dout_reg <= next_status;    -- Output status with current flags

              -- Command Register Read: Return command settings
              when REG_CMD =>
                dout_reg <= cmd_reg;        -- Output command register

              -- Control Register Read: Return control settings
              when REG_CTRL =>
                dout_reg <= ctrl_reg;       -- Output control register

              -- Undefined registers: Return 0xFF
              when others =>
                dout_reg <= x"FF";
            end case;
          end if;
        else
          -- Chip not selected: Output zeros (tri-state)
          dout_reg <= (others => '0');
        end if;

        -- Compute interrupt signal: IRQ = data-available AND interrupt-enabled
        if next_status(ST_RDRF) = '1' and cmd_reg(0) = '1' then
          next_status(ST_IRQ) := '1';       -- Interrupt pending
        else
          next_status(ST_IRQ) := '0';       -- No interrupt
        end if;

        -- Latch updated status for next cycle
        status_reg <= next_status;
      end if;
    end if;
  end process;
end architecture;

