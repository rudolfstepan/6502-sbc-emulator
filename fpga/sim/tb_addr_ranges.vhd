library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_addr_ranges is
end entity;

architecture sim of tb_addr_ranges is
  signal test_addr : addr_t := x"0000";

  function test_range(addr : addr_t; first_addr : unsigned; last_addr : unsigned) return boolean is
  begin
    if is_x(addr) then
      return false;
    end if;
    return unsigned(addr) >= first_addr and unsigned(addr) <= last_addr;
  end function;

begin
  process
  begin
    test_addr <= x"8840";
    wait for 1 ns;

    report "Testing address 0x8840 against known ranges:" severity note;
    report "  VIC_BLIT (8840-844F): " & boolean'image(test_range(test_addr, ADDR_VIC_BLIT_BASE, ADDR_VIC_BLIT_LAST)) severity note;
    report "  SOUND0 (8830-8839): " & boolean'image(test_range(test_addr, ADDR_SOUND0_BASE, ADDR_SOUND0_LAST)) severity note;
    report "  VIC_SPR (8850-888F): " & boolean'image(test_range(test_addr, ADDR_VIC_SPR_BASE, ADDR_VIC_SPR_LAST)) severity note;
    report "  VIC_TEXT (8000-87FF): " & boolean'image(test_range(test_addr, ADDR_VIC_TEXT_BASE, ADDR_VIC_TEXT_LAST)) severity note;

    wait;
  end process;
end architecture;
