library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_sbc_t65_uart is
end entity;

architecture sim of tb_sbc_t65_uart is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal uart_rx      : std_logic := '1';
  signal uart_tx      : std_logic;
  signal irq_out      : std_logic;
  signal dbg_cpu_addr : addr_t;
  signal dbg_cpu_data : data_t;
  signal dbg_cpu_we   : std_logic;
  signal dbg_cpu_sync : std_logic;
  signal dbg_uart_tx_data  : data_t;
  signal dbg_uart_tx_valid : std_logic;
  signal dbg_via_portb_out : data_t;
  signal saw_uart_write : boolean := false;
begin
  clk <= not clk after 5 ns;

  dut : entity work.sbc_t65_top
    generic map (
      ROM_INIT_FILE => "sim/rom_t65_uart.hex"
    )
    port map (
      clk          => clk,
      reset_n      => reset_n,
      uart_rx      => uart_rx,
      uart_tx      => uart_tx,
      irq_out      => irq_out,
      dbg_cpu_addr => dbg_cpu_addr,
      dbg_cpu_data => dbg_cpu_data,
      dbg_cpu_we   => dbg_cpu_we,
      dbg_cpu_sync => dbg_cpu_sync,
      dbg_uart_tx_data  => dbg_uart_tx_data,
      dbg_uart_tx_valid => dbg_uart_tx_valid,
      dbg_via_portb_out => dbg_via_portb_out
    );

  process
  begin
    wait for 35 ns;
    reset_n <= '1';

    for i in 0 to 512 loop
      wait until rising_edge(clk);

      if dbg_cpu_we = '1' and dbg_cpu_addr = x"8810" then
        assert dbg_cpu_data = x"41"
          report "T65 UART DATA write byte mismatch"
          severity failure;

        saw_uart_write <= true;
      end if;

      if dbg_uart_tx_valid = '1' then
        assert saw_uart_write
          report "UART TX pulsed before T65 wrote UART DATA"
          severity failure;

        assert dbg_uart_tx_data = x"41"
          report "T65 UART TX data mismatch"
          severity failure;

        report "tb_sbc_t65_uart passed";
        stop;
      end if;
    end loop;

    assert false
      report "T65 system did not transmit through UART"
      severity failure;
  end process;
end architecture;
