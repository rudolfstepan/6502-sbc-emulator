-- Test Runner: Button-triggered display test routines for PIX16 board
-- 4 buttons select different tests; auto-runs test 0 on reset
--
-- key[0]: Welcome message  (clear + "WELCOME TO 6502 SBC!" centered)
-- key[1]: Clear screen     (fill all 40x25 with spaces)
-- key[2]: All characters   (fill screen with cycling printable chars 0x20-0x7F)
-- key[3]: Character table  (clear + 6x16 grid of all 96 printable chars)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity test_runner is
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    key     : in  std_logic_vector(3 downto 0);  -- active-low push buttons
    addr    : out addr_t;
    dout    : out data_t;
    we      : out std_logic
  );
end entity;

architecture rtl of test_runner is
  -- 20 ms debounce at 50 MHz
  constant DEBOUNCE_CYCLES : natural := 1_000_000;

  type db_arr_t is array (0 to 3) of natural range 0 to DEBOUNCE_CYCLES;
  signal db_cnt   : db_arr_t := (others => 0);
  signal key_sync : std_logic_vector(3 downto 0) := "1111";
  signal key_puls : std_logic_vector(3 downto 0) := "0000";

  type state_t is (IDLE, WRITE_SETUP, WRITE_ASSERT);
  signal state       : state_t := WRITE_SETUP;  -- auto-start test 0 on power-up
  signal active_test : natural range 0 to 3 := 0;
  signal wr_index    : natural range 0 to 1099 := 0;
  signal addr_reg    : addr_t := (others => '0');
  signal data_reg    : data_t := (others => '0');

  -- Welcome message: "WELCOME TO 6502 SBC!" (20 chars)
  type msg20_t is array (0 to 19) of data_t;
  constant WELCOME_MSG : msg20_t := (
    x"57", x"45", x"4C", x"43", x"4F", x"4D", x"45", x"20",
    x"54", x"4F", x"20", x"36", x"35", x"30", x"32", x"20",
    x"53", x"42", x"43", x"21"
  );
  -- Centered in 40-col display: row 12, col 10  =>  offset = 12*40+10 = 490
  constant WELCOME_OFFSET : natural := 12 * 40 + 10;

  -- Char table: 6 rows x 16 cols at row 9, col 12  =>  offset = 9*40+12 = 372
  constant TABLE_OFFSET : natural := 9 * 40 + 12;

begin
  addr <= addr_reg;
  dout <= data_reg;

  -- Button debounce + falling-edge (press) detection
  process(clk)
  begin
    if rising_edge(clk) then
      key_puls <= "0000";
      if reset_n = '0' then
        key_sync <= "1111";
        db_cnt   <= (others => 0);
      else
        for i in 0 to 3 loop
          if key(i) = key_sync(i) then
            db_cnt(i) <= 0;
          elsif db_cnt(i) = DEBOUNCE_CYCLES - 1 then
            db_cnt(i)   <= 0;
            key_sync(i) <= key(i);
            if key(i) = '0' then
              key_puls(i) <= '1';
            end if;
          else
            db_cnt(i) <= db_cnt(i) + 1;
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- Main sequencer FSM
  process(clk)
    variable va   : natural range 0 to 65535;
    variable vd   : natural range 0 to 255;
    variable vi   : natural range 0 to 1099;
    variable done : boolean;
  begin
    if rising_edge(clk) then
      we <= '0';
      if reset_n = '0' then
        state       <= WRITE_SETUP;
        active_test <= 0;
        wr_index    <= 0;
        addr_reg    <= (others => '0');
        data_reg    <= (others => '0');
      else
        case state is

          when IDLE =>
            for i in 0 to 3 loop
              if key_puls(i) = '1' then
                active_test <= i;
                wr_index    <= 0;
                state       <= WRITE_SETUP;
              end if;
            end loop;

          when WRITE_SETUP =>
            vi   := wr_index;
            done := false;

            case active_test is

              -- Test 0: clear screen, then write welcome message
              when 0 =>
                if vi < 1000 then
                  va := 16#8000# + vi;  vd := 16#20#;
                elsif vi < 1020 then
                  va := 16#8000# + WELCOME_OFFSET + (vi - 1000);
                  vd := to_integer(unsigned(WELCOME_MSG(vi - 1000)));
                else
                  done := true;
                end if;

              -- Test 1: clear screen only
              when 1 =>
                if vi < 1000 then
                  va := 16#8000# + vi;  vd := 16#20#;
                else
                  done := true;
                end if;

              -- Test 2: fill with cycling printable chars 0x20-0x7F
              when 2 =>
                if vi < 1000 then
                  va := 16#8000# + vi;
                  vd := 16#20# + (vi mod 96);
                else
                  done := true;
                end if;

              -- Test 3: clear screen, then 6x16 character table
              when 3 =>
                if vi < 1000 then
                  va := 16#8000# + vi;  vd := 16#20#;
                elsif vi < 1096 then
                  va := 16#8000# + TABLE_OFFSET
                        + ((vi - 1000) / 16) * 40
                        + ((vi - 1000) mod 16);
                  vd := 16#20# + (vi - 1000);
                else
                  done := true;
                end if;

              when others =>
                done := true;
            end case;

            if done then
              state <= IDLE;
            else
              addr_reg <= std_logic_vector(to_unsigned(va, 16));
              data_reg <= std_logic_vector(to_unsigned(vd, 8));
              state    <= WRITE_ASSERT;
            end if;

          when WRITE_ASSERT =>
            we       <= '1';
            wr_index <= wr_index + 1;
            state    <= WRITE_SETUP;

        end case;
      end if;
    end if;
  end process;

end architecture;
