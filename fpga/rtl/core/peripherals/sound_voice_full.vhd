-- sound_voice_full.vhd — one full synthesizer voice (the "large" sound chip).
--
-- Hardware port of ONE voice of the C emulator's 4-voice sound chip
-- (src/soundchip.c). Unlike the bring-up sound_voice.vhd (square + noise only,
-- no envelope), this implements the complete model:
--
--   * 5 waveforms: 0=sine (256-entry LUT), 1=square, 2=sawtooth, 3=triangle,
--     4=noise (xorshift32 LFSR, same sequence as the C version).
--   * time-based ADSR envelope (attack/decay/sustain/release), units of 8 ms.
--   * note duration auto-off.
--   * per-voice peak volume.
--
-- Register map (offset from base, identical to src/soundchip.h):
--   +0 FREQ_LO   +1 FREQ_HI   frequency in Hz (20..12000, 0 -> 440 default)
--   +2 DUR_LO    +3 DUR_HI    duration in ms  (0 -> 120 default)
--   +4 VOLUME    peak amplitude 0..255
--   +5 CONTROL   bits 6-4 = waveform, bit 0 = trigger (write 1 -> (re)start note)
--   +6 ATTACK    +7 DECAY     time, units of 8 ms
--   +8 SUSTAIN   level 0..255 (fraction of peak)
--   +9 RELEASE   time, units of 8 ms
--
-- Output `sample_out` is a signed 16-bit per-voice sample, already scaled by
-- volume and envelope and pre-attenuated so four voices sum without clipping
-- (>>10 = volume/255 * env/255 * 0.25 full-scale headroom). The mixer in
-- sound_chip4.vhd just adds the four voices and clips.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sound_voice_full is
  generic (
    CLK_HZ     : positive := 27_000_000;
    PHASE_BITS : positive := 24
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    cs       : in  std_logic;
    we       : in  std_logic;
    addr     : in  std_logic_vector(3 downto 0);  -- register offset 0..9
    din      : in  data_t;
    dout     : out data_t;

    sample_out : out std_logic_vector(15 downto 0);  -- signed, per-voice
    active     : out std_logic                        -- '1' while note is sounding
  );
end entity;

architecture rtl of sound_voice_full is
  -- register file (mirrors src/soundchip.h)
  constant R_FREQ_LO : integer := 0;
  constant R_FREQ_HI : integer := 1;
  constant R_DUR_LO  : integer := 2;
  constant R_DUR_HI  : integer := 3;
  constant R_VOL     : integer := 4;
  constant R_CTRL    : integer := 5;
  constant R_ATTACK  : integer := 6;
  constant R_DECAY   : integer := 7;
  constant R_SUSTAIN : integer := 8;
  constant R_RELEASE : integer := 9;

  type regfile_t is array (0 to 9) of data_t;
  signal regs : regfile_t := (others => (others => '0'));

  constant MS_DIV    : integer := CLK_HZ / 1000;        -- clocks per millisecond
  constant NOISE_DIV : integer := CLK_HZ / 44100;       -- ~44.1 kHz noise update
  constant ENV_FULL  : integer := 255;

  -- Phase increment per Hz, in 8.8 fixed point: inc = (freq * PHASE_MUL) >> 8,
  -- where PHASE_MUL = 2^PHASE_BITS / (CLK_HZ/256). At 27 MHz this is 159
  -- (i.e. inc = freq*159>>8 ≈ freq*0.6211, same as sound_voice.vhd). Computed
  -- with integers only (no math_real) so it stays synthesis-portable.
  constant PHASE_MUL : integer := (2**PHASE_BITS) / (CLK_HZ / 256);

  -- 256-entry signed sine table (127*sin), generated offline.
  type sine_t is array (0 to 255) of integer range -128 to 127;
  constant SINE : sine_t := (
    0, 3, 6, 9, 12, 16, 19, 22, 25, 28, 31, 34, 37, 40, 43, 46,
    49, 51, 54, 57, 60, 63, 65, 68, 71, 73, 76, 78, 81, 83, 85, 88,
    90, 92, 94, 96, 98, 100, 102, 104, 106, 107, 109, 111, 112, 113, 115, 116,
    117, 118, 120, 121, 122, 122, 123, 124, 125, 125, 126, 126, 126, 127, 127, 127,
    127, 127, 127, 127, 126, 126, 126, 125, 125, 124, 123, 122, 122, 121, 120, 118,
    117, 116, 115, 113, 112, 111, 109, 107, 106, 104, 102, 100, 98, 96, 94, 92,
    90, 88, 85, 83, 81, 78, 76, 73, 71, 68, 65, 63, 60, 57, 54, 51,
    49, 46, 43, 40, 37, 34, 31, 28, 25, 22, 19, 16, 12, 9, 6, 3,
    0, -3, -6, -9, -12, -16, -19, -22, -25, -28, -31, -34, -37, -40, -43, -46,
    -49, -51, -54, -57, -60, -63, -65, -68, -71, -73, -76, -78, -81, -83, -85, -88,
    -90, -92, -94, -96, -98, -100, -102, -104, -106, -107, -109, -111, -112, -113, -115, -116,
    -117, -118, -120, -121, -122, -122, -123, -124, -125, -125, -126, -126, -126, -127, -127, -127,
    -127, -127, -127, -127, -126, -126, -126, -125, -125, -124, -123, -122, -122, -121, -120, -118,
    -117, -116, -115, -113, -112, -111, -109, -107, -106, -104, -102, -100, -98, -96, -94, -92,
    -90, -88, -85, -83, -81, -78, -76, -73, -71, -68, -65, -63, -60, -57, -54, -51,
    -49, -46, -43, -40, -37, -34, -31, -28, -25, -22, -19, -16, -12, -9, -6, -3
  );

  -- envelope state machine
  type env_state_t is (S_IDLE, S_ATK, S_DEC, S_SUS, S_REL);
  signal env_state : env_state_t := S_IDLE;

  -- latched note parameters (captured at trigger)
  signal l_wave  : std_logic_vector(2 downto 0) := (others => '0');
  signal l_vol   : unsigned(7 downto 0)  := (others => '0');
  signal l_sus   : unsigned(7 downto 0)  := (others => '0');
  signal l_atk   : unsigned(15 downto 0) := (others => '0');  -- ms
  signal l_dec   : unsigned(15 downto 0) := (others => '0');  -- ms
  signal l_rel   : unsigned(15 downto 0) := (others => '0');  -- ms
  signal l_dur   : unsigned(15 downto 0) := (others => '0');  -- ms
  signal l_relst : unsigned(15 downto 0) := (others => '0');  -- release-start ms
  signal phase_inc : unsigned(PHASE_BITS-1 downto 0) := (others => '0');

  -- running state
  signal active_r : std_logic := '0';
  signal time_ms  : unsigned(15 downto 0) := (others => '0');
  signal ms_cnt   : integer range 0 to MS_DIV-1 := 0;
  signal env      : unsigned(7 downto 0) := (others => '0');
  signal e_acc    : unsigned(19 downto 0) := (others => '0');

  signal phase    : unsigned(PHASE_BITS-1 downto 0) := (others => '0');
  signal n_cnt    : integer range 0 to NOISE_DIV-1 := 0;
  signal lfsr     : unsigned(31 downto 0) := x"DEADBEEF";

  -- trigger pulse
  signal trig : std_logic;
begin

  ------------------------------------------------------------------------
  -- CPU register interface
  ------------------------------------------------------------------------
  trig <= '1' when cs = '1' and we = '1' and addr = "0101" and din(0) = '1'
          else '0';

  reg_proc : process(clk)
    variable idx : integer range 0 to 15;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        regs <= (others => (others => '0'));
        regs(R_VOL)     <= std_logic_vector(to_unsigned(200, 8));
        regs(R_SUSTAIN) <= std_logic_vector(to_unsigned(255, 8));
      elsif cs = '1' and we = '1' then
        idx := to_integer(unsigned(addr));
        if idx < 10 then
          regs(idx) <= din;
        end if;
      end if;
    end if;
  end process;

  read_proc : process(addr, regs)
    variable idx : integer range 0 to 15;
  begin
    idx := to_integer(unsigned(addr));
    if idx < 10 then
      dout <= regs(idx);
    else
      dout <= x"FF";
    end if;
  end process;

  ------------------------------------------------------------------------
  -- Phase increment from latched frequency: inc = (freq*159) >> 8 ≈ f*0.6211
  ------------------------------------------------------------------------
  -- Phase follows the LIVE frequency registers (not just the value latched at
  -- trigger). Writing FREQ_LO/FREQ_HI during a note changes its pitch
  -- immediately — needed to reproduce SID-style vibrato / slides / arpeggios.
  -- A trigger still (re)starts the envelope; duration still ends the note.
  inc_proc : process(clk)
    variable fv     : unsigned(15 downto 0);
    variable scaled : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      fv := unsigned(regs(R_FREQ_HI)) & unsigned(regs(R_FREQ_LO));
      if fv = 0 then fv := to_unsigned(440, 16); end if;  -- 0 -> 440 default
      scaled := resize(fv * to_unsigned(PHASE_MUL, 16), 32);
      phase_inc <= resize(scaled(31 downto 8), PHASE_BITS);
    end if;
  end process;

  ------------------------------------------------------------------------
  -- Oscillator phase + noise LFSR (free running)
  ------------------------------------------------------------------------
  osc_proc : process(clk)
    variable x : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        phase <= (others => '0');
        n_cnt <= 0;
        lfsr  <= x"DEADBEEF";
      else
        phase <= phase + phase_inc;
        if n_cnt = NOISE_DIV-1 then
          n_cnt <= 0;
          x := lfsr;
          x := x xor shift_left(x, 13);
          x := x xor shift_right(x, 17);
          x := x xor shift_left(x, 5);
          lfsr <= x;
        else
          n_cnt <= n_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------
  -- Note trigger: latch parameters, (re)start the envelope
  ------------------------------------------------------------------------
  trig_proc : process(clk)
    variable raw_d : unsigned(15 downto 0);
    variable d_eff : unsigned(15 downto 0);
    variable atk, dec, rel, ad, tmp : unsigned(15 downto 0);
  begin
    if rising_edge(clk) then
      if trig = '1' then
        raw_d := unsigned(regs(R_DUR_HI)) & unsigned(regs(R_DUR_LO));

        if raw_d = 0 then d_eff := to_unsigned(120, 16); else d_eff := raw_d; end if;

        atk := resize(unsigned(regs(R_ATTACK))  * to_unsigned(8, 4), 16);
        dec := resize(unsigned(regs(R_DECAY))   * to_unsigned(8, 4), 16);
        rel := resize(unsigned(regs(R_RELEASE)) * to_unsigned(8, 4), 16);
        ad  := atk + dec;

        -- rel_start = max(dur - rel, atk + dec)
        if d_eff > rel then tmp := d_eff - rel; else tmp := (others => '0'); end if;
        if tmp < ad then tmp := ad; end if;

        l_dur   <= d_eff;
        l_vol   <= unsigned(regs(R_VOL));
        l_sus   <= unsigned(regs(R_SUSTAIN));
        l_wave  <= regs(R_CTRL)(6 downto 4);
        l_atk   <= atk;
        l_dec   <= dec;
        l_rel   <= rel;
        l_relst <= tmp;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------
  -- Millisecond time base + ADSR envelope generator
  ------------------------------------------------------------------------
  env_proc : process(clk)
    variable acc_v   : unsigned(19 downto 0);
    variable env_v   : unsigned(7 downto 0);
    variable tick    : boolean;
    variable delta   : unsigned(15 downto 0);
    variable nv      : unsigned(15 downto 0);
    variable tgt     : unsigned(7 downto 0);
    variable up      : boolean;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        ms_cnt <= 0; time_ms <= (others => '0');
        env <= (others => '0'); e_acc <= (others => '0');
        env_state <= S_IDLE; active_r <= '0';
      else
        tick := false;
        if trig = '1' then
          -- restart time base + envelope on (re)trigger
          ms_cnt    <= 0;
          time_ms   <= (others => '0');
          env       <= (others => '0');
          e_acc     <= (others => '0');
          env_state <= S_ATK;
          active_r  <= '1';
        else
          -- 1 ms tick
          if ms_cnt = MS_DIV-1 then
            ms_cnt <= 0;
            tick   := true;
          else
            ms_cnt <= ms_cnt + 1;
          end if;

          if active_r = '1' then
            if tick then
              time_ms <= time_ms + 1;
            end if;

            -- select ramp parameters for the current phase
            delta := (others => '0'); nv := (others => '0');
            tgt := env; up := false;
            case env_state is
              when S_ATK =>
                delta := to_unsigned(ENV_FULL, 16); nv := l_atk;
                tgt := to_unsigned(ENV_FULL, 8); up := true;
              when S_DEC =>
                delta := resize(to_unsigned(ENV_FULL, 16) - l_sus, 16); nv := l_dec;
                tgt := l_sus; up := false;
              when S_REL =>
                delta := resize(l_sus, 16); nv := l_rel;
                tgt := (others => '0'); up := false;
              when others => null;  -- S_SUS / S_IDLE: hold
            end case;

            -- Bresenham ramp: at most one env step per clock (division-free)
            acc_v := e_acc;
            env_v := env;
            if tick then
              acc_v := acc_v + resize(delta, acc_v'length);
            end if;
            if nv /= 0 and acc_v >= resize(nv, acc_v'length) then
              acc_v := acc_v - resize(nv, acc_v'length);
              if up and env_v < tgt then
                env_v := env_v + 1;
              elsif (not up) and env_v > tgt then
                env_v := env_v - 1;
              end if;
            end if;

            -- time-based phase transitions (mirror envelope_at in soundchip.c)
            if time_ms >= l_dur then
              env_v := (others => '0');
              env_state <= S_IDLE;
              active_r  <= '0';
            else
              case env_state is
                when S_ATK =>
                  if time_ms >= l_atk then
                    env_v := to_unsigned(ENV_FULL, 8);
                    env_state <= S_DEC; acc_v := (others => '0');
                  end if;
                when S_DEC =>
                  if time_ms >= (l_atk + l_dec) then
                    env_v := l_sus;
                    env_state <= S_SUS; acc_v := (others => '0');
                  end if;
                when S_SUS =>
                  if time_ms >= l_relst then
                    env_state <= S_REL; acc_v := (others => '0');
                  end if;
                when others => null;
              end case;
            end if;

            env   <= env_v;
            e_acc <= acc_v;
          end if;  -- active
        end if;  -- not trig
      end if;  -- reset
    end if;
  end process;

  ------------------------------------------------------------------------
  -- Waveform select + volume/envelope scaling
  ------------------------------------------------------------------------
  out_proc : process(clk)
    variable p8   : integer range 0 to 255;
    variable raw  : signed(9 downto 0);   -- ±128 nominal full-scale
    variable amp  : signed(18 downto 0);  -- raw * env
    variable amp2 : signed(27 downto 0);  -- * volume
  begin
    if rising_edge(clk) then
      if active_r = '0' then
        sample_out <= (others => '0');
      else
        p8 := to_integer(phase(PHASE_BITS-1 downto PHASE_BITS-8));
        case l_wave is
          when "001" =>  -- square
            if p8 < 128 then raw := to_signed(127, 10); else raw := to_signed(-128, 10); end if;
          when "010" =>  -- sawtooth: +127 -> -128 over the period
            raw := to_signed(127 - p8, 10);
          when "011" =>  -- triangle
            if p8 < 128 then raw := to_signed(2*p8 - 128, 10);
            else             raw := to_signed(383 - 2*p8, 10); end if;
          when "100" =>  -- noise
            raw := resize(signed(std_logic_vector(lfsr(31 downto 24))), 10);
          when others => -- 000 sine (and any undefined code)
            raw := to_signed(SINE(p8), 10);
        end case;

        -- amp = raw * env * volume, then >>10 (incl. 0.25 mixer headroom)
        amp  := raw * signed('0' & std_logic_vector(env));
        amp2 := amp * signed('0' & std_logic_vector(l_vol));
        sample_out <= std_logic_vector(resize(shift_right(amp2, 10), 16));
      end if;
    end if;
  end process;

  active <= active_r;

end architecture;
