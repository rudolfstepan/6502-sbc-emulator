-- Tang Primer 20K board top — 6502 SBC with HDMI output.
--
-- Clock: 27 MHz on-board oscillator -> rPLL in tang20k_hdmi_tx generates
--   135 MHz (TMDS bit clock) and 27 MHz (PLL-synchronised system clock).
--
-- Video: vic_vga runs at CLK_DIV=1 (27 MHz pixel), giving 640x480
--   @ 33.75 kHz H / 64.3 Hz V.  Encoded to DVI TMDS over the HDMI connector.
--
-- KEY[0] = T5  (LVCMOS33, active-low reset)
-- KEY[1] = T3  (LVCMOS15, spare user button)
-- LED[3:0] active-low, driven by VIA Port B bits 3..0.
library ieee;
use ieee.std_logic_1164.all;
use work.sbc_pkg.all;

entity tang20k_sbc_top is
  generic (
    ROM_INIT_FILE : string   := "../../../sim/hex/rom_welcome.hex";
    BAUD          : positive := 115_200
  );
  port (
    clk_27mhz  : in  std_logic;
    key        : in  std_logic_vector(1 downto 0);
    led        : out std_logic_vector(3 downto 0);
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic;
    -- HDMI TMDS differential outputs
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of tang20k_sbc_top is
  signal clk_sys      : std_logic;   -- 27 MHz from rPLL (synchronised to 5x)
  signal pll_lock     : std_logic;
  signal reset_n      : std_logic;
  signal uart_tx_data : data_t;
  signal uart_tx_valid: std_logic;
  signal uart_tx_busy : std_logic;
  signal via_portb    : data_t;
  signal vga_r        : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal vga_b        : std_logic_vector(4 downto 0);
  signal vga_hs       : std_logic;
  signal vga_vs       : std_logic;
  signal vga_de       : std_logic;
begin
  -- Hold reset until PLL has locked
  reset_n <= key(0) and pll_lock;

  sbc_i : entity work.sbc_minimal_top
    generic map (ROM_INIT_FILE => ROM_INIT_FILE, CLK_DIV => 1)
    port map (
      clk           => clk_sys,
      reset_n       => reset_n,
      vga_r         => vga_r,
      vga_g         => vga_g,
      vga_b         => vga_b,
      vga_hs        => vga_hs,
      vga_vs        => vga_vs,
      vga_de        => vga_de,
      via_portb     => via_portb,
      uart_rx       => uart_rx,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  uart_ser_i : entity work.uart_tx_ser
    generic map (CLK_HZ => 27_000_000, BAUD => BAUD)
    port map (
      clk     => clk_sys,
      reset_n => reset_n,
      data    => uart_tx_data,
      valid   => uart_tx_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

  hdmi_i : entity work.tang20k_hdmi_tx
    port map (
      clk_in     => clk_27mhz,
      reset_n    => key(0),   -- raw key, before pll_lock gate
      vga_de     => vga_de,
      vga_hs     => vga_hs,
      vga_vs     => vga_vs,
      vga_r      => vga_r,
      vga_g      => vga_g,
      vga_b      => vga_b,
      clk_pix    => clk_sys,
      pll_lock   => pll_lock,
      tmds_clk_p => tmds_clk_p,
      tmds_clk_n => tmds_clk_n,
      tmds_d_p   => tmds_d_p,
      tmds_d_n   => tmds_d_n
    );

  led(0) <= not via_portb(0);
  led(1) <= not via_portb(1);
  led(2) <= not via_portb(2);
  led(3) <= not via_portb(3);

end architecture;
