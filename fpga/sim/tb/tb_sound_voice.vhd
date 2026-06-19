-- tb_sound_voice.vhd — smoke test for sound_voice + pt8211_dac.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_sound_voice is
end entity;

architecture sim of tb_sound_voice is
  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal cs, we  : std_logic := '0';
  signal addr    : std_logic_vector(3 downto 0) := (others => '0');
  signal din     : data_t := (others => '0');
  signal dout    : data_t;
  signal sample  : std_logic_vector(15 downto 0);

  signal dac_bck, dac_ws, dac_din : std_logic;

  signal saw_high, saw_low : boolean := false;
  constant CLK_PERIOD : time := 37 ns;  -- ~27 MHz

  procedure wr(signal c : out std_logic; signal w : out std_logic;
               signal a : out std_logic_vector(3 downto 0);
               signal d : out data_t;
               reg : integer; val : integer) is
  begin
    a <= std_logic_vector(to_unsigned(reg, 4));
    d <= std_logic_vector(to_unsigned(val, 8));
    c <= '1'; w <= '1';
    wait for CLK_PERIOD;
    c <= '0'; w <= '0';
    wait for CLK_PERIOD;
  end procedure;
begin
  clk <= not clk after CLK_PERIOD/2;

  dut : entity work.sound_voice
    generic map (CLK_HZ => 27_000_000)
    port map (clk => clk, reset_n => reset_n, cs => cs, we => we,
              addr => addr, din => din, dout => dout, sample => sample);

  dac : entity work.pt8211_dac
    port map (clk => clk, reset_n => reset_n, sample => sample,
              dac_bck => dac_bck, dac_ws => dac_ws, dac_din => dac_din);

  -- track whether the sample swings both ways while gated on
  track : process(clk)
  begin
    if rising_edge(clk) then
      if signed(sample) > 1000 then saw_high <= true; end if;
      if signed(sample) < -1000 then saw_low <= true; end if;
    end if;
  end process;

  stim : process
  begin
    reset_n <= '0';
    wait for 5*CLK_PERIOD;
    reset_n <= '1';
    wait for 5*CLK_PERIOD;

    -- 1000 Hz square wave, full volume, gate on
    wr(cs, we, addr, din, 0, 16#E8#);  -- FREQ_LO = 0x3E8 = 1000
    wr(cs, we, addr, din, 1, 16#03#);
    wr(cs, we, addr, din, 4, 255);     -- VOLUME
    wr(cs, we, addr, din, 5, 16#11#);  -- CONTROL: waveform=1 (square), gate=1

    -- run ~2 ms so the 1 kHz square completes a couple of periods
    wait for 60000 * CLK_PERIOD;

    assert saw_high and saw_low
      report "FAIL: square wave did not swing both polarities" severity failure;

    -- gate off -> sample must go silent
    wr(cs, we, addr, din, 5, 16#10#);  -- gate = 0
    wait for 10*CLK_PERIOD;
    assert signed(sample) = 0
      report "FAIL: sample not silent after gate off" severity failure;

    report "PASS: sound_voice square wave OK" severity note;
    std.env.stop;
  end process;
end architecture;
