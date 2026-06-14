library ieee;
use ieee.std_logic_1164.all;

use std.env.all;
use work.sbc_pkg.all;

entity tb_bus_decode is
end entity;

architecture sim of tb_bus_decode is
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
    addr <= x"0000"; wait for 1 ns; assert sel = DEV_SRAM report "SRAM decode failed" severity failure;
    addr <= x"8000"; wait for 1 ns; assert sel = DEV_VIC_TEXT report "VIC text decode failed" severity failure;
    addr <= x"8800"; wait for 1 ns; assert sel = DEV_VIA report "VIA decode failed" severity failure;
    addr <= x"8810"; wait for 1 ns; assert sel = DEV_UART report "UART decode failed" severity failure;
    addr <= x"8820"; wait for 1 ns; assert sel = DEV_DISK report "DISK decode failed" severity failure;
    addr <= x"8830"; wait for 1 ns; assert sel = DEV_SOUND0 report "SOUND0 decode failed" severity failure;
    addr <= x"8840"; wait for 1 ns; assert sel = DEV_VIC_BLIT report "VIC blitter decode failed" severity failure;
    addr <= x"8850"; wait for 1 ns; assert sel = DEV_VIC_SPR report "VIC sprite reg decode failed" severity failure;
    addr <= x"8890"; wait for 1 ns; assert sel = DEV_SOUND1 report "SOUND1 decode failed" severity failure;
    addr <= x"889A"; wait for 1 ns; assert sel = DEV_SOUND2 report "SOUND2 decode failed" severity failure;
    addr <= x"88A4"; wait for 1 ns; assert sel = DEV_SOUND3 report "SOUND3 decode failed" severity failure;
    addr <= x"8900"; wait for 1 ns; assert sel = DEV_VIC_SPD report "VIC sprite data decode failed" severity failure;
    addr <= x"9000"; wait for 1 ns; assert sel = DEV_VIC_REG report "VIC register decode failed" severity failure;
    addr <= x"9010"; wait for 1 ns; assert sel = DEV_VIC_BMP report "VIC bitmap decode failed" severity failure;
    addr <= x"C000"; wait for 1 ns; assert sel = DEV_ROM report "ROM decode failed" severity failure;
    addr <= x"B000"; wait for 1 ns; assert sel = DEV_NONE report "unmapped decode failed" severity failure;

    report "tb_bus_decode passed";
    finish;
  end process;
end architecture;
