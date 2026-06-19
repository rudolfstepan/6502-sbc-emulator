-- pt8211_dac.vhd — Serializer for the PT8211 (TM8211) audio DAC on the
-- Tang Primer 20K dock board.
--
-- This is a 1:1 VHDL port of Sipeed's proven Verilog driver
-- (TangPrimer-20K-example/PT8211/src/pt8211_drive.v). The earlier hand-written
-- version used the wrong BCK polarity and WS alignment for this part and
-- produced no usable audio; the PT8211 uses a specific right-justified format
-- where WS toggles a few BCK *after* the data word, not on the bit boundary.
--
-- Reference behaviour (per 32-BCK stereo frame, counter b_cnt = 0..31):
--   * BCK is a free-running clock; every register updates on its rising edge.
--   * A fresh 16-bit sample is reloaded at b_cnt 0 and 16 (via the req/req_r1
--     one-cycle delayed load), then shifted out MSB-first on DIN.
--   * WS = 0 at b_cnt 3, WS = 1 at b_cnt 19 ("对齐数据" — data alignment).
-- The same mono sample feeds both channels.
--
-- The reference clocks everything on a dedicated ~1.536 MHz BCK domain. Here we
-- stay in the 27 MHz system-clock domain and generate BCK by division, doing
-- the reference's register updates on each detected BCK rising edge so the
-- BCK/WS/DIN phase relationship is bit-for-bit identical to the working demo.
--   BCK = clk / (2*BCK_HALF). With BCK_HALF = 9 -> 1.5 MHz BCK, fs = 46.9 kHz.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pt8211_dac is
  generic (
    BCK_HALF : positive := 9   -- system-clock cycles per BCK half-period
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    sample  : in  std_logic_vector(15 downto 0);  -- signed mono sample

    -- PT8211 pins
    dac_bck : out std_logic;   -- bit clock (BCK)
    dac_ws  : out std_logic;   -- word/channel select (WS/LRCK)
    dac_din : out std_logic    -- serial data, MSB first (DIN)
  );
end entity;

architecture rtl of pt8211_dac is
  signal clkdiv  : unsigned(7 downto 0) := (others => '0');
  signal bck     : std_logic := '0';
  signal bck_d   : std_logic := '0';

  -- Mirror of the reference registers.
  signal b_cnt   : unsigned(4 downto 0)        := (others => '0');  -- 0..31
  signal req_r   : std_logic                   := '0';
  signal req_r1  : std_logic                   := '0';
  signal idata_r : std_logic_vector(15 downto 0) := (others => '0');
  signal ws_r    : std_logic                   := '0';
  signal din_r   : std_logic                   := '0';
begin

  dac_bck <= bck;
  dac_ws  <= ws_r;
  dac_din <= din_r;

  -- ── BCK generation: free-running divided clock ───────────────────────────
  bck_gen : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        clkdiv <= (others => '0');
        bck    <= '0';
      elsif clkdiv = to_unsigned(BCK_HALF-1, clkdiv'length) then
        clkdiv <= (others => '0');
        bck    <= not bck;
      else
        clkdiv <= clkdiv + 1;
      end if;
    end if;
  end process;

  -- ── Serializer: reference pt8211_drive.v, advanced on each BCK rising edge ─
  ser : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        bck_d   <= '0';
        b_cnt   <= (others => '0');
        req_r   <= '0';
        req_r1  <= '0';
        idata_r <= (others => '0');
        ws_r    <= '0';
        din_r   <= '0';
      else
        bck_d <= bck;
        -- rising edge of BCK == posedge clk_1p536m in the reference
        if bck = '1' and bck_d = '0' then
          b_cnt <= b_cnt + 1;

          -- req_r <= (b_cnt == 0) || (b_cnt == 16)
          if b_cnt = 0 or b_cnt = 16 then
            req_r <= '1';
          else
            req_r <= '0';
          end if;

          req_r1 <= req_r;

          -- idata_r <= req_r1 ? sample : idata_r << 1
          if req_r1 = '1' then
            idata_r <= sample;
          else
            idata_r <= idata_r(14 downto 0) & '0';
          end if;

          din_r <= idata_r(15);

          -- WS aligned a few BCK after the data word
          if b_cnt = 3 then
            ws_r <= '0';
          elsif b_cnt = 19 then
            ws_r <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture;
