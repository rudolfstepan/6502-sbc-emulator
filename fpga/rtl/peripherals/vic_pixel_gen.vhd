-- VIC Pixel Generator: Converts text RAM to VGA pixel output
-- Generates 640×480 @ 60Hz with 40×25 character grid (8×8 pixels per character)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_pixel_gen is
  port (
    clk          : in  std_logic;      -- System clock (50 MHz)
    reset_n      : in  std_logic;      -- Active-low reset

    -- Text/Color RAM interface (read-only from pixel gen perspective)
    text_ram_addr : out integer range 0 to 2047;
    text_ram_data : in data_t;
    color_ram_addr : out integer range 0 to 255;
    color_ram_data : in data_t;

    -- Character ROM interface
    char_rom_addr : out std_logic_vector(9 downto 0);
    char_rom_data : in data_t;

    -- Control register interface
    scroll_x      : in data_t;
    scroll_y      : in data_t;
    mode_reg      : in data_t;

    -- Video output
    h_sync        : out std_logic;     -- Horizontal sync
    v_sync        : out std_logic;     -- Vertical sync
    pixel_out     : out data_t;        -- Pixel data (8-bit color/palette)
    pixel_valid   : out std_logic      -- Pixel valid (inside visible area)
  );
end entity;

architecture rtl of vic_pixel_gen is
  -- VGA timing constants for 640×480 @ 60Hz
  -- Pixel clock: 25.175 MHz (we use 25 MHz from 50 MHz / 2)
  constant H_VISIBLE  : natural := 640;
  constant H_BLANK    : natural := 16;  -- Front porch
  constant H_SYNC_WIDTH : natural := 96;  -- Sync pulse width
  constant H_BACK     : natural := 48;  -- Back porch
  constant H_TOTAL    : natural := H_VISIBLE + H_BLANK + H_SYNC_WIDTH + H_BACK;  -- 800

  constant V_VISIBLE  : natural := 480;
  constant V_BLANK    : natural := 10;  -- Front porch
  constant V_SYNC_WIDTH : natural := 2;   -- Sync pulse width
  constant V_BACK     : natural := 33;  -- Back porch
  constant V_TOTAL    : natural := V_VISIBLE + V_BLANK + V_SYNC_WIDTH + V_BACK;  -- 525

  constant H_SYNC_START : natural := H_VISIBLE + H_BLANK;
  constant H_SYNC_END   : natural := H_SYNC_START + H_SYNC_WIDTH;
  constant V_SYNC_START : natural := V_VISIBLE + V_BLANK;
  constant V_SYNC_END   : natural := V_SYNC_START + V_SYNC_WIDTH;

  signal pixel_ce      : std_logic := '0';

  signal h_counter    : natural range 0 to H_TOTAL - 1 := 0;
  signal v_counter    : natural range 0 to V_TOTAL - 1 := 0;

  -- Character grid position (40×25)
  signal char_col     : natural range 0 to 39;
  signal char_row     : natural range 0 to 24;
  signal char_line    : natural range 0 to 7;  -- Pixel row within character
  signal char_pixel   : natural range 0 to 7;  -- Pixel column within character

  -- RAM access signals
  signal char_code    : data_t;
  signal char_color   : data_t;
  signal rom_pattern  : data_t;
  signal pixel_bit    : std_logic;

  signal h_sync_sig   : std_logic;
  signal v_sync_sig   : std_logic;
  signal in_visible   : std_logic;

begin
  -- Pixel clock enable: 50 MHz -> 25 MHz (advance every other cycle)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        pixel_ce <= '0';
      else
        pixel_ce <= not pixel_ce;
      end if;
    end if;
  end process;

  -- Horizontal and vertical counters (advance at the pixel rate)
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        h_counter <= 0;
        v_counter <= 0;
      elsif pixel_ce = '1' then
        if h_counter = H_TOTAL - 1 then
          h_counter <= 0;
          if v_counter = V_TOTAL - 1 then
            v_counter <= 0;
          else
            v_counter <= v_counter + 1;
          end if;
        else
          h_counter <= h_counter + 1;
        end if;
      end if;
    end if;
  end process;

  -- Calculate character grid position from pixel coordinates
  -- Use modulo to wrap around within 40×25 grid
  char_col <= (h_counter / 8) mod 40;
  char_row <= (v_counter / 8) mod 25;
  char_line <= v_counter mod 8;
  char_pixel <= h_counter mod 8;

  -- Generate sync signals (active-low, standard VGA polarity)
  h_sync_sig <= '0' when (h_counter >= H_SYNC_START and h_counter < H_SYNC_END) else '1';
  v_sync_sig <= '0' when (v_counter >= V_SYNC_START and v_counter < V_SYNC_END) else '1';

  -- Visible area
  in_visible <= '1' when (h_counter < H_VISIBLE and v_counter < V_VISIBLE) else '0';

  -- Text RAM addressing: row * 40 + col (40 characters per row)
  text_ram_addr <= char_row * 40 + char_col when in_visible = '1' else 0;
  color_ram_addr <= (char_row * 40 + char_col) mod 256 when in_visible = '1' else 0;

  -- Character ROM addressing: char_code & char_line
  char_rom_addr <= char_code(6 downto 0) & std_logic_vector(to_unsigned(char_line, 3));
  rom_pattern <= char_rom_data;

  -- Extract pixel from character pattern
  -- Pattern bits are [7:0] = [leftmost:rightmost]
  pixel_bit <= rom_pattern(7 - char_pixel);

  -- Output assignments
  h_sync <= h_sync_sig;
  v_sync <= v_sync_sig;
  pixel_valid <= in_visible;

  -- Pixel color output (combinational)
  pixel_out <= x"FF" when (in_visible = '1' and pixel_bit = '1') else x"00";

  -- Latch character code and color for pipelined access
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        char_code <= (others => '0');
        char_color <= (others => '0');
      elsif pixel_ce = '1' then
        char_code <= text_ram_data;
        char_color <= color_ram_data;
      end if;
    end if;
  end process;

end architecture;
