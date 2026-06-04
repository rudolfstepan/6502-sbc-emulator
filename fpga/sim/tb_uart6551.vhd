library ieee;
use ieee.std_logic_1164.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_uart6551 is
end entity;

architecture sim of tb_uart6551 is
  signal clk      : std_logic := '0';
  signal reset_n  : std_logic := '0';
  signal cs       : std_logic := '0';
  signal we       : std_logic := '0';
  signal addr     : addr_t := x"8810";
  signal din      : data_t := (others => '0');
  signal dout     : data_t;
  signal rx_data  : data_t := (others => '0');
  signal rx_valid : std_logic := '0';
  signal tx_data  : data_t;
  signal tx_valid : std_logic;
  signal irq      : std_logic;

  procedure bus_write(
    signal p_clk  : in  std_logic;
    signal p_cs   : out std_logic;
    signal p_we   : out std_logic;
    signal p_addr : out addr_t;
    signal p_din  : out data_t;
    constant a    : in  addr_t;
    constant d    : in  data_t
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
    constant a    : in  addr_t
  ) is
  begin
    p_addr <= a;
    p_we <= '0';
    p_cs <= '1';
    wait until rising_edge(p_clk);
    wait for 1 ns;
  end procedure;

  procedure inject_rx(
    signal p_clk      : in  std_logic;
    signal p_rx_data  : out data_t;
    signal p_rx_valid : out std_logic;
    constant d        : in  data_t
  ) is
  begin
    p_rx_data <= d;
    p_rx_valid <= '1';
    wait until rising_edge(p_clk);
    wait for 1 ns;
    p_rx_valid <= '0';
    wait until rising_edge(p_clk);
  end procedure;
begin
  clk <= not clk after 5 ns;

  dut : entity work.uart6551
    port map (
      clk      => clk,
      reset_n  => reset_n,
      cs       => cs,
      we       => we,
      addr     => addr,
      din      => din,
      dout     => dout,
      rx_data  => rx_data,
      rx_valid => rx_valid,
      tx_data  => tx_data,
      tx_valid => tx_valid,
      irq      => irq
    );

  process
  begin
    wait for 25 ns;
    reset_n <= '1';
    wait until rising_edge(clk);

    bus_read(clk, cs, we, addr, x"8811");

    assert dout = x"10"
      report "UART reset status mismatch"
      severity failure;

    cs <= '0';
    wait until rising_edge(clk);

    bus_write(clk, cs, we, addr, din, x"8810", x"55");

    assert tx_data = x"55"
      report "UART TX data mismatch"
      severity failure;

    inject_rx(clk, rx_data, rx_valid, x"33");
    bus_read(clk, cs, we, addr, x"8811");

    assert dout(3) = '1'
      report "UART RDRF did not set"
      severity failure;

    bus_read(clk, cs, we, addr, x"8810");

    assert dout = x"33"
      report "UART RX data mismatch"
      severity failure;

    cs <= '0';
    wait until rising_edge(clk);
    bus_read(clk, cs, we, addr, x"8811");

    assert dout(3) = '0'
      report "UART DATA read did not clear RDRF"
      severity failure;

    cs <= '0';
    wait until rising_edge(clk);
    bus_write(clk, cs, we, addr, din, x"8812", x"01");
    inject_rx(clk, rx_data, rx_valid, x"44");
    bus_read(clk, cs, we, addr, x"8811");

    assert dout(7) = '1' and irq = '1'
      report "UART RX IRQ did not assert"
      severity failure;

    inject_rx(clk, rx_data, rx_valid, x"45");
    bus_read(clk, cs, we, addr, x"8811");

    assert dout(2) = '1'
      report "UART overrun flag did not set"
      severity failure;

    bus_write(clk, cs, we, addr, din, x"8811", x"00");
    bus_read(clk, cs, we, addr, x"8811");

    assert dout = x"10"
      report "UART programmed reset mismatch"
      severity failure;

    report "tb_uart6551 passed";
    stop;
  end process;
end architecture;

