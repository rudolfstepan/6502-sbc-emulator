-- Generic Register Stub: Placeholder peripheral with simple register read/write
-- Provides a basic register file interface for undefined or not-yet-implemented peripherals
-- Supports read and write operations, but does not perform any real device functions
-- IRQ output is permanently disabled (hardwired to '0')
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity reg_stub is
  generic (
    REG_COUNT : positive := 16      -- Number of 8-bit registers in this peripheral
  );
  port (
    clk       : in  std_logic;      -- System clock for synchronous operations
    reset_n   : in  std_logic;      -- Active-low reset (synchronous)
    cs        : in  std_logic;      -- Chip Select: 1 = device active, 0 = inactive
    we        : in  std_logic;      -- Write Enable: 1 = write, 0 = read operation
    addr      : in  addr_t;         -- Register address (lower bits select register)
    din       : in  data_t;         -- Data input: data to write to register
    dout      : out data_t;         -- Data output: data read from register
    irq       : out std_logic       -- Interrupt Request (not used, tied to ground)
  );
end entity;

architecture rtl of reg_stub is
  -- Array of registers (default size is 16 registers of 8 bits each)
  type regs_t is array (0 to REG_COUNT - 1) of data_t;
  signal regs : regs_t := (others => (others => '0'));  -- Initialize all registers to 0x00

begin
  -- Main register access process: handles reads and writes synchronously
  process(clk)
    variable index : natural;  -- Computed register index
  begin
    if rising_edge(clk) then
      -- Reset: Clear all registers and output on active-low reset
      if reset_n = '0' then
        regs <= (others => (others => '0'));  -- Clear all registers
        dout <= (others => '0');              -- Clear data output

      -- Normal operation: Chip select must be active for register access
      elsif cs = '1' then
        -- Compute register index from address (modulo operation wraps address to reg count)
        -- This allows partial address decoding at the bus level
        index := to_integer(unsigned(addr)) mod REG_COUNT;

        -- Write operation: Store input data to selected register
        if we = '1' then
          regs(index) <= din;
        end if;

        -- Read operation: Always output data from selected register
        -- In case of simultaneous read and write, the new data appears on output
        dout <= regs(index);

      -- Chip not selected: Output all zeros (tri-state simulation)
      else
        dout <= (others => '0');
      end if;
    end if;
  end process;

  -- Interrupt line: Permanently disabled (no interrupts from this stub)
  irq <= '0';

end architecture;

