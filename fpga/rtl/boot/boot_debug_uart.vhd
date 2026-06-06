-- UART debug message generator for the SD boot path.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity boot_debug_uart is
  generic (
    STATUS_DIV : positive := 25_000_000
  );
  port (
    clk             : in  std_logic;
    reset_n         : in  std_logic;

    sd_init_done    : in  std_logic;
    sd_sec_read     : in  std_logic;
    sd_sec_read_end : in  std_logic;
    boot_done       : in  std_logic;
    boot_error      : in  std_logic;

    sd_ncs          : in  std_logic;
    sd_dclk         : in  std_logic;
    sd_mosi_o       : in  std_logic;
    sd_miso_i       : in  std_logic;
    loader_state    : in  std_logic_vector(3 downto 0);
    sd_sec_state    : in  std_logic_vector(4 downto 0);
    sd_cmd_state    : in  std_logic_vector(3 downto 0);
    sd_cmd_error    : in  std_logic;

    uart_busy       : in  std_logic;
    uart_data       : out data_t;
    uart_valid      : out std_logic;
    active          : out std_logic
  );
end entity;

architecture rtl of boot_debug_uart is
  type state_t is (
    S_BOOT_0, S_BOOT_1, S_BOOT_2, S_BOOT_3, S_BOOT_4, S_BOOT_5, S_BOOT_6, S_BOOT_7,
    S_IDLE,
    S_INIT,
    S_REQ,
    S_END,
    S_STAT_0, S_STAT_1, S_STAT_2, S_STAT_3, S_STAT_4, S_STAT_5, S_STAT_6,
    S_STAT_7, S_STAT_8, S_STAT_9, S_STAT_10, S_STAT_11, S_STAT_12, S_STAT_13,
    S_STAT_14, S_STAT_15,
    S_DONE_0, S_DONE_1, S_DONE_2,
    S_ERR_0, S_ERR_1, S_ERR_2,
    S_FINISHED
  );

  signal state       : state_t := S_BOOT_0;
  signal prev_init   : std_logic := '0';
  signal prev_read   : std_logic := '0';
  signal prev_end    : std_logic := '0';
  signal prev_done   : std_logic := '0';
  signal prev_error  : std_logic := '0';
  signal pend_init   : std_logic := '0';
  signal pend_read   : std_logic := '0';
  signal pend_end    : std_logic := '0';
  signal pend_done   : std_logic := '0';
  signal pend_error  : std_logic := '0';
  signal pend_status : std_logic := '0';
  signal data_reg    : data_t := (others => '0');
  signal valid_reg   : std_logic := '0';
  signal active_reg  : std_logic := '1';
  signal wait_uart   : std_logic := '0';
  signal seen_busy   : std_logic := '0';
  signal status_cnt  : natural range 0 to STATUS_DIV - 1 := 0;

  function hex_char(v : std_logic_vector(3 downto 0)) return data_t is
    variable n : unsigned(3 downto 0);
  begin
    n := unsigned(v);
    if n < 10 then
      return std_logic_vector(to_unsigned(48 + to_integer(n), 8));
    end if;
    return std_logic_vector(to_unsigned(55 + to_integer(n), 8));
  end function;

  function msg_byte(s : state_t) return data_t is
  begin
    case s is
      when S_BOOT_0  => return x"0D";
      when S_BOOT_1  => return x"0A";
      when S_BOOT_2  => return x"42"; -- B
      when S_BOOT_3  => return x"4F"; -- O
      when S_BOOT_4  => return x"4F"; -- O
      when S_BOOT_5  => return x"54"; -- T
      when S_BOOT_6  => return x"0D";
      when S_BOOT_7  => return x"0A";
      when S_INIT    => return x"49"; -- I: SD init done
      when S_REQ     => return x"52"; -- R: sector read requested
      when S_END     => return x"45"; -- E: sector read ended
      when S_STAT_0  => return x"0D";
      when S_STAT_1  => return x"0A";
      when S_STAT_2  => return x"50"; -- P: pins/state frame
      when S_STAT_4  => return x"4C"; -- L: loader state
      when S_STAT_6  => return x"53"; -- S: SD sector state
      when S_STAT_9  => return x"43"; -- C: SD command state
      when S_STAT_11 => return x"46"; -- F: flags
      when S_STAT_13 => return x"0D";
      when S_STAT_14 => return x"0A";
      when S_DONE_0  => return x"44"; -- D: boot done
      when S_DONE_1  => return x"0D";
      when S_DONE_2  => return x"0A";
      when S_ERR_0   => return x"58"; -- X: boot error
      when S_ERR_1   => return x"0D";
      when S_ERR_2   => return x"0A";
      when others    => return x"3F";
    end case;
  end function;

  function next_msg_state(s : state_t) return state_t is
  begin
    case s is
      when S_BOOT_0  => return S_BOOT_1;
      when S_BOOT_1  => return S_BOOT_2;
      when S_BOOT_2  => return S_BOOT_3;
      when S_BOOT_3  => return S_BOOT_4;
      when S_BOOT_4  => return S_BOOT_5;
      when S_BOOT_5  => return S_BOOT_6;
      when S_BOOT_6  => return S_BOOT_7;
      when S_BOOT_7  => return S_IDLE;
      when S_STAT_0  => return S_STAT_1;
      when S_STAT_1  => return S_STAT_2;
      when S_STAT_2  => return S_STAT_3;
      when S_STAT_3  => return S_STAT_4;
      when S_STAT_4  => return S_STAT_5;
      when S_STAT_5  => return S_STAT_6;
      when S_STAT_6  => return S_STAT_7;
      when S_STAT_7  => return S_STAT_8;
      when S_STAT_8  => return S_STAT_9;
      when S_STAT_9  => return S_STAT_10;
      when S_STAT_10 => return S_STAT_11;
      when S_STAT_11 => return S_STAT_12;
      when S_STAT_12 => return S_STAT_13;
      when S_STAT_13 => return S_STAT_14;
      when S_STAT_14 => return S_STAT_15;
      when S_STAT_15 => return S_IDLE;
      when S_DONE_0  => return S_DONE_1;
      when S_DONE_1  => return S_DONE_2;
      when S_DONE_2  => return S_FINISHED;
      when S_ERR_0   => return S_ERR_1;
      when S_ERR_1   => return S_ERR_2;
      when S_ERR_2   => return S_IDLE;
      when others    => return S_IDLE;
    end case;
  end function;

  function state_byte(
    s         : state_t;
    pins      : std_logic_vector(3 downto 0);
    ldr       : std_logic_vector(3 downto 0);
    sec       : std_logic_vector(4 downto 0);
    cmd       : std_logic_vector(3 downto 0);
    flags     : std_logic_vector(3 downto 0)
  ) return data_t is
  begin
    case s is
      when S_STAT_3  => return hex_char(pins);
      when S_STAT_5  => return hex_char(ldr);
      when S_STAT_7  => return hex_char("000" & sec(4));
      when S_STAT_8  => return hex_char(sec(3 downto 0));
      when S_STAT_10 => return hex_char(cmd);
      when S_STAT_12 => return hex_char(flags);
      when others    => return msg_byte(s);
    end case;
  end function;
begin
  uart_data  <= data_reg;
  uart_valid <= valid_reg;
  active     <= active_reg;

  process(clk)
    variable pins_v  : std_logic_vector(3 downto 0);
    variable flags_v : std_logic_vector(3 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state       <= S_BOOT_0;
        prev_init   <= '0';
        prev_read   <= '0';
        prev_end    <= '0';
        prev_done   <= '0';
        prev_error  <= '0';
        pend_init   <= '0';
        pend_read   <= '0';
        pend_end    <= '0';
        pend_done   <= '0';
        pend_error  <= '0';
        pend_status <= '0';
        data_reg    <= (others => '0');
        valid_reg   <= '0';
        active_reg  <= '1';
        wait_uart   <= '0';
        seen_busy   <= '0';
        status_cnt  <= 0;
      else
        valid_reg <= '0';

        prev_init  <= sd_init_done;
        prev_read  <= sd_sec_read;
        prev_end   <= sd_sec_read_end;
        prev_done  <= boot_done;
        prev_error <= boot_error;

        if sd_init_done = '1' and prev_init = '0' then
          pend_init <= '1';
        end if;
        if sd_sec_read = '1' and prev_read = '0' then
          pend_read <= '1';
        end if;
        if sd_sec_read_end = '1' and prev_end = '0' then
          pend_end <= '1';
        end if;
        if boot_done = '1' and prev_done = '0' then
          pend_done <= '1';
        end if;
        if boot_error = '1' and prev_error = '0' then
          pend_error <= '1';
        end if;

        if active_reg = '1' then
          if status_cnt = STATUS_DIV - 1 then
            status_cnt <= 0;
            pend_status <= '1';
          else
            status_cnt <= status_cnt + 1;
          end if;
        end if;

        if wait_uart = '1' then
          if uart_busy = '1' then
            seen_busy <= '1';
          elsif seen_busy = '1' then
            wait_uart <= '0';
            seen_busy <= '0';
          end if;
        elsif uart_busy = '0' then
          pins_v  := sd_ncs & sd_dclk & sd_mosi_o & sd_miso_i;
          flags_v := boot_done & boot_error & sd_init_done & sd_cmd_error;

          case state is
            when S_IDLE =>
              if pend_error = '1' then
                data_reg <= msg_byte(S_ERR_0);
                valid_reg <= '1';
                wait_uart <= '1';
                pend_error <= '0';
                state <= S_ERR_1;
              elsif pend_done = '1' then
                data_reg <= msg_byte(S_DONE_0);
                valid_reg <= '1';
                wait_uart <= '1';
                pend_done <= '0';
                state <= S_DONE_1;
              elsif pend_init = '1' then
                data_reg <= msg_byte(S_INIT);
                valid_reg <= '1';
                wait_uart <= '1';
                pend_init <= '0';
              elsif pend_read = '1' then
                data_reg <= msg_byte(S_REQ);
                valid_reg <= '1';
                wait_uart <= '1';
                pend_read <= '0';
              elsif pend_end = '1' then
                data_reg <= msg_byte(S_END);
                valid_reg <= '1';
                wait_uart <= '1';
                pend_end <= '0';
              elsif pend_status = '1' then
                data_reg <= msg_byte(S_STAT_0);
                valid_reg <= '1';
                wait_uart <= '1';
                pend_status <= '0';
                state <= S_STAT_1;
              end if;

            when S_FINISHED =>
              active_reg <= '0';

            when others =>
              data_reg <= state_byte(state, pins_v, loader_state, sd_sec_state, sd_cmd_state, flags_v);
              valid_reg <= '1';
              wait_uart <= '1';
              state <= next_msg_state(state);
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
