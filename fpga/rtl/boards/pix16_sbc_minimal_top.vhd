-- PIX16 Board Top fuer minimales 6502-SBC mit VGA-Ausgabe
--
-- Einfacher Durchreicher: sbc_minimal_top enthaelt jetzt den kompletten
-- VIC mit Bus-Stealing und VGA-Ausgabe. Kein separater pixel_gen noetig.
-- Passt exakt zu fpga/constraints/pix16.ucf.
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

entity pix16_sbc_minimal_top is
  generic (
    ROM_INIT_FILE : string := "../sim/rom_welcome.hex"
  );
  port (
    -- System (pix16.ucf: clk=T8, reset_n=L3)
    clk        : in  std_logic;
    reset_n    : in  std_logic;

    -- VGA (pix16.ucf: R=M13..M11, G=P11..M9, B=L7..P7, vs=L13, hs=M14)
    vga_out_r  : out std_logic_vector(4 downto 0);
    vga_out_g  : out std_logic_vector(5 downto 0);
    vga_out_b  : out std_logic_vector(4 downto 0);
    vga_out_hs : out std_logic;
    vga_out_vs : out std_logic;

    -- Tasten und LEDs (pix16.ucf: key=C3..E3, led=P4,N5)
    key        : in  std_logic_vector(3 downto 0);
    led        : out std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of pix16_sbc_minimal_top is
begin
  led(0) <= '1';            -- Power-LED
  led(1) <= not key(0);    -- KEY0-Anzeige

  sbc_i : entity work.sbc_minimal_top
    generic map (ROM_INIT_FILE => ROM_INIT_FILE)
    port map (
      clk          => clk,
      reset_n      => reset_n,
      vga_r        => vga_out_r,
      vga_g        => vga_out_g,
      vga_b        => vga_out_b,
      vga_hs       => vga_out_hs,
      vga_vs       => vga_out_vs,
      dbg_cpu_addr => open,
      dbg_cpu_data => open,
      dbg_cpu_din  => open,
      dbg_cpu_we   => open,
      dbg_cpu_sync => open
    );
end architecture;
