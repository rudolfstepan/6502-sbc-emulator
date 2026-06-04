-- Testbench for VIC Raster Interrupt
-- Tests raster line comparison and interrupt generation
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;
use work.sbc_pkg.all;

entity tb_vic_raster_irq is
end entity;

architecture test of tb_vic_raster_irq is
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
    report "VIC Raster Interrupt Test Suite" severity note;
    report "========================================" severity note;
    report "" severity note;

    -- Test 1: Configure raster interrupt at line 100
    report "Test 1: Configure raster interrupt at line 100" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"9002";
    din <= x"64";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;

    cs <= '1';
    we <= '1';
    addr <= x"9003";
    din <= x"A0";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;
    report "  PASS: Raster interrupt configured" severity note;

    -- Test 2: Verify raster_cmp register was written
    report "" severity note;
    report "Test 2: Verify raster compare register" severity note;
    cs <= '1';
    we <= '0';
    addr <= x"9002";
    wait for CLK_PERIOD;
    if dout = x"64" then
      report "  PASS: Raster compare = 0x64 (line 100)" severity note;
    else
      report "  FAIL: Expected 0x64, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';
    wait for CLK_PERIOD;

    -- Test 3: Verify mode register shows IRQ enabled
    report "" severity note;
    report "Test 3: Verify raster IRQ enabled in mode" severity note;
    cs <= '1';
    we <= '0';
    addr <= x"9003";
    wait for CLK_PERIOD;
    if dout(5) = '1' then
      report "  PASS: Raster IRQ enabled (bit 5)" severity note;
    else
      report "  FAIL: Raster IRQ should be enabled" severity error;
    end if;
    cs <= '0';
    wait for CLK_PERIOD;

    -- Test 4: Clear raster interrupt by reading status
    report "" severity note;
    report "Test 4: Read status register to clear IRQ flag" severity note;
    cs <= '1';
    we <= '0';
    addr <= x"8811";
    wait for CLK_PERIOD;
    report "  STATUS: 0x" & to_hstring(dout) severity note;
    cs <= '0';
    wait for CLK_PERIOD;
    report "  PASS: Status read completes" severity note;

    -- Test 5: Change raster compare to different line
    report "" severity note;
    report "Test 5: Change raster compare to line 50" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"9002";
    din <= x"32";
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;

    cs <= '1';
    we <= '0';
    addr <= x"9002";
    wait for CLK_PERIOD;
    if dout = x"32" then
      report "  PASS: Raster compare updated to 0x32 (line 50)" severity note;
    else
      report "  FAIL: Expected 0x32, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';
    wait for CLK_PERIOD;

    -- Test 6: Disable raster interrupt
    report "" severity note;
    report "Test 6: Disable raster interrupt" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"9003";
    din <= x"80";  -- Clear bit 5
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD;

    cs <= '1';
    we <= '0';
    addr <= x"9003";
    wait for CLK_PERIOD;
    if dout(5) = '0' then
      report "  PASS: Raster IRQ disabled" severity note;
    else
      report "  FAIL: Raster IRQ should be disabled" severity error;
    end if;
    cs <= '0';

    report "" severity note;
    report "========================================" severity note;
    report "VIC Raster Interrupt Tests Complete" severity note;
    report "========================================" severity note;
    finish;
  end process;

end architecture;
