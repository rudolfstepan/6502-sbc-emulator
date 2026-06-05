-- Testbench fuer sbc_minimal_top (Bus-Stealing Design)
-- Prueft: CPU fuehrt Kernel aus und schreibt "WILLKOMMEN ZUM 6502 SBC!"
-- tatsaechlich via CPU-Bus in den VRAM ($8000+).
-- VIC stiehlt Bus waehrend H-Blank -> Test wartet laenger (mehr Takte).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;
use work.sbc_pkg.all;

entity tb_sbc_minimal is
end entity;

architecture sim of tb_sbc_minimal is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';

  -- VGA (nicht geprueft, nur angeschlossen damit keine Treiber fehlen)
  signal vga_r        : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal vga_b        : std_logic_vector(4 downto 0);
  signal vga_hs       : std_logic;
  signal vga_vs       : std_logic;

  -- Debug-Bus
  signal dbg_cpu_addr : addr_t;
  signal dbg_cpu_data : data_t;
  signal dbg_cpu_din  : data_t;
  signal dbg_cpu_we   : std_logic;
  signal dbg_cpu_sync : std_logic;

  -- Erwartete Zeichen "WILLKOMMEN ZUM 6502 SBC!"
  type expected_t is array (0 to 23) of data_t;
  constant EXPECTED : expected_t := (
    x"57", x"49", x"4C", x"4C", x"4B", x"4F", x"4D", x"4D",
    x"45", x"4E", x"20", x"5A", x"55", x"4D", x"20", x"36",
    x"35", x"30", x"32", x"20", x"53", x"42", x"43", x"21"
  );
begin
  clk <= not clk after 5 ns;  -- 100 MHz

  dut : entity work.sbc_minimal_top
    generic map (ROM_INIT_FILE => "sim/rom_welcome.hex")
    port map (
      clk          => clk,
      reset_n      => reset_n,
      vga_r        => vga_r,
      vga_g        => vga_g,
      vga_b        => vga_b,
      vga_hs       => vga_hs,
      vga_vs       => vga_vs,
      dbg_cpu_addr => dbg_cpu_addr,
      dbg_cpu_data => dbg_cpu_data,
      dbg_cpu_din  => dbg_cpu_din,
      dbg_cpu_we   => dbg_cpu_we,
      dbg_cpu_sync => dbg_cpu_sync
    );

  process
    variable char_idx : integer := 0;
  begin
    wait for 60 ns;
    reset_n <= '1';

    -- Mehr Takte als vorher: VIC stiehlt Bus waehrend H-Blank
    -- -> CPU-Schreibzugriffe kommen etwas spaeter an
    for cycle in 0 to 5000 loop
      wait until rising_edge(clk);

      if dbg_cpu_we = '1' and
         unsigned(dbg_cpu_addr) >= x"8000" and
         unsigned(dbg_cpu_addr) <= x"8017"
      then
        assert dbg_cpu_data = EXPECTED(char_idx)
          report "Zeichen " & integer'image(char_idx) &
                 ": erwartet 0x" & to_hstring(EXPECTED(char_idx)) &
                 " bekommen 0x" & to_hstring(dbg_cpu_data)
          severity failure;

        char_idx := char_idx + 1;

        if char_idx = EXPECTED'length then
          report "tb_sbc_minimal BESTANDEN: " &
                 integer'image(EXPECTED'length) &
                 " Zeichen korrekt via CPU in VRAM geschrieben";
          stop;
        end if;
      end if;
    end loop;

    assert false
      report "tb_sbc_minimal FEHLER: nur " & integer'image(char_idx) &
             " von " & integer'image(EXPECTED'length) & " Zeichen empfangen"
      severity failure;
  end process;
end architecture;
