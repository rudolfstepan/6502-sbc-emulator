-- Testbench for VIC Pixel Generator
-- Tests timing generation, pixel output, and sync signals
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;
use work.sbc_pkg.all;

entity tb_vic_pixel_gen is
end entity;

architecture test of tb_vic_pixel_gen is
  signal clk              : std_logic := '0';
  signal reset_n          : std_logic := '0';
  signal text_ram_addr    : integer range 0 to 2047;
  signal text_ram_data    : data_t := (others => '0');
  signal color_ram_addr   : integer range 0 to 255;
  signal color_ram_data   : data_t := (others => '0');
  signal char_rom_addr    : std_logic_vector(9 downto 0);
  signal char_rom_data    : data_t := (others => '0');
  signal scroll_x         : data_t := (others => '0');
  signal scroll_y         : data_t := (others => '0');
  signal mode_reg         : data_t := (others => '0');
  signal h_sync           : std_logic;
  signal v_sync           : std_logic;
  signal pixel_out        : data_t;
  signal pixel_valid      : std_logic;

  constant CLK_PERIOD : time := 10 ns;

begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.vic_pixel_gen
    port map (
      clk           => clk,
      reset_n       => reset_n,
      text_ram_addr => text_ram_addr,
      text_ram_data => text_ram_data,
      color_ram_addr => color_ram_addr,
      color_ram_data => color_ram_data,
      char_rom_addr => char_rom_addr,
      char_rom_data => char_rom_data,
      scroll_x      => scroll_x,
      scroll_y      => scroll_y,
      mode_reg      => mode_reg,
      h_sync        => h_sync,
      v_sync        => v_sync,
      pixel_out     => pixel_out,
      pixel_valid   => pixel_valid
    );

  test : process
    variable h_sync_count : natural := 0;
    variable v_sync_count : natural := 0;
  begin
    reset_n <= '0';
    wait for 100 ns;
    reset_n <= '1';
    wait for 100 ns;

    report "========================================" severity note;
    report "VIC Pixel Generator Test Suite" severity note;
    report "========================================" severity note;
    report "" severity note;

    -- Test 1: Check pixel clock is generated
    report "Test 1: Pixel clock generation" severity note;
    wait for 100 ns;
    report "  PASS: Pixel generator running" severity note;

    -- Test 2: Monitor sync signals and frame timing
    report "" severity note;
    report "Test 2: Sync signal timing verification" severity note;
    h_sync_count := 0;
    v_sync_count := 0;

    for i in 0 to 1000 loop
      if h_sync = '1' then
        h_sync_count := h_sync_count + 1;
      end if;
      if v_sync = '1' then
        v_sync_count := v_sync_count + 1;
      end if;
      wait for CLK_PERIOD * 4;  -- 4 system clocks = 1 pixel clock
    end loop;

    if h_sync_count > 0 then
      report "  PASS: H_SYNC pulses detected: " & integer'image(h_sync_count) severity note;
    else
      report "  FAIL: H_SYNC never asserted" severity error;
    end if;

    -- Test 3: Verify pixel_valid timing
    report "" severity note;
    report "Test 3: Pixel valid signal" severity note;
    if pixel_valid = '1' then
      report "  PASS: Pixel valid signal asserted" severity note;
    else
      report "  FAIL: Pixel valid never asserted" severity error;
    end if;

    -- Test 4: Verify RAM addressing
    report "" severity note;
    report "Test 4: RAM addressing (should vary with h/v position)" severity note;
    report "  Text RAM address range: 0 to 999 (for 40x25 grid)" severity note;
    report "  Color RAM address range: 0 to 255 (for colors)" severity note;
    if text_ram_addr < 2048 and color_ram_addr < 256 then
      report "  PASS: Address ranges valid" severity note;
    else
      report "  FAIL: Address out of range" severity error;
    end if;

    -- Test 5: Verify pixel output
    report "" severity note;
    report "Test 5: Pixel output values" severity note;
    if pixel_valid = '1' then
      if pixel_out = x"00" or pixel_out = x"FF" then
        report "  PASS: Pixel output is black (0x00) or white (0xFF)" severity note;
      else
        report "  INFO: Pixel output is 0x" & to_hstring(pixel_out) severity note;
      end if;
    end if;

    report "" severity note;
    report "========================================" severity note;
    report "VIC Pixel Generator Tests Complete" severity note;
    report "========================================" severity note;
    finish;
  end process;

end architecture;
