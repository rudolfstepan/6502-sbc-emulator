library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_rom_image is
end entity;

architecture sim of tb_rom_image is
  signal clk  : std_logic := '0';
  signal addr : std_logic_vector(13 downto 0) := (others => '0');
  signal dout : data_t;

  procedure rom_read(
    signal p_clk  : in  std_logic;
    signal p_addr : out std_logic_vector(13 downto 0);
    constant a    : in  std_logic_vector(13 downto 0)
  ) is
  begin
    p_addr <= a;
    wait until rising_edge(p_clk);
    wait for 1 ns;
  end procedure;
begin
  clk <= not clk after 5 ns;

  dut : entity work.rom
    generic map (
      ADDR_WIDTH => 14,
      INIT_FILE  => "sim/generated/chess_rom.hex"
    )
    port map (
      clk  => clk,
      addr => addr,
      dout => dout
    );

  process
  begin
    rom_read(clk, addr, "11111111111100");

    assert dout = x"00"
      report "chess ROM reset vector low byte mismatch"
      severity failure;

    rom_read(clk, addr, "11111111111101");

    assert dout = x"C0"
      report "chess ROM reset vector high byte mismatch"
      severity failure;

    report "tb_rom_image passed";
    stop;
  end process;
end architecture;

