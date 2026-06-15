-- VGA boot status screen for the SD boot path.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity boot_vga_debug is
  generic (
    CLK_DIV : natural range 1 to 2 := 2
  );
  port (
    clk             : in  std_logic;
    reset_n         : in  std_logic;
    sd_init_done    : in  std_logic;
    sd_sec_read     : in  std_logic;
    sd_sec_read_end : in  std_logic;
    boot_done       : in  std_logic;
    boot_error      : in  std_logic;
    sd_ncs          : in  std_logic;
    sd_dclk         : in  std_logic;
    sd_mosi_o       : in  std_logic;
    sd_miso_i       : in  std_logic;
    loader_state    : in  std_logic_vector(3 downto 0);
    sd_sec_state    : in  std_logic_vector(4 downto 0);
    sd_cmd_state    : in  std_logic_vector(3 downto 0);
    sd_cmd_error    : in  std_logic;
    usb_connected   : in  std_logic := '0';
    usb_keycode     : in  std_logic_vector(7 downto 0) := (others => '0');
    usb_modif       : in  std_logic_vector(7 downto 0) := (others => '0');
    usb_ascii       : in  std_logic_vector(7 downto 0) := (others => '0');
    usb_phase       : in  std_logic_vector(3 downto 0) := (others => '0');
    usb_key_event   : in  std_logic := '0';
    usb_polling     : in  std_logic := '0';
    ram_test_active : in  std_logic;
    ram_test_done   : in  std_logic;
    ram_test_error  : in  std_logic;
    ram_test_phase  : in  std_logic_vector(3 downto 0);
    ram_test_addr   : in  std_logic_vector(14 downto 0);
    ram_test_fail_addr : in  std_logic_vector(14 downto 0);
    ram_test_expected  : in  data_t;
    ram_test_actual    : in  data_t;
    vga_r           : out std_logic_vector(4 downto 0);
    vga_g           : out std_logic_vector(5 downto 0);
    vga_b           : out std_logic_vector(4 downto 0);
    vga_hs          : out std_logic;
    vga_vs          : out std_logic;
    vga_de          : out std_logic
  );
end entity;

architecture rtl of boot_vga_debug is
  constant H_VIS : natural := 640;
  constant H_TOT : natural := 800;
  constant H_SS  : natural := 656;
  constant H_SE  : natural := 752;

  constant V_VIS : natural := 480;
  constant V_TOT : natural := 525;
  constant V_SS  : natural := 490;
  constant V_SE  : natural := 492;

  constant V_BORD : natural := 40;
  constant TV_END : natural := V_BORD + 400;

  constant INIT_TIMEOUT_CYC : natural := 100000000;

  signal pce : std_logic := '0';
  signal hc  : natural range 0 to H_TOT - 1 := 0;
  signal vc  : natural range 0 to V_TOT - 1 := 0;

  signal init_timeout_cnt : natural range 0 to INIT_TIMEOUT_CYC := 0;
  signal no_card_timeout  : std_logic := '0';
  signal seen_read_end    : std_logic := '0';

  signal in_text   : std_logic;
  signal active    : std_logic;
  signal v_off     : natural range 0 to V_VIS := 0;
  signal col       : natural range 0 to 39 := 0;
  signal crow      : natural range 0 to 24 := 0;
  signal cline     : natural range 0 to 7 := 0;
  signal cpix      : natural range 0 to 7 := 0;
  signal char_code : data_t := x"20";
  signal char_addr : std_logic_vector(9 downto 0);
  signal char_data : data_t;
  signal pbit      : std_logic;

  function ascii(c : character) return data_t is
  begin
    return std_logic_vector(to_unsigned(character'pos(c), 8));
  end function;

  function bit_char(b : std_logic) return data_t is
  begin
    if b = '1' then
      return x"31";
    end if;
    return x"30";
  end function;

  function hex_char(v : std_logic_vector(3 downto 0)) return data_t is
  begin
    case v is
      when x"0" => return x"30";
      when x"1" => return x"31";
      when x"2" => return x"32";
      when x"3" => return x"33";
      when x"4" => return x"34";
      when x"5" => return x"35";
      when x"6" => return x"36";
      when x"7" => return x"37";
      when x"8" => return x"38";
      when x"9" => return x"39";
      when x"A" => return x"41";
      when x"B" => return x"42";
      when x"C" => return x"43";
      when x"D" => return x"44";
      when x"E" => return x"45";
      when others => return x"46";
    end case;
  end function;

  procedure put_str(
    variable ch    : inout data_t;
    constant col_i : in natural;
    constant x     : in natural;
    constant s     : in string
  ) is
    variable idx : integer;
  begin
    if col_i >= x and col_i < x + s'length then
      idx := s'low + integer(col_i - x);
      ch := ascii(s(idx));
    end if;
  end procedure;

begin
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

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        init_timeout_cnt <= 0;
        seen_read_end    <= '0';
      else
        if sd_init_done = '0' and init_timeout_cnt < INIT_TIMEOUT_CYC then
          init_timeout_cnt <= init_timeout_cnt + 1;
        end if;
        if sd_sec_read_end = '1' then
          seen_read_end <= '1';
        end if;
      end if;
    end if;
  end process;

  no_card_timeout <= '1' when sd_init_done = '0' and init_timeout_cnt = INIT_TIMEOUT_CYC else '0';

  active  <= '1' when hc < H_VIS and vc < V_VIS else '0';
  in_text <= '1' when hc < H_VIS and vc >= V_BORD and vc < TV_END else '0';
  v_off   <= (vc - V_BORD) when vc >= V_BORD else 0;
  col     <= hc / 16 when hc < H_VIS else 0;
  crow    <= v_off / 16;
  cline   <= (v_off / 2) mod 8;
  cpix    <= (hc / 2) mod 8;

  process(crow, col, sd_init_done, no_card_timeout, sd_sec_read,
          seen_read_end, boot_done, boot_error, sd_cmd_error,
          loader_state, sd_sec_state, sd_cmd_state,
          sd_ncs, sd_dclk, sd_mosi_o, sd_miso_i,
          usb_connected, usb_keycode, usb_modif, usb_ascii, usb_phase,
          usb_key_event, usb_polling,
          ram_test_active, ram_test_done, ram_test_error,
          ram_test_phase, ram_test_addr, ram_test_fail_addr,
          ram_test_expected, ram_test_actual)
    variable ch : data_t;
  begin
    ch := x"20";

    case crow is
      when 2 =>
        put_str(ch, col, 11, "PIX16 6502 SBC");
      when 4 =>
        put_str(ch, col, 12, "SD BOOT DEBUG");
      when 6 =>
        if ram_test_error = '1' then
          put_str(ch, col, 9, "SDRAM TEST FAILED");
        elsif boot_error = '1' then
          put_str(ch, col, 5, "BOOT ERROR - CHECK SD IMAGE");
        elsif boot_done = '1' and ram_test_done = '1' then
          put_str(ch, col, 8, "BOOT OK - STARTING CPU");
        elsif boot_done = '1' then
          put_str(ch, col, 8, "SD OK - TESTING SDRAM");
        elsif no_card_timeout = '1' then
          put_str(ch, col, 4, "NO SD CARD OR INIT TIMEOUT");
        elsif sd_init_done = '1' then
          put_str(ch, col, 7, "SD CARD INITIALIZED");
        else
          put_str(ch, col, 7, "WAITING FOR SD CARD");
        end if;
      when 8 =>
        put_str(ch, col, 4, "SD INIT:");
        if sd_init_done = '1' then
          put_str(ch, col, 15, "OK");
        elsif no_card_timeout = '1' then
          put_str(ch, col, 15, "TIMEOUT");
        else
          put_str(ch, col, 15, "WAIT");
        end if;
      when 9 =>
        put_str(ch, col, 4, "SECTOR:");
        if sd_sec_read = '1' then
          put_str(ch, col, 15, "READ");
        elsif seen_read_end = '1' then
          put_str(ch, col, 15, "DONE");
        else
          put_str(ch, col, 15, "IDLE");
        end if;
      when 10 =>
        put_str(ch, col, 4, "SD BOOT:");
        if boot_error = '1' then
          put_str(ch, col, 15, "ERROR");
        elsif boot_done = '1' then
          put_str(ch, col, 15, "DONE");
        else
          put_str(ch, col, 15, "LOADING");
        end if;
      when 11 =>
        put_str(ch, col, 4, "RAM TEST:");
        if ram_test_error = '1' then
          put_str(ch, col, 15, "ERROR");
        elsif ram_test_done = '1' then
          put_str(ch, col, 15, "OK");
        elsif ram_test_active = '1' then
          put_str(ch, col, 15, "RUN");
        elsif boot_done = '1' then
          put_str(ch, col, 15, "WAIT");
        else
          put_str(ch, col, 15, "PENDING");
        end if;
      when 12 =>
        put_str(ch, col, 4, "RAM PHASE: $");
        put_str(ch, col, 18, "ADDR: $");
        if col = 16 then
          ch := hex_char(ram_test_phase);
        elsif col = 25 then
          ch := hex_char('0' & ram_test_addr(14 downto 12));
        elsif col = 26 then
          ch := hex_char(ram_test_addr(11 downto 8));
        elsif col = 27 then
          ch := hex_char(ram_test_addr(7 downto 4));
        elsif col = 28 then
          ch := hex_char(ram_test_addr(3 downto 0));
        end if;
      when 13 =>
        if ram_test_error = '1' then
          put_str(ch, col, 4, "FAIL: $");
          put_str(ch, col, 16, "EXP: $");
          put_str(ch, col, 25, "GOT: $");
          if col = 11 then
            ch := hex_char('0' & ram_test_fail_addr(14 downto 12));
          elsif col = 12 then
            ch := hex_char(ram_test_fail_addr(11 downto 8));
          elsif col = 13 then
            ch := hex_char(ram_test_fail_addr(7 downto 4));
          elsif col = 14 then
            ch := hex_char(ram_test_fail_addr(3 downto 0));
          elsif col = 22 then
            ch := hex_char(ram_test_expected(7 downto 4));
          elsif col = 23 then
            ch := hex_char(ram_test_expected(3 downto 0));
          elsif col = 31 then
            ch := hex_char(ram_test_actual(7 downto 4));
          elsif col = 32 then
            ch := hex_char(ram_test_actual(3 downto 0));
          end if;
        else
          put_str(ch, col, 4, "LOADER: $");
          put_str(ch, col, 17, "SEC: $");
          put_str(ch, col, 28, "CMD: $");
        end if;
        if ram_test_error = '0' and col = 13 then
          ch := hex_char(loader_state);
        elsif ram_test_error = '0' and col = 23 then
          ch := hex_char("000" & sd_sec_state(4));
        elsif ram_test_error = '0' and col = 24 then
          ch := hex_char(sd_sec_state(3 downto 0));
        elsif ram_test_error = '0' and col = 34 then
          ch := hex_char(sd_cmd_state);
        end if;
      when 15 =>
        put_str(ch, col, 4, "PINS: NCS=");
        put_str(ch, col, 17, "CLK=");
        put_str(ch, col, 24, "MOSI=");
        put_str(ch, col, 32, "MISO=");
        if col = 14 then
          ch := bit_char(sd_ncs);
        elsif col = 21 then
          ch := bit_char(sd_dclk);
        elsif col = 29 then
          ch := bit_char(sd_mosi_o);
        elsif col = 37 then
          ch := bit_char(sd_miso_i);
        end if;
      when 16 =>
        put_str(ch, col, 4, "FLAGS: DONE=");
        put_str(ch, col, 18, "ERR=");
        put_str(ch, col, 25, "INIT=");
        put_str(ch, col, 33, "CMD=");
        if col = 16 then
          ch := bit_char(boot_done);
        elsif col = 22 then
          ch := bit_char(boot_error);
        elsif col = 30 then
          ch := bit_char(sd_init_done);
        elsif col = 37 then
          ch := bit_char(sd_cmd_error);
        end if;
      when 17 =>
        -- USB HID: CON=X  KEY=$XX  MOD=$XX
        put_str(ch, col, 4, "USB HID: CON=");
        put_str(ch, col, 19, "KEY=$");
        put_str(ch, col, 27, "MOD=$");
        if col = 17 then
          ch := bit_char(usb_connected);
        elsif col = 24 then
          ch := hex_char(usb_keycode(7 downto 4));
        elsif col = 25 then
          ch := hex_char(usb_keycode(3 downto 0));
        elsif col = 32 then
          ch := hex_char(usb_modif(7 downto 4));
        elsif col = 33 then
          ch := hex_char(usb_modif(3 downto 0));
        end if;
      when 18 =>
        -- USB HID: PH=X DATA=$XX POLL=X EV=X
        -- PH=0:init 1:detect 2:rst 3:enum 4:poll F:err
        -- POLL=1 means actively polling, EV toggles when key received
        put_str(ch, col, 4, "USB HID: PH=");
        put_str(ch, col, 17, "DATA=$");
        put_str(ch, col, 28, "POLL=");
        put_str(ch, col, 37, "EV=");
        if col = 16 then
          ch := hex_char(usb_phase);
        elsif col = 23 then
          ch := hex_char(usb_ascii(7 downto 4));
        elsif col = 24 then
          ch := hex_char(usb_ascii(3 downto 0));
        elsif col = 33 then
          ch := bit_char(usb_polling);
        elsif col = 39 then
          ch := bit_char(usb_key_event);
        end if;
      when 19 =>
        put_str(ch, col, 6, "UART DEBUG STILL ACTIVE");
      when 20 =>
        put_str(ch, col, 4, "SCREEN SWITCHES AFTER SD AND RAM OK");
      when 22 =>
        -- Display all 32 PETSCII block-graphics glyphs (ROM codes 0x60-0x7F).
        -- "GFX:" label at cols 1-4, then one glyph per column at cols 6-37.
        put_str(ch, col, 1, "GFX:");
        if col >= 6 and col <= 37 then
          ch := std_logic_vector(to_unsigned(16#60# + (col - 6), 8));
        end if;
      when others =>
        null;
    end case;

    char_code <= ch;
  end process;

  char_addr <= char_code(6 downto 0) & std_logic_vector(to_unsigned(cline, 3));
  char_i : entity work.char_rom
    port map (addr => char_addr, dout => char_data);

  pbit <= (char_data(7 - cpix) xor char_code(7)) when in_text = '1' else '0';

  vga_hs <= '0' when hc >= H_SS and hc < H_SE else '1';
  vga_vs <= '0' when vc >= V_SS and vc < V_SE else '1';
  vga_de <= active;

  vga_r <= "11111" when pbit = '1' and active = '1' and (boot_error = '1' or ram_test_error = '1' or no_card_timeout = '1') else
           "11111" when pbit = '1' and active = '1' and crow = 2 else
           "11100" when pbit = '1' and active = '1' else
           "00000";
  vga_g <= "000000" when pbit = '1' and active = '1' and (boot_error = '1' or ram_test_error = '1' or no_card_timeout = '1') else
           "111111" when pbit = '1' and active = '1' else
           "000000";
  vga_b <= "00000" when pbit = '1' and active = '1' and (boot_error = '1' or ram_test_error = '1' or no_card_timeout = '1') else
           "11111" when pbit = '1' and active = '1' and crow = 2 else
           "00000";
end architecture;
