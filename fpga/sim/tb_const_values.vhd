library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_const_values is
end entity;

architecture sim of tb_const_values is
begin
  process
  begin
    wait for 1 ns;
    report "ADDR_VIC_BLIT_BASE = " & to_hstring(ADDR_VIC_BLIT_BASE) severity note;
    report "ADDR_VIC_BLIT_LAST = " & to_hstring(ADDR_VIC_BLIT_LAST) severity note;
    report "ADDR_SOUND0_LAST = " & to_hstring(ADDR_SOUND0_LAST) severity note;

    report "Test: 0x8840 >= 0x8840? " & boolean'image(x"8840" >= ADDR_VIC_BLIT_BASE) severity note;
    report "Test: 0x8840 <= 0x844F? " & boolean'image(x"8840" <= ADDR_VIC_BLIT_LAST) severity note;

    wait;
  end process;
end architecture;
