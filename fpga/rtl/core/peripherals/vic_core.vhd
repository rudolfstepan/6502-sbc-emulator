-- VIC Core: Video Interface Controller with text mode display
-- Implements 40×25 character text display with configurable colors and control registers
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity vic_core is
  port (
    clk          : in  std_logic;      -- System clock
    reset_n      : in  std_logic;      -- Active-low synchronous reset
    cs           : in  std_logic;      -- Chip Select (1 = device active)
    we           : in  std_logic;      -- Write Enable (1 = write, 0 = read)
    addr         : in  addr_t;         -- CPU address bus
    din          : in  data_t;         -- Data input (write data)
    dout         : out data_t;         -- Data output (read data)
    irq          : out std_logic;      -- Raster interrupt output

    -- Video timing outputs (for pixel generator, optional for now)
    h_counter    : out integer range 0 to 1023;  -- Horizontal pixel counter
    v_counter    : out integer range 0 to 1023;  -- Vertical pixel counter
    raster_irq   : out std_logic;      -- Raster interrupt strobe

    -- Video read port for the pixel generator
    pixel_text_addr  : in  integer range 0 to 2047;
    pixel_text_data  : out data_t;
    pixel_color_addr : in  integer range 0 to 255;
    pixel_color_data : out data_t
  );
end entity;

architecture rtl of vic_core is
  -- Text RAM: 0x8000-0x87FF (2KB for 40×25 characters)
  type text_ram_t is array (0 to 2047) of data_t;
  signal text_ram : text_ram_t := (others => (others => '0'));

  -- Color RAM: 0x8800-0x88FF (256 bytes, optional colors)
  type color_ram_t is array (0 to 255) of data_t;
  signal color_ram : color_ram_t := (others => (others => '0'));

  attribute ram_style : string;
  attribute ram_style of text_ram : signal is "block";
  attribute ram_style of color_ram : signal is "distributed";

  -- Control registers: 0x9000-0x900F (16 bytes)
  signal scroll_x    : data_t := (others => '0');  -- 0x9000: Horizontal scroll
  signal scroll_y    : data_t := (others => '0');  -- 0x9001: Vertical scroll
  signal raster_cmp  : data_t := x"FF";            -- 0x9002: Raster compare (init to 255 to avoid false match)
  signal mode_reg    : data_t := x"80";            -- 0x9003: Mode (display enabled)
  signal color_reg   : data_t := (others => '0');  -- 0x9004: Border/BG color
  signal reserved0   : data_t := (others => '0');  -- 0x9005: Reserved
  signal reserved1   : data_t := (others => '0');  -- 0x9006: Reserved
  signal reserved2   : data_t := (others => '0');  -- 0x9007: Reserved
  signal reserved3   : data_t := (others => '0');  -- 0x9008: Reserved
  signal reserved4   : data_t := (others => '0');  -- 0x9009: Reserved
  signal reserved5   : data_t := (others => '0');  -- 0x900A: Reserved
  signal reserved6   : data_t := (others => '0');  -- 0x900B: Reserved
  signal reserved7   : data_t := (others => '0');  -- 0x900C: Reserved
  signal reserved8   : data_t := (others => '0');  -- 0x900D: Reserved
  signal reserved9   : data_t := (others => '0');  -- 0x900E: Reserved
  signal reservedA   : data_t := (others => '0');  -- 0x900F: Reserved

  signal dout_reg   : data_t := (others => '0');  -- Output register
  signal pixel_text_data_reg  : data_t := (others => '0');
  signal pixel_color_data_reg : data_t := (others => '0');
  signal raster_irq_flag : std_logic := '0';
  signal raster_irq_armed : std_logic := '0';  -- IRQ armed when condition matches
  signal h_count : integer range 0 to 1023 := 0;
  signal v_count : integer range 0 to 1023 := 0;
  signal prev_raster_match : std_logic := '0';  -- Detect rising edge of raster match

begin
  dout <= dout_reg;
  h_counter <= h_count;
  v_counter <= v_count;
  pixel_text_data <= pixel_text_data_reg;
  pixel_color_data <= pixel_color_data_reg;

  -- Main register access process
  process(clk)
    variable text_index : natural;
    variable color_index : natural;
    variable reg_index : natural;
  begin
    if rising_edge(clk) then
      raster_irq <= '0';  -- Clear interrupt strobe by default
      pixel_text_data_reg <= text_ram(pixel_text_addr);
      pixel_color_data_reg <= color_ram(pixel_color_addr);

      if reset_n = '0' then
        scroll_x <= (others => '0');
        scroll_y <= (others => '0');
        raster_cmp <= (others => '0');
        mode_reg <= x"80";  -- Display enabled
        color_reg <= (others => '0');
        reserved0 <= (others => '0');
        reserved1 <= (others => '0');
        reserved2 <= (others => '0');
        reserved3 <= (others => '0');
        reserved4 <= (others => '0');
        reserved5 <= (others => '0');
        reserved6 <= (others => '0');
        reserved7 <= (others => '0');
        reserved8 <= (others => '0');
        reserved9 <= (others => '0');
        dout_reg <= (others => '0');
        raster_irq_flag <= '0';

      elsif cs = '1' then
        -- Determine which region is being accessed
        if unsigned(addr) >= x"8000" and unsigned(addr) <= x"87FF" then
          -- Text RAM access (0x8000-0x87FF)
          text_index := to_integer(unsigned(addr(10 downto 0)));
          if we = '1' then
            text_ram(text_index) <= din;
          end if;
          dout_reg <= text_ram(text_index);

        elsif unsigned(addr) >= x"8800" and unsigned(addr) <= x"88FF" then
          -- Color RAM access (0x8800-0x88FF)
          color_index := to_integer(unsigned(addr(7 downto 0)));
          if we = '1' then
            color_ram(color_index) <= din;
          end if;
          dout_reg <= color_ram(color_index);

        elsif unsigned(addr) >= x"9000" and unsigned(addr) <= x"900F" then
          -- Control register access (0x9000-0x900F)
          reg_index := to_integer(unsigned(addr(3 downto 0)));
          if we = '1' then
            case reg_index is
              when 0 => scroll_x <= din;
              when 1 => scroll_y <= din;
              when 2 => raster_cmp <= din;
              when 3 => mode_reg <= din;
              when 4 => color_reg <= din;
              when 5 => reserved0 <= din;
              when 6 => reserved1 <= din;
              when 7 => reserved2 <= din;
              when 8 => reserved3 <= din;
              when 9 => reserved4 <= din;
              when 10 => reserved5 <= din;
              when 11 => reserved6 <= din;
              when 12 => reserved7 <= din;
              when 13 => reserved8 <= din;
              when 14 => reserved9 <= din;
              when others => null;
            end case;
          end if;

          case reg_index is
            when 0 => dout_reg <= scroll_x;
            when 1 => dout_reg <= scroll_y;
            when 2 => dout_reg <= raster_cmp;
            when 3 => dout_reg <= mode_reg;
            when 4 => dout_reg <= color_reg;
            when 5 => dout_reg <= reserved0;
            when 6 => dout_reg <= reserved1;
            when 7 => dout_reg <= reserved2;
            when 8 => dout_reg <= reserved3;
            when 9 => dout_reg <= reserved4;
            when 10 => dout_reg <= reserved5;
            when 11 => dout_reg <= reserved6;
            when 12 => dout_reg <= reserved7;
            when 13 => dout_reg <= reserved8;
            when 14 => dout_reg <= reserved9;
            when others => dout_reg <= (others => '0');
          end case;

        else
          -- Unmapped address
          dout_reg <= (others => '0');
        end if;

        -- Raster interrupt generation
        -- Compare current vertical position with raster compare register
        -- Only compare lower 8 bits of v_count (0-255 range)
        if std_logic_vector(to_unsigned(v_count, 8)) = raster_cmp then
          raster_irq_armed <= '1';
        else
          raster_irq_armed <= '0';
        end if;

        -- Generate interrupt on rising edge of raster match (when raster_irq_armed goes high)
        if raster_irq_armed = '1' and prev_raster_match = '0' then
          raster_irq_flag <= '1';
          raster_irq <= '1';
        end if;

        prev_raster_match <= raster_irq_armed;

        -- Clear raster flag when status register is read
        if unsigned(addr) = x"8811" and we = '0' then
          raster_irq_flag <= '0';
        end if;

      else
        dout_reg <= (others => '0');
      end if;
    end if;
  end process;

  irq <= raster_irq_flag and mode_reg(5);

end architecture;
