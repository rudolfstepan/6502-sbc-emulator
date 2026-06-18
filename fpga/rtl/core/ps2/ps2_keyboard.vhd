-- PS/2 keyboard controller — drop-in replacement for usb_hid_host.
--
-- Directly receives PS/2 clock and data from a PS/2 keyboard connector.
-- Pins need external or FPGA-internal pull-ups (active-low, open-collector).
--
-- Register map (same as usb_hid_host, 4 registers, directly bus-mapped):
--   +0  STATUS  R   [7]=connected [0]=key_ready
--   +1  KEY     R   PS/2 scan code (Set 2 make code); read clears key_ready
--   +2  MODIF   R   modifier byte [0]=LCtrl [1]=LShift [2]=LAlt
--                                  [4]=RCtrl [5]=RShift [6]=RAlt
--   +3  ASCII   R   ASCII translation; read clears key_ready
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_keyboard is
  generic (
    CLK_HZ : positive := 27_000_000
  );
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    ps2_clk  : in std_logic;
    ps2_data : in std_logic;

    cs   : in  std_logic;
    we   : in  std_logic;
    addr : in  std_logic_vector(1 downto 0);
    dout : out std_logic_vector(7 downto 0);
    irq  : out std_logic;

    diag_connected : out std_logic;
    diag_keycode   : out std_logic_vector(7 downto 0);
    diag_modif     : out std_logic_vector(7 downto 0);
    diag_ascii     : out std_logic_vector(7 downto 0);
    diag_phase     : out std_logic_vector(3 downto 0);
    diag_key_event : out std_logic;
    diag_polling   : out std_logic
  );
end entity;

architecture rtl of ps2_keyboard is

  -- PS/2 clock synchroniser and falling-edge detector
  signal clk_sr   : std_logic_vector(2 downto 0) := "111";
  signal clk_fall : std_logic;

  -- Shift register for 11-bit PS/2 frame
  signal sr       : std_logic_vector(10 downto 0) := (others => '1');
  signal bit_cnt  : unsigned(3 downto 0) := (others => '0');
  signal byte_rdy : std_logic := '0';
  signal rx_byte  : std_logic_vector(7 downto 0);
  signal parity_ok : std_logic;

  -- Scan code state machine
  signal is_break   : std_logic := '0';  -- F0 prefix seen
  signal is_ext     : std_logic := '0';  -- E0 prefix seen

  -- Modifier tracking
  signal modif_r : std_logic_vector(7 downto 0) := (others => '0');

  -- Key output registers
  signal scancode_r : std_logic_vector(7 downto 0) := (others => '0');
  signal ascii_r    : std_logic_vector(7 downto 0) := (others => '0');
  signal key_ready  : std_logic := '0';
  signal key_ev_tog : std_logic := '0';

  -- Activity detector: connected if PS/2 clock toggled recently
  constant ACT_TIMEOUT : natural := CLK_HZ / 2;  -- 0.5 s
  signal act_cnt  : natural range 0 to ACT_TIMEOUT := 0;
  signal connected : std_logic := '0';

  -- Scan code Set 2 to ASCII (unshifted / shifted)
  function sc2_to_ascii(sc  : std_logic_vector(7 downto 0);
                         m   : std_logic_vector(7 downto 0);
                         ext : std_logic)
    return std_logic_vector is
    variable ki    : integer;
    variable shift : boolean;
    variable ctrl  : boolean;
    variable c     : std_logic_vector(7 downto 0);
  begin
    ki    := to_integer(unsigned(sc));
    shift := (m(1) = '1') or (m(5) = '1');
    ctrl  := (m(0) = '1') or (m(4) = '1');
    c     := x"00";
    if ext = '1' then
      case ki is
        when 16#6B# => c := x"9D"; -- Cursor left
        when 16#74# => c := x"1D"; -- Cursor right
        when 16#75# => c := x"91"; -- Cursor up
        when 16#72# => c := x"11"; -- Cursor down
        when 16#6C# =>              -- Home / Shift+Home = clear screen
          if shift then
            c := x"93";
          else
            c := x"13";
          end if;
        when others => c := x"00";
      end case;
      return c;
    end if;

    if ctrl then
      case ki is
        when 16#21# => c := x"03"; -- Ctrl+C / RUN-STOP
        when 16#4B# => c := x"93"; -- Ctrl+L / clear screen
        when others => null;
      end case;
      if c /= x"00" then
        return c;
      end if;
    end if;

    if not shift then
      case ki is
        when 16#1C# => c := x"61"; -- a
        when 16#32# => c := x"62"; -- b
        when 16#21# => c := x"63"; -- c
        when 16#23# => c := x"64"; -- d
        when 16#24# => c := x"65"; -- e
        when 16#2B# => c := x"66"; -- f
        when 16#34# => c := x"67"; -- g
        when 16#33# => c := x"68"; -- h
        when 16#43# => c := x"69"; -- i
        when 16#3B# => c := x"6A"; -- j
        when 16#42# => c := x"6B"; -- k
        when 16#4B# => c := x"6C"; -- l
        when 16#3A# => c := x"6D"; -- m
        when 16#31# => c := x"6E"; -- n
        when 16#44# => c := x"6F"; -- o
        when 16#4D# => c := x"70"; -- p
        when 16#15# => c := x"71"; -- q
        when 16#2D# => c := x"72"; -- r
        when 16#1B# => c := x"73"; -- s
        when 16#2C# => c := x"74"; -- t
        when 16#3C# => c := x"75"; -- u
        when 16#2A# => c := x"76"; -- v
        when 16#1D# => c := x"77"; -- w
        when 16#22# => c := x"78"; -- x
        when 16#35# => c := x"79"; -- y
        when 16#1A# => c := x"7A"; -- z
        when 16#45# => c := x"30"; -- 0
        when 16#16# => c := x"31"; -- 1
        when 16#1E# => c := x"32"; -- 2
        when 16#26# => c := x"33"; -- 3
        when 16#25# => c := x"34"; -- 4
        when 16#2E# => c := x"35"; -- 5
        when 16#36# => c := x"36"; -- 6
        when 16#3D# => c := x"37"; -- 7
        when 16#3E# => c := x"38"; -- 8
        when 16#46# => c := x"39"; -- 9
        when 16#5A# => c := x"0D"; -- Enter
        when 16#76# => c := x"1B"; -- Escape
        when 16#66# => c := x"08"; -- Backspace
        when 16#0D# => c := x"09"; -- Tab
        when 16#29# => c := x"20"; -- Space
        when 16#4E# => c := x"2D"; -- -
        when 16#55# => c := x"3D"; -- =
        when 16#54# => c := x"5B"; -- [
        when 16#5B# => c := x"5D"; -- ]
        when 16#5D# => c := x"5C"; -- backslash
        when 16#4C# => c := x"3B"; -- ;
        when 16#52# => c := x"27"; -- '
        when 16#0E# => c := x"60"; -- `
        when 16#41# => c := x"2C"; -- ,
        when 16#49# => c := x"2E"; -- .
        when 16#4A# => c := x"2F"; -- /
        when others => c := x"00";
      end case;
    else
      case ki is
        when 16#1C# => c := x"41"; -- A
        when 16#32# => c := x"42"; -- B
        when 16#21# => c := x"43"; -- C
        when 16#23# => c := x"44"; -- D
        when 16#24# => c := x"45"; -- E
        when 16#2B# => c := x"46"; -- F
        when 16#34# => c := x"47"; -- G
        when 16#33# => c := x"48"; -- H
        when 16#43# => c := x"49"; -- I
        when 16#3B# => c := x"4A"; -- J
        when 16#42# => c := x"4B"; -- K
        when 16#4B# => c := x"4C"; -- L
        when 16#3A# => c := x"4D"; -- M
        when 16#31# => c := x"4E"; -- N
        when 16#44# => c := x"4F"; -- O
        when 16#4D# => c := x"50"; -- P
        when 16#15# => c := x"51"; -- Q
        when 16#2D# => c := x"52"; -- R
        when 16#1B# => c := x"53"; -- S
        when 16#2C# => c := x"54"; -- T
        when 16#3C# => c := x"55"; -- U
        when 16#2A# => c := x"56"; -- V
        when 16#1D# => c := x"57"; -- W
        when 16#22# => c := x"58"; -- X
        when 16#35# => c := x"59"; -- Y
        when 16#1A# => c := x"5A"; -- Z
        when 16#45# => c := x"29"; -- )
        when 16#16# => c := x"21"; -- !
        when 16#1E# => c := x"40"; -- @
        when 16#26# => c := x"23"; -- #
        when 16#25# => c := x"24"; -- $
        when 16#2E# => c := x"25"; -- %
        when 16#36# => c := x"5E"; -- ^
        when 16#3D# => c := x"26"; -- &
        when 16#3E# => c := x"2A"; -- *
        when 16#46# => c := x"28"; -- (
        when 16#5A# => c := x"0D"; -- Enter
        when 16#76# => c := x"1B"; -- Escape
        when 16#66# => c := x"08"; -- Backspace
        when 16#0D# => c := x"09"; -- Tab
        when 16#29# => c := x"20"; -- Space
        when 16#4E# => c := x"5F"; -- _
        when 16#55# => c := x"2B"; -- +
        when 16#54# => c := x"7B"; -- {
        when 16#5B# => c := x"7D"; -- }
        when 16#5D# => c := x"7C"; -- |
        when 16#4C# => c := x"3A"; -- :
        when 16#52# => c := x"22"; -- "
        when 16#0E# => c := x"7E"; -- ~
        when 16#41# => c := x"3C"; -- <
        when 16#49# => c := x"3E"; -- >
        when 16#4A# => c := x"3F"; -- ?
        when others => c := x"00";
      end case;
    end if;
    return c;
  end function;

begin

  -- Synchronise PS/2 clock into system domain and detect falling edge
  process(clk)
  begin
    if rising_edge(clk) then
      clk_sr <= clk_sr(1 downto 0) & ps2_clk;
    end if;
  end process;
  clk_fall <= clk_sr(2) and not clk_sr(1);

  -- Shift in PS/2 bits on falling edge of ps2_clk
  process(clk)
    variable parity : std_logic;
  begin
    if rising_edge(clk) then
      byte_rdy <= '0';
      if reset_n = '0' then
        sr      <= (others => '1');
        bit_cnt <= (others => '0');
      elsif clk_fall = '1' then
        sr      <= ps2_data & sr(10 downto 1);
        if bit_cnt = 10 then
          -- Full frame received (before this cycle's shift takes effect):
          --   sr(10)        = parity
          --   sr(9 downto 2) = data[7:0]
          --   sr(1)         = start bit (should be 0)
          --   ps2_data      = stop bit  (should be 1)
          parity := sr(10) xor sr(9) xor sr(8) xor sr(7) xor sr(6) xor
                    sr(5) xor sr(4) xor sr(3) xor sr(2);
          if ps2_data = '1' and sr(1) = '0' then
            rx_byte    <= sr(9 downto 2);
            parity_ok  <= parity;
            byte_rdy   <= '1';
          end if;
          bit_cnt <= (others => '0');
          sr      <= (others => '1');
        else
          bit_cnt <= bit_cnt + 1;
        end if;
      end if;
    end if;
  end process;

  -- Activity detector: keyboard is "connected" while clock is toggling
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        act_cnt   <= 0;
        connected <= '0';
      elsif clk_fall = '1' then
        act_cnt   <= 0;
        connected <= '1';
      elsif act_cnt < ACT_TIMEOUT then
        act_cnt <= act_cnt + 1;
      else
        connected <= '0';
      end if;
    end if;
  end process;

  -- Scan code decode: track modifiers and generate key events
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        is_break   <= '0';
        is_ext     <= '0';
        modif_r    <= (others => '0');
        scancode_r <= (others => '0');
        ascii_r    <= (others => '0');
        key_ready  <= '0';
        key_ev_tog <= '0';
      else
        if byte_rdy = '1' then
          if rx_byte = x"F0" then
            is_break <= '1';
          elsif rx_byte = x"E0" then
            is_ext <= '1';
          else
            -- Modifier tracking
            if is_ext = '0' then
              case rx_byte is
                when x"12" => modif_r(1) <= not is_break; -- Left Shift
                when x"59" => modif_r(5) <= not is_break; -- Right Shift
                when x"14" => modif_r(0) <= not is_break; -- Left Ctrl
                when x"11" => modif_r(2) <= not is_break; -- Left Alt
                when others => null;
              end case;
            else
              case rx_byte is
                when x"14" => modif_r(4) <= not is_break; -- Right Ctrl
                when x"11" => modif_r(6) <= not is_break; -- Right Alt
                when others => null;
              end case;
            end if;

            -- On make (not break), latch scancode and ASCII
            if is_break = '0' then
              scancode_r <= rx_byte;
              ascii_r    <= sc2_to_ascii(rx_byte, modif_r, is_ext);
              key_ready  <= '1';
              key_ev_tog <= not key_ev_tog;
            end if;

            is_break <= '0';
            is_ext   <= '0';
          end if;
        end if;

        -- Read of KEY or ASCII clears key_ready
        if cs = '1' and we = '0' then
          if addr = "01" or addr = "11" then
            key_ready <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Register read
  process(cs, we, addr, connected, key_ready, scancode_r, modif_r, ascii_r)
  begin
    dout <= (others => '0');
    if cs = '1' and we = '0' then
      case addr is
        when "00"   => dout <= connected & "000000" & key_ready;
        when "01"   => dout <= scancode_r;
        when "10"   => dout <= modif_r;
        when others => dout <= ascii_r;
      end case;
    end if;
  end process;

  irq <= key_ready;

  -- Diagnostics (directly usable by boot_vga_debug)
  diag_connected <= connected;
  diag_keycode   <= scancode_r;
  diag_modif     <= modif_r;
  diag_ascii     <= ascii_r;
  diag_key_event <= key_ev_tog;
  diag_polling   <= connected;
  diag_phase     <= x"4" when connected = '1' else x"3";

end architecture;
