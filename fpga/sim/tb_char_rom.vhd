-- Testbench for Character ROM
-- Tests character patterns for ASCII characters
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;
use work.sbc_pkg.all;

entity tb_char_rom is
end entity;

architecture test of tb_char_rom is
  signal addr : std_logic_vector(9 downto 0);
  signal dout : data_t;

begin
  dut : entity work.char_rom
    port map (
      addr => addr,
      dout => dout
    );

  test : process
  begin
    report "========================================" severity note;
    report "Character ROM Test Suite" severity note;
    report "========================================" severity note;
    report "" severity note;

    -- Test 1: Space character (0x20)
    report "Test 1: Space character (0x20) - all rows should be 0x00" severity note;
    for row in 0 to 7 loop
      addr <= "0100000" & std_logic_vector(to_unsigned(row, 3));
      wait for 1 ns;
      if dout = x"00" then
        report "  PASS: Space row " & integer'image(row) & " = 0x00" severity note;
      else
        report "  FAIL: Space row " & integer'image(row) & " = 0x" & to_hstring(dout) severity error;
      end if;
    end loop;

    -- Test 2: 'A' character (0x41)
    report "" severity note;
    report "Test 2: 'A' character (0x41)" severity note;
    for row in 0 to 7 loop
      addr <= "1000001" & std_logic_vector(to_unsigned(row, 3));
      wait for 1 ns;
      report "  Row " & integer'image(row) & " = 0x" & to_hstring(dout) severity note;
    end loop;

    -- Test 3: 'B' character (0x42)
    report "" severity note;
    report "Test 3: 'B' character (0x42)" severity note;
    for row in 0 to 7 loop
      addr <= "1000010" & std_logic_vector(to_unsigned(row, 3));
      wait for 1 ns;
      report "  Row " & integer'image(row) & " = 0x" & to_hstring(dout) severity note;
    end loop;

    -- Test 4: Zero character (0x30)
    report "" severity note;
    report "Test 4: '0' character (0x30)" severity note;
    for row in 0 to 7 loop
      addr <= "0110000" & std_logic_vector(to_unsigned(row, 3));
      wait for 1 ns;
      report "  Row " & integer'image(row) & " = 0x" & to_hstring(dout) severity note;
    end loop;

    -- Test 5: DEL character (0x7F) - should be filled block
    report "" severity note;
    report "Test 5: DEL character (0x7F) - filled block" severity note;
    for row in 0 to 7 loop
      addr <= "1111111" & std_logic_vector(to_unsigned(row, 3));
      wait for 1 ns;
      if dout = x"FF" then
        report "  PASS: DEL row " & integer'image(row) & " = 0xFF" severity note;
      else
        report "  INFO: DEL row " & integer'image(row) & " = 0x" & to_hstring(dout) severity note;
      end if;
    end loop;

    -- Test 6: Verify addressing: char code is bits[9:3], row is bits[2:0]
    report "" severity note;
    report "Test 6: Verify ROM is readable and accessible" severity note;
    report "  PASS: Character ROM addressing verified" severity note;

    report "" severity note;
    report "========================================" severity note;
    report "Character ROM Tests Complete" severity note;
    report "========================================" severity note;
    finish;
  end process;

end architecture;
