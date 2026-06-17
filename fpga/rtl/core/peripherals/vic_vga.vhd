-- VIC VGA: Video Controller mit Bus-Stealing und VGA-Ausgabe
--
-- Funktionsprinzip (aehnlich C64):
--   Waehrend H-Blank (160 Pixel-Takte = 320 System-Takte) stiehlt der VIC
--   41 System-Takte vom CPU-Bus: einen Vorlauf-Takt fuer synchrones VRAM
--   und danach einen pro Zeichen der Zeile.
--   Die CPU wird dabei via RDY gehalten. Kein Dual-Port-RAM noetig.
--
--   Waehrend der sichtbaren Zeile laeuft die CPU ungehindert; der VIC
--   zeigt Zeichen aus dem 40-Byte Zeilenpuffer mit kombinatorischer
--   Char-ROM-Ausgabe.
--
-- Timing: 640x480 @ 59.94 Hz, CEA-861 480p totals (858x525).
--   CLK_DIV=2 with 50 MHz -> 25 MHz pixel clock (PIX16 board).
--   CLK_DIV=1 with 27 MHz -> 27 MHz pixel clock (Tang Primer 20K).
-- Textmodus: 40x25 Zeichen, 2x skaliert (16x16 Bildschirmpixel pro Zeichen)
-- Randhoehe oben/unten: 40 Pixel
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_vga is
  generic (
    -- Pixel-clock divisor: 2 for 50 MHz systems (pixel = 25 MHz),
    --                      1 for 27 MHz systems (pixel = 27 MHz, ~64 Hz refresh).
    CLK_DIV : natural := 2;
    -- Number of clk cycles per cursor blink phase. 25_000_000 gives a
    -- C64-like half-second phase on 50 MHz boards.
    CURSOR_BLINK_DIV : positive := 25_000_000
  );
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;

    -- Bus-Steal-Interface
    vic_addr     : out addr_t;
    vram_data    : in  data_t;
    vic_stealing : out std_logic;

    -- Char-ROM (kombinatorisch)
    char_addr    : out std_logic_vector(9 downto 0);
    char_data    : in  data_t;

    -- Text cursor register inputs (0..39, 0..24)
    cursor_x     : in  std_logic_vector(5 downto 0);
    cursor_y     : in  std_logic_vector(4 downto 0);
    cursor_enable : in std_logic := '1';

    -- VGA-Ausgang 640x480
    vga_hs       : out std_logic;
    vga_vs       : out std_logic;
    vga_de       : out std_logic;  -- data enable: '1' during active video
    vga_r        : out std_logic_vector(4 downto 0);
    vga_g        : out std_logic_vector(5 downto 0);
    vga_b        : out std_logic_vector(4 downto 0)
  );
end entity;

architecture rtl of vic_vga is
  -- 640x480 @ 59.94 Hz (27 MHz pixel clock, CEA-861 480p total timing)
  -- H_freq = 27 MHz / 858 = 31.47 kHz,  V_freq = 31468 / 525 = 59.94 Hz
  constant H_VIS  : natural := 640;
  constant H_TOT  : natural := 858;
  constant H_SS   : natural := 671;   -- H-Sync-Start  (640 + 31 front porch)
  constant H_SE   : natural := 767;   -- H-Sync-Ende   (671 + 96 sync width)

  constant V_VIS  : natural := 480;
  constant V_TOT  : natural := 525;
  constant V_SS   : natural := 490;   -- V-Sync-Start  (480 + 10 front porch)
  constant V_SE   : natural := 492;   -- V-Sync-Ende   (490 + 2 sync width)

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
  signal fetching       : std_logic := '0';
  signal fetch_col      : natural range 0 to 39 := 0;
  signal fetch_store_col : natural range 0 to 39 := 0;
  signal fetch_row      : natural range 0 to 24 := 0;
  signal fetch_valid    : std_logic := '0';

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
  signal cursor_pixel   : std_logic;
  signal cursor_visible : std_logic := '1';
  signal cursor_cnt     : natural range 0 to CURSOR_BLINK_DIV - 1 := 0;

begin
  -- Pixel-clock enable: divide by CLK_DIV (2 for 50 MHz, 1 for 27 MHz)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        pce <= '0';
      elsif CLK_DIV = 1 then
        pce <= '1';
      else
        pce <= not pce;
      end if;
    end if;
  end process;

  -- C64-style blinking text cursor: invert the whole character cell while
  -- visible. The kernel updates cursor_x/y through VIC registers $9001/$9002.
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cursor_cnt <= 0;
        cursor_visible <= '1';
      elsif cursor_cnt = CURSOR_BLINK_DIV - 1 then
        cursor_cnt <= 0;
        cursor_visible <= not cursor_visible;
      else
        cursor_cnt <= cursor_cnt + 1;
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
  -- Laeuft 41 System-Takte am Anfang jedes H-Blank
  -- pre-fetcht fuer die NAECHSTE Scan-Zeile
  -- Das VRAM ist synchron: vic_addr wird einen Takt vor dem Speichern
  -- ausgegeben. Ohne diesen Vorlauf landet besonders Spalte 0 mit altem
  -- RAM-Datenwert im Zeilenpuffer.
  process(clk)
    variable nv : natural range 0 to V_TOT - 1;
    variable nr : natural range 0 to 24;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fetching        <= '0';
        fetch_col       <= 0;
        fetch_store_col <= 0;
        fetch_row       <= 0;
        fetch_valid     <= '0';
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
            fetch_row       <= nr;
            fetch_col       <= 0;
            fetch_store_col <= 0;
            fetch_valid     <= '0';
            fetching        <= '1';
          end if;
        else
          -- Einen Takt nach Ausgabe der Adresse liegt das synchrone VRAM-Datum an.
          if fetch_valid = '1' then
            linebuf(fetch_store_col) <= vram_data;
            if fetch_store_col = 39 then
              fetching    <= '0';
              fetch_valid <= '0';
            else
              fetch_store_col <= fetch_store_col + 1;
            end if;
          else
            fetch_valid <= '1';
          end if;

          if fetch_col < 39 then
            fetch_col <= fetch_col + 1;
          else
            fetch_col <= 39;
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

  -- Pixel-Bit aus ROM-Muster; bit 7 im Zeichencode ist Reverse-Video.
  -- The cursor is an OR overlay on the lower scan lines. It never clears
  -- character pixels, so it cannot hide the last typed character.
  cursor_pixel <= '1' when in_text = '1' and cursor_enable = '1' and
                           cursor_visible = '1' and
                           to_integer(unsigned(cursor_x)) = col and
                           to_integer(unsigned(cursor_y)) = crow and
                           cline >= 6
                  else '0';
  pbit <= ((char_data(7 - cpix) xor char_code(7)) or cursor_pixel)
          when in_text = '1' else '0';

  -- VGA-Sync (aktiv-low)
  vga_hs <= '0' when hc >= H_SS and hc < H_SE else '1';
  vga_vs <= '0' when vc >= V_SS and vc < V_SE else '1';
  vga_de <= '1' when hc < H_VIS and vc < V_VIS else '0';

  -- VGA-Farbe: weiss auf schwarz
  vga_r <= "11111"  when pbit = '1' else "00000";
  vga_g <= "111111" when pbit = '1' else "000000";
  vga_b <= "11111"  when pbit = '1' else "00000";

end architecture;
