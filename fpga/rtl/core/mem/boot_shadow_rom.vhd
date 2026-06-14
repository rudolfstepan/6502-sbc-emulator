-- Boot-loaded shadow ROM.
--
-- During boot, an external loader writes the firmware image into this RAM.
-- After boot, the CPU reads it as ROM at $C000-$FFFF.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity boot_shadow_rom is
  generic (
    ADDR_WIDTH : positive := 14
  );
  port (
    clk       : in  std_logic;

    cpu_addr  : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    cpu_dout  : out data_t;

    load_we   : in  std_logic;
    load_addr : in  std_logic_vector(ADDR_WIDTH - 1 downto 0);
    load_data : in  data_t
  );
end entity;

architecture rtl of boot_shadow_rom is
  type ram_t is array (0 to (2 ** ADDR_WIDTH) - 1) of data_t;
  signal ram : ram_t := (others => x"EA");
  attribute ram_style : string;
  attribute ram_style of ram : signal is "block";
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if load_we = '1' then
        ram(to_integer(unsigned(load_addr))) <= load_data;
      end if;
      cpu_dout <= ram(to_integer(unsigned(cpu_addr)));
    end if;
  end process;
end architecture;
