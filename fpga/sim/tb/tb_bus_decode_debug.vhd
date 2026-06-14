library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_bus_decode_debug is
end entity;

architecture sim of tb_bus_decode_debug is
  signal addr : addr_t := x"0000";
  signal sel  : device_sel_t;
begin
  dut : entity work.bus_decode
    port map (
      addr => addr,
      sel  => sel
    );

  process
  begin
    addr <= x"8840";
    wait for 1 ns;

    report "Testing address 0x8840" severity note;
    report "Expected: DEV_VIC_BLIT" severity note;

    if sel = DEV_VIC_BLIT then
      report "Result: PASS - Got DEV_VIC_BLIT" severity note;
    elsif sel = DEV_SOUND0 then
      report "Result: FAIL - Got DEV_SOUND0 (overlap issue?)" severity error;
    elsif sel = DEV_VIC_SPR then
      report "Result: FAIL - Got DEV_VIC_SPR (wrong range?)" severity error;
    else
      report "Result: FAIL - Got " & device_sel_t'image(sel) severity error;
    end if;

    wait;
  end process;
end architecture;
