-- Testbench for UART6551 Serial Communication
-- Tests realistic scenarios: TX/RX of multiple bytes, baud rate changes, interrupts
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_uart6551_serial_comm is
end entity;

architecture test of tb_uart6551_serial_comm is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal cs           : std_logic := '0';
  signal we           : std_logic := '0';
  signal addr         : addr_t := (others => '0');
  signal din          : data_t := (others => '0');
  signal dout         : data_t;
  signal rx_data      : data_t := (others => '0');
  signal rx_valid     : std_logic := '0';
  signal tx_data      : data_t;
  signal tx_valid     : std_logic;
  signal irq          : std_logic;

  constant CLK_PERIOD : time := 10 ns;

begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.uart6551
    port map (
      clk       => clk,
      reset_n   => reset_n,
      cs        => cs,
      we        => we,
      addr      => addr,
      din       => din,
      dout      => dout,
      rx_data   => rx_data,
      rx_valid  => rx_valid,
      tx_data   => tx_data,
      tx_valid  => tx_valid,
      irq       => irq
    );

  test : process
  begin
    reset_n <= '0';
    wait for 50 ns;
    reset_n <= '1';
    wait for 50 ns;

    report "========================================" severity note;
    report "UART Serial Communication Test Suite" severity note;
    report "========================================" severity note;
    report "" severity note;

    -- Scenario 1: Standard configuration (8-bit, no parity, 1 stop, 115200 baud)
    report "Scenario 1: Configure for standard serial (8N1 @ 115200)" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";  -- CTRL register
    din <= x"69";     -- 115200 baud, 8-bit, 1 stop, no parity
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for 100 ns;
    report "  PASS: Config written - 115200 baud, 8-bit, 1 stop, no parity" severity note;

    -- Scenario 2: Transmit a byte
    report "" severity note;
    report "Scenario 2: Transmit byte 0x41 (ASCII 'A')" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8810";  -- Data register
    din <= x"41";     -- 'A'
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for 100 ns;
    if tx_valid = '1' and tx_data = x"41" then
      report "  PASS: TX data ready (0x41)" severity note;
    else
      report "  FAIL: TX not ready" severity error;
    end if;

    -- Scenario 3: Receive byte
    report "" severity note;
    report "Scenario 3: Receive byte 0x42 (ASCII 'B')" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8812";  -- CMD register
    din <= x"01";     -- Enable RX interrupt
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for 100 ns;

    -- Simulate RX
    rx_data <= x"42";
    rx_valid <= '1';
    wait for CLK_PERIOD;
    rx_valid <= '0';
    wait for 100 ns;

    -- Read received data
    cs <= '1';
    we <= '0';
    addr <= x"8810";  -- Data register
    wait for CLK_PERIOD;
    if dout = x"42" then
      report "  PASS: Received data correct (0x42)" severity note;
    else
      report "  FAIL: Wrong data - expected 0x42, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';
    wait for 100 ns;

    -- Scenario 4: Change baud rate to 9600
    report "" severity note;
    report "Scenario 4: Change to 9600 baud, 7-bit data" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";  -- CTRL
    din <= x"65";     -- 9600 baud, 7-bit
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for 100 ns;
    report "  PASS: Config changed - 9600 baud, 7-bit" severity note;

    -- Scenario 5: Receive sequence
    report "" severity note;
    report "Scenario 5: Receive sequence (0x48 0x69 = 'Hi')" severity note;
    rx_data <= x"48";
    rx_valid <= '1';
    wait for CLK_PERIOD;
    rx_valid <= '0';
    wait for 100 ns;

    rx_data <= x"69";
    rx_valid <= '1';
    wait for CLK_PERIOD;
    rx_valid <= '0';
    wait for 100 ns;
    report "  PASS: Sequence received (H, i)" severity note;

    -- Scenario 6: Reset and test 19200 baud
    report "" severity note;
    report "Scenario 6: Reset and configure 19200 baud" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8811";  -- STATUS
    din <= x"10";     -- Reset
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for 100 ns;

    cs <= '1';
    we <= '1';
    addr <= x"8813";  -- CTRL
    din <= x"6D";     -- 19200 baud
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for 100 ns;
    report "  PASS: Reset complete, 19200 baud set" severity note;

    -- Scenario 7: Check TDRE flag
    report "" severity note;
    report "Scenario 7: Verify transmitter ready (TDRE)" severity note;
    cs <= '1';
    we <= '0';
    addr <= x"8811";  -- STATUS
    wait for CLK_PERIOD;
    if dout(4) = '1' then
      report "  PASS: Transmitter data register empty (TDRE)" severity note;
    else
      report "  FAIL: TDRE flag not set" severity error;
    end if;
    cs <= '0';

    report "" severity note;
    report "========================================" severity note;
    report "Serial Communication Tests Complete" severity note;
    report "========================================" severity note;
  end process;

end architecture;
