library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_sbc_bus_write is
end entity;

architecture sim of tb_sbc_bus_write is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal uart_rx      : std_logic := '1';
  signal uart_tx      : std_logic;
  signal irq_out      : std_logic;
  signal dbg_cpu_addr : addr_t;
  signal dbg_cpu_data : data_t;
  signal dbg_cpu_we   : std_logic;
  signal dbg_read_data  : data_t;
  signal dbg_read_valid : std_logic;
begin
  clk <= not clk after 5 ns;

  dut : entity work.sbc_top
    generic map (
      ROM_INIT_FILE => "sim/hex/rom_bus_write.hex"
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
      dbg_read_data  => dbg_read_data,
      dbg_read_valid => dbg_read_valid
    );

  process
  begin
    wait for 25 ns;
    reset_n <= '1';

    for i in 0 to 32 loop
      wait until rising_edge(clk);

      if dbg_cpu_we = '1' then
        report "write addr=$" & to_hstring(dbg_cpu_addr) &
               " data=$" & to_hstring(dbg_cpu_data);

        assert dbg_cpu_addr = x"0002"
          report "script write address mismatch"
          severity failure;

        assert dbg_cpu_data = x"42"
          report "script write data mismatch"
          severity failure;

        report "tb_sbc_bus_write passed";
        stop;
      end if;
    end loop;

    assert false
      report "script write did not occur"
      severity failure;
  end process;
end architecture;
