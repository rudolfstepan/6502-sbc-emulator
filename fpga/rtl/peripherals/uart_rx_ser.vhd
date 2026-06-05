-- UART 8N1 Deserializer
-- Receives serial bytes from an RS-232 / USB-UART input pin and outputs
-- the byte as a parallel word with a one-clock valid pulse.
-- Default: 115200 baud @ 50 MHz.  Includes a 2-stage input synchroniser.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx_ser is
  generic (
    CLK_HZ : positive := 50_000_000;
    BAUD   : positive := 115_200
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    rx      : in  std_logic;           -- serial input (idle high)
    data    : out std_logic_vector(7 downto 0);
    valid   : out std_logic            -- one-clock pulse per received byte
  );
end entity;

architecture rtl of uart_rx_ser is

  constant BAUD_DIV : positive := CLK_HZ / BAUD;   -- clocks per bit: 434
  constant HALF_DIV : positive := BAUD_DIV / 2;    -- mid-bit sample offset: 217

  type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
  signal state    : state_t;
  signal baud_cnt : unsigned(8 downto 0);           -- 0 .. 433
  signal bit_cnt  : unsigned(2 downto 0);           -- 0 .. 7
  signal sr       : std_logic_vector(7 downto 0);
  signal rx_sync  : std_logic_vector(1 downto 0);   -- 2-stage synchroniser
  signal rx_s     : std_logic;
  signal valid_r  : std_logic;
  signal data_r   : std_logic_vector(7 downto 0);

begin

  data  <= data_r;
  valid <= valid_r;
  rx_s  <= rx_sync(1);

  -- Input synchroniser (metastability protection)
  process(clk)
  begin
    if rising_edge(clk) then
      rx_sync <= rx_sync(0) & rx;
    end if;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state    <= S_IDLE;
        baud_cnt <= (others => '0');
        bit_cnt  <= (others => '0');
        sr       <= (others => '0');
        valid_r  <= '0';
        data_r   <= (others => '0');
      else
        valid_r <= '0';

        case state is

          when S_IDLE =>
            if rx_s = '0' then          -- start bit detected (line went low)
              baud_cnt <= (others => '0');
              state    <= S_START;
            end if;

          when S_START =>
            -- Wait HALF_DIV clocks to sample at the centre of the start bit
            if baud_cnt = HALF_DIV - 1 then
              baud_cnt <= (others => '0');
              bit_cnt  <= (others => '0');
              state    <= S_DATA;
            else
              baud_cnt <= baud_cnt + 1;
            end if;

          when S_DATA =>
            -- Sample one bit per BAUD_DIV clocks, LSB first
            if baud_cnt = BAUD_DIV - 1 then
              baud_cnt <= (others => '0');
              sr       <= rx_s & sr(7 downto 1);   -- shift right, rx into MSB
              if bit_cnt = 7 then
                state   <= S_STOP;
                bit_cnt <= (others => '0');
              else
                bit_cnt <= bit_cnt + 1;
              end if;
            else
              baud_cnt <= baud_cnt + 1;
            end if;

          when S_STOP =>
            -- Wait one bit time; accept only if stop bit is high
            if baud_cnt = BAUD_DIV - 1 then
              baud_cnt <= (others => '0');
              if rx_s = '1' then
                data_r  <= sr;
                valid_r <= '1';
              end if;
              state <= S_IDLE;
            else
              baud_cnt <= baud_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;
