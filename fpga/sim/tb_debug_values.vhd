library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_debug_values is
end entity;

architecture sim of tb_debug_values is
begin
  process
    variable test_val : unsigned(15 downto 0);
    variable base_val : unsigned(15 downto 0);
    variable last_val : unsigned(15 downto 0);
  begin
    wait for 1 ns;

    test_val := x"8840";
    base_val := ADDR_VIC_BLIT_BASE;
    last_val := ADDR_VIC_BLIT_LAST;

    report "test_val = " & to_hstring(test_val) & " (" & integer'image(to_integer(test_val)) & ")" severity note;
    report "base_val = " & to_hstring(base_val) & " (" & integer'image(to_integer(base_val)) & ")" severity note;
    report "last_val = " & to_hstring(last_val) & " (" & integer'image(to_integer(last_val)) & ")" severity note;

    report "test_val >= base_val? " & boolean'image(test_val >= base_val) severity note;
    report "test_val <= last_val? " & boolean'image(test_val <= last_val) severity note;

    wait;
  end process;
end architecture;
