-- USB Full-Speed HID Boot-Protocol keyboard host over ULPI.
--
-- Supports a single FS device (keyboard only, no hub).  Uses USB HID boot
-- protocol (SetProtocol 0) so the 8-byte report format is fixed and no HID
-- descriptor parsing is required.
--
-- Clock domains:
--   ulpi_clk (60 MHz from USB3317) - all USB/ULPI state machines
--   clk      (system, e.g. 27 MHz) - register interface to 6502 bus
--
-- Register map (relative to cs base address, 4 registers):
--   +0  STATUS  R   [7]=connected [1]=key_ready [0]=fifo_not_empty
--   +1  KEY     R   HID keycode of the most recent key-down (0 = none)
--   +2  MODIF   R   modifier byte (bit0=LCtrl bit1=LShift bit4=RCtrl ...)
--   +3  ASCII   R   ASCII equivalent of KEY+MODIF (0 if unmappable)
--
-- Reading KEY or ASCII clears key_ready and dequeues the entry.
-- The device IRQ line is asserted while fifo_not_empty = '1'.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_hid_host is
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;

    ulpi_clk     : in  std_logic;
    ulpi_dir     : in  std_logic;
    ulpi_nxt     : in  std_logic;
    ulpi_data_i  : in  std_logic_vector(7 downto 0);
    ulpi_data_o  : out std_logic_vector(7 downto 0);
    ulpi_data_oe : out std_logic;
    ulpi_stp     : out std_logic;
    ulpi_rst     : out std_logic;

    cs           : in  std_logic;
    we           : in  std_logic;
    addr         : in  std_logic_vector(1 downto 0);
    dout         : out std_logic_vector(7 downto 0);
    irq          : out std_logic;

    -- Diagnostic outputs (clk domain) for boot debug display
    diag_connected : out std_logic;
    diag_keycode   : out std_logic_vector(7 downto 0);
    diag_modif     : out std_logic_vector(7 downto 0);
    diag_ascii     : out std_logic_vector(7 downto 0);
    -- Phase: 0=PHY init, 1=detect, 2=bus rst, 3=enum, 4=poll, F=error
    diag_phase     : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of usb_hid_host is

  -- -------------------------------------------------------------------------
  -- CRC helpers
  -- -------------------------------------------------------------------------
  -- CRC5: polynomial x^5+x^2+1, init=11111, final XOR=11111.
  -- Process one bit, LSB-first as on the USB wire.
  function crc5_bit(crc : std_logic_vector(4 downto 0);
                    b   : std_logic) return std_logic_vector is
    variable fb : std_logic;
    variable c  : std_logic_vector(4 downto 0);
  begin
    fb   := crc(4) xor b;
    c(4) := crc(3);
    c(3) := crc(2);
    c(2) := crc(1) xor fb;
    c(1) := crc(0);
    c(0) := fb;
    return c;
  end function;

  -- CRC5 over any 11-bit field sent LSB-first (used for both tokens and SOF).
  function crc5_11(field : std_logic_vector(10 downto 0))
    return std_logic_vector is
    variable crc : std_logic_vector(4 downto 0) := "11111";
  begin
    for i in 0 to 10 loop
      crc := crc5_bit(crc, field(i));
    end loop;
    return not crc;
  end function;

  -- CRC5 over token {EP[3:0], ADDR[6:0]} sent LSB-first.
  function crc5_token(addr7 : std_logic_vector(6 downto 0);
                      ep4   : std_logic_vector(3 downto 0))
    return std_logic_vector is
  begin
    return crc5_11(ep4 & addr7);
  end function;

  -- CRC16: polynomial x^16+x^15+x^2+1, init=FFFF, final XOR=FFFF.
  function crc16_bit(crc : std_logic_vector(15 downto 0);
                     b   : std_logic) return std_logic_vector is
    variable fb : std_logic;
    variable c  : std_logic_vector(15 downto 0);
  begin
    fb    := crc(15) xor b;
    c(15) := crc(14);
    c(14) := crc(13);
    c(13) := crc(12);
    c(12) := crc(11);
    c(11) := crc(10);
    c(10) := crc(9);
    c(9)  := crc(8);
    c(8)  := crc(7);
    c(7)  := crc(6);
    c(6)  := crc(5);
    c(5)  := crc(4);
    c(4)  := crc(3);
    c(3)  := crc(2);
    c(2)  := crc(1) xor fb;
    c(1)  := crc(0);
    c(0)  := fb;
    return c;
  end function;

  function crc16_byte(crc  : std_logic_vector(15 downto 0);
                      byte : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable c : std_logic_vector(15 downto 0) := crc;
  begin
    for i in 0 to 7 loop
      c := crc16_bit(c, byte(i));
    end loop;
    return c;
  end function;

  -- Build the 2 token bytes for address/endpoint (after PID).
  function token_bytes(addr7 : std_logic_vector(6 downto 0);
                       ep4   : std_logic_vector(3 downto 0))
    return std_logic_vector is  -- returns 16 bits = 2 bytes
    variable crc5 : std_logic_vector(4 downto 0);
    variable b0   : std_logic_vector(7 downto 0);
    variable b1   : std_logic_vector(7 downto 0);
  begin
    crc5  := crc5_token(addr7, ep4);
    b0    := ep4(0) & addr7(6 downto 0);
    b1    := crc5(4 downto 0) & ep4(3 downto 1);
    return b1 & b0;
  end function;

  -- -------------------------------------------------------------------------
  -- USB PID constants
  -- -------------------------------------------------------------------------
  constant PID_SOF   : std_logic_vector(7 downto 0) := x"A5";
  constant PID_SETUP : std_logic_vector(7 downto 0) := x"2D";
  constant PID_IN    : std_logic_vector(7 downto 0) := x"69";
  constant PID_OUT   : std_logic_vector(7 downto 0) := x"E1";
  constant PID_DATA0 : std_logic_vector(7 downto 0) := x"C3";
  constant PID_DATA1 : std_logic_vector(7 downto 0) := x"4B";
  constant PID_ACK   : std_logic_vector(7 downto 0) := x"D2";
  constant PID_NAK   : std_logic_vector(7 downto 0) := x"5A";
  constant PID_STALL : std_logic_vector(7 downto 0) := x"1E";

  -- ULPI TX_CMD for FS normal transmit (bits[7:6]="01", FS xcvr)
  constant ULPI_TXCMD_FS : std_logic_vector(7 downto 0) := x"40";

  -- ULPI register addresses (USB3317)
  constant REG_FUNC_CTRL : std_logic_vector(5 downto 0) := "000100"; -- 0x04
  constant REG_OTG_CTRL  : std_logic_vector(5 downto 0) := "001010"; -- 0x0A
  constant REG_USB_INT_EN: std_logic_vector(5 downto 0) := "001101"; -- 0x0D
  constant REG_SCRATCH   : std_logic_vector(5 downto 0) := "010110"; -- 0x16

  -- ULPI FunctionControl bits:
  --   bit6 SuspendM, bit5 PHY reset, bits4:3 OpMode, bit2 TermSelect,
  --   bits1:0 XcvrSelect.  FS normal host is SuspendM=1, Reset=0,
  --   OpMode=00, TermSelect=1, XcvrSelect=FS(01) => 0x45.
  constant FUNC_FS_NORMAL : std_logic_vector(7 downto 0) := x"45";
  -- USB bus reset is SE0 on the USB lines, not the ULPI PHY reset bit.
  -- Use FS transceiver with OpMode=10 for the reset interval.
  constant FUNC_FS_SE0    : std_logic_vector(7 downto 0) := x"55";

  -- OTGControl: DrvVbus + DpPulldown + DmPulldown for host mode.
  constant OTG_HOST       : std_logic_vector(7 downto 0) := x"23";

  -- ULPI RXCMD line states (bits[3:2])
  constant LS_SE0 : std_logic_vector(1 downto 0) := "00";
  constant LS_K   : std_logic_vector(1 downto 0) := "01";
  constant LS_J   : std_logic_vector(1 downto 0) := "10";

  -- -------------------------------------------------------------------------
  -- Timing constants at 60 MHz
  -- -------------------------------------------------------------------------
  -- PHY reset: >=10 ms -> 600 000 cycles. Use 20 ms for margin.
  constant T_PHY_RESET   : natural := 1_200_000;
  -- PHY hardware reset from the system clock, so the PHY can be released even
  -- if ulpi_clk is stopped while reset is asserted.
  constant T_PHY_RESET_SYS : natural := 540_000;
  -- USB bus reset SE0: >=50 ms -> 3 000 000 cycles
  constant T_BUS_RESET   : natural := 3_000_000;
  -- Post-reset recovery: >=2.5 us -> 150 cycles (use 300 for margin)
  constant T_RESET_RECOV : natural := 300;
  -- SOF period: 1 ms = 60 000 cycles
  constant T_SOF_PERIOD  : natural := 60_000;
  -- Time after BUS_RESET before starting enumeration: 10 ms
  constant T_ENUM_WAIT   : natural := 600_000;
  -- Response timeout: ~18 bit times + packet = ~200 cycles enough for HS
  constant T_RX_TIMEOUT  : natural := 3_000;
  -- NAK retry delay: ~1 ms
  constant T_NAK_RETRY   : natural := 60_000;
  -- SETUP GetDescriptor minimal wait before IN: ~50 ns = 3 cycles
  constant T_SETUP_GAP   : natural := 32;
  -- Initial PHY RXCMDs can hold DIR for a short burst. Wait before forcing an
  -- error so the debug screen can distinguish this from no clock/no reset.
  constant T_REG_DIR_WAIT : natural := 60_000;
  constant T_REG_DIR_WAIT_U : unsigned(15 downto 0) := to_unsigned(60_000, 16);

  -- -------------------------------------------------------------------------
  -- TX buffer - small ROM-like array of bytes to stream
  -- -------------------------------------------------------------------------
  constant TX_BUF_LEN : natural := 16;
  type tx_buf_t is array (0 to TX_BUF_LEN - 1) of std_logic_vector(7 downto 0);

  -- -------------------------------------------------------------------------
  -- HID keycode -> ASCII table (only boot protocol unshifted, no modifiers)
  -- Index = USB HID Usage ID
  -- -------------------------------------------------------------------------
  type ascii_table_t is array (0 to 127) of std_logic_vector(7 downto 0);

  function make_ascii_table return ascii_table_t is
    variable t : ascii_table_t := (others => x"00");
  begin
    -- letters a-z  (HID 0x04-0x1D)
    for i in 0 to 25 loop
      t(i + 4) := std_logic_vector(to_unsigned(97 + i, 8));
    end loop;
    -- digits 1-9 (HID 0x1E-0x26), 0 (0x27)
    for i in 0 to 8 loop
      t(i + 30) := std_logic_vector(to_unsigned(49 + i, 8));
    end loop;
    t(39) := x"30";                      -- 0
    t(40) := x"0D";                      -- Enter
    t(41) := x"1B";                      -- Escape
    t(42) := x"08";                      -- Backspace
    t(43) := x"09";                      -- Tab
    t(44) := x"20";                      -- Space
    t(45) := x"2D";                      -- -
    t(46) := x"3D";                      -- =
    t(47) := x"5B";                      -- [
    t(48) := x"5D";                      -- ]
    t(49) := x"5C";                      -- backslash
    t(51) := x"3B";                      -- ;
    t(52) := x"27";                      -- '
    t(53) := x"60";                      -- `
    t(54) := x"2C";                      -- ,
    t(55) := x"2E";                      -- .
    t(56) := x"2F";                      -- /
    return t;
  end function;

  constant ASCII_TABLE : ascii_table_t := make_ascii_table;

  function keycode_to_ascii(key   : std_logic_vector(7 downto 0);
                             modif : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable idx   : integer;
    variable shift : std_logic;
    variable ch    : std_logic_vector(7 downto 0);
  begin
    idx   := to_integer(unsigned(key));
    shift := modif(1) or modif(5);
    ch    := x"00";
    if idx < 128 then
      ch := ASCII_TABLE(idx);
    end if;
    -- upper-case letters
    if shift = '1' and ch >= x"61" and ch <= x"7A" then
      ch(5) := '0';
    end if;
    return ch;
  end function;

  -- -------------------------------------------------------------------------
  -- ulpi_clk domain signals
  -- -------------------------------------------------------------------------
  type host_state_t is (
    -- PHY bring-up
    H_PHY_RST, H_PHY_RST_WAIT,
    H_REG_WRITE, H_REG_WRITE_NXT, H_REG_WRITE_STP, H_REG_DIR_BLOCKED,
    -- Line monitoring
    H_DETECT,
    -- USB bus reset
    H_BUS_RST, H_BUS_RST_WAIT, H_BUS_RST_RECOV,
    -- Enumeration sequencer
    H_ENUM_WAIT,
    H_SETUP_TOKEN, H_SETUP_TX,
    H_SETUP_DATA,  H_SETUP_DATA_TX,
    H_STATUS_IN,   H_STATUS_IN_TX,
    H_STATUS_WAIT,
    H_IN_TOKEN, H_IN_TX,
    H_RX_WAIT, H_RX_ACK, H_RX_ACK_TX,
    H_NAK_WAIT,
    H_ERROR
  );

  function host_phase_code(s : host_state_t) return std_logic_vector is
  begin
    case s is
      when H_PHY_RST | H_PHY_RST_WAIT | H_REG_WRITE | H_REG_WRITE_NXT |
           H_REG_WRITE_STP | H_REG_DIR_BLOCKED =>
        return x"0";
      when H_DETECT =>
        return x"1";
      when H_BUS_RST | H_BUS_RST_WAIT | H_BUS_RST_RECOV =>
        return x"2";
      when H_ENUM_WAIT | H_SETUP_TOKEN | H_SETUP_TX | H_SETUP_DATA |
           H_SETUP_DATA_TX | H_STATUS_IN | H_STATUS_IN_TX |
           H_STATUS_WAIT | H_RX_ACK_TX | H_NAK_WAIT =>
        return x"3";
      when H_IN_TOKEN | H_IN_TX | H_RX_WAIT | H_RX_ACK =>
        return x"4";
      when others =>
        return x"F";
    end case;
  end function;

  function host_state_code(s : host_state_t) return std_logic_vector is
  begin
    case s is
      when H_PHY_RST        => return x"00";
      when H_PHY_RST_WAIT   => return x"01";
      -- 0x8x marks the current HID-host debug build on the boot screen.
      when H_REG_WRITE      => return x"82";
      when H_REG_WRITE_NXT  => return x"83";
      when H_REG_WRITE_STP  => return x"84";
      when H_REG_DIR_BLOCKED => return x"85";
      when H_DETECT         => return x"10";
      when H_BUS_RST        => return x"20";
      when H_BUS_RST_WAIT   => return x"21";
      when H_BUS_RST_RECOV  => return x"22";
      when H_ENUM_WAIT      => return x"30";
      when H_SETUP_TOKEN    => return x"31";
      when H_SETUP_TX       => return x"32";
      when H_SETUP_DATA     => return x"33";
      when H_SETUP_DATA_TX  => return x"34";
      when H_STATUS_IN      => return x"35";
      when H_STATUS_IN_TX   => return x"36";
      when H_STATUS_WAIT    => return x"37";
      when H_IN_TOKEN       => return x"40";
      when H_IN_TX          => return x"41";
      when H_RX_WAIT        => return x"42";
      when H_RX_ACK         => return x"43";
      when H_RX_ACK_TX      => return x"44";
      when H_NAK_WAIT       => return x"45";
      when H_ERROR          => return x"E0";
      when others           => return x"F0";
    end case;
  end function;

  signal host_st     : host_state_t := H_PHY_RST;
  signal timer       : natural range 0 to T_BUS_RESET + 1 := 0;
  signal rw_timeout  : unsigned(15 downto 0) := (others => '0');  -- separate from timer

  -- ULPI output registers
  signal data_o_r    : std_logic_vector(7 downto 0) := (others => '0');
  signal data_oe_r   : std_logic := '0';
  signal stp_r       : std_logic := '0';
  signal phy_rst_release : std_logic := '0';
  signal phy_rst_cnt : natural range 0 to T_PHY_RESET_SYS := 0;
  signal phy_rst_rel_meta : std_logic := '0';
  signal phy_rst_rel_sync : std_logic := '0';

  -- ULPI register write helpers
  signal rw_addr_r   : std_logic_vector(5 downto 0) := (others => '0');
  signal rw_data_r   : std_logic_vector(7 downto 0) := (others => '0');
  signal rw_return_r : host_state_t := H_DETECT;

  -- PHY config register write sequence
  -- Each reg_seq entry: addr[5:0] & data[7:0] = 14 bits
  type reg_seq_t is array (0 to 3) of std_logic_vector(13 downto 0);
  constant REG_SEQ : reg_seq_t := (
    REG_FUNC_CTRL  & FUNC_FS_NORMAL,
    REG_OTG_CTRL   & OTG_HOST,
    REG_USB_INT_EN & x"00",   -- disable PHY interrupts
    REG_SCRATCH    & x"A5"    -- scratch verify
  );
  signal reg_seq_idx : natural range 0 to 4 := 0;

  -- TX packet buffer
  signal tx_buf      : tx_buf_t := (others => (others => '0'));
  signal tx_len      : natural range 0 to TX_BUF_LEN := 0;
  signal tx_idx      : natural range 0 to TX_BUF_LEN := 0;

  -- SOF / enumeration counters
  signal enum_wait_cnt : natural range 0 to T_ENUM_WAIT := 0;

  -- Enumeration step
  type enum_step_t is (
    EN_SET_ADDR, EN_SET_CFG, EN_SET_PROTO, EN_POLL
  );
  signal enum_step   : enum_step_t := EN_SET_ADDR;
  signal dev_addr    : std_logic_vector(6 downto 0) := (others => '0');
  signal ctrl_toggle : std_logic := '0';
  signal hid_toggle  : std_logic := '0';

  -- RX state
  type rx_buf_t is array (0 to 9) of std_logic_vector(7 downto 0);
  signal rx_buf      : rx_buf_t := (others => (others => '0'));
  signal rx_len      : natural range 0 to 10 := 0;
  signal rx_active   : std_logic := '0';
  signal rx_pid      : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_timeout  : natural range 0 to T_RX_TIMEOUT := 0;

  -- Key output latch (ulpi_clk domain)
  signal key_mod_u   : std_logic_vector(7 downto 0) := (others => '0');
  signal key_code_u  : std_logic_vector(7 downto 0) := (others => '0');
  signal key_valid_u : std_logic := '0';

  -- Connected flag
  signal connected_u : std_logic := '0';
  signal line_state_u : std_logic_vector(1 downto 0) := LS_SE0;
  signal phase_u      : std_logic_vector(3 downto 0);
  signal state_code_u : std_logic_vector(7 downto 0);
  signal bus_debug_u  : std_logic_vector(7 downto 0);
  signal progress_u   : std_logic_vector(7 downto 0) := (others => '0');
  signal ulpi_beat_u  : unsigned(25 downto 0) := (others => '0');
  signal ulpi_data_dbg_u : std_logic_vector(7 downto 0) := (others => '0');

  -- -------------------------------------------------------------------------
  -- Clock domain crossing (ulpi_clk -> clk)
  -- -------------------------------------------------------------------------
  signal key_mod_m   : std_logic_vector(7 downto 0) := (others => '0');
  signal key_code_m  : std_logic_vector(7 downto 0) := (others => '0');
  signal key_valid_m : std_logic := '0';
  signal connected_m : std_logic := '0';
  signal rx_pid_m    : std_logic_vector(7 downto 0) := (others => '0');
  signal line_state_m : std_logic_vector(1 downto 0) := (others => '0');
  signal phase_m     : std_logic_vector(3 downto 0) := (others => '0');
  signal state_code_m : std_logic_vector(7 downto 0) := (others => '0');
  signal bus_debug_m  : std_logic_vector(7 downto 0) := (others => '0');
  signal progress_m   : std_logic_vector(7 downto 0) := (others => '0');
  signal ulpi_data_dbg_m : std_logic_vector(7 downto 0) := (others => '0');

  signal key_mod_s   : std_logic_vector(7 downto 0) := (others => '0');
  signal key_code_s  : std_logic_vector(7 downto 0) := (others => '0');
  signal key_valid_s : std_logic := '0';
  signal connected_s : std_logic := '0';
  signal rx_pid_s    : std_logic_vector(7 downto 0) := (others => '0');
  signal line_state_s : std_logic_vector(1 downto 0) := (others => '0');
  signal phase_s     : std_logic_vector(3 downto 0) := (others => '0');
  signal state_code_s : std_logic_vector(7 downto 0) := (others => '0');
  signal bus_debug_s  : std_logic_vector(7 downto 0) := (others => '0');
  signal progress_s   : std_logic_vector(7 downto 0) := (others => '0');
  signal ulpi_data_dbg_s : std_logic_vector(7 downto 0) := (others => '0');

  -- clk-domain key FIFO (depth 8)
  type key_entry_t is record
    code  : std_logic_vector(7 downto 0);
    modif : std_logic_vector(7 downto 0);
  end record;
  type key_fifo_t is array (0 to 7) of key_entry_t;
  signal fifo        : key_fifo_t;
  -- 4-bit pointers so full/empty are distinguishable (depth=8, indices mod 8)
  signal fifo_wp     : unsigned(3 downto 0) := (others => '0');
  signal fifo_rp     : unsigned(3 downto 0) := (others => '0');
  signal fifo_full   : std_logic;
  signal fifo_empty  : std_logic;

  signal key_valid_prev : std_logic := '0';
  signal key_ready_s    : std_logic := '0';

begin

  ulpi_data_o  <= data_o_r;
  ulpi_data_oe <= data_oe_r;
  ulpi_stp     <= stp_r;
  ulpi_rst     <= phy_rst_release;
  phase_u       <= host_phase_code(host_st);
  state_code_u  <= host_state_code(host_st);
  bus_debug_u   <= ulpi_dir & ulpi_nxt & data_oe_r & stp_r & ulpi_data_i(3 downto 0);

  -- =========================================================================
  -- ULPI / USB host state machine  (ulpi_clk domain)
  -- =========================================================================
  process(ulpi_clk)


    variable crc5v  : std_logic_vector(4 downto 0);
    variable tokv   : std_logic_vector(15 downto 0);
    variable crc16v : std_logic_vector(15 downto 0);
    variable sv     : tx_buf_t;   -- local setup bytes for CRC computation
    variable timeout_v : unsigned(15 downto 0);

  begin
    if rising_edge(ulpi_clk) then
      -- Default: de-assert STP; OE holds its last value
      stp_r      <= '0';
      data_oe_r  <= data_oe_r;
      phy_rst_rel_meta <= phy_rst_release;
      phy_rst_rel_sync <= phy_rst_rel_meta;


      if reset_n = '0' or phy_rst_rel_sync = '0' then
        host_st      <= H_PHY_RST;
        timer        <= 0;
        rw_timeout   <= (others => '0');
        data_o_r     <= (others => '0');
        data_oe_r    <= '0';
        stp_r        <= '0';
        enum_wait_cnt <= 0;
        connected_u  <= '0';
        line_state_u <= LS_SE0;
        progress_u   <= (others => '0');
        ulpi_beat_u  <= (others => '0');
        ulpi_data_dbg_u <= (others => '0');
        key_valid_u  <= '0';
        reg_seq_idx  <= 0;
        enum_step    <= EN_SET_ADDR;
        dev_addr     <= (others => '0');
        ctrl_toggle  <= '0';
        hid_toggle   <= '0';
        rx_active    <= '0';

      else
        ulpi_beat_u <= ulpi_beat_u + 1;
        timeout_v := rw_timeout;
        progress_u <= std_logic_vector(ulpi_beat_u(25 downto 22)) &
                      std_logic_vector(timeout_v(15 downto 12));
        ulpi_data_dbg_u <= ulpi_data_i;
        if ulpi_dir = '1' and ulpi_nxt = '0' then
          line_state_u <= ulpi_data_i(3 downto 2);
        end if;

        case host_st is

          -- -------------------------------------------------------------------
          -- Phase 1: Hold PHY in reset, then release and wait for it to start
          -- -------------------------------------------------------------------
          when H_PHY_RST =>
            data_oe_r <= '0';
            timer   <= T_PHY_RESET;
            host_st <= H_PHY_RST_WAIT;

          when H_PHY_RST_WAIT =>
            if timer = 0 then
              -- Start init register sequence: write REG_SEQ(0..3) then go to H_DETECT
              reg_seq_idx <= 1;           -- next entry to write after this one
              rw_addr_r   <= REG_SEQ(0)(13 downto 8);
              rw_data_r   <= REG_SEQ(0)(7 downto 0);
              rw_return_r <= H_DETECT;    -- final return after all 4 regs
              rw_timeout  <= T_REG_DIR_WAIT_U;
              host_st     <= H_REG_WRITE;
            else
              timer <= timer - 1;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 2: ULPI register write primitive (single register)
          --   Set rw_addr_r, rw_data_r, rw_return_r before entering H_REG_WRITE.
          --   For a sequenced write, also set reg_seq_idx to the next entry
          --   (0 = no more entries after this one).
          -- -------------------------------------------------------------------
          when H_REG_WRITE =>
            if ulpi_dir = '0' then
              data_o_r  <= "10" & rw_addr_r;
              data_oe_r <= '1';
              rw_timeout <= T_REG_DIR_WAIT_U;
              host_st   <= H_REG_WRITE_NXT;
            else
              data_oe_r <= '0';
              host_st <= H_REG_DIR_BLOCKED;
            end if;

          when H_REG_DIR_BLOCKED =>
            data_oe_r <= '0';
            if ulpi_dir = '0' then
              rw_timeout <= T_REG_DIR_WAIT_U;
              host_st <= H_REG_WRITE;
            elsif rw_timeout = x"0000" then
              host_st <= H_ERROR;
            else
              rw_timeout <= rw_timeout - 1;
            end if;

          when H_REG_WRITE_NXT =>
            data_o_r  <= "10" & rw_addr_r;
            if ulpi_dir = '1' then
              -- PHY owns the ULPI bus for an RXCMD/event. Release DATA and
              -- retry the register write once DIR drops.
              data_oe_r <= '0';
              if rw_timeout = x"0000" then
                host_st <= H_ERROR;
              else
                rw_timeout <= rw_timeout - 1;
                host_st <= H_REG_WRITE;
              end if;
            elsif rw_timeout = T_REG_DIR_WAIT_U then
              data_oe_r <= '1';
              -- The command reaches the pins after this clock edge. Start
              -- sampling NXT on the following ULPI clock.
              rw_timeout <= rw_timeout - 1;
            elsif ulpi_nxt = '1' then
              data_oe_r <= '1';
              host_st <= H_REG_WRITE_STP;
            elsif rw_timeout = x"0000" then
              data_oe_r <= '1';
              host_st <= H_ERROR;
            else
              data_oe_r <= '1';
              rw_timeout <= rw_timeout - 1;
            end if;

          when H_REG_WRITE_STP =>
            -- DATA + STP simultaneously (ULPI register write completes here)
            data_o_r  <= rw_data_r;
            data_oe_r <= '1';
            stp_r     <= '1';
            if reg_seq_idx > 0 and reg_seq_idx <= 3 then
              -- More registers in the init sequence
              rw_addr_r   <= REG_SEQ(reg_seq_idx)(13 downto 8);
              rw_data_r   <= REG_SEQ(reg_seq_idx)(7 downto 0);
              rw_timeout  <= T_REG_DIR_WAIT_U;
              if reg_seq_idx < 3 then
                reg_seq_idx <= reg_seq_idx + 1;
              else
                reg_seq_idx <= 0;
              end if;
              host_st     <= H_REG_WRITE;
            else
              reg_seq_idx <= 0;
              host_st     <= rw_return_r;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 3: Monitor RXCMD for device connect
          --   When PHY sees FS device (SE0->J) it reports LS=J in RXCMD
          -- -------------------------------------------------------------------
          when H_DETECT =>
            data_oe_r   <= '0';
            connected_u <= '0';
            -- DIR=1, NXT=0 -> RXCMD byte; bits[3:2] = LineState
            if ulpi_dir = '1' and ulpi_nxt = '0' then
              if ulpi_data_i(3 downto 2) = LS_J then
                -- FS device attached (J = idle on FS bus)
                timer   <= T_BUS_RESET;
                host_st <= H_BUS_RST;
              end if;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 4: USB bus reset (drive SE0 for 50 ms)
          -- -------------------------------------------------------------------
          when H_BUS_RST =>
            rw_addr_r   <= REG_FUNC_CTRL;
            rw_data_r   <= FUNC_FS_SE0;
            rw_return_r <= H_BUS_RST_WAIT;
            reg_seq_idx <= 0;         -- single register write, no sequence
            timer       <= T_BUS_RESET;
            rw_timeout  <= T_REG_DIR_WAIT_U;
            host_st     <= H_REG_WRITE;

          when H_BUS_RST_WAIT =>
            if timer = 0 then
              rw_addr_r   <= REG_FUNC_CTRL;
              rw_data_r   <= FUNC_FS_NORMAL;
              rw_return_r <= H_BUS_RST_RECOV;
              reg_seq_idx <= 0;         -- single register write, no sequence
              timer       <= T_RESET_RECOV;
              rw_timeout  <= T_REG_DIR_WAIT_U;
              host_st     <= H_REG_WRITE;
            else
              timer <= timer - 1;
            end if;

          when H_BUS_RST_RECOV =>
            if timer = 0 then
              enum_step     <= EN_SET_ADDR;
              dev_addr      <= (others => '0');
              ctrl_toggle   <= '0';
              hid_toggle    <= '0';
              enum_wait_cnt <= T_ENUM_WAIT;
              host_st       <= H_ENUM_WAIT;
            else
              timer <= timer - 1;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 5: SOF + enumeration
          -- -------------------------------------------------------------------
          when H_ENUM_WAIT =>
            if enum_wait_cnt = 0 then
              host_st <= H_SETUP_TOKEN;
            else
              enum_wait_cnt <= enum_wait_cnt - 1;
            end if;

          -- -------------------------------------------------------------------
          -- SETUP token -> DATA0 -> STATUS_IN
          -- -------------------------------------------------------------------
          when H_SETUP_TOKEN =>
            if ulpi_dir = '0' then
              tokv := token_bytes(dev_addr, "0000");
              tx_buf(0) <= PID_SETUP;
              tx_buf(1) <= tokv(7 downto 0);
              tx_buf(2) <= tokv(15 downto 8);
              tx_len    <= 3;
              tx_idx    <= 0;
              data_o_r  <= ULPI_TXCMD_FS;
              data_oe_r <= '1';

              host_st   <= H_SETUP_TX;
            end if;

          when H_SETUP_TX =>
            -- Same as SOF_TX but returns to H_SETUP_DATA
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r  <= (others => '0');
                data_oe_r <= '1';
                stp_r     <= '1';
                timer     <= T_SETUP_GAP;
                host_st   <= H_SETUP_DATA;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              host_st   <= H_SETUP_DATA;
            end if;

          when H_SETUP_DATA =>
            -- Build the 8-byte SETUP DATA0 depending on enum_step
            if timer > 0 then
              timer <= timer - 1;
            elsif ulpi_dir = '0' then
              -- Build CRC16 over 8 setup bytes
              -- Load setup bytes into variable first so CRC is over correct data
              sv := (others => x"00");
              sv(0) := PID_DATA0;
              case enum_step is
                when EN_SET_ADDR =>
                  -- SetAddress(1): bmRT=0x00 bReq=0x05 wVal=0x0001 wIdx=0 wLen=0
                  sv(1) := x"00"; sv(2) := x"05";
                  sv(3) := x"01"; sv(4) := x"00";
                  sv(5) := x"00"; sv(6) := x"00";
                  sv(7) := x"00"; sv(8) := x"00";
                when EN_SET_CFG =>
                  -- SetConfiguration(1): bmRT=0x00 bReq=0x09 wVal=0x0001 wIdx=0 wLen=0
                  sv(1) := x"00"; sv(2) := x"09";
                  sv(3) := x"01"; sv(4) := x"00";
                  sv(5) := x"00"; sv(6) := x"00";
                  sv(7) := x"00"; sv(8) := x"00";
                when EN_SET_PROTO =>
                  -- SetProtocol(0 = boot): bmRT=0x21 bReq=0x0B wVal=0x0000 wIdx=0 wLen=0
                  sv(1) := x"21"; sv(2) := x"0B";
                  sv(3) := x"00"; sv(4) := x"00";
                  sv(5) := x"00"; sv(6) := x"00";
                  sv(7) := x"00"; sv(8) := x"00";
                when others =>
                  null;
              end case;
              -- CRC16 over the 8 setup data bytes (using variable sv, correct this cycle)
              crc16v := x"FFFF";
              for bi in 1 to 8 loop
                crc16v := crc16_byte(crc16v, sv(bi));
              end loop;
              crc16v := not crc16v;
              sv(9)  := crc16v(7 downto 0);
              sv(10) := crc16v(15 downto 8);
              -- Now copy all to tx_buf signals
              for bi in 0 to 10 loop
                tx_buf(bi) <= sv(bi);
              end loop;
              tx_len     <= 11;
              tx_idx     <= 0;
              data_o_r   <= ULPI_TXCMD_FS;
              data_oe_r  <= '1';

              host_st    <= H_SETUP_DATA_TX;
            end if;

          when H_SETUP_DATA_TX =>
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r  <= (others => '0');
                data_oe_r <= '1';
                stp_r     <= '1';
                timer     <= T_SETUP_GAP;
                host_st   <= H_STATUS_IN;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              host_st   <= H_STATUS_IN;
            end if;

          -- STATUS_IN: send IN token, expect empty DATA1 ACK from device
          when H_STATUS_IN =>
            if timer > 0 then
              timer <= timer - 1;
            elsif ulpi_dir = '0' then
              tokv := token_bytes(dev_addr, "0000");
              tx_buf(0) <= PID_IN;
              tx_buf(1) <= tokv(7 downto 0);
              tx_buf(2) <= tokv(15 downto 8);
              tx_len    <= 3;
              tx_idx    <= 0;
              data_o_r  <= ULPI_TXCMD_FS;
              data_oe_r <= '1';

              host_st   <= H_STATUS_IN_TX;
            end if;

          when H_STATUS_IN_TX =>
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r  <= (others => '0');
                data_oe_r <= '1';
                stp_r     <= '1';
                rx_len    <= 0;
                rx_active <= '0';
                rx_timeout <= T_RX_TIMEOUT;
                host_st   <= H_STATUS_WAIT;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              rx_len    <= 0;
              rx_active <= '0';
              rx_timeout <= T_RX_TIMEOUT;
              host_st   <= H_STATUS_WAIT;
            end if;

          -- Wait for DATA1 (or NAK/STALL) from device, then send ACK
          when H_STATUS_WAIT =>
            data_oe_r <= '0';
            if rx_timeout = 0 then
              host_st <= H_NAK_WAIT;
              timer   <= T_NAK_RETRY;
            elsif ulpi_dir = '1' then
              -- DIR=1, NXT=1 -> USB packet data byte
              if ulpi_nxt = '1' then
                rx_pid <= ulpi_data_i;
                rx_len <= 1;
              end if;
              rx_timeout <= rx_timeout - 1;
            elsif rx_len > 0 then
              -- DIR de-asserted: packet received
              if rx_pid = PID_DATA1 or rx_pid = PID_DATA0 then
                -- Status phase complete - send ACK then advance
                tx_buf(0) <= PID_ACK;
                tx_len    <= 1;
                tx_idx    <= 0;
                data_o_r  <= ULPI_TXCMD_FS;
                data_oe_r <= '1';
                host_st   <= H_RX_ACK_TX;
              elsif rx_pid = PID_NAK then
                host_st <= H_NAK_WAIT;
                timer   <= T_NAK_RETRY;
              else
                -- STALL or other - skip this step
                host_st <= H_NAK_WAIT;
                timer   <= T_NAK_RETRY;
              end if;
            else
              rx_timeout <= rx_timeout - 1;
            end if;

          when H_RX_ACK_TX =>
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r  <= (others => '0');
                data_oe_r <= '1';
                stp_r     <= '1';
                -- Advance enumeration or start polling
                case enum_step is
                  when EN_SET_ADDR =>
                    dev_addr  <= "0000001";
                    enum_step <= EN_SET_CFG;
                    host_st   <= H_SETUP_TOKEN;
                  when EN_SET_CFG =>
                    enum_step <= EN_SET_PROTO;
                    host_st   <= H_SETUP_TOKEN;
                  when EN_SET_PROTO =>
                    connected_u <= '1';
                    enum_step   <= EN_POLL;
                    host_st     <= H_IN_TOKEN;
                  when EN_POLL =>
                    -- Should not arrive here via ACK
                    host_st <= H_IN_TOKEN;
                end case;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              host_st   <= H_IN_TOKEN;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 6: HID polling - send IN to endpoint 1
          -- -------------------------------------------------------------------
          when H_IN_TOKEN =>
            if ulpi_dir = '0' then
              tokv := token_bytes(dev_addr, "0001");
              tx_buf(0) <= PID_IN;
              tx_buf(1) <= tokv(7 downto 0);
              tx_buf(2) <= tokv(15 downto 8);
              tx_len    <= 3;
              tx_idx    <= 0;
              data_o_r  <= ULPI_TXCMD_FS;
              data_oe_r <= '1';

              host_st   <= H_IN_TX;
            end if;

          when H_IN_TX =>
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r   <= (others => '0');
                data_oe_r  <= '1';
                stp_r      <= '1';
                rx_len     <= 0;
                rx_active  <= '0';
                rx_timeout <= T_RX_TIMEOUT;
                host_st    <= H_RX_WAIT;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r  <= '0';
              rx_len     <= 0;
              rx_active  <= '0';
              rx_timeout <= T_RX_TIMEOUT;
              host_st    <= H_RX_WAIT;
            end if;

          -- Wait for DATA1 keyboard report (8 bytes)
          when H_RX_WAIT =>
            data_oe_r <= '0';
            if rx_timeout = 0 then
              -- Device not responding - poll again after NAK delay
              host_st <= H_NAK_WAIT;
              timer   <= T_NAK_RETRY;
            elsif ulpi_dir = '1' then
              -- DIR=1, NXT=1 -> USB receive data byte (not RXCMD)
              if ulpi_nxt = '1' then
                if rx_len = 0 then
                  rx_pid <= ulpi_data_i;
                  rx_len <= 1;
                elsif rx_len <= 9 then
                  rx_buf(rx_len - 1) <= ulpi_data_i;
                  rx_len <= rx_len + 1;
                end if;
              end if;
              rx_timeout <= rx_timeout - 1;
            elsif rx_len > 0 then
              -- Packet received (DIR deasserted)
              if rx_pid = PID_DATA1 or rx_pid = PID_DATA0 then
                hid_toggle <= not hid_toggle;
                -- Parse 8-byte boot protocol report
                -- Byte 1 = modifier, Byte 2 = reserved, Bytes 3-8 = keycodes
                if rx_len >= 4 then
                  key_mod_u   <= rx_buf(0);  -- byte after PID: modifier
                  key_code_u  <= rx_buf(2);  -- byte 3: first keycode
                  if rx_buf(2) /= x"00" then
                    key_valid_u <= not key_valid_u;
                  end if;
                end if;
                -- Send ACK
                tx_buf(0) <= PID_ACK;
                tx_len    <= 1;
                tx_idx    <= 0;
                data_o_r  <= ULPI_TXCMD_FS;
                data_oe_r <= '1';
                host_st   <= H_RX_ACK;
              elsif rx_pid = PID_NAK then
                host_st <= H_NAK_WAIT;
                timer   <= T_NAK_RETRY;
              else
                host_st <= H_NAK_WAIT;
                timer   <= T_NAK_RETRY;
              end if;
              rx_len <= 0;
            else
              rx_timeout <= rx_timeout - 1;
            end if;

          when H_RX_ACK =>
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r  <= (others => '0');
                data_oe_r <= '1';
                stp_r     <= '1';
                host_st   <= H_NAK_WAIT;
                timer     <= T_NAK_RETRY;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              host_st   <= H_NAK_WAIT;
              timer     <= T_NAK_RETRY;
            end if;

          when H_NAK_WAIT =>
            data_oe_r <= '0';
            if timer = 0 then
              if enum_step = EN_POLL then
                host_st <= H_IN_TOKEN;
              else
                host_st <= H_SETUP_TOKEN;
              end if;
            else
              timer <= timer - 1;
            end if;

          when H_ERROR =>
            -- Stay here until reset
            data_oe_r <= '0';

          when others =>
            host_st <= H_ERROR;
        end case;
      end if;
    end if;
  end process;

  -- =========================================================================
  -- Clock domain crossing: ulpi_clk -> clk (2-FF synchroniser on each signal)
  -- =========================================================================
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        phy_rst_release <= '0';
        phy_rst_cnt <= 0;
      elsif phy_rst_cnt = T_PHY_RESET_SYS then
        phy_rst_release <= '1';
      else
        phy_rst_cnt <= phy_rst_cnt + 1;
        phy_rst_release <= '0';
      end if;

      -- Meta
      key_mod_m   <= key_mod_u;
      key_code_m  <= key_code_u;
      key_valid_m <= key_valid_u;
      connected_m <= connected_u;
      rx_pid_m    <= rx_pid;
      line_state_m <= line_state_u;
      phase_m     <= phase_u;
      state_code_m <= state_code_u;
      bus_debug_m <= bus_debug_u;
      progress_m <= progress_u;
      ulpi_data_dbg_m <= ulpi_data_dbg_u;
      -- Sync
      key_mod_s   <= key_mod_m;
      key_code_s  <= key_code_m;
      key_valid_s <= key_valid_m;
      connected_s <= connected_m;
      rx_pid_s    <= rx_pid_m;
      line_state_s <= line_state_m;
      phase_s     <= phase_m;
      state_code_s <= state_code_m;
      bus_debug_s <= bus_debug_m;
      progress_s <= progress_m;
      ulpi_data_dbg_s <= ulpi_data_dbg_m;
    end if;
  end process;

  -- =========================================================================
  -- clk domain: key FIFO + register interface
  -- =========================================================================
  -- Full: same lower 3 bits but MSB differs; Empty: pointers equal
  fifo_full  <= '1' when fifo_wp(2 downto 0) = fifo_rp(2 downto 0)
                         and fifo_wp(3) /= fifo_rp(3) else '0';
  fifo_empty <= '1' when fifo_wp = fifo_rp else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        fifo_wp        <= (others => '0');
        fifo_rp        <= (others => '0');
        key_valid_prev <= '0';
        key_ready_s    <= '0';
      else
        -- Detect edge on key_valid toggle (means new key arrived)
        key_valid_prev <= key_valid_s;
        if key_valid_s /= key_valid_prev and key_code_s /= x"00"
           and fifo_full = '0' then
          fifo(to_integer(fifo_wp(2 downto 0))).code  <= key_code_s;
          fifo(to_integer(fifo_wp(2 downto 0))).modif <= key_mod_s;
          fifo_wp     <= fifo_wp + 1;
          key_ready_s <= '1';
        end if;

        -- Register reads pop the FIFO
        if cs = '1' and we = '0' then
          case addr is
            when "00" => null;         -- STATUS: no side-effect
            when "01" | "11" =>        -- KEY or ASCII: pop
              if fifo_empty = '0' then
                fifo_rp <= fifo_rp + 1;
                if fifo_wp = fifo_rp + 1 then
                  key_ready_s <= '0';
                end if;
              end if;
            when others => null;
          end case;
        end if;
      end if;
    end if;
  end process;

  -- Register read mux (combinatorial)
  process(cs, we, addr, connected_s, key_ready_s, fifo_empty,
          fifo, fifo_rp, key_code_s, key_mod_s)
    variable head_code  : std_logic_vector(7 downto 0);
    variable head_modif : std_logic_vector(7 downto 0);
  begin
    dout      <= x"FF";
    if fifo_empty = '0' then
      head_code  := fifo(to_integer(fifo_rp(2 downto 0))).code;
      head_modif := fifo(to_integer(fifo_rp(2 downto 0))).modif;
    else
      head_code  := x"00";
      head_modif := x"00";
    end if;
    if cs = '1' and we = '0' then
      case addr is
        when "00" =>
          dout <= connected_s & "00000" & key_ready_s & (not fifo_empty);
        when "01" =>
          dout <= head_code;
        when "10" =>
          dout <= head_modif;
        when others =>
          dout <= keycode_to_ascii(head_code, head_modif);
      end case;
    end if;
  end process;

  irq <= not fifo_empty;

  -- Diagnostic phase: encode host state as 4-bit nibble for display.
  diag_phase <= phase_s;

  -- Diagnostic outputs: head of FIFO once keys arrive.  Before that, expose
  -- host debug breadcrumbs on the boot screen:
  --   KEY=state code, MOD=DIR/NXT/OE/STP/RXCMD-low, ASCII=raw ULPI DATA.
  diag_connected <= connected_s;
  diag_keycode   <= fifo(to_integer(fifo_rp(2 downto 0))).code  when fifo_empty = '0' else state_code_s;
  diag_modif     <= fifo(to_integer(fifo_rp(2 downto 0))).modif when fifo_empty = '0' else bus_debug_s;
  diag_ascii     <= keycode_to_ascii(
                      fifo(to_integer(fifo_rp(2 downto 0))).code,
                      fifo(to_integer(fifo_rp(2 downto 0))).modif)
                    when fifo_empty = '0' else ulpi_data_dbg_s;

end architecture;
