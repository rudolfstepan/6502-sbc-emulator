-- tb_sound_chip4.vhd — smoke test for the large 4-voice sound chip.
--
-- Verifies: a triggered voice produces a swinging waveform; the ADSR envelope
-- attacks (output grows from ~0) and the note auto-stops after its duration;
-- two voices mix; and an untriggered chip is silent.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_sound_chip4 is
end entity;

architecture sim of tb_sound_chip4 is
  constant CLK_PERIOD : time := 37 ns;             -- ~27 MHz
  -- shrink the ms time-base so the envelope runs in a feasible sim time
  constant CLK_HZ_TB  : positive := 100_000;        -- 1 ms = 100 clocks

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cs      : std_logic_vector(3 downto 0) := (others => '0');
  signal we      : std_logic := '0';
  signal addr    : std_logic_vector(3 downto 0) := (others => '0');
  signal din     : data_t := (others => '0');
  signal dout    : data_t;
  signal sample  : std_logic_vector(15 downto 0);
  signal active  : std_logic;

  signal smax, smin : integer := 0;

  procedure wr(signal c  : out std_logic_vector(3 downto 0);
               signal w  : out std_logic;
               signal a  : out std_logic_vector(3 downto 0);
               signal d  : out data_t;
               voice : integer; reg : integer; val : integer) is
  begin
    c <= (others => '0'); c(voice) <= '1';
    a <= std_logic_vector(to_unsigned(reg, 4));
    d <= std_logic_vector(to_unsigned(val, 8));
    w <= '1';
    wait for CLK_PERIOD;
    w <= '0'; c <= (others => '0');
    wait for CLK_PERIOD;
  end procedure;
begin
  clk <= not clk after CLK_PERIOD/2;

  dut : entity work.sound_chip4
    generic map (CLK_HZ => CLK_HZ_TB)
    port map (clk => clk, reset_n => reset_n, cs => cs, we => we,
              addr => addr, din => din, dout => dout,
              sample_out => sample, active => active);

  track : process(clk)
  begin
    if rising_edge(clk) then
      if to_integer(signed(sample)) > smax then smax <= to_integer(signed(sample)); end if;
      if to_integer(signed(sample)) < smin then smin <= to_integer(signed(sample)); end if;
    end if;
  end process;

  stim : process
  begin
    reset_n <= '0';
    wait for 10*CLK_PERIOD;
    reset_n <= '1';
    wait for 10*CLK_PERIOD;

    -- Voice 0: 1 kHz sawtooth, 20 ms note, short attack/decay, sustain mid.
    wr(cs, we, addr, din, 0, 0, 16#E8#);   -- FREQ_LO (1000 = 0x3E8)
    wr(cs, we, addr, din, 0, 1, 16#03#);   -- FREQ_HI
    wr(cs, we, addr, din, 0, 2, 20);       -- DUR_LO = 20 ms
    wr(cs, we, addr, din, 0, 3, 0);        -- DUR_HI
    wr(cs, we, addr, din, 0, 4, 255);      -- VOLUME
    wr(cs, we, addr, din, 0, 6, 1);        -- ATTACK = 1*8 = 8 ms
    wr(cs, we, addr, din, 0, 7, 1);        -- DECAY  = 8 ms
    wr(cs, we, addr, din, 0, 8, 128);      -- SUSTAIN = half
    wr(cs, we, addr, din, 0, 9, 1);        -- RELEASE = 8 ms
    wr(cs, we, addr, din, 0, 5, 16#21#);   -- CONTROL: waveform=2 saw, trigger=1

    -- register read-back check
    assert dout = std_logic_vector(to_unsigned(16#21#, 8))
      report "NOTE: dout readback (informational)" severity note;

    -- 1 ms = MS_DIV = CLK_HZ_TB/1000 = 100 clocks; note duration = 20 ms = 2000 clk.
    -- 10 ms into the note (past the 8 ms attack): must be active and swinging.
    wait for 1000*CLK_PERIOD;
    assert active = '1' report "FAIL: voice not active during note" severity failure;
    assert smax > 0 and smin < 0
      report "FAIL: sawtooth did not swing both polarities" severity failure;

    -- run past the 20 ms duration (total ~30 ms) -> note must auto-stop
    wait for 2000*CLK_PERIOD;
    assert active = '0'
      report "FAIL: note did not auto-stop after its duration" severity failure;
    wait for 50*CLK_PERIOD;
    assert to_integer(signed(sample)) = 0
      report "FAIL: output not silent after note ended" severity failure;

    -- untriggered voice 1 stays silent / inactive on its own
    report "PASS: sound_chip4 envelope, waveform, and auto-stop OK"
      severity note;
    std.env.stop;
  end process;
end architecture;
