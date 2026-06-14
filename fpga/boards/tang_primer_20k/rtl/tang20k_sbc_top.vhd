-- Tang Primer 20K board top — minimal SBC (no external memory).
--
-- Uses sbc_minimal_top: all RAM and ROM in Gowin internal BSRAM.
-- ROM image loaded from hex file at synthesis time via ROM_INIT_FILE generic.
--
-- VGA signals are routed to the P3 GPIO expansion header.
-- Wire a resistor DAC VGA breakout to the header pins listed in the CST file.
--
-- KEY[0] = S1 (T10, LVCMOS33) = active-low reset
-- KEY[1] = S2 (T3, LVCMOS15) = user button (unused in this build)
-- LED[3:0] = active-low, driven by VIA Port B bits 3..0
library ieee;
use ieee.std_logic_1164.all;
use work.sbc_pkg.all;

entity tang20k_sbc_top is
  generic (
    ROM_INIT_FILE : string  := "../../../sim/hex/rom_welcome.hex";
    CLK_HZ        : positive := 27_000_000;
    BAUD          : positive := 115_200
  );
  port (
    clk_27mhz : in  std_logic;
    key        : in  std_logic_vector(1 downto 0);
    led        : out std_logic_vector(3 downto 0);
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic;
    vga_r      : out std_logic_vector(4 downto 0);
    vga_g      : out std_logic_vector(5 downto 0);
    vga_b      : out std_logic_vector(4 downto 0);
    vga_hs     : out std_logic;
    vga_vs     : out std_logic
  );
end entity;

architecture rtl of tang20k_sbc_top is
  signal uart_tx_data  : data_t;
  signal uart_tx_valid : std_logic;
  signal uart_tx_busy  : std_logic;
  signal via_portb     : data_t;
begin

  sbc_i : entity work.sbc_minimal_top
    generic map (ROM_INIT_FILE => ROM_INIT_FILE)
    port map (
      clk           => clk_27mhz,
      reset_n       => key(0),
      vga_r         => vga_r,
      vga_g         => vga_g,
      vga_b         => vga_b,
      vga_hs        => vga_hs,
      vga_vs        => vga_vs,
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
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (
      clk     => clk_27mhz,
      reset_n => key(0),
      data    => uart_tx_data,
      valid   => uart_tx_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

  led(0) <= not via_portb(0);
  led(1) <= not via_portb(1);
  led(2) <= not via_portb(2);
  led(3) <= not via_portb(3);

end architecture;
