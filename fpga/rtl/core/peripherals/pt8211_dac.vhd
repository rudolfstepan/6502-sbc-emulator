-- pt8211_dac.vhd — I2S serializer for the PT8211 (a.k.a. TM8211) audio DAC.
--
-- The PT8211 is a minimal 16-bit stereo I2S-style DAC found on the Tang
-- Primer 20K dock board (pins R16/P15/P16/N15 in the board CST). It latches
-- data MSB-first on the rising edge of BCK, and WS selects the channel
-- (WS low = right, WS high = left for this part — exact polarity is not
-- audible for a mono beep, both channels get the same sample here).
--
-- Clocking: derived from the 27 MHz system clock by a simple counter.
--   BCK  = clk_27 / (2*BCK_DIV)
--   With BCK_DIV = 4  -> BCK ≈ 3.375 MHz, 32 BCK/frame -> fs ≈ 105 kHz.
--
-- Interface: a single signed 16-bit mono `sample` input is latched at the
-- start of every stereo frame and shifted out on both channels.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pt8211_dac is
  generic (
    BCK_DIV : positive := 4   -- system-clock half-periods per BCK half-period
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    sample  : in  std_logic_vector(15 downto 0);  -- signed mono sample

    -- PT8211 pins
    dac_bck : out std_logic;   -- bit clock
    dac_ws  : out std_logic;   -- word/channel select (LRCK)
    dac_din : out std_logic    -- serial data, MSB first
  );
end entity;

architecture rtl of pt8211_dac is
  signal clkdiv  : unsigned(7 downto 0) := (others => '0');
  signal bck_r   : std_logic := '0';
  signal bck_prev: std_logic := '0';

  -- 32-bit frame: bits 31..16 = left channel, 15..0 = right channel.
  signal shifter : std_logic_vector(31 downto 0) := (others => '0');
  signal bitcnt  : unsigned(5 downto 0) := (others => '0');  -- 0..31
  signal ws_r    : std_logic := '0';
begin

  dac_bck <= bck_r;
  dac_ws  <= ws_r;
  dac_din <= shifter(31);

  -- ── BCK generation ────────────────────────────────────────────────────
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        clkdiv <= (others => '0');
        bck_r  <= '0';
      elsif clkdiv = to_unsigned(BCK_DIV-1, clkdiv'length) then
        clkdiv <= (others => '0');
        bck_r  <= not bck_r;
      else
        clkdiv <= clkdiv + 1;
      end if;
    end if;
  end process;

  -- ── Shift register, advanced on the falling edge of BCK ───────────────
  -- Data changes on BCK falling so it is stable at the DAC's rising-edge latch.
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        shifter  <= (others => '0');
        bitcnt   <= (others => '0');
        ws_r     <= '0';
        bck_prev <= '0';
      else
        bck_prev <= bck_r;
        -- falling edge of BCK
        if bck_prev = '1' and bck_r = '0' then
          if bitcnt = to_unsigned(31, bitcnt'length) then
            -- start of new frame: latch fresh sample into both channels
            shifter <= sample & sample;
            bitcnt  <= (others => '0');
            ws_r    <= '0';
          else
            shifter <= shifter(30 downto 0) & '0';
            bitcnt  <= bitcnt + 1;
            -- WS toggles at the channel boundary (after bit 15 shifted out)
            if bitcnt = to_unsigned(15, bitcnt'length) then
              ws_r <= '1';
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
