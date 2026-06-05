-- PIX16 Board Top — minimal 6502 SBC
-- Matches fpga/constraints/pix16.ucf.
-- uart_tx (D12) / uart_rx (C11) connect to the CH340C USB-UART converter.
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
    led        : out std_logic_vector(1 downto 0);
    uart_tx    : out std_logic;   -- to CH340C RXD (pin D12)
    uart_rx    : in  std_logic    -- from CH340C TXD (pin C11)
  );
end entity;

architecture rtl of pix16_sbc_minimal_top is
  signal via_portb    : data_t;
  signal uart_tx_data : data_t;
  signal uart_tx_valid: std_logic;
  signal uart_tx_busy : std_logic;
begin

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
      uart_rx       => uart_rx,
      via_portb     => via_portb,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  uart_ser : entity work.uart_tx_ser
    port map (
      clk     => clk,
      reset_n => reset_n,
      data    => uart_tx_data,
      valid   => uart_tx_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

end architecture;
