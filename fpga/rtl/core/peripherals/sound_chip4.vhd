-- sound_chip4.vhd — the "large" 4-voice sound chip (full ADSR + 5 waveforms).
--
-- Wraps four sound_voice_full instances and mixes them, matching the C
-- emulator's 4-voice model (src/soundchip.c). This is an independent second
-- sound-chip version alongside the bring-up single voice (sound_voice.vhd +
-- pt8211_dac.vhd); both can be implemented/selected on the board.
--
-- Each voice has its own 10-register window and one chip-select line. In the
-- emulator the voice base addresses are:
--   Voice 0 $8830, Voice 1 $8890, Voice 2 $889A, Voice 3 $88A4.
-- The bus decoder selects one voice via cs(i); addr(3:0) is the register offset.
--
-- Mixing: each voice already outputs a signed 16-bit sample pre-scaled by
-- volume, envelope and a 0.25 headroom factor (>>10 inside the voice), so the
-- four can be summed without clipping. A hard clip guards against corner cases.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sound_chip4 is
  generic (
    CLK_HZ : positive := 27_000_000
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    cs       : in  std_logic_vector(3 downto 0);  -- one chip-select per voice
    we       : in  std_logic;
    addr     : in  std_logic_vector(3 downto 0);  -- register offset 0..9
    din      : in  data_t;
    dout     : out data_t;                         -- muxed from the selected voice

    sample_out : out std_logic_vector(15 downto 0);  -- signed mixed output
    active     : out std_logic
  );
end entity;

architecture rtl of sound_chip4 is
  type dout_arr   is array (0 to 3) of data_t;
  type sample_arr is array (0 to 3) of std_logic_vector(15 downto 0);

  signal v_dout   : dout_arr;
  signal v_sample : sample_arr;
  signal v_active : std_logic_vector(3 downto 0);
begin

  gen_voices : for i in 0 to 3 generate
    voice_i : entity work.sound_voice_full
      generic map (CLK_HZ => CLK_HZ)
      port map (
        clk        => clk,
        reset_n    => reset_n,
        cs         => cs(i),
        we         => we,
        addr       => addr,
        din        => din,
        dout       => v_dout(i),
        sample_out => v_sample(i),
        active     => v_active(i)
      );
  end generate;

  -- read mux: return the selected voice's register, else $FF
  dout <= v_dout(0) when cs(0) = '1' else
          v_dout(1) when cs(1) = '1' else
          v_dout(2) when cs(2) = '1' else
          v_dout(3) when cs(3) = '1' else
          x"FF";

  active <= v_active(0) or v_active(1) or v_active(2) or v_active(3);

  -- mixer: sum the four signed voices, then hard-clip to signed 16-bit
  mix_proc : process(clk)
    variable sum : signed(17 downto 0);
  begin
    if rising_edge(clk) then
      sum := resize(signed(v_sample(0)), 18)
           + resize(signed(v_sample(1)), 18)
           + resize(signed(v_sample(2)), 18)
           + resize(signed(v_sample(3)), 18);
      if sum > to_signed(32767, 18) then
        sample_out <= std_logic_vector(to_signed(32767, 16));
      elsif sum < to_signed(-32768, 18) then
        sample_out <= std_logic_vector(to_signed(-32768, 16));
      else
        sample_out <= std_logic_vector(resize(sum, 16));
      end if;
    end if;
  end process;

end architecture;
