library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_sbc_t65_kernel_smoke is
end entity;

architecture sim of tb_sbc_t65_kernel_smoke is
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

  signal saw_reset_fetch : boolean := false;
  signal saw_via_ddra    : boolean := false;
  signal saw_scrptr_lo   : boolean := false;
  signal saw_scrptr_hi   : boolean := false;
begin
  clk <= not clk after 5 ns;

  dut : entity work.sbc_t65_top
    generic map (
      ROM_INIT_FILE => "sim/generated/sbc_rom.hex"
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

    for i in 0 to 20000 loop
      wait until rising_edge(clk);

      if dbg_cpu_sync = '1' and dbg_cpu_addr = x"C000" then
        saw_reset_fetch <= true;
      end if;

      if dbg_cpu_we = '1' and dbg_cpu_addr = x"8803" then
        assert dbg_cpu_data = x"00"
          report "kernel VIA DDRA init mismatch"
          severity failure;

        saw_via_ddra <= true;
      end if;

      if dbg_cpu_we = '1' and dbg_cpu_addr = x"00F2" then
        assert dbg_cpu_data = x"00"
          report "kernel SCRPTR_LO init mismatch"
          severity failure;

        saw_scrptr_lo <= true;
      end if;

      if dbg_cpu_we = '1' and dbg_cpu_addr = x"00F3" then
        assert dbg_cpu_data = x"80"
          report "kernel SCRPTR_HI init mismatch"
          severity failure;

        saw_scrptr_hi <= true;
      end if;

      if saw_reset_fetch and saw_via_ddra and saw_scrptr_lo and saw_scrptr_hi then
        report "tb_sbc_t65_kernel_smoke passed";
        stop;
      end if;
    end loop;

    assert false
      report "kernel smoke test did not observe expected early activity"
      severity failure;
  end process;
end architecture;
