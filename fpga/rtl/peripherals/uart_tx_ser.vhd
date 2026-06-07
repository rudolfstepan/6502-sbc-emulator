-- UART 8N1 Serializer
-- Converts parallel byte + valid-pulse to a physical RS-232 bit stream.
-- Default: 230400 baud @ 50 MHz.  Change generics as needed.
--
-- Protocol: 1 start bit (low), 8 data bits LSB-first, 1 stop bit (high).
-- 'busy' is high from the start bit until the stop bit completes.
-- A new 'valid' pulse while busy is ignored.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx_ser is
  generic (
    CLK_HZ : positive := 50_000_000;
    BAUD   : positive := 230_400
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    data    : in  std_logic_vector(7 downto 0);
    valid   : in  std_logic;   -- one-clock pulse: load data and start
    tx      : out std_logic;
    busy    : out std_logic
  );
end entity;

architecture rtl of uart_tx_ser is

  constant BAUD_DIV : positive := CLK_HZ / BAUD;  -- clocks per bit period

  -- 10 bits total: [0]=start, [1..8]=data LSB-first, [9]=stop
  signal sr       : std_logic_vector(9 downto 0);
  signal baud_cnt : unsigned(8 downto 0);          -- 0 .. BAUD_DIV-1
  signal bit_cnt  : unsigned(3 downto 0);          -- 0 .. 9
  signal active   : std_logic;

begin

  busy <= active;
  tx   <= sr(0) when active = '1' else '1';        -- idle high

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        active   <= '0';
        baud_cnt <= (others => '0');
        bit_cnt  <= (others => '0');
        sr       <= (others => '1');
      else
        if active = '0' then
          if valid = '1' then
            -- Load: start(0) + 8 data bits + stop(1)
            sr       <= '1' & data(7) & data(6) & data(5) & data(4) &
                              data(3) & data(2) & data(1) & data(0) & '0';
            baud_cnt <= (others => '0');
            bit_cnt  <= (others => '0');
            active   <= '1';
          end if;
        else
          if baud_cnt = BAUD_DIV - 1 then
            baud_cnt <= (others => '0');
            sr       <= '1' & sr(9 downto 1);      -- shift out LSB
            if bit_cnt = 9 then
              active <= '0';                        -- stop bit sent
            else
              bit_cnt <= bit_cnt + 1;
            end if;
          else
            baud_cnt <= baud_cnt + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
