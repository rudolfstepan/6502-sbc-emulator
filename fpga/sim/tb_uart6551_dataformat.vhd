-- Testbench for UART6551 Data Format Configuration
-- Verifies support for 5/6/7/8 bit data formats
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_uart6551_dataformat is
end entity;

architecture test of tb_uart6551_dataformat is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal cs           : std_logic := '0';
  signal we           : std_logic := '0';
  signal addr         : addr_t := (others => '0');
  signal din          : data_t := (others => '0');
  signal dout         : data_t;
  signal rx_data      : data_t := (others => '0');
  signal rx_valid     : std_logic := '0';
  signal tx_data      : data_t;
  signal tx_valid     : std_logic;
  signal irq          : std_logic;

  constant CLK_PERIOD : time := 10 ns;

begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.uart6551
    port map (
      clk       => clk,
      reset_n   => reset_n,
      cs        => cs,
      we        => we,
      addr      => addr,
      din       => din,
      dout      => dout,
      rx_data   => rx_data,
      rx_valid  => rx_valid,
      tx_data   => tx_data,
      tx_valid  => tx_valid,
      irq       => irq
    );

  test : process
  begin
    reset_n <= '0';
    wait for 50 ns;
    reset_n <= '1';
    wait for 50 ns;

    report "UART Data Format Configuration Test" severity note;
    report "" severity note;

    -- Test 1: Set 5-bit data format
    report "Test 1: Configure 5-bit data format" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";  -- CTRL register
    din <= x"00";     -- CTRL[1:0] = 00 (5 bits)
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"00" then
      report "  PASS: CTRL[1:0] = 00 (5 bits)" severity note;
    else
      report "  FAIL: Expected 0x00, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 2: Set 6-bit data format
    report "" severity note;
    report "Test 2: Configure 6-bit data format" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    din <= x"01";     -- CTRL[1:0] = 01 (6 bits)
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"01" then
      report "  PASS: CTRL[1:0] = 01 (6 bits)" severity note;
    else
      report "  FAIL: Expected 0x01, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 3: Set 7-bit data format
    report "" severity note;
    report "Test 3: Configure 7-bit data format" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    din <= x"02";     -- CTRL[1:0] = 10 (7 bits)
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"02" then
      report "  PASS: CTRL[1:0] = 10 (7 bits)" severity note;
    else
      report "  FAIL: Expected 0x02, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 4: Set 8-bit data format (default)
    report "" severity note;
    report "Test 4: Configure 8-bit data format" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    din <= x"03";     -- CTRL[1:0] = 11 (8 bits)
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"03" then
      report "  PASS: CTRL[1:0] = 11 (8 bits)" severity note;
    else
      report "  FAIL: Expected 0x03, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 5: Combine data format with baud rate
    report "" severity note;
    report "Test 5: Combine data format (7 bits) with baud rate (115200)" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    din <= x"9A";     -- CTRL[3:0] = 1001 (115200), CTRL[1:0] = 10 (7 bits)
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"9A" then
      report "  PASS: Combined config CTRL = 0x9A (115200 baud, 7 bits)" severity note;
    else
      report "  FAIL: Expected 0x9A, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    report "" severity note;
    report "========================================" severity note;
    report "Data Format Configuration Tests Complete" severity note;
    report "========================================" severity note;
    wait;
  end process;

end architecture;
