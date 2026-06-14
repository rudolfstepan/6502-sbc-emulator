-- Simple SRAM test: write then read
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_sram_basic is
end entity;

architecture test of tb_sram_basic is
  signal clk   : std_logic := '0';
  signal we    : std_logic := '0';
  signal addr  : std_logic_vector(14 downto 0) := (others => '0');
  signal din   : data_t := x"00";
  signal dout  : data_t;
begin
  clk <= not clk after 5 ns;

  sram : entity work.sync_ram
    generic map (
      ADDR_WIDTH => 15,
      ASYNC_READ => true
    )
    port map (
      clk  => clk,
      we   => we,
      addr => addr,
      din  => din,
      dout => dout
    );

  test : process
  begin
    wait for 35 ns;

    report "Test 1: Write AB to address 00F2" severity note;
    addr <= std_logic_vector(to_unsigned(16#00F2#, 15));
    din <= x"AB";
    we <= '1';
    wait for 10 ns;
    wait for 10 ns;
    we <= '0';
    wait for 10 ns;

    report "Test 2: Read from address 00F2" severity note;
    addr <= std_logic_vector(to_unsigned(16#00F2#, 15));
    wait for 20 ns;
    report "Data read: " & to_hstring(dout) severity note;
    if dout = x"AB" then
      report "PASS: Read correct value" severity note;
    else
      report "FAIL: Read incorrect value (expected AB)" severity error;
    end if;

    report "Test 3: Write 80 to address 00F3" severity note;
    addr <= std_logic_vector(to_unsigned(16#00F3#, 15));
    din <= x"80";
    we <= '1';
    wait for 10 ns;
    wait for 10 ns;
    we <= '0';
    wait for 10 ns;

    report "Test 4: Read from address 00F3" severity note;
    addr <= std_logic_vector(to_unsigned(16#00F3#, 15));
    wait for 20 ns;
    report "Data read: " & to_hstring(dout) severity note;
    if dout = x"80" then
      report "PASS: Read correct value" severity note;
    else
      report "FAIL: Read incorrect value (expected 80)" severity error;
    end if;

    report "Test 5: Verify first write is still there" severity note;
    addr <= std_logic_vector(to_unsigned(16#00F2#, 15));
    wait for 20 ns;
    report "Data at 00F2: " & to_hstring(dout) severity note;
    if dout = x"AB" then
      report "PASS: First write retained" severity note;
    else
      report "FAIL: First write lost" severity error;
    end if;

    wait;
  end process;
end architecture;
