-- PIX16 Board Wrapper — SBC with SDRAM
-- Matches fpga/constraints/pix16_sdram.ucf.
-- sdram_clk driven via ODDR2 (no PLL required at 50 MHz).
-- uart_tx (D12) drives the CH340C USB-UART for host diagnostics.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

use work.sbc_pkg.all;

entity pix16_sbc_sdram_top is
  generic (
    ROM_INIT_FILE : string := "../sim/rom_welcome.hex"
  );
  port (
    clk         : in    std_logic;   -- 50 MHz crystal (T8)
    reset_n     : in    std_logic;   -- active-low reset (L3)

    -- VGA (resistor-ladder DAC)
    vga_out_r   : out   std_logic_vector(4 downto 0);
    vga_out_g   : out   std_logic_vector(5 downto 0);
    vga_out_b   : out   std_logic_vector(4 downto 0);
    vga_out_hs  : out   std_logic;
    vga_out_vs  : out   std_logic;

    -- User interface
    key         : in    std_logic_vector(3 downto 0);
    led         : out   std_logic_vector(1 downto 0);
    uart_tx     : out   std_logic;   -- to CH340C RXD (pin D12)

    -- SDRAM (HY57V2562GTR, 256 Mbit, 16-bit)
    sdram_clk   : out   std_logic;
    sdram_cke   : out   std_logic;
    sdram_cs_n  : out   std_logic;
    sdram_ras_n : out   std_logic;
    sdram_cas_n : out   std_logic;
    sdram_we_n  : out   std_logic;
    sdram_ba    : out   std_logic_vector(1 downto 0);
    sdram_addr  : out   std_logic_vector(12 downto 0);
    sdram_dqm   : out   std_logic_vector(1 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of pix16_sbc_sdram_top is

  signal via_portb    : data_t;
  signal uart_tx_data : data_t;
  signal uart_tx_valid: std_logic;
  signal clk_n        : std_logic;

begin

  -- -------------------------------------------------------------------------
  -- SDRAM clock: ODDR2 outputs system clock to sdram_clk IOB pin.
  -- D0='1'/D1='0' with complementary clocks reproduces 50 MHz at the pin.
  -- -------------------------------------------------------------------------
  clk_n <= not clk;

  sdram_clk_oddr : ODDR2
    generic map (DDR_ALIGNMENT => "NONE", INIT => '0', SRTYPE => "SYNC")
    port map (
      Q  => sdram_clk,
      C0 => clk,  C1 => clk_n,
      CE => '1',
      D0 => '1',  D1 => '0',
      R  => '0',  S  => '0'
    );

  -- -------------------------------------------------------------------------
  sbc_i : entity work.sbc_sdram_top
    generic map (ROM_INIT_FILE => ROM_INIT_FILE)
    port map (
      clk           => clk,
      reset_n       => reset_n,
      vga_r         => vga_out_r,
      vga_g         => vga_out_g,
      vga_b         => vga_out_b,
      vga_hs        => vga_out_hs,
      vga_vs        => vga_out_vs,
      sdram_cke     => sdram_cke,
      sdram_cs_n    => sdram_cs_n,
      sdram_ras_n   => sdram_ras_n,
      sdram_cas_n   => sdram_cas_n,
      sdram_we_n    => sdram_we_n,
      sdram_ba      => sdram_ba,
      sdram_addr    => sdram_addr,
      sdram_dqm     => sdram_dqm,
      sdram_dq      => sdram_dq,
      via_portb     => via_portb,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid
    );

  -- -------------------------------------------------------------------------
  -- UART 8N1 serializer → CH340C USB-UART → host PC
  -- -------------------------------------------------------------------------
  uart_ser : entity work.uart_tx_ser
    port map (
      clk     => clk,
      reset_n => reset_n,
      data    => uart_tx_data,
      valid   => uart_tx_valid,
      tx      => uart_tx,
      busy    => open
    );

  led(0) <= via_portb(0);
  led(1) <= via_portb(1);

end architecture;
