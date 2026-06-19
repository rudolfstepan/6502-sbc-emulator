-- sound_voice.vhd — Single-voice FPGA sound synthesizer (stripped-down bring-up).
--
-- Register-compatible subset of the C emulator soundchip (src/soundchip.c).
-- This first hardware version implements ONE voice (channel 0, $8830-$8839)
-- with two waveforms: square and noise. Frequency and volume are honoured;
-- duration and ADSR registers are accepted (so existing 6502 code writing the
-- full 10-register block does not error) but not yet acted upon — the note
-- plays as long as the CONTROL gate bit is set.
--
-- Register map (offset from base, matches src/soundchip.h):
--   +0 FREQ_LO   frequency low byte   (Hz)
--   +1 FREQ_HI   frequency high byte
--   +2 DUR_LO    duration  (accepted, unused in this version)
--   +3 DUR_HI
--   +4 VOLUME    peak amplitude 0..255
--   +5 CONTROL   bits 6-4 = waveform (1=square, 4=noise; others -> square)
--                bit 0 = trigger/gate (1 = note on)
--   +6..+9 ATTACK/DECAY/SUSTAIN/RELEASE (accepted, unused)
--
-- Output: signed 16-bit sample, updated every clock. The audio rate is set by
-- the phase accumulator; downstream DAC serializer resamples it.
--
-- Phase increment: inc = freq_hz * 2^PHASE_BITS / CLK_HZ.
-- With CLK_HZ = 27 MHz and PHASE_BITS = 24, that is freq * 0.6213.
-- We approximate as (freq * 159) >> 8 = freq * 0.6211  (error < 0.05%).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sound_voice is
  generic (
    CLK_HZ      : positive := 27_000_000;
    PHASE_BITS  : positive := 24
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    -- CPU register bus (active when cs = '1')
    cs       : in  std_logic;
    we       : in  std_logic;
    addr     : in  std_logic_vector(3 downto 0);  -- register offset 0..9
    din      : in  data_t;
    dout     : out data_t;

    -- Audio output, signed 16-bit
    sample   : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of sound_voice is
  -- Register layout (mirrors src/soundchip.h SOUND_* enum)
  constant SOUND_REG_COUNT : integer := 10;
  constant SOUND_FREQ_LO   : integer := 0;
  constant SOUND_FREQ_HI   : integer := 1;
  constant SOUND_VOL       : integer := 4;
  constant SOUND_CTRL      : integer := 5;

  type regfile_t is array (0 to SOUND_REG_COUNT-1) of data_t;
  signal regs : regfile_t := (others => (others => '0'));

  signal phase     : unsigned(PHASE_BITS-1 downto 0) := (others => '0');
  signal phase_inc : unsigned(PHASE_BITS-1 downto 0) := (others => '0');

  -- xorshift-style LFSR for noise (matches the emulator's noise concept,
  -- a simple 16-bit Galois LFSR is plenty for a beep).
  signal lfsr : std_logic_vector(15 downto 0) := x"ACE1";

  signal gate     : std_logic;
  signal waveform : std_logic_vector(2 downto 0);
  signal volume   : unsigned(7 downto 0);
begin

  -- ── Control-bit decode ────────────────────────────────────────────────
  gate     <= regs(SOUND_CTRL)(0);
  waveform <= regs(SOUND_CTRL)(6 downto 4);
  volume   <= unsigned(regs(SOUND_VOL));

  -- ── CPU register writes / reads ───────────────────────────────────────
  reg_proc : process(clk)
    variable idx : integer range 0 to 15;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        regs <= (others => (others => '0'));
      elsif cs = '1' and we = '1' then
        idx := to_integer(unsigned(addr));
        if idx < SOUND_REG_COUNT then
          regs(idx) <= din;
        end if;
      end if;
    end if;
  end process;

  read_proc : process(addr, regs)
    variable idx : integer range 0 to 15;
  begin
    idx := to_integer(unsigned(addr));
    if idx < SOUND_REG_COUNT then
      dout <= regs(idx);
    else
      dout <= x"FF";
    end if;
  end process;

  -- ── Phase increment from frequency registers ─────────────────────────
  -- inc = (freq * 159) >> 8, sized to PHASE_BITS.
  inc_proc : process(clk)
    variable freq  : unsigned(15 downto 0);
    variable scaled : unsigned(23 downto 0);
  begin
    if rising_edge(clk) then
      freq   := unsigned(regs(SOUND_FREQ_HI)) & unsigned(regs(SOUND_FREQ_LO));
      scaled := resize(freq * to_unsigned(159, 8), 24);  -- 16x8 -> 24 bits
      phase_inc <= resize(scaled(23 downto 8), PHASE_BITS);
    end if;
  end process;

  -- ── Oscillator + noise LFSR ──────────────────────────────────────────
  osc_proc : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        phase <= (others => '0');
        lfsr  <= x"ACE1";
      else
        phase <= phase + phase_inc;
        -- Galois LFSR, taps 16,14,13,11 (maximal-length).
        if lfsr(0) = '1' then
          lfsr <= ('0' & lfsr(15 downto 1)) xor x"B400";
        else
          lfsr <= '0' & lfsr(15 downto 1);
        end if;
      end if;
    end if;
  end process;

  -- ── Waveform select + volume scaling ─────────────────────────────────
  out_proc : process(clk)
    variable raw  : signed(8 downto 0);   -- -256..+255 nominal full-scale
    variable amp  : signed(17 downto 0);
  begin
    if rising_edge(clk) then
      if gate = '0' then
        sample <= (others => '0');
      else
        case waveform is
          when "100" =>  -- noise
            raw := signed(resize(signed(lfsr(7) & lfsr(6 downto 0)), 9));
          when others =>  -- square (default, incl. waveform=1)
            if phase(PHASE_BITS-1) = '1' then
              raw := to_signed(127, 9);
            else
              raw := to_signed(-128, 9);
            end if;
        end case;
        -- amplitude = raw * volume  (9b signed * 8b unsigned -> 17b)
        amp := raw * signed('0' & std_logic_vector(volume));
        -- max magnitude = 128*255 = 32640 < 32767, fits signed 16-bit
        sample <= std_logic_vector(resize(amp, 16));
      end if;
    end if;
  end process;

end architecture;
