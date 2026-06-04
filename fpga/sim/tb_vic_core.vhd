-- Testbench for VIC Core Module
-- Tests text RAM, color RAM, and control register access
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_vic_core is
end entity;

architecture test of tb_vic_core is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal cs           : std_logic := '0';
  signal we           : std_logic := '0';
  signal addr         : addr_t := (others => '0');
  signal din          : data_t := (others => '0');
  signal dout         : data_t;
  signal irq          : std_logic;
  signal h_counter    : integer range 0 to 1023;
  signal v_counter    : integer range 0 to 1023;
  signal raster_irq   : std_logic;

  constant CLK_PERIOD : time := 10 ns;

begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.vic_core
    port map (
      clk        => clk,
      reset_n    => reset_n,
      cs         => cs,
      we         => we,
      addr       => addr,
      din        => din,
      dout       => dout,
      irq        => irq,
      h_counter  => h_counter,
      v_counter  => v_counter,
      raster_irq => raster_irq
    );

  test : process
  begin
    reset_n <= '0';
    wait for 50 ns;
    reset_n <= '1';
    wait for 50 ns;

    report "========================================" severity note;
    report "VIC Core Module Test Suite" severity note;
    report "========================================" severity note;
    report "" severity note;

    -- Test 1: Write and read text RAM at 0x8000
    report "Test 1: Write and read text RAM at 0x8000" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8000";
    din <= x"41";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;

    cs <= '1';
    we <= '0';
    addr <= x"8000";
    wait for CLK_PERIOD;
    if dout = x"41" then
      report "  PASS: Text RAM[0x8000] = 0x41" severity note;
    else
      report "  FAIL: Expected 0x41, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';
    wait for CLK_PERIOD;

    -- Test 2: Write to multiple locations in text RAM
    report "" severity note;
    report "Test 2: Write to offsets 1,2,3 in text RAM" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8001";
    din <= x"42";
    wait for CLK_PERIOD;
    addr <= x"8002";
    din <= x"43";
    wait for CLK_PERIOD;
    addr <= x"8003";
    din <= x"44";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;
    report "  PASS: Wrote multiple text RAM locations" severity note;

    -- Test 3: Write and read color RAM
    report "" severity note;
    report "Test 3: Write and read color RAM at 0x8800" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8800";
    din <= x"F0";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;

    cs <= '1';
    we <= '0';
    addr <= x"8800";
    wait for CLK_PERIOD;
    if dout = x"F0" then
      report "  PASS: Color RAM[0x8800] = 0xF0" severity note;
    else
      report "  FAIL: Expected 0xF0, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';
    wait for CLK_PERIOD;

    -- Test 4: Control registers
    report "" severity note;
    report "Test 4: Write control registers (SCROLL_X, SCROLL_Y, RASTER, MODE, COLORS)" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"9000";
    din <= x"03";
    wait for CLK_PERIOD;
    addr <= x"9001";
    din <= x"02";
    wait for CLK_PERIOD;
    addr <= x"9002";
    din <= x"64";
    wait for CLK_PERIOD;
    addr <= x"9003";
    din <= x"A0";
    wait for CLK_PERIOD;
    addr <= x"9004";
    din <= x"E5";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    -- Read back and verify
    cs <= '1';
    we <= '0';
    addr <= x"9000";
    wait for CLK_PERIOD;
    if dout = x"03" then
      report "  PASS: SCROLL_X = 0x03" severity note;
    else
      report "  FAIL: SCROLL_X expected 0x03, got 0x" & to_hstring(dout) severity error;
    end if;

    addr <= x"9001";
    wait for CLK_PERIOD;
    if dout = x"02" then
      report "  PASS: SCROLL_Y = 0x02" severity note;
    else
      report "  FAIL: SCROLL_Y expected 0x02" severity error;
    end if;

    addr <= x"9002";
    wait for CLK_PERIOD;
    if dout = x"64" then
      report "  PASS: RASTER_CMP = 0x64" severity note;
    else
      report "  FAIL: RASTER_CMP expected 0x64" severity error;
    end if;

    addr <= x"9003";
    wait for CLK_PERIOD;
    if dout = x"A0" then
      report "  PASS: MODE = 0xA0" severity note;
    else
      report "  FAIL: MODE expected 0xA0" severity error;
    end if;

    addr <= x"9004";
    wait for CLK_PERIOD;
    if dout = x"E5" then
      report "  PASS: COLORS = 0xE5" severity note;
    else
      report "  FAIL: COLORS expected 0xE5" severity error;
    end if;

    cs <= '0';
    wait for CLK_PERIOD;

    -- Test 5: Text RAM boundary at 0x87FF
    report "" severity note;
    report "Test 5: Text RAM boundary at 0x87FF" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"87FF";
    din <= x"5A";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;

    cs <= '1';
    we <= '0';
    addr <= x"87FF";
    wait for CLK_PERIOD;
    if dout = x"5A" then
      report "  PASS: Text RAM[0x87FF] = 0x5A" severity note;
    else
      report "  FAIL: Expected 0x5A, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    report "" severity note;
    report "========================================" severity note;
    report "VIC Core Tests Complete" severity note;
    report "========================================" severity note;
    wait;
  end process;

end architecture;
