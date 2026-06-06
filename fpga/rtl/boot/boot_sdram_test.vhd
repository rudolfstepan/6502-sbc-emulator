-- SDRAM boot-time memory test.
--
-- Runs before the 6502 is released. It writes and verifies two byte patterns
-- through the same burst-1 SDRAM controller interface used by the CPU bridge.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity boot_sdram_test is
  generic (
    START_ADDR : natural := 16#0200#;
    END_ADDR   : natural := 16#7FFF#
  );
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    start     : in  std_logic;

    ctrl_idle : in  std_logic;

    wr_burst_req      : out std_logic;
    wr_burst_data     : out std_logic_vector(15 downto 0);
    wr_burst_len      : out std_logic_vector(9 downto 0);
    wr_burst_addr     : out std_logic_vector(23 downto 0);
    wr_dqm            : out std_logic_vector(1 downto 0);
    wr_burst_data_req : in  std_logic;
    wr_burst_finish   : in  std_logic;

    rd_burst_req        : out std_logic;
    rd_burst_len        : out std_logic_vector(9 downto 0);
    rd_burst_addr       : out std_logic_vector(23 downto 0);
    rd_burst_data       : in  std_logic_vector(15 downto 0);
    rd_burst_data_valid : in  std_logic;
    rd_burst_finish     : in  std_logic;

    active        : out std_logic;
    done          : out std_logic;
    error         : out std_logic;
    phase         : out std_logic_vector(3 downto 0);
    progress_addr : out std_logic_vector(14 downto 0);
    fail_addr     : out std_logic_vector(14 downto 0);
    expected      : out data_t;
    actual        : out data_t
  );
end entity;

architecture rtl of boot_sdram_test is
  type state_t is (
    S_IDLE,
    S_WAIT_IDLE,
    S_WR_REQ,
    S_WR_WAIT,
    S_RD_REQ,
    S_RD_WAIT,
    S_ERROR,
    S_DONE
  );

  signal state      : state_t := S_IDLE;
  signal pass       : std_logic := '0';
  signal clear_pass : std_logic := '0';
  signal addr       : unsigned(14 downto 0) := to_unsigned(START_ADDR, 15);
  signal active_reg : std_logic := '0';
  signal done_reg   : std_logic := '0';
  signal error_reg  : std_logic := '0';
  signal phase_reg  : std_logic_vector(3 downto 0) := x"0";
  signal fail_reg   : std_logic_vector(14 downto 0) := (others => '0');
  signal exp_reg    : data_t := (others => '0');
  signal act_reg    : data_t := (others => '0');

  function test_pattern(a : unsigned(14 downto 0); inv : std_logic) return data_t is
    variable low  : data_t;
    variable high : data_t;
    variable pat  : data_t;
  begin
    low  := std_logic_vector(a(7 downto 0));
    high := '0' & std_logic_vector(a(14 downto 8));
    pat  := low xor high xor x"A5";
    if inv = '1' then
      pat := not pat;
    end if;
    return pat;
  end function;

begin
  wr_burst_len  <= std_logic_vector(to_unsigned(1, 10));
  rd_burst_len  <= std_logic_vector(to_unsigned(1, 10));
  wr_burst_data <= x"0000" when clear_pass = '1' else x"00" & test_pattern(addr, pass);
  wr_burst_addr <= "000000000" & std_logic_vector(addr);
  rd_burst_addr <= "000000000" & std_logic_vector(addr);
  wr_dqm        <= "10";

  active        <= active_reg;
  done          <= done_reg;
  error         <= error_reg;
  phase         <= phase_reg;
  progress_addr <= std_logic_vector(addr);
  fail_addr     <= fail_reg;
  expected      <= exp_reg;
  actual        <= act_reg;

  process(clk)
    variable expected_v : data_t;
    variable mismatch_v : boolean;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state        <= S_IDLE;
        pass         <= '0';
        clear_pass   <= '0';
        addr         <= to_unsigned(START_ADDR, 15);
        wr_burst_req <= '0';
        rd_burst_req <= '0';
        active_reg   <= '0';
        done_reg     <= '0';
        error_reg    <= '0';
        phase_reg    <= x"0";
        fail_reg     <= (others => '0');
        exp_reg      <= (others => '0');
        act_reg      <= (others => '0');
      else
        wr_burst_req <= '0';
        rd_burst_req <= '0';

        case state is
          when S_IDLE =>
            active_reg <= '0';
            phase_reg  <= x"0";
            if start = '1' and done_reg = '0' and error_reg = '0' then
              pass       <= '0';
              clear_pass <= '0';
              addr       <= to_unsigned(START_ADDR, 15);
              active_reg <= '1';
              phase_reg  <= x"1";
              state      <= S_WAIT_IDLE;
            end if;

          when S_WAIT_IDLE =>
            active_reg <= '1';
            if ctrl_idle = '1' then
              state <= S_WR_REQ;
            end if;

          when S_WR_REQ =>
            active_reg   <= '1';
            if clear_pass = '1' then
              phase_reg <= x"5";
            elsif pass = '0' then
              phase_reg <= x"1";
            else
              phase_reg <= x"3";
            end if;
            wr_burst_req <= '1';
            -- Hold the request until accepted; refresh has priority in S_IDLE.
            if wr_burst_data_req = '1' then
              state <= S_WR_WAIT;
            end if;

          when S_WR_WAIT =>
            active_reg <= '1';
            if ctrl_idle = '1' then
              if addr = to_unsigned(END_ADDR, 15) then
                if clear_pass = '1' then
                  done_reg   <= '1';
                  active_reg <= '0';
                  phase_reg  <= x"F";
                  state      <= S_DONE;
                else
                  addr <= to_unsigned(START_ADDR, 15);
                  if pass = '0' then
                    phase_reg <= x"2";
                  else
                    phase_reg <= x"4";
                  end if;
                  state <= S_RD_REQ;
                end if;
              else
                addr  <= addr + 1;
                state <= S_WR_REQ;
              end if;
            end if;

          when S_RD_REQ =>
            active_reg   <= '1';
            if pass = '0' then
              phase_reg <= x"2";
            else
              phase_reg <= x"4";
            end if;
            rd_burst_req <= '1';
            expected_v := test_pattern(addr, pass);
            mismatch_v := false;
            if rd_burst_data_valid = '1' then
              if rd_burst_data(7 downto 0) /= expected_v then
                mismatch_v := true;
                fail_reg  <= std_logic_vector(addr);
                exp_reg   <= expected_v;
                act_reg   <= rd_burst_data(7 downto 0);
                error_reg <= '1';
                phase_reg <= x"E";
                state     <= S_ERROR;
              else
                state <= S_RD_WAIT;
              end if;
            end if;

          when S_RD_WAIT =>
            active_reg <= '1';
            if ctrl_idle = '1' then
              if addr = to_unsigned(END_ADDR, 15) then
                if pass = '0' then
                  pass      <= '1';
                  addr      <= to_unsigned(START_ADDR, 15);
                  phase_reg <= x"3";
                  state     <= S_WR_REQ;
                else
                  clear_pass <= '1';
                  addr       <= to_unsigned(START_ADDR, 15);
                  phase_reg  <= x"5";
                  state      <= S_WR_REQ;
                end if;
              else
                addr  <= addr + 1;
                state <= S_RD_REQ;
              end if;
            end if;

          when S_ERROR =>
            active_reg <= '0';

          when S_DONE =>
            active_reg <= '0';

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
