-- Read-Only Memory (ROM): Firmware and system boot code storage
-- Loads binary image from file at synthesis time and provides read-only access
-- Used for kernel.rom and msbasic.rom in the system. Supports optional asynchronous reads.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;  -- For std_logic I/O operations

library std;
use std.textio.all;  -- For file I/O operations

use work.sbc_pkg.all;

entity rom is
  generic (
    ADDR_WIDTH : positive := 14;    -- Address width (2^ADDR_WIDTH = capacity in bytes)
    INIT_FILE  : string := "";      -- Path to hex file containing ROM image data
    ASYNC_READ : boolean := false    -- true = asynchronous reads, false = synchronous reads
  );
  port (
    clk  : in  std_logic;           -- System clock input (only used for synchronous reads)
    addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);  -- Address bus for ROM access
    dout : out data_t               -- Data output: byte read from ROM
  );
end entity;

architecture rtl of rom is
  -- ROM array type: array of 8-bit words
  type rom_t is array (0 to (2 ** ADDR_WIDTH) - 1) of data_t;

  -- File loading function: Reads hex image file at compile time
  impure function load_image(file_name : string) return rom_t is
    -- Initialize ROM with NOP (0xEA) instructions as default
    variable mem    : rom_t := (others => x"EA");
    variable status : file_open_status;
    file rom_file   : text;
    variable row    : line;
    variable offset : std_logic_vector(15 downto 0);  -- Address offset from file
    variable value  : data_t;                         -- Data value from file
    variable index  : natural;                        -- Array index
  begin
    -- If no init file specified, return ROM filled with NOPs
    if file_name'length = 0 then
      return mem;
    end if;

    -- Attempt to open the ROM hex file (format: offset value, hex format)
    file_open(status, rom_file, file_name, read_mode);
    assert status = open_ok
      report "could not open ROM init file: " & file_name
      severity failure;

    -- Read file line by line until end of file
    while not endfile(rom_file) loop
      -- Read one line from file
      readline(rom_file, row);

      -- Skip empty lines
      if row.all'length > 0 then
        -- Parse first hex value: address offset within ROM
        hread(row, offset);
        -- Parse second hex value: data byte to store
        hread(row, value);

        -- Convert address to array index
        index := to_integer(unsigned(offset));

        -- Store data in ROM array at computed index (with bounds checking)
        if index < mem'length then
          mem(index) := value;
        end if;
      end if;
    end loop;

    -- Close file and return loaded ROM image
    file_close(rom_file);
    return mem;
  end function;

  -- Load ROM image from file at synthesis time
  signal image : rom_t := load_image(INIT_FILE);
begin
  -- Synchronous read path (default): Output updates on clock edge
  -- Introduces one clock cycle latency but integrates with synchronous CPU timing
  sync_read_g : if not ASYNC_READ generate
    process(clk)
    begin
      if rising_edge(clk) then
        -- On each clock edge, latch the data from addressed ROM location to output
        dout <= image(to_integer(unsigned(addr)));
      end if;
    end process;
  end generate;

  -- Asynchronous read path (optional): Combinational logic for immediate access
  -- Provides zero-latency reads but may impact timing closure
  async_read_g : if ASYNC_READ generate
    process(addr, image)
    begin
      -- Handle undefined address bits in simulation
      if is_x(addr) then
        dout <= (others => '0');
      else
        -- Immediately output data from addressed ROM location
        dout <= image(to_integer(unsigned(addr)));
      end if;
    end process;
  end generate;
end architecture;
