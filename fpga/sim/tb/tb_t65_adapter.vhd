library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_t65_adapter is
end entity;

architecture sim of tb_t65_adapter is
  signal clk      : std_logic := '0';
  signal reset_n  : std_logic := '0';
  signal data_in  : data_t := x"EA";
  signal addr     : addr_t;
  signal data_out : data_t;
  signal we       : std_logic;
  signal sync     : std_logic;
begin
  clk <= not clk after 5 ns;

  dut : entity work.t65_adapter
    port map (
      clk      => clk,
      reset_n  => reset_n,
      enable   => '1',
      irq_n    => '1',
      nmi_n    => '1',
      data_in  => data_in,
      addr     => addr,
      data_out => data_out,
      we       => we,
      sync     => sync
    );

  process
  begin
    wait for 35 ns;
    reset_n <= '1';

    for i in 0 to 32 loop
      wait until rising_edge(clk);

      assert not is_x(addr)
        report "T65 adapter produced an unknown address"
        severity failure;

      assert not is_x(we)
        report "T65 adapter produced an unknown write-enable"
        severity failure;
    end loop;

    report "tb_t65_adapter passed";
    stop;
  end process;
end architecture;

