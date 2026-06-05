-- PIX16 Board Top fuer minimales 6502-SBC
-- Passt exakt zu fpga/constraints/pix16.ucf.
-- VIA Port B bit 0/1 steuert die LEDs (sichtbarer Timer-Beweis).
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

entity pix16_sbc_minimal_top is
  generic (
    ROM_INIT_FILE : string := "../sim/rom_welcome.hex"
  );
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;
    vga_out_r  : out std_logic_vector(4 downto 0);
    vga_out_g  : out std_logic_vector(5 downto 0);
    vga_out_b  : out std_logic_vector(4 downto 0);
    vga_out_hs : out std_logic;
    vga_out_vs : out std_logic;
    key        : in  std_logic_vector(3 downto 0);
    led        : out std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of pix16_sbc_minimal_top is
  signal via_portb : data_t;
begin
  -- LEDs spiegeln VIA Port B bits 1:0
  -- bit 0 toggelt im ISR alle ~330ms -> sichtbares Blinken
  led(0) <= via_portb(0);
  led(1) <= via_portb(1);

  sbc_i : entity work.sbc_minimal_top
    generic map (ROM_INIT_FILE => ROM_INIT_FILE)
    port map (
      clk           => clk,
      reset_n       => reset_n,
      vga_r         => vga_out_r,
      vga_g         => vga_out_g,
      vga_b         => vga_out_b,
      vga_hs        => vga_out_hs,
      vga_vs        => vga_out_vs,
      via_portb     => via_portb,
      uart_tx_data  => open,
      uart_tx_valid => open,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );
end architecture;
