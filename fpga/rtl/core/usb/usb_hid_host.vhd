-- USB HID host over PMOD GPIO — nand2mario core wrapper.
--
-- Wraps the nand2mario/hi631 usb_hid_host_nm Verilog core (low-speed USB,
-- 1.5 Mbps, bit-bang on two PMOD GPIO pins) and presents the same register
-- and diagnostic interface that the rest of the project expects.
--
-- Physical connection required:
--   usb_dm  -> USB D-  (also: 15 kΩ pull-down resistor D- to GND)
--   usb_dp  -> USB D+  (also: 15 kΩ pull-down resistor D+ to GND)
--   VBUS    -> 5 V     (host must supply VBUS externally)
--   GND     -> GND
--
-- Clock domains:
--   usb_clk (12 MHz, from rPLL) — nand2mario UKP processor
--   clk     (27 MHz system)     — register interface, diagnostics
--
-- Register map (4 registers, cs-selected):
--   +0  STATUS  R   [7]=connected [0]=key_ready
--   +1  KEY     R   HID keycode (key1 from nand2mario); read clears key_ready
--   +2  MODIF   R   HID modifier byte (key_modifiers)
--   +3  ASCII   R   ASCII translation of KEY+MODIF; read clears key_ready
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_hid_host is
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;

    usb_clk : in  std_logic;
    usb_dm  : inout std_logic;
    usb_dp  : inout std_logic;

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

architecture rtl of usb_hid_host is

  -- HID keycode -> ASCII (unshifted then shifted).
  -- Returns 0x00 for unmapped keys.
  function hid_to_ascii(k : std_logic_vector(7 downto 0);
                         m : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable ki    : integer;
    variable shift : boolean;
    variable c     : std_logic_vector(7 downto 0);
  begin
    ki    := to_integer(unsigned(k));
    shift := (m(1) = '1') or (m(5) = '1');
    c     := x"00";
    if not shift then
      case ki is
        when 4  => c := x"61"; when 5  => c := x"62"; when 6  => c := x"63";
        when 7  => c := x"64"; when 8  => c := x"65"; when 9  => c := x"66";
        when 10 => c := x"67"; when 11 => c := x"68"; when 12 => c := x"69";
        when 13 => c := x"6A"; when 14 => c := x"6B"; when 15 => c := x"6C";
        when 16 => c := x"6D"; when 17 => c := x"6E"; when 18 => c := x"6F";
        when 19 => c := x"70"; when 20 => c := x"71"; when 21 => c := x"72";
        when 22 => c := x"73"; when 23 => c := x"74"; when 24 => c := x"75";
        when 25 => c := x"76"; when 26 => c := x"77"; when 27 => c := x"78";
        when 28 => c := x"79"; when 29 => c := x"7A";  -- a-z
        when 30 => c := x"31"; when 31 => c := x"32"; when 32 => c := x"33";
        when 33 => c := x"34"; when 34 => c := x"35"; when 35 => c := x"36";
        when 36 => c := x"37"; when 37 => c := x"38"; when 38 => c := x"39";
        when 39 => c := x"30";  -- 1-9, 0
        when 40 => c := x"0D";  -- Enter
        when 41 => c := x"1B";  -- Escape
        when 42 => c := x"08";  -- Backspace
        when 43 => c := x"09";  -- Tab
        when 44 => c := x"20";  -- Space
        when 45 => c := x"2D";  -- -
        when 46 => c := x"3D";  -- =
        when 47 => c := x"5B";  -- [
        when 48 => c := x"5D";  -- ]
        when 49 => c := x"5C";  -- backslash
        when 51 => c := x"3B";  -- ;
        when 52 => c := x"27";  -- '
        when 53 => c := x"60";  -- `
        when 54 => c := x"2C";  -- ,
        when 55 => c := x"2E";  -- .
        when 56 => c := x"2F";  -- /
        when others => c := x"00";
      end case;
    else
      case ki is
        when 4  => c := x"41"; when 5  => c := x"42"; when 6  => c := x"43";
        when 7  => c := x"44"; when 8  => c := x"45"; when 9  => c := x"46";
        when 10 => c := x"47"; when 11 => c := x"48"; when 12 => c := x"49";
        when 13 => c := x"4A"; when 14 => c := x"4B"; when 15 => c := x"4C";
        when 16 => c := x"4D"; when 17 => c := x"4E"; when 18 => c := x"4F";
        when 19 => c := x"50"; when 20 => c := x"51"; when 21 => c := x"52";
        when 22 => c := x"53"; when 23 => c := x"54"; when 24 => c := x"55";
        when 25 => c := x"56"; when 26 => c := x"57"; when 27 => c := x"58";
        when 28 => c := x"59"; when 29 => c := x"5A";  -- A-Z
        when 30 => c := x"21"; when 31 => c := x"40"; when 32 => c := x"23";
        when 33 => c := x"24"; when 34 => c := x"25"; when 35 => c := x"5E";
        when 36 => c := x"26"; when 37 => c := x"2A"; when 38 => c := x"28";
        when 39 => c := x"29";  -- !@#$%^&*()
        when 40 => c := x"0D";  -- Enter (shift+enter = enter)
        when 41 => c := x"1B";  -- Escape
        when 42 => c := x"08";  -- Backspace
        when 43 => c := x"09";  -- Tab
        when 44 => c := x"20";  -- Space
        when 45 => c := x"5F";  -- _
        when 46 => c := x"2B";  -- +
        when 47 => c := x"7B";  -- {
        when 48 => c := x"7D";  -- }
        when 49 => c := x"7C";  -- |
        when 51 => c := x"3A";  -- :
        when 52 => c := x"22";  -- "
        when 53 => c := x"7E";  -- ~
        when 54 => c := x"3C";  -- <
        when 55 => c := x"3E";  -- >
        when 56 => c := x"3F";  -- ?
        when others => c := x"00";
      end case;
    end if;
    return c;
  end function;

  -- nand2mario USB HID host (Verilog, low-speed bit-bang)
  component usb_hid_host_nm is
    port (
      usbclk        : in    std_logic;
      usbrst_n      : in    std_logic;
      usb_dm        : inout std_logic;
      usb_dp        : inout std_logic;
      typ           : out   std_logic_vector(1 downto 0);
      rpt           : out   std_logic;   -- renamed: 'report' is a VHDL reserved word
      conerr        : out   std_logic;
      key_modifiers : out   std_logic_vector(7 downto 0);
      key1          : out   std_logic_vector(7 downto 0);
      key2          : out   std_logic_vector(7 downto 0);
      key3          : out   std_logic_vector(7 downto 0);
      key4          : out   std_logic_vector(7 downto 0);
      mouse_btn     : out   std_logic_vector(7 downto 0);
      mouse_dx      : out   std_logic_vector(7 downto 0);
      mouse_dy      : out   std_logic_vector(7 downto 0);
      game_l        : out   std_logic;
      game_r        : out   std_logic;
      game_u        : out   std_logic;
      game_d        : out   std_logic;
      game_a        : out   std_logic;
      game_b        : out   std_logic;
      game_x        : out   std_logic;
      game_y        : out   std_logic;
      game_sel      : out   std_logic;
      game_sta      : out   std_logic;
      dbg_hid_report : out  std_logic_vector(63 downto 0)
    );
  end component;

  -- Signals in usb_clk domain (12 MHz)
  signal nm_typ    : std_logic_vector(1 downto 0);
  signal nm_rpt    : std_logic;
  signal nm_conerr : std_logic;
  signal nm_key1   : std_logic_vector(7 downto 0);
  signal nm_modif  : std_logic_vector(7 downto 0);

  -- Latched in usb_clk domain, toggled on every report
  signal key_u       : std_logic_vector(7 downto 0) := (others => '0');
  signal mod_u       : std_logic_vector(7 downto 0) := (others => '0');
  signal rpt_tog_u   : std_logic := '0';
  signal conn_u      : std_logic := '0';
  signal err_u       : std_logic := '0';

  -- 2-FF synchronisers into clk domain
  signal rpt_tog_m   : std_logic := '0';
  signal rpt_tog_s   : std_logic := '0';
  signal rpt_tog_p   : std_logic := '0';
  signal key_m       : std_logic_vector(7 downto 0) := (others => '0');
  signal key_s       : std_logic_vector(7 downto 0) := (others => '0');
  signal mod_m       : std_logic_vector(7 downto 0) := (others => '0');
  signal mod_s       : std_logic_vector(7 downto 0) := (others => '0');
  signal conn_m      : std_logic := '0';
  signal conn_s      : std_logic := '0';
  signal err_m       : std_logic := '0';
  signal err_s       : std_logic := '0';

  -- clk domain state
  signal key_ready   : std_logic := '0';
  signal keycode_r   : std_logic_vector(7 downto 0) := (others => '0');
  signal modif_r     : std_logic_vector(7 downto 0) := (others => '0');
  signal ascii_r     : std_logic_vector(7 downto 0) := (others => '0');
  signal key_ev_tog  : std_logic := '0';

begin

  nm_i : usb_hid_host_nm
    port map (
      usbclk         => usb_clk,
      usbrst_n       => reset_n,
      usb_dm         => usb_dm,
      usb_dp         => usb_dp,
      typ            => nm_typ,
      rpt            => nm_rpt,
      conerr         => nm_conerr,
      key_modifiers  => nm_modif,
      key1           => nm_key1,
      key2           => open,
      key3           => open,
      key4           => open,
      mouse_btn      => open,
      mouse_dx       => open,
      mouse_dy       => open,
      game_l         => open,
      game_r         => open,
      game_u         => open,
      game_d         => open,
      game_a         => open,
      game_b         => open,
      game_x         => open,
      game_y         => open,
      game_sel       => open,
      game_sta       => open,
      dbg_hid_report => open
    );

  -- usb_clk domain: latch key data on every report pulse and toggle flag
  process(usb_clk)
  begin
    if rising_edge(usb_clk) then
      if reset_n = '0' then
        key_u     <= (others => '0');
        mod_u     <= (others => '0');
        rpt_tog_u <= '0';
        conn_u    <= '0';
        err_u     <= '0';
      else
        if nm_typ = "00" then conn_u <= '0'; else conn_u <= '1'; end if;
        err_u  <= nm_conerr;
        if nm_rpt = '1' then
          key_u     <= nm_key1;
          mod_u     <= nm_modif;
          rpt_tog_u <= not rpt_tog_u;
        end if;
      end if;
    end if;
  end process;

  -- clk domain: synchronise and drive register interface
  process(clk)
  begin
    if rising_edge(clk) then
      -- 2-FF synchronisers
      rpt_tog_m <= rpt_tog_u;  rpt_tog_s <= rpt_tog_m;  rpt_tog_p <= rpt_tog_s;
      key_m     <= key_u;      key_s     <= key_m;
      mod_m     <= mod_u;      mod_s     <= mod_m;
      conn_m    <= conn_u;     conn_s    <= conn_m;
      err_m     <= err_u;      err_s     <= err_m;

      if reset_n = '0' then
        key_ready  <= '0';
        keycode_r  <= (others => '0');
        modif_r    <= (others => '0');
        ascii_r    <= (others => '0');
        key_ev_tog <= '0';
      else
        -- Rising or falling edge of toggle = new HID report
        if rpt_tog_s /= rpt_tog_p then
          key_ready  <= '1';
          keycode_r  <= key_s;
          modif_r    <= mod_s;
          ascii_r    <= hid_to_ascii(key_s, mod_s);
          key_ev_tog <= not key_ev_tog;
        end if;
        -- Read of KEY (addr=01) or ASCII (addr=11) clears key_ready
        if cs = '1' and we = '0' then
          if addr = "01" or addr = "11" then
            key_ready <= '0';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Register read (combinational)
  process(cs, we, addr, conn_s, key_ready, keycode_r, modif_r, ascii_r)
  begin
    dout <= (others => '0');
    if cs = '1' and we = '0' then
      case addr is
        when "00"   => dout <= conn_s & "000000" & key_ready;
        when "01"   => dout <= keycode_r;
        when "10"   => dout <= modif_r;
        when others => dout <= ascii_r;
      end case;
    end if;
  end process;

  irq <= key_ready;

  -- Diagnostics (clk domain)
  diag_connected <= conn_s;
  diag_keycode   <= keycode_r;
  diag_modif     <= modif_r;
  diag_ascii     <= ascii_r;
  diag_key_event <= key_ev_tog;
  diag_polling   <= conn_s;  -- '1' whenever a device is enumerated
  diag_phase     <= x"F" when err_s  = '1' else
                    x"4" when conn_s = '1' else
                    x"3";

end architecture;
