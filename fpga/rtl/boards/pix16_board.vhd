-- PIX16 Spartan-6 Board Integration
-- Integrates VIC core with hardware: VGA output, SDRAM, push buttons
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity pix16_board is
  generic (
    TEST_ROM_INIT_FILE : string := "../rtl/mem/pix16_welcome_test.hex"
  );
  port (
    -- System
    clk         : in  std_logic;      -- 50MHz oscillator input
    reset_n     : in  std_logic;      -- Active-low reset

    -- VGA Output (resistor-ladder DAC)
    vga_out_r   : out std_logic_vector(4 downto 0);
    vga_out_g   : out std_logic_vector(5 downto 0);
    vga_out_b   : out std_logic_vector(4 downto 0);
    vga_out_hs  : out std_logic;
    vga_out_vs  : out std_logic;

    -- User Interface
    key         : in  std_logic_vector(3 downto 0);  -- Push buttons (active-low)
    led         : out std_logic_vector(1 downto 0);  -- Status LEDs

    -- SDRAM Interface (optional, placeholder for future use)
    sdram_clk   : out std_logic;
    sdram_cke   : out std_logic;
    sdram_cs_n  : out std_logic;
    sdram_ras_n : out std_logic;
    sdram_cas_n : out std_logic;
    sdram_we_n  : out std_logic;
    sdram_dqm   : out std_logic_vector(1 downto 0);
    sdram_ba    : out std_logic_vector(1 downto 0);
    sdram_addr  : out std_logic_vector(12 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of pix16_board is
  -- Clock generation
  signal clk_pll     : std_logic;  -- PLL-derived clock (100MHz for logic)
  signal pll_locked  : std_logic;
  signal reset_sync  : std_logic;

  -- VIC timing signals
  signal h_counter   : integer range 0 to 1023;
  signal v_counter   : integer range 0 to 1023;

  -- Pixel data
  signal pixel_r     : std_logic_vector(4 downto 0);
  signal pixel_g     : std_logic_vector(5 downto 0);
  signal pixel_b     : std_logic_vector(4 downto 0);
  signal h_sync      : std_logic;
  signal v_sync      : std_logic;
  signal pixel_valid : std_logic;
  signal pixel_data  : data_t;

  -- VIC bus signals
  signal vic_cs      : std_logic := '0';
  signal vic_we      : std_logic := '0';
  signal vic_addr    : addr_t := (others => '0');
  signal vic_din     : data_t := (others => '0');
  signal vic_dout    : data_t;
  signal vic_irq     : std_logic;
  signal raster_irq  : std_logic;
  signal text_ram_addr : integer range 0 to 2047;
  signal text_ram_data : data_t;
  signal color_ram_addr : integer range 0 to 255;
  signal color_ram_data : data_t;

  -- Test ROM bus master
  signal cpu_addr   : addr_t := (others => '0');
  signal cpu_dout   : data_t := (others => '0');
  signal cpu_din    : data_t := (others => '0');
  signal cpu_we     : std_logic := '0';
  signal dev_sel    : device_sel_t;
  signal rom_dout   : data_t;
  signal dbg_read_data  : data_t;
  signal dbg_read_valid : std_logic;

  -- Character ROM interface
  signal char_rom_addr : std_logic_vector(9 downto 0);
  signal char_rom_data : data_t;

begin
  -- For now, SDRAM signals are inactive (pulled low)
  -- These would connect to a proper SDRAM controller in a full implementation
  sdram_clk   <= '0';
  sdram_cke   <= '0';
  sdram_cs_n  <= '1';
  sdram_ras_n <= '1';
  sdram_cas_n <= '1';
  sdram_we_n  <= '1';
  sdram_dqm   <= "11";
  sdram_ba    <= "00";
  sdram_addr  <= (others => '0');
  sdram_dq    <= (others => 'Z');

  -- Status LEDs
  led(0) <= not pll_locked;  -- LED1: PLL lock status
  led(1) <= not key(0);       -- LED2: KEY1 pressed indicator

  -- =========================================================================
  -- Clock Generation (PLL)
  -- =========================================================================
  -- For simplicity, using system clock directly for now
  -- In full implementation, would use DCM/PLL to generate multiple clocks
  clk_pll <= clk;
  pll_locked <= '1';
  reset_sync <= reset_n and pll_locked;

  -- =========================================================================
  -- Test ROM Bus Master
  -- =========================================================================
  decode_i : entity work.bus_decode
    port map (
      addr => cpu_addr,
      sel  => dev_sel
    );

  cpu_i : entity work.cpu6502_slot
    port map (
      clk      => clk_pll,
      reset_n  => reset_sync,
      irq_n    => not vic_irq,
      data_in  => cpu_din,
      addr     => cpu_addr,
      data_out => cpu_dout,
      we       => cpu_we,
      dbg_read_data  => dbg_read_data,
      dbg_read_valid => dbg_read_valid
    );

  rom_i : entity work.rom
    generic map (
      ADDR_WIDTH => 14,
      INIT_FILE  => TEST_ROM_INIT_FILE,
      ASYNC_READ => true
    )
    port map (
      clk  => clk_pll,
      addr => cpu_addr(13 downto 0),
      dout => rom_dout
    );

  vic_cs <= '1' when dev_sel = DEV_VIC_TEXT or dev_sel = DEV_VIC_REG else '0';
  vic_we <= cpu_we;
  vic_addr <= cpu_addr;
  vic_din <= cpu_dout;

  with dev_sel select cpu_din <=
    rom_dout when DEV_ROM,
    vic_dout when DEV_VIC_TEXT | DEV_VIC_REG,
    x"FF"    when others;

  -- =========================================================================
  -- VIC Core Instance
  -- =========================================================================
  vic_core_i : entity work.vic_core
    port map (
      clk        => clk_pll,
      reset_n    => reset_sync,
      cs         => vic_cs,
      we         => vic_we,
      addr       => vic_addr,
      din        => vic_din,
      dout       => vic_dout,
      irq        => vic_irq,
      h_counter  => h_counter,
      v_counter  => v_counter,
      raster_irq => raster_irq,
      pixel_text_addr => text_ram_addr,
      pixel_text_data => text_ram_data,
      pixel_color_addr => color_ram_addr,
      pixel_color_data => color_ram_data
    );

  -- =========================================================================
  -- Character ROM Instance
  -- =========================================================================
  char_rom_i : entity work.char_rom
    port map (
      addr => char_rom_addr,
      dout => char_rom_data
    );

  -- =========================================================================
  -- Pixel Generator Instance
  -- =========================================================================
  pixel_gen_i : entity work.vic_pixel_gen
    port map (
      clk           => clk_pll,
      reset_n       => reset_sync,
      text_ram_addr => text_ram_addr,
      text_ram_data => text_ram_data,
      color_ram_addr => color_ram_addr,
      color_ram_data => color_ram_data,
      char_rom_addr => char_rom_addr,
      char_rom_data => char_rom_data,
      scroll_x      => (others => '0'),
      scroll_y      => (others => '0'),
      mode_reg      => x"80",         -- Display enabled, text mode
      h_sync        => h_sync,
      v_sync        => v_sync,
      pixel_out     => pixel_data,
      pixel_valid   => pixel_valid
    );

  -- =========================================================================
  -- VGA Output Assignment
  -- =========================================================================
  -- For now, output a test pattern (solid color during valid pixels)
  vga_out_hs <= h_sync;
  vga_out_vs <= v_sync;

  vga_out_r <= "11111" when pixel_data /= x"00" else "00000";
  vga_out_g <= "111111" when pixel_data /= x"00" else "000000";
  vga_out_b <= "11111" when pixel_data /= x"00" else "00000";

end architecture;
