library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_via6522 is
end entity;

architecture sim of tb_via6522 is
  signal clk       : std_logic := '0';
  signal reset_n   : std_logic := '0';
  signal cs        : std_logic := '0';
  signal we        : std_logic := '0';
  signal addr      : addr_t := x"8800";
  signal din       : data_t := (others => '0');
  signal dout      : data_t;
  signal porta_in  : data_t := x"0F";
  signal portb_in  : data_t := x"F0";
  signal porta_out : data_t;
  signal portb_out : data_t;
  signal irq       : std_logic;

  procedure bus_write(
    signal p_clk  : in  std_logic;
    signal p_cs   : out std_logic;
    signal p_we   : out std_logic;
    signal p_addr : out addr_t;
    signal p_din  : out data_t;
    constant a  : in  addr_t;
    constant d  : in  data_t
  ) is
  begin
    p_addr <= a;
    p_din <= d;
    p_we <= '1';
    p_cs <= '1';
    wait until rising_edge(p_clk);
    wait for 1 ns;
    p_cs <= '0';
    p_we <= '0';
    wait until rising_edge(p_clk);
  end procedure;

  procedure bus_read(
    signal p_clk  : in  std_logic;
    signal p_cs   : out std_logic;
    signal p_we   : out std_logic;
    signal p_addr : out addr_t;
    constant a  : in  addr_t
  ) is
  begin
    p_addr <= a;
    p_we <= '0';
    p_cs <= '1';
    wait until rising_edge(p_clk);
    wait for 1 ns;
  end procedure;
begin
  clk <= not clk after 5 ns;

  dut : entity work.via6522
    port map (
      clk       => clk,
      reset_n   => reset_n,
      cs        => cs,
      we        => we,
      addr      => addr,
      din       => din,
      dout      => dout,
      porta_in  => porta_in,
      portb_in  => portb_in,
      porta_out => porta_out,
      portb_out => portb_out,
      irq       => irq
    );

  process
  begin
    wait for 25 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    bus_write(clk, cs, we, addr, din, x"8802", x"F0");
    bus_write(clk, cs, we, addr, din, x"8800", x"AA");
    bus_read(clk, cs, we, addr, x"8800");

    assert dout = x"A0"
      report "VIA ORB mixed port read mismatch"
      severity failure;

    assert portb_out = x"A0"
      report "VIA port B output mask mismatch"
      severity failure;

    cs <= '0';
    wait until rising_edge(clk);

    bus_write(clk, cs, we, addr, din, x"880E", x"C0");

    assert irq = '0'
      report "VIA IRQ unexpectedly active without flags"
      severity failure;

    bus_write(clk, cs, we, addr, din, x"8804", x"01");
    bus_write(clk, cs, we, addr, din, x"8805", x"00");
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    assert irq = '1'
      report "VIA T1 IRQ did not assert"
      severity failure;

    bus_read(clk, cs, we, addr, x"880D");

    assert dout(7) = '1' and dout(6) = '1'
      report "VIA IFR T1/ANY bits mismatch"
      severity failure;

    bus_read(clk, cs, we, addr, x"8804");
    bus_read(clk, cs, we, addr, x"880D");

    assert dout(6) = '0'
      report "VIA T1CL read should clear T1 flag"
      severity failure;

    bus_read(clk, cs, we, addr, x"880E");

    assert dout = x"C0"
      report "VIA IER read mismatch"
      severity failure;

    report "tb_via6522 passed";
    stop;
  end process;
end architecture;
