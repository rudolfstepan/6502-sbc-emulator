-- PIX16 Top-Level Design
-- Spartan-6 FPGA development board with VIC text mode display
library ieee;
use ieee.std_logic_1164.all;

entity pix16_top is
  generic (
    TEST_ROM_INIT_FILE : string := "../rtl/mem/pix16_welcome_test.hex"
  );
  port (
    -- System
    clk         : in  std_logic;              -- 50MHz crystal oscillator
    reset_n     : in  std_logic;              -- Active-low reset button

    -- VGA Output
    vga_out_r   : out std_logic_vector(4 downto 0);
    vga_out_g   : out std_logic_vector(5 downto 0);
    vga_out_b   : out std_logic_vector(4 downto 0);
    vga_out_hs  : out std_logic;
    vga_out_vs  : out std_logic;

    -- User Interface
    key         : in  std_logic_vector(3 downto 0);
    led         : out std_logic_vector(1 downto 0);

    -- SDRAM Interface
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

architecture rtl of pix16_top is
begin
  -- Instantiate board integration layer
  board_i : entity work.pix16_board
    generic map (
      TEST_ROM_INIT_FILE => TEST_ROM_INIT_FILE
    )
    port map (
      clk         => clk,
      reset_n     => reset_n,
      vga_out_r   => vga_out_r,
      vga_out_g   => vga_out_g,
      vga_out_b   => vga_out_b,
      vga_out_hs  => vga_out_hs,
      vga_out_vs  => vga_out_vs,
      key         => key,
      led         => led,
      sdram_clk   => sdram_clk,
      sdram_cke   => sdram_cke,
      sdram_cs_n  => sdram_cs_n,
      sdram_ras_n => sdram_ras_n,
      sdram_cas_n => sdram_cas_n,
      sdram_we_n  => sdram_we_n,
      sdram_dqm   => sdram_dqm,
      sdram_ba    => sdram_ba,
      sdram_addr  => sdram_addr,
      sdram_dq    => sdram_dq
    );

end architecture;
