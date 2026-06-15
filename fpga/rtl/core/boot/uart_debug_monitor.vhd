-- UART machine-language style monitor for FPGA-side RAM inspection.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity uart_debug_monitor is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    enter_btn : in  std_logic;

    rx_data  : in  data_t;
    rx_valid : in  std_logic;

    tx_busy  : in  std_logic;
    tx_data  : out data_t;
    tx_valid : out std_logic;
    active   : out std_logic;

    mem_req   : out std_logic;
    mem_we    : out std_logic;
    mem_addr  : out addr_t;
    mem_wdata : out data_t;
    mem_rdata : in  data_t;
    mem_ready : in  std_logic;

    jump_req  : out std_logic;
    jump_addr : out addr_t;

    usb_connected : in std_logic := '0';
    usb_keycode   : in std_logic_vector(7 downto 0) := (others => '0');
    usb_modif     : in std_logic_vector(7 downto 0) := (others => '0');
    usb_ascii     : in std_logic_vector(7 downto 0) := (others => '0');
    usb_phase     : in std_logic_vector(3 downto 0) := (others => '0');
    usb_key_event : in std_logic := '0';
    usb_polling   : in std_logic := '0'
  );
end entity;

architecture rtl of uart_debug_monitor is
  -- Small hardware machine monitor. It owns the UART while active and talks to
  -- the system through one-byte memory transactions (mem_req/mem_ready).
  -- The CPU is held by the board/core top, so monitor reads/writes cannot race
  -- normal 6502 bus cycles.
  type state_t is (
    S_OFF, S_SEND_MSG, S_INPUT, S_EXEC,
    S_WRITE_REQ, S_WRITE_WAIT,
    S_LOAD_INPUT, S_LOAD_WRITE_REQ, S_LOAD_WRITE_WAIT,
    S_DUMP_CR, S_DUMP_LF,
    S_DUMP_A3, S_DUMP_A2, S_DUMP_A1, S_DUMP_A0, S_DUMP_COLON,
    S_DUMP_REQ, S_DUMP_WAIT, S_DUMP_SPACE, S_DUMP_B1, S_DUMP_B0,
    S_DUMP_NEXT, S_DUMP_PAD_SP, S_DUMP_PAD_HI, S_DUMP_PAD_LO,
    S_DUMP_ASC_GAP1, S_DUMP_ASC_GAP2, S_DUMP_ASC_OPEN,
    S_DUMP_ASC_CHAR, S_DUMP_ASC_CLOSE, S_DUMP_END_CR, S_DUMP_END_LF,
    S_DIS_CR, S_DIS_LF,
    S_DIS_A3, S_DIS_A2, S_DIS_A1, S_DIS_A0, S_DIS_COLON,
    S_DIS_REQ0, S_DIS_WAIT0, S_DIS_REQ1, S_DIS_WAIT1,
    S_DIS_REQ2, S_DIS_WAIT2,
    S_DIS_BYTE_SP, S_DIS_BYTE_HI, S_DIS_BYTE_LO, S_DIS_BYTE_NEXT,
    S_DIS_GAP1, S_DIS_GAP2, S_DIS_MNEM, S_DIS_OPER_SP,
    S_DIS_OPER_CHAR, S_DIS_NEXT, S_DIS_END_LF,
    S_USB_DIAG,
    S_DEACT
  );

  type msg_t is (MSG_BANNER, MSG_HELP, MSG_ERR, MSG_RANGE, MSG_OK, MSG_PROMPT, MSG_GO, MSG_LOAD);
  type dump_line_t is array (0 to 15) of data_t;

  signal state       : state_t := S_OFF;
  signal after_msg   : state_t := S_INPUT;
  signal msg         : msg_t := MSG_BANNER;
  signal msg_idx     : natural range 0 to 127 := 0;
  signal active_reg  : std_logic := '0';
  signal btn_d       : std_logic := '0';

  signal tx_data_reg  : data_t := (others => '0');
  signal tx_valid_reg : std_logic := '0';
  signal wait_uart    : std_logic := '0';
  signal seen_busy    : std_logic := '0';

  signal cmd       : data_t := (others => '0');
  signal arg0      : addr_t := (others => '0');
  signal arg1      : addr_t := (others => '0');
  signal arg0_nibs : natural range 0 to 4 := 0;
  signal arg1_nibs : natural range 0 to 4 := 0;
  signal arg_sel   : natural range 0 to 1 := 0;

  signal cur_addr   : addr_t := (others => '0');
  signal dump_end   : addr_t := (others => '0');
  signal write_data : data_t := (others => '0');
  signal read_data  : data_t := (others => '0');
  signal dump_count : natural range 0 to 15 := 0;
  signal dump_line  : dump_line_t := (others => x"00");
  signal dump_ascii_last : natural range 0 to 15 := 0;
  signal dump_ascii_idx  : natural range 0 to 15 := 0;
  signal dump_final_line : std_logic := '0';
  signal load_base   : addr_t := (others => '0');
  signal load_hi_nib : std_logic_vector(3 downto 0) := (others => '0');
  signal load_half   : std_logic := '0';
  signal dis_op     : data_t := (others => '0');
  signal dis_b1     : data_t := (others => '0');
  signal dis_b2     : data_t := (others => '0');
  signal dis_len    : natural range 1 to 3 := 1;
  signal dis_mode   : natural range 0 to 12 := 0;
  signal dis_byte   : natural range 0 to 2 := 0;
  signal dis_midx   : natural range 0 to 2 := 0;
  signal dis_oidx   : natural range 0 to 6 := 0;

  signal mem_req_reg   : std_logic := '0';
  signal mem_we_reg    : std_logic := '0';
  signal mem_addr_reg  : addr_t := (others => '0');
  signal mem_wdata_reg : data_t := (others => '0');
  signal jump_req_reg  : std_logic := '0';
  signal jump_addr_reg : addr_t := (others => '0');
  signal usb_idx       : natural range 0 to 48 := 0;

  constant MODE_IMP  : natural := 0;
  constant MODE_ACC  : natural := 1;
  constant MODE_IMM  : natural := 2;
  constant MODE_ZP   : natural := 3;
  constant MODE_ZPX  : natural := 4;
  constant MODE_ZPY  : natural := 5;
  constant MODE_ABS  : natural := 6;
  constant MODE_ABSX : natural := 7;
  constant MODE_ABSY : natural := 8;
  constant MODE_IND  : natural := 9;
  constant MODE_INDX : natural := 10;
  constant MODE_INDY : natural := 11;
  constant MODE_REL  : natural := 12;

  function ascii(c : character) return data_t is
  begin
    return std_logic_vector(to_unsigned(character'pos(c), 8));
  end function;

  function upper(c : data_t) return data_t is
  begin
    if c >= x"61" and c <= x"7A" then
      return std_logic_vector(unsigned(c) - 32);
    end if;
    return c;
  end function;

  function is_space(c : data_t) return boolean is
  begin
    return c = x"20" or c = x"09";
  end function;

  function is_eol(c : data_t) return boolean is
  begin
    return c = x"0D" or c = x"0A";
  end function;

  function is_hex(c : data_t) return boolean is
  begin
    return (c >= x"30" and c <= x"39") or
           (c >= x"41" and c <= x"46") or
           (c >= x"61" and c <= x"66");
  end function;

  function is_monitor_addr(a : addr_t) return boolean is
    variable u : unsigned(15 downto 0);
  begin
    -- Keep this whitelist in sync with the memory master in
    -- sbc_t65_sdram_boot_top. Stubbed video/sound ranges are deliberately not
    -- exposed until real storage/registers exist behind them.
    u := unsigned(a);
    return u <= ADDR_SRAM_LAST or
           (u >= ADDR_VIC_TEXT_BASE and u <= ADDR_UART_LAST) or
           u >= ADDR_ROM_BASE;
  end function;

  function is_monitor_range(a : addr_t; b : addr_t) return boolean is
    variable au : unsigned(15 downto 0);
    variable bu : unsigned(15 downto 0);
  begin
    au := unsigned(a);
    bu := unsigned(b);
    if not is_monitor_addr(a) or not is_monitor_addr(b) then
      return false;
    end if;
    -- The hex loader writes sequentially. Reject ranges that cross a hole in
    -- the current map, for example $8813 -> $8814 or $7FFF -> $8000.
    if bu < au then
      return false;
    end if;
    return bu <= ADDR_UART_LAST or au >= ADDR_ROM_BASE;
  end function;

  function monitor_span_end(a : addr_t; extra : natural) return addr_t is
    variable au : unsigned(15 downto 0);
    variable lim : unsigned(15 downto 0);
    variable sum : unsigned(15 downto 0);
  begin
    au := unsigned(a);
    if au >= ADDR_ROM_BASE then
      lim := ADDR_ROM_LAST;
    else
      lim := ADDR_UART_LAST;
    end if;
    sum := au + to_unsigned(extra, 16);
    if sum < au or sum > lim then
      return std_logic_vector(lim);
    end if;
    return std_logic_vector(sum);
  end function;

  function hex_nibble(c : data_t) return std_logic_vector is
    variable u : data_t;
  begin
    u := upper(c);
    if u <= x"39" then
      return std_logic_vector(unsigned(u(3 downto 0)));
    end if;
    return std_logic_vector(to_unsigned(to_integer(unsigned(u)) - 55, 4));
  end function;

  function hex_char(v : std_logic_vector(3 downto 0)) return data_t is
    variable n : natural;
  begin
    n := to_integer(unsigned(v));
    if n < 10 then
      return std_logic_vector(to_unsigned(48 + n, 8));
    end if;
    return std_logic_vector(to_unsigned(55 + n, 8));
  end function;

  function printable_char(v : data_t) return data_t is
  begin
    if v >= x"20" and v <= x"7E" then
      return v;
    end if;
    return ascii('.');
  end function;

  function pick3(a : character; b : character; c : character; i : natural) return data_t is
  begin
    case i is
      when 0 => return ascii(a);
      when 1 => return ascii(b);
      when others => return ascii(c);
    end case;
  end function;

  function opcode_len(op : data_t) return natural is
    variable n : natural;
  begin
    n := to_integer(unsigned(op));
    case n is
      when 16#01# | 16#05# | 16#06# | 16#09# | 16#10# | 16#11# | 16#15# | 16#16# |
           16#21# | 16#24# | 16#25# | 16#26# | 16#29# | 16#30# | 16#31# | 16#35# | 16#36# |
           16#41# | 16#45# | 16#46# | 16#49# | 16#50# | 16#51# | 16#55# | 16#56# |
           16#61# | 16#65# | 16#66# | 16#69# | 16#70# | 16#71# | 16#75# | 16#76# |
           16#81# | 16#84# | 16#85# | 16#86# | 16#90# | 16#91# | 16#94# | 16#95# | 16#96# |
           16#A0# | 16#A1# | 16#A2# | 16#A4# | 16#A5# | 16#A6# | 16#A9# | 16#B0# | 16#B1# | 16#B4# | 16#B5# | 16#B6# |
           16#C0# | 16#C1# | 16#C4# | 16#C5# | 16#C6# | 16#C9# | 16#D0# | 16#D1# | 16#D5# | 16#D6# |
           16#E0# | 16#E1# | 16#E4# | 16#E5# | 16#E6# | 16#E9# | 16#F0# | 16#F1# | 16#F5# | 16#F6# =>
        return 2;
      when 16#0D# | 16#0E# | 16#19# | 16#1D# | 16#1E# | 16#20# | 16#2C# | 16#2D# | 16#2E# | 16#39# | 16#3D# | 16#3E# |
           16#4C# | 16#4D# | 16#4E# | 16#59# | 16#5D# | 16#5E# | 16#6C# | 16#6D# | 16#6E# | 16#79# | 16#7D# | 16#7E# |
           16#8C# | 16#8D# | 16#8E# | 16#99# | 16#9D# | 16#AC# | 16#AD# | 16#AE# | 16#B9# | 16#BC# | 16#BD# | 16#BE# |
           16#CC# | 16#CD# | 16#CE# | 16#D9# | 16#DD# | 16#DE# | 16#EC# | 16#ED# | 16#EE# | 16#F9# | 16#FD# | 16#FE# =>
        return 3;
      when others =>
        return 1;
    end case;
  end function;

  function opcode_mode(op : data_t) return natural is
    variable n : natural;
  begin
    n := to_integer(unsigned(op));
    case n is
      when 16#0A# | 16#2A# | 16#4A# | 16#6A# =>
        return MODE_ACC;
      when 16#09# | 16#29# | 16#49# | 16#69# | 16#A0# | 16#A2# | 16#A9# |
           16#C0# | 16#C9# | 16#E0# | 16#E9# =>
        return MODE_IMM;
      when 16#05# | 16#06# | 16#24# | 16#25# | 16#26# | 16#45# | 16#46# |
           16#65# | 16#66# | 16#84# | 16#85# | 16#86# | 16#A4# | 16#A5# | 16#A6# |
           16#C4# | 16#C5# | 16#C6# | 16#E4# | 16#E5# | 16#E6# =>
        return MODE_ZP;
      when 16#15# | 16#16# | 16#35# | 16#36# | 16#55# | 16#56# | 16#75# | 16#76# |
           16#94# | 16#95# | 16#B4# | 16#B5# | 16#D5# | 16#D6# | 16#F5# | 16#F6# =>
        return MODE_ZPX;
      when 16#96# | 16#B6# =>
        return MODE_ZPY;
      when 16#0D# | 16#0E# | 16#20# | 16#2C# | 16#2D# | 16#2E# | 16#4C# | 16#4D# | 16#4E# |
           16#6D# | 16#6E# | 16#8C# | 16#8D# | 16#8E# | 16#AC# | 16#AD# | 16#AE# |
           16#CC# | 16#CD# | 16#CE# | 16#EC# | 16#ED# | 16#EE# =>
        return MODE_ABS;
      when 16#1D# | 16#1E# | 16#3D# | 16#3E# | 16#5D# | 16#5E# | 16#7D# | 16#7E# |
           16#9D# | 16#BC# | 16#BD# | 16#DD# | 16#DE# | 16#FD# | 16#FE# =>
        return MODE_ABSX;
      when 16#19# | 16#39# | 16#59# | 16#79# | 16#99# | 16#B9# | 16#BE# | 16#D9# | 16#F9# =>
        return MODE_ABSY;
      when 16#6C# =>
        return MODE_IND;
      when 16#01# | 16#21# | 16#41# | 16#61# | 16#81# | 16#A1# | 16#C1# | 16#E1# =>
        return MODE_INDX;
      when 16#11# | 16#31# | 16#51# | 16#71# | 16#91# | 16#B1# | 16#D1# | 16#F1# =>
        return MODE_INDY;
      when 16#10# | 16#30# | 16#50# | 16#70# | 16#90# | 16#B0# | 16#D0# | 16#F0# =>
        return MODE_REL;
      when others =>
        return MODE_IMP;
    end case;
  end function;

  function opcode_mnemonic_char(op : data_t; i : natural) return data_t is
    variable n : natural;
  begin
    n := to_integer(unsigned(op));
    case n is
      when 16#00# => return pick3('B', 'R', 'K', i);
      when 16#01# | 16#05# | 16#09# | 16#0D# | 16#11# | 16#15# | 16#19# | 16#1D# => return pick3('O', 'R', 'A', i);
      when 16#06# | 16#0A# | 16#0E# | 16#16# | 16#1E# => return pick3('A', 'S', 'L', i);
      when 16#08# => return pick3('P', 'H', 'P', i);
      when 16#10# => return pick3('B', 'P', 'L', i);
      when 16#18# => return pick3('C', 'L', 'C', i);
      when 16#20# => return pick3('J', 'S', 'R', i);
      when 16#21# | 16#25# | 16#29# | 16#2D# | 16#31# | 16#35# | 16#39# | 16#3D# => return pick3('A', 'N', 'D', i);
      when 16#24# | 16#2C# => return pick3('B', 'I', 'T', i);
      when 16#26# | 16#2A# | 16#2E# | 16#36# | 16#3E# => return pick3('R', 'O', 'L', i);
      when 16#28# => return pick3('P', 'L', 'P', i);
      when 16#30# => return pick3('B', 'M', 'I', i);
      when 16#38# => return pick3('S', 'E', 'C', i);
      when 16#40# => return pick3('R', 'T', 'I', i);
      when 16#41# | 16#45# | 16#49# | 16#4D# | 16#51# | 16#55# | 16#59# | 16#5D# => return pick3('E', 'O', 'R', i);
      when 16#46# | 16#4A# | 16#4E# | 16#56# | 16#5E# => return pick3('L', 'S', 'R', i);
      when 16#48# => return pick3('P', 'H', 'A', i);
      when 16#4C# | 16#6C# => return pick3('J', 'M', 'P', i);
      when 16#50# => return pick3('B', 'V', 'C', i);
      when 16#58# => return pick3('C', 'L', 'I', i);
      when 16#60# => return pick3('R', 'T', 'S', i);
      when 16#61# | 16#65# | 16#69# | 16#6D# | 16#71# | 16#75# | 16#79# | 16#7D# => return pick3('A', 'D', 'C', i);
      when 16#66# | 16#6A# | 16#6E# | 16#76# | 16#7E# => return pick3('R', 'O', 'R', i);
      when 16#68# => return pick3('P', 'L', 'A', i);
      when 16#70# => return pick3('B', 'V', 'S', i);
      when 16#78# => return pick3('S', 'E', 'I', i);
      when 16#81# | 16#85# | 16#8D# | 16#91# | 16#95# | 16#99# | 16#9D# => return pick3('S', 'T', 'A', i);
      when 16#84# | 16#8C# | 16#94# => return pick3('S', 'T', 'Y', i);
      when 16#86# | 16#8E# | 16#96# => return pick3('S', 'T', 'X', i);
      when 16#88# => return pick3('D', 'E', 'Y', i);
      when 16#8A# => return pick3('T', 'X', 'A', i);
      when 16#90# => return pick3('B', 'C', 'C', i);
      when 16#98# => return pick3('T', 'Y', 'A', i);
      when 16#9A# => return pick3('T', 'X', 'S', i);
      when 16#A0# | 16#A4# | 16#AC# | 16#B4# | 16#BC# => return pick3('L', 'D', 'Y', i);
      when 16#A1# | 16#A5# | 16#A9# | 16#AD# | 16#B1# | 16#B5# | 16#B9# | 16#BD# => return pick3('L', 'D', 'A', i);
      when 16#A2# | 16#A6# | 16#AE# | 16#B6# | 16#BE# => return pick3('L', 'D', 'X', i);
      when 16#A8# => return pick3('T', 'A', 'Y', i);
      when 16#AA# => return pick3('T', 'A', 'X', i);
      when 16#B0# => return pick3('B', 'C', 'S', i);
      when 16#B8# => return pick3('C', 'L', 'V', i);
      when 16#BA# => return pick3('T', 'S', 'X', i);
      when 16#C0# | 16#C4# | 16#CC# => return pick3('C', 'P', 'Y', i);
      when 16#C1# | 16#C5# | 16#C9# | 16#CD# | 16#D1# | 16#D5# | 16#D9# | 16#DD# => return pick3('C', 'M', 'P', i);
      when 16#C6# | 16#CE# | 16#D6# | 16#DE# => return pick3('D', 'E', 'C', i);
      when 16#C8# => return pick3('I', 'N', 'Y', i);
      when 16#CA# => return pick3('D', 'E', 'X', i);
      when 16#D0# => return pick3('B', 'N', 'E', i);
      when 16#D8# => return pick3('C', 'L', 'D', i);
      when 16#E0# | 16#E4# | 16#EC# => return pick3('C', 'P', 'X', i);
      when 16#E1# | 16#E5# | 16#E9# | 16#ED# | 16#F1# | 16#F5# | 16#F9# | 16#FD# => return pick3('S', 'B', 'C', i);
      when 16#E6# | 16#EE# | 16#F6# | 16#FE# => return pick3('I', 'N', 'C', i);
      when 16#E8# => return pick3('I', 'N', 'X', i);
      when 16#EA# => return pick3('N', 'O', 'P', i);
      when 16#F0# => return pick3('B', 'E', 'Q', i);
      when 16#F8# => return pick3('S', 'E', 'D', i);
      when others => return pick3('?', '?', '?', i);
    end case;
  end function;

  function operand_len(mode : natural) return natural is
  begin
    case mode is
      when MODE_IMP => return 0;
      when MODE_ACC => return 1;
      when MODE_ZP | MODE_ABS | MODE_REL => return 5;
      when MODE_IMM => return 4;
      when MODE_ZPX | MODE_ZPY => return 7;
      when MODE_ABSX | MODE_ABSY | MODE_IND | MODE_INDX | MODE_INDY => return 7;
      when others => return 0;
    end case;
  end function;

  function operand_char(mode : natural; i : natural; b1 : data_t; b2 : data_t; base : addr_t) return data_t is
    variable off : integer;
    variable target_i : integer;
    variable target : addr_t;
  begin
    if mode = MODE_REL then
      off := to_integer(unsigned(b1));
      if off >= 128 then
        off := off - 256;
      end if;
      target_i := to_integer(unsigned(base)) + 2 + off;
      if target_i < 0 then
        target_i := target_i + 65536;
      end if;
      target := std_logic_vector(to_unsigned(target_i mod 65536, 16));
    else
      target := b2 & b1;
    end if;

    case mode is
      when MODE_ACC =>
        return ascii('A');
      when MODE_IMM =>
        case i is
          when 0 => return ascii('#');
          when 1 => return ascii('$');
          when 2 => return hex_char(b1(7 downto 4));
          when others => return hex_char(b1(3 downto 0));
        end case;
      when MODE_ZP =>
        case i is
          when 0 => return ascii('$');
          when 1 => return ascii('0');
          when 2 => return ascii('0');
          when 3 => return hex_char(b1(7 downto 4));
          when others => return hex_char(b1(3 downto 0));
        end case;
      when MODE_ZPX | MODE_ZPY =>
        case i is
          when 0 => return ascii('$');
          when 1 => return ascii('0');
          when 2 => return ascii('0');
          when 3 => return hex_char(b1(7 downto 4));
          when 4 => return hex_char(b1(3 downto 0));
          when 5 => return ascii(',');
          when others =>
            if mode = MODE_ZPX then
              return ascii('X');
            end if;
            return ascii('Y');
        end case;
      when MODE_ABS | MODE_ABSX | MODE_ABSY | MODE_REL =>
        case i is
          when 0 => return ascii('$');
          when 1 => return hex_char(target(15 downto 12));
          when 2 => return hex_char(target(11 downto 8));
          when 3 => return hex_char(target(7 downto 4));
          when 4 => return hex_char(target(3 downto 0));
          when 5 => return ascii(',');
          when others =>
            if mode = MODE_ABSX then
              return ascii('X');
            end if;
            return ascii('Y');
        end case;
      when MODE_IND =>
        case i is
          when 0 => return ascii('(');
          when 1 => return ascii('$');
          when 2 => return hex_char(b2(7 downto 4));
          when 3 => return hex_char(b2(3 downto 0));
          when 4 => return hex_char(b1(7 downto 4));
          when 5 => return hex_char(b1(3 downto 0));
          when others => return ascii(')');
        end case;
      when MODE_INDX =>
        case i is
          when 0 => return ascii('(');
          when 1 => return ascii('$');
          when 2 => return hex_char(b1(7 downto 4));
          when 3 => return hex_char(b1(3 downto 0));
          when 4 => return ascii(',');
          when 5 => return ascii('X');
          when others => return ascii(')');
        end case;
      when MODE_INDY =>
        case i is
          when 0 => return ascii('(');
          when 1 => return ascii('$');
          when 2 => return hex_char(b1(7 downto 4));
          when 3 => return hex_char(b1(3 downto 0));
          when 4 => return ascii(')');
          when 5 => return ascii(',');
          when others => return ascii('Y');
        end case;
      when others =>
        return ascii(' ');
    end case;
  end function;

  function msg_len(m : msg_t) return natural is
  begin
    case m is
      when MSG_BANNER => return 28;
      when MSG_HELP   => return 119;
      when MSG_ERR    => return 5;
      when MSG_RANGE  => return 15;
      when MSG_OK     => return 6;
      when MSG_PROMPT => return 2;
      when MSG_GO     => return 6;
      when MSG_LOAD   => return 20;
    end case;
  end function;

  function msg_char(m : msg_t; i : natural) return data_t is
  begin
    case m is
      when MSG_BANNER =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('F'); when 3 => return ascii('P');
          when 4 => return ascii('G'); when 5 => return ascii('A');
          when 6 => return ascii(' ');
          when 7 => return ascii('M'); when 8 => return ascii('O');
          when 9 => return ascii('N'); when 10 => return ascii('I');
          when 11 => return ascii('T'); when 12 => return ascii('O');
          when 13 => return ascii('R');
          when 14 => return x"0D"; when 15 => return x"0A";
          when 16 => return ascii('H'); when 17 => return ascii(' ');
          when 18 => return ascii('f'); when 19 => return ascii('o');
          when 20 => return ascii('r'); when 21 => return ascii(' ');
          when 22 => return ascii('h'); when 23 => return ascii('e');
          when 24 => return ascii('l'); when 25 => return ascii('p');
          when 26 => return x"0D"; when 27 => return x"0A";
          when others => return x"00";
        end case;
      when MSG_HELP =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('M'); when 3 => return ascii(' ');
          when 4 => return ascii('a'); when 5 => return ascii('d');
          when 6 => return ascii('d'); when 7 => return ascii('r');
          when 8 => return ascii(' ');
          when 9 => return ascii('['); when 10 => return ascii('e');
          when 11 => return ascii('n'); when 12 => return ascii('d');
          when 13 => return ascii(']'); when 14 => return ascii(' ');
          when 15 => return ascii('-'); when 16 => return ascii(' ');
          when 17 => return ascii('m'); when 18 => return ascii('e');
          when 19 => return ascii('m'); when 20 => return ascii('o');
          when 21 => return ascii('r'); when 22 => return ascii('y');
          when 23 => return x"0D"; when 24 => return x"0A";
          when 25 => return ascii('D'); when 26 => return ascii(' ');
          when 27 => return ascii('a'); when 28 => return ascii('d');
          when 29 => return ascii('d'); when 30 => return ascii('r');
          when 31 => return ascii(' ');
          when 32 => return ascii('['); when 33 => return ascii('e');
          when 34 => return ascii('n'); when 35 => return ascii('d');
          when 36 => return ascii(']'); when 37 => return ascii(' ');
          when 38 => return ascii('-'); when 39 => return ascii(' ');
          when 40 => return ascii('d'); when 41 => return ascii('i');
          when 42 => return ascii('s'); when 43 => return ascii('a');
          when 44 => return ascii('s'); when 45 => return ascii('m');
          when 46 => return x"0D"; when 47 => return x"0A";
          when 48 => return ascii('E'); when 49 => return ascii(' ');
          when 50 => return ascii('a'); when 51 => return ascii('d');
          when 52 => return ascii('d'); when 53 => return ascii('r');
          when 54 => return ascii(' ');
          when 55 => return ascii('b'); when 56 => return ascii('y');
          when 57 => return ascii('t'); when 58 => return ascii('e');
          when 59 => return ascii(' ');
          when 60 => return ascii('-'); when 61 => return ascii(' ');
          when 62 => return ascii('e'); when 63 => return ascii('d');
          when 64 => return ascii('i'); when 65 => return ascii('t');
          when 66 => return x"0D"; when 67 => return x"0A";
          when 68 => return ascii('L'); when 69 => return ascii(' ');
          when 70 => return ascii('a'); when 71 => return ascii('d');
          when 72 => return ascii('d'); when 73 => return ascii('r');
          when 74 => return ascii(' ');
          when 75 => return ascii('-'); when 76 => return ascii(' ');
          when 77 => return ascii('l'); when 78 => return ascii('o');
          when 79 => return ascii('a'); when 80 => return ascii('d');
          when 81 => return ascii(' ');
          when 82 => return ascii('h'); when 83 => return ascii('e');
          when 84 => return ascii('x'); when 85 => return ascii(' ');
          when 86 => return x"0D"; when 87 => return x"0A";
          when 88 => return ascii('G'); when 89 => return ascii(' ');
          when 90 => return ascii('['); when 91 => return ascii('a');
          when 92 => return ascii('d'); when 93 => return ascii('d');
          when 94 => return ascii('r'); when 95 => return ascii(']');
          when 96 => return ascii(' '); when 97 => return ascii('-');
          when 98 => return ascii(' '); when 99 => return ascii('g');
          when 100 => return ascii('o'); when 101 => return x"0D";
          when 102 => return x"0A";
          when 103 => return ascii('M'); when 104 => return ascii('E');
          when 105 => return ascii('M'); when 106 => return ascii('/');
          when 107 => return ascii('I'); when 108 => return ascii('O');
          when 109 => return ascii('/'); when 110 => return ascii('R');
          when 111 => return ascii('O'); when 112 => return ascii('M');
          when 113 => return ascii(' '); when 114 => return ascii('O');
          when 115 => return ascii('K'); when 116 => return ascii(' ');
          when 117 => return x"0D"; when 118 => return x"0A";
          when others => return x"00";
        end case;
      when MSG_ERR =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('?'); when 3 => return x"0D";
          when 4 => return x"0A"; when others => return x"00";
        end case;
      when MSG_RANGE =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('M'); when 3 => return ascii('E');
          when 4 => return ascii('M'); when 5 => return ascii('/');
          when 6 => return ascii('I'); when 7 => return ascii('O');
          when 8 => return ascii(' ');
          when 9 => return ascii('O'); when 10 => return ascii('N');
          when 11 => return ascii('L'); when 12 => return ascii('Y');
          when 13 => return x"0D"; when 14 => return x"0A";
          when others => return x"00";
        end case;
      when MSG_OK =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('O'); when 3 => return ascii('K');
          when 4 => return x"0D"; when 5 => return x"0A";
          when others => return x"00";
        end case;
      when MSG_PROMPT =>
        case i is
          when 0 => return ascii('.');
          when 1 => return ascii(' ');
          when others => return x"00";
        end case;
      when MSG_GO =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('G'); when 3 => return ascii('O');
          when 4 => return x"0D"; when 5 => return x"0A";
          when others => return x"00";
        end case;
      when MSG_LOAD =>
        case i is
          when 0 => return x"0D"; when 1 => return x"0A";
          when 2 => return ascii('L'); when 3 => return ascii('O');
          when 4 => return ascii('A'); when 5 => return ascii('D');
          when 6 => return ascii(' ');
          when 7 => return ascii('H'); when 8 => return ascii('E');
          when 9 => return ascii('X');
          when 10 => return ascii(' ');
          when 11 => return ascii('.'); when 12 => return ascii(' ');
          when 13 => return ascii('E'); when 14 => return ascii('N');
          when 15 => return ascii('D');
          when 16 => return x"0D"; when 17 => return x"0A";
          when 18 => return ascii('>');
          when 19 => return ascii(' ');
          when others => return x"00";
        end case;
    end case;
  end function;

begin
  tx_data  <= tx_data_reg;
  tx_valid <= tx_valid_reg;
  active   <= active_reg;

  mem_req   <= mem_req_reg;
  mem_we    <= mem_we_reg;
  mem_addr  <= mem_addr_reg;
  mem_wdata <= mem_wdata_reg;
  jump_req  <= jump_req_reg;
  jump_addr <= jump_addr_reg;

  process(clk)
    variable ch : data_t;
    variable hn : std_logic_vector(3 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state        <= S_OFF;
        after_msg    <= S_INPUT;
        msg          <= MSG_BANNER;
        msg_idx      <= 0;
        active_reg   <= '0';
        btn_d        <= '0';
        tx_data_reg  <= (others => '0');
        tx_valid_reg <= '0';
        wait_uart    <= '0';
        seen_busy    <= '0';
        cmd          <= (others => '0');
        arg0         <= (others => '0');
        arg1         <= (others => '0');
        arg0_nibs    <= 0;
        arg1_nibs    <= 0;
        arg_sel      <= 0;
        cur_addr     <= (others => '0');
        dump_end     <= (others => '0');
        write_data   <= (others => '0');
        read_data    <= (others => '0');
        dump_count   <= 0;
        dump_line    <= (others => x"00");
        dump_ascii_last <= 0;
        dump_ascii_idx  <= 0;
        dump_final_line <= '0';
        load_base   <= (others => '0');
        load_hi_nib <= (others => '0');
        load_half   <= '0';
        dis_op       <= (others => '0');
        dis_b1       <= (others => '0');
        dis_b2       <= (others => '0');
        dis_len      <= 1;
        dis_mode     <= MODE_IMP;
        dis_byte     <= 0;
        dis_midx     <= 0;
        dis_oidx     <= 0;
        mem_req_reg  <= '0';
        mem_we_reg   <= '0';
        mem_addr_reg <= (others => '0');
        mem_wdata_reg <= (others => '0');
        jump_req_reg  <= '0';
        jump_addr_reg <= (others => '0');
      else
        tx_valid_reg <= '0';
        mem_req_reg  <= '0';
        jump_req_reg <= '0';
        btn_d        <= enter_btn;

        if active_reg = '0' and enter_btn = '1' and btn_d = '0' then
          active_reg <= '1';
          msg        <= MSG_BANNER;
          msg_idx    <= 0;
          after_msg  <= S_SEND_MSG;
          state      <= S_SEND_MSG;
        end if;

        if wait_uart = '1' then
          if tx_busy = '1' then
            seen_busy <= '1';
          elsif seen_busy = '1' then
            wait_uart <= '0';
            seen_busy <= '0';
          end if;
        elsif tx_busy = '0' then
          case state is
            when S_OFF =>
              null;

            when S_SEND_MSG =>
              tx_data_reg  <= msg_char(msg, msg_idx);
              tx_valid_reg <= '1';
              wait_uart    <= '1';
              if msg_idx + 1 >= msg_len(msg) then
                msg_idx <= 0;
                if msg = MSG_PROMPT or msg = MSG_GO or msg = MSG_LOAD then
                  state <= after_msg;
                elsif msg = MSG_BANNER then
                  usb_idx <= 0;
                  state   <= S_USB_DIAG;
                else
                  msg       <= MSG_PROMPT;
                  after_msg <= S_INPUT;
                  state     <= S_SEND_MSG;
                end if;
              else
                msg_idx <= msg_idx + 1;
              end if;

            when S_INPUT =>
              if rx_valid = '1' then
                ch := upper(rx_data);
                if is_eol(ch) then
                  state <= S_EXEC;
                elsif is_space(ch) then
                  if arg_sel = 0 and arg0_nibs > 0 then
                    arg_sel <= 1;
                  end if;
                elsif cmd = x"00" then
                  cmd <= ch;
                elsif is_hex(ch) then
                  hn := hex_nibble(ch);
                  if arg_sel = 0 and arg0_nibs < 4 then
                    arg0 <= arg0(11 downto 0) & hn;
                    arg0_nibs <= arg0_nibs + 1;
                  elsif arg_sel = 1 and arg1_nibs < 4 then
                    arg1 <= arg1(11 downto 0) & hn;
                    arg1_nibs <= arg1_nibs + 1;
                  end if;
                end if;
              end if;

            when S_EXEC =>
              if cmd = ascii('M') then
                if arg0_nibs > 0 then
                  cur_addr <= arg0;
                  if arg1_nibs > 0 then
                    dump_end <= arg1;
                  else
                    dump_end <= monitor_span_end(arg0, 15);
                  end if;
                else
                  dump_end <= monitor_span_end(cur_addr, 15);
                end if;
                if (arg0_nibs > 0 and arg1_nibs > 0 and not is_monitor_range(arg0, arg1)) or
                   (arg0_nibs > 0 and arg1_nibs = 0 and not is_monitor_addr(arg0)) or
                   (arg0_nibs = 0 and not is_monitor_addr(cur_addr)) then
                  msg <= MSG_RANGE;
                  after_msg <= S_INPUT;
                  state <= S_SEND_MSG;
                else
                  dump_count <= 0;
                  state <= S_DUMP_CR;
                end if;
              elsif cmd = ascii('D') or cmd = ascii('U') then
                if arg0_nibs > 0 then
                  cur_addr <= arg0;
                  if arg1_nibs > 0 then
                    dump_end <= arg1;
                  else
                    dump_end <= monitor_span_end(arg0, 31);
                  end if;
                else
                  dump_end <= monitor_span_end(cur_addr, 31);
                end if;
                if (arg0_nibs > 0 and arg1_nibs > 0 and not is_monitor_range(arg0, arg1)) or
                   (arg0_nibs > 0 and arg1_nibs = 0 and not is_monitor_addr(arg0)) or
                   (arg0_nibs = 0 and not is_monitor_addr(cur_addr)) then
                  msg <= MSG_RANGE;
                  after_msg <= S_INPUT;
                  state <= S_SEND_MSG;
                else
                  state <= S_DIS_CR;
                end if;
              elsif cmd = ascii('E') or cmd = ascii('W') or cmd = ascii(':') then
                if arg0_nibs = 0 or arg1_nibs = 0 or arg1_nibs > 2 or not is_monitor_addr(arg0) then
                  msg <= MSG_ERR;
                  after_msg <= S_INPUT;
                  state <= S_SEND_MSG;
                else
                  cur_addr   <= arg0;
                  write_data <= arg1(7 downto 0);
                  state      <= S_WRITE_REQ;
                end if;
              elsif cmd = ascii('L') then
                if arg0_nibs = 0 or not is_monitor_addr(arg0) then
                  msg <= MSG_ERR;
                  after_msg <= S_INPUT;
                  state <= S_SEND_MSG;
                else
                  cur_addr <= arg0;
                  load_base <= arg0;
                  load_hi_nib <= (others => '0');
                  load_half <= '0';
                  msg <= MSG_LOAD;
                  after_msg <= S_LOAD_INPUT;
                  state <= S_SEND_MSG;
                end if;
              elsif cmd = ascii('H') or cmd = ascii('?') then
                msg <= MSG_HELP;
                after_msg <= S_SEND_MSG;
                state <= S_SEND_MSG;
              elsif cmd = ascii('G') then
                if arg0_nibs > 0 then
                  jump_addr_reg <= arg0;
                  jump_req_reg  <= '1';
                end if;
                msg <= MSG_GO;
                after_msg <= S_DEACT;
                state <= S_SEND_MSG;
              else
                msg <= MSG_ERR;
                after_msg <= S_INPUT;
                state <= S_SEND_MSG;
              end if;
              cmd       <= (others => '0');
              arg0      <= (others => '0');
              arg1      <= (others => '0');
              arg0_nibs <= 0;
              arg1_nibs <= 0;
              arg_sel   <= 0;

            when S_WRITE_REQ =>
              mem_addr_reg  <= cur_addr;
              mem_wdata_reg <= write_data;
              mem_we_reg    <= '1';
              mem_req_reg   <= '1';
              state         <= S_WRITE_WAIT;

            when S_WRITE_WAIT =>
              mem_we_reg <= '0';
              if mem_ready = '1' then
                msg <= MSG_OK;
                after_msg <= S_SEND_MSG;
                state <= S_SEND_MSG;
              end if;

            when S_LOAD_INPUT =>
              -- Raw hex upload mode used by tools/upload_monitor_hex.py.
              -- Bytes are accepted as two nibbles; whitespace, comma and '$'
              -- are separators. A single '.' returns to command mode.
              if rx_valid = '1' then
                ch := upper(rx_data);
                if ch = ascii('.') then
                  if load_half = '1' then
                    msg <= MSG_ERR;
                  else
                    msg <= MSG_OK;
                  end if;
                  load_half <= '0';
                  after_msg <= S_INPUT;
                  state <= S_SEND_MSG;
                elsif is_hex(ch) then
                  hn := hex_nibble(ch);
                  if load_half = '0' then
                    load_hi_nib <= hn;
                    load_half <= '1';
                  elsif is_monitor_range(load_base, cur_addr) then
                    write_data <= load_hi_nib & hn;
                    load_half <= '0';
                    state <= S_LOAD_WRITE_REQ;
                  else
                    msg <= MSG_RANGE;
                    after_msg <= S_INPUT;
                    state <= S_SEND_MSG;
                  end if;
                elsif is_space(ch) or is_eol(ch) or ch = ascii(',') or ch = ascii('$') then
                  null;
                else
                  msg <= MSG_ERR;
                  after_msg <= S_INPUT;
                  state <= S_SEND_MSG;
                end if;
              end if;

            when S_LOAD_WRITE_REQ =>
              -- Present one byte to the core memory master. The request stays
              -- asserted for one cycle; completion is reported in
              -- S_LOAD_WRITE_WAIT through mem_ready.
              mem_addr_reg  <= cur_addr;
              mem_wdata_reg <= write_data;
              mem_we_reg    <= '1';
              mem_req_reg   <= '1';
              state         <= S_LOAD_WRITE_WAIT;

            when S_LOAD_WRITE_WAIT =>
              mem_we_reg <= '0';
              if mem_ready = '1' then
                cur_addr <= std_logic_vector(unsigned(cur_addr) + 1);
                state <= S_LOAD_INPUT;
              end if;

            when S_DUMP_CR =>
              tx_data_reg <= x"0D"; tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_LF;
            when S_DUMP_LF =>
              tx_data_reg <= x"0A"; tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_A3;

            when S_DUMP_A3 =>
              tx_data_reg <= hex_char(cur_addr(15 downto 12)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_A2;
            when S_DUMP_A2 =>
              tx_data_reg <= hex_char(cur_addr(11 downto 8)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_A1;
            when S_DUMP_A1 =>
              tx_data_reg <= hex_char(cur_addr(7 downto 4)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_A0;
            when S_DUMP_A0 =>
              tx_data_reg <= hex_char(cur_addr(3 downto 0)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_COLON;
            when S_DUMP_COLON =>
              tx_data_reg <= ascii(':'); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_REQ;

            when S_DUMP_REQ =>
              mem_addr_reg <= std_logic_vector(unsigned(cur_addr) + dump_count);
              mem_we_reg   <= '0';
              mem_req_reg  <= '1';
              state        <= S_DUMP_WAIT;

            when S_DUMP_WAIT =>
              if mem_ready = '1' then
                read_data <= mem_rdata;
                dump_line(dump_count) <= mem_rdata;
                state <= S_DUMP_SPACE;
              end if;

            when S_DUMP_SPACE =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_B1;
            when S_DUMP_B1 =>
              tx_data_reg <= hex_char(read_data(7 downto 4)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_B0;
            when S_DUMP_B0 =>
              tx_data_reg <= hex_char(read_data(3 downto 0)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_NEXT;

            when S_DUMP_NEXT =>
              if unsigned(cur_addr) + dump_count >= unsigned(dump_end) then
                dump_ascii_last <= dump_count;
                dump_final_line <= '1';
                if dump_count = 15 then
                  state <= S_DUMP_ASC_GAP1;
                else
                  dump_count <= dump_count + 1;
                  state <= S_DUMP_PAD_SP;
                end if;
              elsif dump_count = 15 then
                dump_ascii_last <= 15;
                dump_final_line <= '0';
                state <= S_DUMP_ASC_GAP1;
              else
                dump_count <= dump_count + 1;
                state <= S_DUMP_REQ;
              end if;

            when S_DUMP_PAD_SP =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_PAD_HI;
            when S_DUMP_PAD_HI =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_PAD_LO;
            when S_DUMP_PAD_LO =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1';
              if dump_count = 15 then
                state <= S_DUMP_ASC_GAP1;
              else
                dump_count <= dump_count + 1;
                state <= S_DUMP_PAD_SP;
              end if;

            when S_DUMP_ASC_GAP1 =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_ASC_GAP2;
            when S_DUMP_ASC_GAP2 =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DUMP_ASC_OPEN;
            when S_DUMP_ASC_OPEN =>
              tx_data_reg <= ascii('|');
              tx_valid_reg <= '1';
              wait_uart <= '1';
              dump_ascii_idx <= 0;
              state <= S_DUMP_ASC_CHAR;
            when S_DUMP_ASC_CHAR =>
              tx_data_reg <= printable_char(dump_line(dump_ascii_idx));
              tx_valid_reg <= '1';
              wait_uart <= '1';
              if dump_ascii_idx >= dump_ascii_last then
                state <= S_DUMP_ASC_CLOSE;
              else
                dump_ascii_idx <= dump_ascii_idx + 1;
              end if;
            when S_DUMP_ASC_CLOSE =>
              tx_data_reg <= ascii('|');
              tx_valid_reg <= '1';
              wait_uart <= '1';
              if dump_final_line = '1' then
                state <= S_DUMP_END_CR;
              else
                cur_addr <= std_logic_vector(unsigned(cur_addr) + 16);
                dump_count <= 0;
                state <= S_DUMP_CR;
              end if;

            when S_DUMP_END_CR =>
              tx_data_reg <= x"0D";
              tx_valid_reg <= '1';
              wait_uart <= '1';
              state <= S_DUMP_END_LF;

            when S_DUMP_END_LF =>
              tx_data_reg <= x"0A";
              tx_valid_reg <= '1';
              wait_uart <= '1';
              msg <= MSG_PROMPT;
              after_msg <= S_INPUT;
              state <= S_SEND_MSG;

            when S_DIS_CR =>
              tx_data_reg <= x"0D"; tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_LF;
            when S_DIS_LF =>
              tx_data_reg <= x"0A"; tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_A3;

            when S_DIS_A3 =>
              tx_data_reg <= hex_char(cur_addr(15 downto 12)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_A2;
            when S_DIS_A2 =>
              tx_data_reg <= hex_char(cur_addr(11 downto 8)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_A1;
            when S_DIS_A1 =>
              tx_data_reg <= hex_char(cur_addr(7 downto 4)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_A0;
            when S_DIS_A0 =>
              tx_data_reg <= hex_char(cur_addr(3 downto 0)); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_COLON;
            when S_DIS_COLON =>
              tx_data_reg <= ascii(':'); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_REQ0;

            when S_DIS_REQ0 =>
              mem_addr_reg <= cur_addr;
              mem_we_reg   <= '0';
              mem_req_reg  <= '1';
              state        <= S_DIS_WAIT0;
            when S_DIS_WAIT0 =>
              if mem_ready = '1' then
                dis_op   <= mem_rdata;
                dis_len  <= opcode_len(mem_rdata);
                dis_mode <= opcode_mode(mem_rdata);
                if opcode_len(mem_rdata) > 1 then
                  state <= S_DIS_REQ1;
                else
                  dis_b1 <= x"00";
                  dis_b2 <= x"00";
                  dis_byte <= 0;
                  state <= S_DIS_BYTE_SP;
                end if;
              end if;
            when S_DIS_REQ1 =>
              mem_addr_reg <= std_logic_vector(unsigned(cur_addr) + 1);
              mem_we_reg   <= '0';
              mem_req_reg  <= '1';
              state        <= S_DIS_WAIT1;
            when S_DIS_WAIT1 =>
              if mem_ready = '1' then
                dis_b1 <= mem_rdata;
                if dis_len > 2 then
                  state <= S_DIS_REQ2;
                else
                  dis_b2 <= x"00";
                  dis_byte <= 0;
                  state <= S_DIS_BYTE_SP;
                end if;
              end if;
            when S_DIS_REQ2 =>
              mem_addr_reg <= std_logic_vector(unsigned(cur_addr) + 2);
              mem_we_reg   <= '0';
              mem_req_reg  <= '1';
              state        <= S_DIS_WAIT2;
            when S_DIS_WAIT2 =>
              if mem_ready = '1' then
                dis_b2 <= mem_rdata;
                dis_byte <= 0;
                state <= S_DIS_BYTE_SP;
              end if;

            when S_DIS_BYTE_SP =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_BYTE_HI;
            when S_DIS_BYTE_HI =>
              if dis_byte >= dis_len then
                tx_data_reg <= ascii(' ');
              elsif dis_byte = 0 then
                tx_data_reg <= hex_char(dis_op(7 downto 4));
              elsif dis_byte = 1 then
                tx_data_reg <= hex_char(dis_b1(7 downto 4));
              else
                tx_data_reg <= hex_char(dis_b2(7 downto 4));
              end if;
              tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_BYTE_LO;
            when S_DIS_BYTE_LO =>
              if dis_byte >= dis_len then
                tx_data_reg <= ascii(' ');
              elsif dis_byte = 0 then
                tx_data_reg <= hex_char(dis_op(3 downto 0));
              elsif dis_byte = 1 then
                tx_data_reg <= hex_char(dis_b1(3 downto 0));
              else
                tx_data_reg <= hex_char(dis_b2(3 downto 0));
              end if;
              tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_BYTE_NEXT;
            when S_DIS_BYTE_NEXT =>
              if dis_byte = 2 then
                state <= S_DIS_GAP1;
              else
                dis_byte <= dis_byte + 1;
                state <= S_DIS_BYTE_SP;
              end if;

            when S_DIS_GAP1 =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_GAP2;
            when S_DIS_GAP2 =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1';
              dis_midx <= 0;
              state <= S_DIS_MNEM;
            when S_DIS_MNEM =>
              tx_data_reg <= opcode_mnemonic_char(dis_op, dis_midx);
              tx_valid_reg <= '1';
              wait_uart <= '1';
              if dis_midx = 2 then
                dis_oidx <= 0;
                if operand_len(dis_mode) = 0 then
                  state <= S_DIS_NEXT;
                else
                  state <= S_DIS_OPER_SP;
                end if;
              else
                dis_midx <= dis_midx + 1;
              end if;
            when S_DIS_OPER_SP =>
              tx_data_reg <= ascii(' '); tx_valid_reg <= '1'; wait_uart <= '1'; state <= S_DIS_OPER_CHAR;
            when S_DIS_OPER_CHAR =>
              tx_data_reg <= operand_char(dis_mode, dis_oidx, dis_b1, dis_b2, cur_addr);
              tx_valid_reg <= '1';
              wait_uart <= '1';
              if dis_oidx + 1 >= operand_len(dis_mode) then
                state <= S_DIS_NEXT;
              else
                dis_oidx <= dis_oidx + 1;
              end if;

            when S_DIS_NEXT =>
              if unsigned(cur_addr) + to_unsigned(dis_len - 1, 16) >= unsigned(dump_end) then
                tx_data_reg <= x"0D";
                tx_valid_reg <= '1';
                wait_uart <= '1';
                state <= S_DIS_END_LF;
              else
                cur_addr <= std_logic_vector(unsigned(cur_addr) + to_unsigned(dis_len, 16));
                state <= S_DIS_CR;
              end if;

            when S_DIS_END_LF =>
              tx_data_reg <= x"0A";
              tx_valid_reg <= '1';
              wait_uart <= '1';
              msg <= MSG_PROMPT;
              after_msg <= S_INPUT;
              state <= S_SEND_MSG;

            when S_USB_DIAG =>
              -- Print "USB CON=X PH=X KEY=XX MOD=XX ASC=XX POLL=X EV=X\r\n"
              -- POLL=1 means actively polling for keys, EV toggles on each key press
              case usb_idx is
                when 0  => tx_data_reg <= ascii('U');
                when 1  => tx_data_reg <= ascii('S');
                when 2  => tx_data_reg <= ascii('B');
                when 3  => tx_data_reg <= ascii(' ');
                when 4  => tx_data_reg <= ascii('C');
                when 5  => tx_data_reg <= ascii('O');
                when 6  => tx_data_reg <= ascii('N');
                when 7  => tx_data_reg <= ascii('=');
                when 8  =>
                  if usb_connected = '1' then
                    tx_data_reg <= ascii('1');
                  else
                    tx_data_reg <= ascii('0');
                  end if;
                when 9  => tx_data_reg <= ascii(' ');
                when 10 => tx_data_reg <= ascii('P');
                when 11 => tx_data_reg <= ascii('H');
                when 12 => tx_data_reg <= ascii('=');
                when 13 => tx_data_reg <= hex_char(usb_phase);
                when 14 => tx_data_reg <= ascii(' ');
                when 15 => tx_data_reg <= ascii('K');
                when 16 => tx_data_reg <= ascii('E');
                when 17 => tx_data_reg <= ascii('Y');
                when 18 => tx_data_reg <= ascii('=');
                when 19 => tx_data_reg <= hex_char(usb_keycode(7 downto 4));
                when 20 => tx_data_reg <= hex_char(usb_keycode(3 downto 0));
                when 21 => tx_data_reg <= ascii(' ');
                when 22 => tx_data_reg <= ascii('M');
                when 23 => tx_data_reg <= ascii('O');
                when 24 => tx_data_reg <= ascii('D');
                when 25 => tx_data_reg <= ascii('=');
                when 26 => tx_data_reg <= hex_char(usb_modif(7 downto 4));
                when 27 => tx_data_reg <= hex_char(usb_modif(3 downto 0));
                when 28 => tx_data_reg <= ascii(' ');
                when 29 => tx_data_reg <= ascii('A');
                when 30 => tx_data_reg <= ascii('S');
                when 31 => tx_data_reg <= ascii('C');
                when 32 => tx_data_reg <= ascii('=');
                when 33 => tx_data_reg <= hex_char(usb_ascii(7 downto 4));
                when 34 => tx_data_reg <= hex_char(usb_ascii(3 downto 0));
                when 35 => tx_data_reg <= ascii(' ');
                when 36 => tx_data_reg <= ascii('P');
                when 37 => tx_data_reg <= ascii('O');
                when 38 => tx_data_reg <= ascii('L');
                when 39 => tx_data_reg <= ascii('L');
                when 40 => tx_data_reg <= ascii('=');
                when 41 =>
                  if usb_polling = '1' then
                    tx_data_reg <= ascii('1');
                  else
                    tx_data_reg <= ascii('0');
                  end if;
                when 42 => tx_data_reg <= ascii(' ');
                when 43 => tx_data_reg <= ascii('E');
                when 44 => tx_data_reg <= ascii('V');
                when 45 => tx_data_reg <= ascii('=');
                when 46 =>
                  if usb_key_event = '1' then
                    tx_data_reg <= ascii('1');
                  else
                    tx_data_reg <= ascii('0');
                  end if;
                when 47 => tx_data_reg <= x"0D";
                when others => tx_data_reg <= x"0A";
              end case;
              tx_valid_reg <= '1';
              wait_uart    <= '1';
              if usb_idx < 48 then
                usb_idx <= usb_idx + 1;
              else
                usb_idx   <= 0;
                msg       <= MSG_PROMPT;
                after_msg <= S_INPUT;
                state     <= S_SEND_MSG;
              end if;

            when S_DEACT =>
              active_reg <= '0';
              state <= S_OFF;

            when others =>
              state <= S_OFF;
          end case;
        end if;
      end if;
    end if;
  end process;
end architecture;
