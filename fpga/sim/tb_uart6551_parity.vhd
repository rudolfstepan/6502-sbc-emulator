-- Testbench for UART6551 Parity Support
-- Tests parity generation, error detection, and stop bits configuration
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_uart6551_parity is
end entity;

architecture test of tb_uart6551_parity is
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

  -- Parity bit calculation helper for bits 0-6 (bit 7 is the parity bit)
  function calc_parity_8bit(data : data_t; mode : std_logic) return std_logic is
    variable p : std_logic;
  begin
    p := data(0) xor data(1) xor data(2) xor data(3) xor
         data(4) xor data(5) xor data(6);  -- Only bits 0-6
    if mode = '0' then
      return not p;  -- Odd parity
    else
      return p;      -- Even parity
    end if;
  end function;

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
    variable parity_bit : std_logic;
    variable status : data_t;
  begin
    reset_n <= '0';
    wait for 50 ns;
    reset_n <= '1';
    wait for 50 ns;

    report "UART Parity Support Test" severity note;
    report "" severity note;

    -- Test 1: Configure odd parity, 8-bit data, 1 stop bit
    report "Test 1: Configure odd parity + 8-bit data + 1 stop bit" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";  -- CTRL register
    -- CTRL[7:6]=00 (odd), CTRL[5]=1 (parity enable), CTRL[4]=0 (1 stop bit)
    -- CTRL[3:2]=01 (9600 baud), CTRL[1:0]=11 (8-bit data)
    din <= x"73";     -- Binary: 01110011
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"73" then
      report "  PASS: Parity config set (0x73)" severity note;
    else
      report "  FAIL: Expected 0x73, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 2: Configure even parity, 7-bit data, 2 stop bits
    report "" severity note;
    report "Test 2: Configure even parity + 7-bit data + 2 stop bits" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    -- CTRL[7:6]=01 (even), CTRL[5]=1 (parity enable), CTRL[4]=1 (2 stop bits)
    -- CTRL[3:2]=01 (9600 baud), CTRL[1:0]=10 (7-bit data)
    din <= x"7A";     -- Binary: 01111010
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"7A" then
      report "  PASS: Even parity config set (0x7A)" severity note;
    else
      report "  FAIL: Expected 0x7A, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 3: Parity disabled, 8-bit data, 2 stop bits
    report "" severity note;
    report "Test 3: Configure no parity + 8-bit data + 2 stop bits" severity note;
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    -- CTRL[5]=0 (parity disabled), CTRL[4]=1 (2 stop bits)
    -- CTRL[3:2]=01 (9600 baud), CTRL[1:0]=11 (8-bit data)
    din <= x"1B";     -- Binary: 00011011
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    cs <= '1';
    we <= '0';
    addr <= x"8813";
    wait for CLK_PERIOD;
    if dout = x"1B" then
      report "  PASS: No parity config set (0x1B)" severity note;
    else
      report "  FAIL: Expected 0x1B, got 0x" & to_hstring(dout) severity error;
    end if;
    cs <= '0';

    -- Test 4: Test parity error detection with odd parity
    report "" severity note;
    report "Test 4: Parity error detection (odd parity)" severity note;
    -- Configure odd parity, 8-bit
    cs <= '1';
    we <= '1';
    addr <= x"8813";
    din <= x"63";     -- Odd parity, 8-bit, 1 stop, 9600 baud
    wait for CLK_PERIOD;
    cs <= '0';
    we <= '0';
    wait for CLK_PERIOD * 2;

    -- Send RX data with correct parity: 0x5A = 01011010
    -- XOR = 0, so odd parity bit should be 1: 0x80 | 0x5A = 0xDA
    report "  Sending valid odd parity data: 0x5A with parity bit" severity note;
    parity_bit := calc_parity_8bit(x"5A", '0');  -- Odd parity
    -- Create 8-bit value: parity in bit 7
    -- 0x5A = 01011010, 0xDA = 11011010
    if parity_bit = '1' then
      rx_data <= x"DA";  -- Parity bit = 1 in bit 7
    else
      rx_data <= x"5A";  -- Parity bit = 0 in bit 7
    end if;
    rx_valid <= '1';
    wait for CLK_PERIOD;
    rx_valid <= '0';
    wait for CLK_PERIOD * 2;

    -- Read status register to check for parity error
    cs <= '1';
    we <= '0';
    addr <= x"8811";  -- STATUS register
    wait for CLK_PERIOD;
    status := dout;
    if status(0) = '0' then
      report "  PASS: No parity error with valid parity (0x" & to_hstring(status) & ")" severity note;
    else
      report "  FAIL: Unexpected parity error" severity error;
    end if;
    cs <= '0';

    -- Test 5: Send RX data with wrong parity
    report "" severity note;
    report "Test 5: Detect parity error (wrong parity)" severity note;
    -- Send data with WRONG parity (inverted)
    if parity_bit = '1' then
      rx_data <= x"5A";  -- Wrong: should be DA but sending 5A
    else
      rx_data <= x"DA";  -- Wrong: should be 5A but sending DA
    end if;
    rx_valid <= '1';
    wait for CLK_PERIOD;
    rx_valid <= '0';
    wait for CLK_PERIOD * 2;

    -- Read status register to check for parity error
    cs <= '1';
    we <= '0';
    addr <= x"8811";
    wait for CLK_PERIOD;
    status := dout;
    if status(0) = '1' then
      report "  PASS: Parity error detected (0x" & to_hstring(status) & ")" severity note;
    else
      report "  FAIL: Parity error not detected" severity error;
    end if;
    cs <= '0';

    report "" severity note;
    report "========================================" severity note;
    report "UART Parity Support Tests Complete" severity note;
    report "========================================" severity note;
    wait;
  end process;

end architecture;
