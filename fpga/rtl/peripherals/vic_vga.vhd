-- VIC VGA: Video Controller mit Bus-Stealing und VGA-Ausgabe
--
-- Funktionsprinzip (aehnlich C64):
--   Waehrend H-Blank (160 Pixel-Takte = 320 System-Takte) stiehlt der VIC
--   exakt 40 System-Takte vom CPU-Bus (einen pro Zeichen der Zeile).
--   Die CPU wird dabei via RDY gehalten. Kein Dual-Port-RAM noetig.
--
--   Waehrend der sichtbaren Zeile laeuft die CPU ungehindert; der VIC
--   zeigt Zeichen aus dem 40-Byte Zeilenpuffer mit kombinatorischer
--   Char-ROM-Ausgabe.
--
-- Timing: 640x480 @ ~60Hz, Pixel-Takt 25MHz (50MHz / 2)
-- Textmodus: 40x25 Zeichen, 2x skaliert (16x16 Bildschirmpixel pro Zeichen)
-- Randhoehe oben/unten: 40 Pixel
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_vga is
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;

    -- Bus-Steal-Interface
    -- Wenn vic_stealing='1': VIC treibt vic_addr, liest vram_data, CPU gehalten
    vic_addr     : out addr_t;
    vram_data    : in  data_t;      -- async VRAM-Ausgabe
    vic_stealing : out std_logic;

    -- Char-ROM (kombinatorisch)
    char_addr    : out std_logic_vector(9 downto 0);
    char_data    : in  data_t;

    -- VGA-Ausgang 640x480 @ ~60Hz
    vga_hs       : out std_logic;
    vga_vs       : out std_logic;
    vga_r        : out std_logic_vector(4 downto 0);
    vga_g        : out std_logic_vector(5 downto 0);
    vga_b        : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of vic_vga is
  -- 640x480 @ 60Hz VGA-Timing (Pixel-Takt 25MHz = 50MHz / 2)
  constant H_VIS  : natural := 640;
  constant H_TOT  : natural := 800;
  constant H_SS   : natural := 656;   -- H-Sync-Start  (656 = 640+16)
  constant H_SE   : natural := 752;   -- H-Sync-Ende   (752 = 656+96)

  constant V_VIS  : natural := 480;
  constant V_TOT  : natural := 525;
  constant V_SS   : natural := 490;   -- V-Sync-Start
  constant V_SE   : natural := 492;   -- V-Sync-Ende

  -- Textbereich: 40px Rand oben, 25 Zeilen * 16 Pixel = 400px, 40px Rand unten
  constant V_BORD : natural := 40;
  constant TV_END : natural := V_BORD + 400;   -- 440

  -- Pixel-Takt-Enable (div2)
  signal pce      : std_logic := '0';

  -- Scan-Zaehler (Pixel-Takt-Einheiten)
  signal hc       : natural range 0 to H_TOT - 1 := 0;
  signal vc       : natural range 0 to V_TOT - 1 := 0;

  -- 40-Byte Zeilenpuffer (Zeichencodes der aktuellen Zeile)
  type linebuf_t is array (0 to 39) of data_t;
  signal linebuf  : linebuf_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of linebuf : signal is "distributed";

  -- Fetch-Zustandsautomat
  signal fetching  : std_logic := '0';
  signal fetch_col : natural range 0 to 39 := 0;
  signal fetch_row : natural range 0 to 24 := 0;

  -- Anzeige-Geometrie (kombinatorisch aus Scanzaehlern)
  -- Breiter Wertebereich um Out-of-Bounds bei Blanking zu vermeiden
  signal in_text  : std_logic;
  signal v_off    : natural range 0 to V_VIS := 0;
  signal col      : natural range 0 to 39 := 0;
  signal crow     : natural range 0 to 24 := 0;
  signal cline    : natural range 0 to 7  := 0;
  signal cpix     : natural range 0 to 7  := 0;

  signal char_code : data_t;
  signal pbit      : std_logic;

begin
  -- Pixel-Takt-Enable: 50MHz -> 25MHz
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        pce <= '0';
      else
        pce <= not pce;
      end if;
    end if;
  end process;

  -- Horizontal/Vertikal-Zaehler
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        hc <= 0;
        vc <= 0;
      elsif pce = '1' then
        if hc = H_TOT - 1 then
          hc <= 0;
          if vc = V_TOT - 1 then
            vc <= 0;
          else
            vc <= vc + 1;
          end if;
        else
          hc <= hc + 1;
        end if;
      end if;
    end if;
  end process;

  -- Zeilenpuffer-Lade-Automat
  -- Laeuft genau 40 System-Takte am Anfang jedes H-Blank
  -- pre-fetcht fuer die NAECHSTE Scan-Zeile
  process(clk)
    variable nv : natural range 0 to V_TOT - 1;
    variable nr : natural range 0 to 24;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fetching  <= '0';
        fetch_col <= 0;
        fetch_row <= 0;
      else
        if fetching = '0' then
          -- Trigger beim letzten sichtbaren Pixel
          if pce = '1' and hc = H_VIS - 1 then
            -- Naechste Scanzeile
            if vc = V_TOT - 1 then nv := 0;
            else nv := vc + 1;
            end if;
            -- Zeichenzeile fuer naechste Scanzeile berechnen
            if nv >= V_BORD and nv < TV_END then
              nr := (nv - V_BORD) / 16;
            else
              nr := 0;
            end if;
            fetch_row <= nr;
            fetch_col <= 0;
            fetching  <= '1';
          end if;
        else
          -- Ein gestohlener Takt pro Zeichen: async VRAM-Ausgabe erfassen
          linebuf(fetch_col) <= vram_data;
          if fetch_col = 39 then
            fetching  <= '0';
          else
            fetch_col <= fetch_col + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Bus-Steal-Ausgaenge (kombinatorisch)
  vic_stealing <= fetching;
  vic_addr <= std_logic_vector(
      to_unsigned(16#8000# + fetch_row * 40 + fetch_col, 16))
    when fetching = '1' else (others => '0');

  -- Anzeige-Geometrie: col/row auf gueltigen Bereich klemmen
  -- damit kein Out-of-Bounds bei Blanking entsteht
  in_text <= '1' when hc < H_VIS and vc >= V_BORD and vc < TV_END else '0';

  v_off <= (vc - V_BORD)   when vc >= V_BORD else 0;
  col   <= hc / 16         when hc < H_VIS   else 0;
  crow  <= v_off / 16;
  cline <= (v_off / 2) mod 8;
  cpix  <= (hc  / 2) mod 8;

  -- Zeichencode aus Zeilenpuffer
  char_code <= linebuf(col) when in_text = '1' else x"00";

  -- Char-ROM-Adresse: char_code[6:0] & cline[2:0]
  char_addr <= char_code(6 downto 0) &
               std_logic_vector(to_unsigned(cline, 3));

  -- Pixel-Bit aus ROM-Muster
  pbit <= char_data(7 - cpix) when in_text = '1' else '0';

  -- VGA-Sync (aktiv-low)
  vga_hs <= '0' when hc >= H_SS and hc < H_SE else '1';
  vga_vs <= '0' when vc >= V_SS and vc < V_SE else '1';

  -- VGA-Farbe: weiss auf schwarz
  vga_r <= "11111"  when pbit = '1' else "00000";
  vga_g <= "111111" when pbit = '1' else "000000";
  vga_b <= "11111"  when pbit = '1' else "00000";

end architecture;
