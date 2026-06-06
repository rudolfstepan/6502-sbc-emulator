-- Synchronous RAM: Configurable single-port RAM with optional asynchronous reads
-- Used for system main memory (SRAM). Supports both synchronous and asynchronous read modes.
-- This module implements a block RAM with optional asynchronous output for faster read access.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sync_ram is
  generic (
    ADDR_WIDTH : positive := 15;   -- Address width in bits (2^ADDR_WIDTH = capacity in bytes)
    ASYNC_READ : boolean := false   -- When true: asynchronous reads, when false: synchronous reads
  );
  port (
    clk  : in  std_logic;           -- System clock input
    we   : in  std_logic;           -- Write Enable: 1 = write, 0 = read
    addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);  -- Address bus (selects memory location)
    din  : in  data_t;              -- Data input: data to write to memory
    dout : out data_t               -- Data output: data read from memory
  );
end entity;

architecture rtl of sync_ram is
  -- Array type to represent RAM as indexed memory (array of 8-bit words)
  type ram_t is array (0 to (2 ** ADDR_WIDTH) - 1) of data_t;

  -- RAM signal initialized to all zeros (0x00)
  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is "distributed";

begin
  -- Synchronous memory write and synchronous read (when ASYNC_READ=false)
  sync_write_g : if not ASYNC_READ generate
    process(clk)
    begin
      if rising_edge(clk) then
        -- Write operation: When we='1', store input data to addressed location
        if we = '1' then
          ram(to_integer(unsigned(addr))) <= din;
        end if;

        -- Synchronous read path: Update output register on every clock edge
        -- Includes write-through behavior: if we='1', dout gets the new data value
        dout <= ram(to_integer(unsigned(addr)));
      end if;
    end process;
  end generate;

  -- Synchronous memory write only (when ASYNC_READ=true)
  async_write_g : if ASYNC_READ generate
    process(clk)
    begin
      if rising_edge(clk) then
        -- Write operation only (async read provides read path)
        if we = '1' then
          ram(to_integer(unsigned(addr))) <= din;
        end if;
      end if;
    end process;
  end generate;

  -- Asynchronous read path (combinational logic, no clock delay)
  -- When ASYNC_READ=true, this logic provides the read path for faster access
  async_read_g : if ASYNC_READ generate
    process(addr, we, din, ram)
    begin
      -- Handle undefined address bits safely (simulation only)
      if is_x(addr) then
        dout <= (others => '0');
      -- During write operations: forward input data to output (write-through)
      elsif we = '1' then
        dout <= din;
      -- Read operations: immediately output data from addressed location
      else
        dout <= ram(to_integer(unsigned(addr)));
      end if;
    end process;
  end generate;
end architecture;
