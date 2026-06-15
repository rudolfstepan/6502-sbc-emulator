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
  generic (
    -- Divides the large millisecond-scale timing constants so a testbench can
    -- exercise PHY init / bus reset / enumeration in a feasible sim time.
    -- Defaults to 1 (real hardware timing); set large (e.g. 1000) in simulation.
    SIM_SCALE : positive := 1
  );
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
    diag_phase     : out std_logic_vector(3 downto 0);
    -- Key event signal: toggles when new key is received
    diag_key_event : out std_logic;
    -- Polling active flag: '1' when in EN_POLL state
    diag_polling   : out std_logic;

    -- In-system ULPI bus capture (logic-analyzer): records {dir,nxt,oe,stp,
    -- phase,bus-byte} for 128 ulpi_clk cycles starting when the host issues the
    -- GET_DESCRIPTOR IN token.  Read out (clk domain) for a UART hex dump.
    diag_cap_addr  : in  std_logic_vector(6 downto 0) := (others => '0');
    diag_cap_data  : out std_logic_vector(15 downto 0);
    diag_cap_ready : out std_logic
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
    variable res : std_logic_vector(4 downto 0);
    variable rev : std_logic_vector(4 downto 0);
  begin
    for i in 0 to 10 loop
      crc := crc5_bit(crc, field(i));
    end loop;
    res := not crc;
    -- USB transmits the CRC residual MSB-first (crc(4) first on the wire).
    -- The byte serialiser sends bits LSB-first, so bit-reverse the residual
    -- here; otherwise the device sees a bad CRC5 and silently drops the token.
    -- Verified against the canonical addr0/ep0 token 2D 00 10.
    for i in 0 to 4 loop
      rev(i) := res(4 - i);
    end loop;
    return rev;
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

  -- ULPI FunctionControl register (addr 0x04).
  -- IMPORTANT EMPIRICAL FINDING: the standard ULPI 1.1 layout (bit6=SuspendM,
  -- bits[1:0]=XcvrSelect) predicts 0x45 for active-FS, but on THIS board 0x45
  -- consistently regresses (PH stuck at 2, device classified LS) while 0x86
  -- consistently reaches enumeration (PH=3).  That is only self-consistent if
  -- this PHY/data path uses the REVERSED bit order, under which:
  --   bit7=SuspendM, bit6=Reset, bits[5:4]=OpMode, bits[3:2]=XcvrSelect, bit1=TermSelect
  --   0x86 = 1000_0110 = SuspendM=1, Reset=0, OpMode=00, XcvrSelect=01(FS), TermSelect=1
  --   0x45 = 0100_0101 = SuspendM=0, Reset=1 (constant PHY reset!) -> worse
  -- The reversed interpretation MATCHES the hardware behaviour, so we use 0x86.
  -- (This strongly suggests the ulpi_data byte lane is bit-reversed in this
  --  design -- see the bit-reverse experiment in the top-level wrapper.)
  constant FUNC_FS_NORMAL : std_logic_vector(7 downto 0) := x"86";
  constant FUNC_LS_NORMAL : std_logic_vector(7 downto 0) := x"8A";
  -- USB bus reset: drive SE0 (reversed layout: bits[5:4]=OpMode=10).
  constant FUNC_FS_SE0    : std_logic_vector(7 downto 0) := x"A6";
  constant FUNC_LS_SE0    : std_logic_vector(7 downto 0) := x"AA";

  -- OTGControl for FS host: DmPulldown(bit2)+DpPulldown(bit1)+IdPullup(bit0).
  -- DrvVbusExternal(5) and DrvVbus(6) are intentionally NOT set: on the Tang
  -- Primer 20K the USB3317 DRV_VBUS output drives a PMOS gate directly (no
  -- inverter), so DRV_VBUS=LOW (bits 5:6 = 0) turns the PMOS ON and supplies
  -- VBUS to the USB-A host connector.  Setting either bit would de-assert VBUS.
  constant OTG_HOST       : std_logic_vector(7 downto 0) := x"07";

  -- ULPI RXCMD line states (bits[5:4], per ULPI 1.1 spec)
  constant LS_SE0 : std_logic_vector(1 downto 0) := "00";
  constant LS_K   : std_logic_vector(1 downto 0) := "01";
  constant LS_J   : std_logic_vector(1 downto 0) := "10";

  -- -------------------------------------------------------------------------
  -- Timing constants at 60 MHz
  -- -------------------------------------------------------------------------
  -- PHY reset: >=10 ms -> 600 000 cycles. Use 20 ms for margin.
  constant T_PHY_RESET   : natural := 1_200_000 / SIM_SCALE;
  -- PHY hardware reset from the system clock, so the PHY can be released even
  -- if ulpi_clk is stopped while reset is asserted.
  constant T_PHY_RESET_SYS : natural := 540_000 / SIM_SCALE;
  -- USB bus reset SE0: >=50 ms -> 3 000 000 cycles
  constant T_BUS_RESET   : natural := 3_000_000 / SIM_SCALE;
  -- Post-reset recovery: >=2.5 us -> 150 cycles (use 300 for margin)
  constant T_RESET_RECOV : natural := 300;
  -- SOF period: 1 ms = 60 000 cycles
  constant T_SOF_PERIOD  : natural := 60_000 / SIM_SCALE;
  -- Time after BUS_RESET before starting enumeration: 10 ms
  constant T_ENUM_WAIT   : natural := 600_000 / SIM_SCALE;
  -- Response timeout: ~18 bit times + packet = ~200 cycles enough for HS
  constant T_RX_TIMEOUT  : natural := 3_000;
  -- NAK retry delay: ~1 ms
  constant T_NAK_RETRY   : natural := 60_000 / SIM_SCALE;
  -- Detect fallback: if no reliable RXCMD line-state is observed, force an
  -- FS reset probe and continue enumeration instead of stalling in detect.
  constant T_DETECT_FALLBACK : natural := 120_000 / SIM_SCALE;
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
    H_REG_WRITE, H_REG_WRITE_NXT, H_REG_WRITE_DATA, H_REG_WRITE_STP, H_REG_DIR_BLOCKED,
    -- Line monitoring
    H_DETECT,
    -- USB bus reset
    H_BUS_RST, H_BUS_RST_WAIT, H_BUS_RST_RECOV,
    -- Enumeration sequencer
    H_ENUM_WAIT,
    H_SETUP_TOKEN, H_SETUP_TX,
    H_SETUP_DATA,  H_SETUP_DATA_TX,
    H_CTRL_IN, H_CTRL_IN_TX,
    H_CTRL_DATA_WAIT, H_CTRL_ACK_TX,
    H_STATUS_OUT, H_STATUS_OUT_TX,
    H_STATUS_OUT_DATA, H_STATUS_OUT_DATA_TX,
    H_STATUS_OUT_WAIT,
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
           H_REG_WRITE_DATA | H_REG_WRITE_STP | H_REG_DIR_BLOCKED =>
        return x"0";
      when H_DETECT =>
        return x"1";
      when H_BUS_RST | H_BUS_RST_WAIT | H_BUS_RST_RECOV =>
        return x"2";
      when H_ENUM_WAIT | H_SETUP_TOKEN | H_SETUP_TX | H_SETUP_DATA |
           H_SETUP_DATA_TX | H_CTRL_IN | H_CTRL_IN_TX |
           H_CTRL_DATA_WAIT | H_CTRL_ACK_TX | H_STATUS_OUT |
           H_STATUS_OUT_TX | H_STATUS_OUT_DATA | H_STATUS_OUT_DATA_TX |
           H_STATUS_OUT_WAIT | H_STATUS_IN | H_STATUS_IN_TX |
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
      when H_REG_WRITE_DATA => return x"86";
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
      when H_CTRL_IN        => return x"35";
      when H_CTRL_IN_TX     => return x"36";
      when H_CTRL_DATA_WAIT => return x"37";
      when H_CTRL_ACK_TX    => return x"38";
      when H_STATUS_OUT     => return x"39";
      when H_STATUS_OUT_TX  => return x"3A";
      when H_STATUS_OUT_DATA => return x"3B";
      when H_STATUS_OUT_DATA_TX => return x"3C";
      when H_STATUS_OUT_WAIT => return x"3D";
      when H_STATUS_IN      => return x"3E";
      when H_STATUS_IN_TX   => return x"3F";
      when H_STATUS_WAIT    => return x"48";
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
  -- Watchdog: detects frozen ulpi_clk in the 27 MHz clk domain.
  -- progress_s(4) = ulpi_beat_u[22] toggles every 70 ms at 60 MHz.
  -- If it doesn't toggle within 200 ms of PHY release, the clock has stopped
  -- and we re-assert hardware reset to recover.
  signal phy_clk_alive_prev : std_logic := '0';
  signal phy_clk_wdt : natural range 0 to 5_400_000 := 0;
  signal phy_rst_rel_meta : std_logic := '0';
  signal phy_rst_rel_sync : std_logic := '0';

  -- ULPI register write helpers
  signal rw_addr_r   : std_logic_vector(5 downto 0) := (others => '0');
  signal rw_data_r   : std_logic_vector(7 downto 0) := (others => '0');
  signal rw_return_r : host_state_t := H_DETECT;
  -- One-shot flag: marks the first cycle in H_REG_WRITE_NXT after the command
  -- byte was placed on the bus.  Replaces the "rw_timeout = T_REG_DIR_WAIT_U"
  -- startup check so the timeout is free to run without being reset on DIR edges.
  signal rw_first    : std_logic := '0';

  -- PHY config register write sequence
  -- Each reg_seq entry: addr[5:0] & data[7:0] = 14 bits
  type reg_seq_t is array (0 to 3) of std_logic_vector(13 downto 0);
  constant REG_SEQ : reg_seq_t := (
    std_logic_vector'(REG_FUNC_CTRL  & FUNC_FS_NORMAL),
    std_logic_vector'(REG_OTG_CTRL   & OTG_HOST),
    std_logic_vector'(REG_USB_INT_EN & x"00"),   -- disable PHY interrupts
    std_logic_vector'(REG_SCRATCH    & x"A5")    -- scratch verify
  );
  signal reg_seq_idx : natural range 0 to 4 := 0;

  -- TX packet buffer
  signal tx_buf      : tx_buf_t := (others => (others => '0'));
  signal tx_len      : natural range 0 to TX_BUF_LEN := 0;
  signal tx_idx      : natural range 0 to TX_BUF_LEN := 0;

  -- SOF / enumeration counters
  signal enum_wait_cnt : natural range 0 to T_ENUM_WAIT := 0;
  -- Count failed early-enumeration attempts.  If the first descriptor never
  -- responds, the detected bus speed is likely wrong, so after a few tries we
  -- flip the speed and re-run the USB bus reset (robust to J/K polarity).
  signal enum_retry  : unsigned(4 downto 0) := (others => '0');

  -- Enumeration step
  type enum_step_t is (
    EN_GET_DEV_DESC, EN_SET_ADDR,
    EN_SET_CFG, EN_SET_IDLE, EN_SET_PROTO, EN_POLL
  );
  signal enum_step   : enum_step_t := EN_SET_ADDR;

  -- 3-bit code for the enumeration step, for the UART diagnostic.
  function enum_step_code(s : enum_step_t) return std_logic_vector is
  begin
    case s is
      when EN_GET_DEV_DESC => return "000";
      when EN_SET_ADDR     => return "001";
      when EN_SET_CFG      => return "010";
      when EN_SET_IDLE     => return "011";
      when EN_SET_PROTO    => return "100";
      when EN_POLL         => return "101";
    end case;
  end function;
  signal dev_addr    : std_logic_vector(6 downto 0) := (others => '0');
  signal ctrl_toggle : std_logic := '0';
  signal hid_toggle  : std_logic := '0';
  signal ep0_maxpkt  : natural range 1 to 64 := 8;

  -- RX state
  constant RX_BUF_BYTES : natural := 66;
  type rx_buf_t is array (0 to RX_BUF_BYTES - 1) of std_logic_vector(7 downto 0);
  signal rx_buf      : rx_buf_t := (others => (others => '0'));
  signal rx_len      : natural range 0 to RX_BUF_BYTES + 1 := 0;
  signal rx_active   : std_logic := '0';
  signal rx_pid      : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_timeout  : natural range 0 to T_RX_TIMEOUT := 0;
  signal ctrl_need   : natural range 0 to 64 := 0;
  signal ctrl_count  : natural range 0 to 64 := 0;
  signal ctrl_last_pkt_len : natural range 0 to 64 := 0;

  -- Key output latch (ulpi_clk domain)
  signal key_mod_u   : std_logic_vector(7 downto 0) := (others => '0');
  signal key_code_u  : std_logic_vector(7 downto 0) := (others => '0');
  signal key_valid_u : std_logic := '0';

  -- Connected flag
  signal connected_u : std_logic := '0';
  signal line_state_u : std_logic_vector(1 downto 0) := LS_SE0;
  signal low_speed_u  : std_logic := '0';
  signal phase_u      : std_logic_vector(3 downto 0);
  signal state_code_u : std_logic_vector(7 downto 0);
  signal bus_debug_u  : std_logic_vector(7 downto 0);
  signal progress_u   : std_logic_vector(7 downto 0) := (others => '0');
  signal ulpi_beat_u  : unsigned(25 downto 0) := (others => '0');
  signal ulpi_data_dbg_u : std_logic_vector(7 downto 0) := (others => '0');
  -- Sticky diagnostic facts captured in the ulpi_clk domain since reset:
  --   bit7 dir_high_seen, bit6 dir_low_seen, bit5 reg_done_seen,
  --   bit4 detect_seen.  Bits[3:0] mirror the same so a single hex byte
  --   (high nibble) tells the whole story even from one UART line.
  signal diag_sticky_u : std_logic_vector(7 downto 0) := (others => '0');

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
  signal diag_sticky_m : std_logic_vector(7 downto 0) := (others => '0');

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
  signal diag_sticky_s : std_logic_vector(7 downto 0) := (others => '0');
  -- Clock-alive flag derived from the 27 MHz watchdog (1 = ulpi_clk beating).
  signal ulpi_clk_alive_s : std_logic := '0';
  -- Enumeration-step + speed snapshot for the UART diagnostic (MOD field).
  signal enum_dbg_u : std_logic_vector(7 downto 0) := (others => '0');
  signal enum_dbg_m : std_logic_vector(7 downto 0) := (others => '0');
  signal enum_dbg_s : std_logic_vector(7 downto 0) := (others => '0');

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

  -- ULPI bus capture buffer (logic-analyzer-in-FPGA).  Written in ulpi_clk
  -- domain; frozen after one capture so the clk-domain read port is stable.
  -- Entry: [15]=dir [14]=nxt [13]=oe [12]=stp [11:8]=phase [7:0]=bus byte.
  type cap_mem_t is array (0 to 127) of std_logic_vector(15 downto 0);
  signal cap_mem   : cap_mem_t := (others => (others => '0'));
  signal cap_idx   : natural range 0 to 128 := 128;  -- 128 = idle/done
  signal cap_armed : std_logic := '1';                -- one-shot trigger
  signal cap_done_u: std_logic := '0';
  signal cap_done_m: std_logic := '0';
  signal cap_done_s: std_logic := '0';

  -- STP wake: when ulpi_clk is detected stopped (USB3317 entered low-power and
  -- halted CLKOUT), the link must assert STP to wake the PHY and restart the
  -- clock.  Driven from the always-running 27 MHz domain because the ULPI FSM
  -- is frozen while the clock is down.  ULPI low-power exit per USB3317 spec.
  signal stp_wake_s     : std_logic := '0';
  -- Free-running divider to shape STP wake into periodic pulses (assert then
  -- release so CLKOUT can come up between pulses).
  signal wake_div       : unsigned(16 downto 0) := (others => '0');

begin

  ulpi_data_o  <= data_o_r;
  ulpi_data_oe <= data_oe_r;
  -- STP is normally driven by the ULPI FSM (stp_r).  When the clock has stopped
  -- the FSM is frozen, so stp_wake_s (27 MHz domain) pulses STP to wake the PHY.
  ulpi_stp     <= stp_r or stp_wake_s;
  -- USB3317 RESET# is active-LOW. phy_rst_release='1' means run, '0' means reset.
  ulpi_rst     <= phy_rst_release;
  phase_u       <= host_phase_code(host_st);
  state_code_u  <= host_state_code(host_st);
  -- MOD diagnostic: bit7 = low-speed device, bit6 = connected,
  -- bits[2:0] = enumeration step (0 GET_DEV_DESC,1 SET_ADDR,2 SET_CFG,
  -- 3 SET_IDLE,4 SET_PROTO,5 POLL).
  enum_dbg_u    <= low_speed_u & connected_u & "000" & enum_step_code(enum_step);
  -- bus_debug_u is now a register updated inside the ulpi_clk process.

  -- =========================================================================
  -- ULPI / USB host state machine  (ulpi_clk domain)
  -- =========================================================================
  process(ulpi_clk)


    variable crc5v  : std_logic_vector(4 downto 0);
    variable tokv   : std_logic_vector(15 downto 0);
    variable crc16v : std_logic_vector(15 downto 0);
    variable crc16r : std_logic_vector(15 downto 0);   -- bit-reversed CRC16
    variable sv     : tx_buf_t;   -- local setup bytes for CRC computation
    variable timeout_v : unsigned(15 downto 0);
    variable payload_len_v : natural;
    variable key_std_v : std_logic_vector(7 downto 0);
    variable key_rid_v : std_logic_vector(7 downto 0);
    variable mod_v     : std_logic_vector(7 downto 0);
    variable cap_byte_v : std_logic_vector(7 downto 0);

  begin
    if rising_edge(ulpi_clk) then
      -- Default: de-assert STP; OE holds its last value
      stp_r      <= '0';
      data_oe_r  <= data_oe_r;
      phy_rst_rel_meta <= phy_rst_release;
      phy_rst_rel_sync <= phy_rst_rel_meta;


      if reset_n = '0' then
        host_st      <= H_PHY_RST;
        timer        <= 0;
        rw_timeout   <= (others => '0');
        rw_first     <= '0';
        data_o_r     <= (others => '0');
        data_oe_r    <= '0';
        stp_r        <= '0';
        enum_wait_cnt <= 0;
        connected_u  <= '0';
        line_state_u <= LS_SE0;
        low_speed_u  <= '0';
        progress_u   <= (others => '0');
        ulpi_beat_u  <= (others => '0');
        ulpi_data_dbg_u <= (others => '0');
        bus_debug_u  <= (others => '0');
        diag_sticky_u <= (others => '0');
        key_valid_u  <= '0';
        reg_seq_idx  <= 0;
        enum_step    <= EN_GET_DEV_DESC;
        enum_retry   <= (others => '0');
        dev_addr     <= (others => '0');
        ctrl_toggle  <= '0';
        hid_toggle   <= '0';
        ep0_maxpkt   <= 8;
        rx_active    <= '0';
        ctrl_need    <= 0;
        ctrl_count   <= 0;
        ctrl_last_pkt_len <= 0;
        cap_idx      <= 128;
        cap_armed    <= '1';
        cap_done_u   <= '0';

      else
        ulpi_beat_u <= ulpi_beat_u + 1;
        timeout_v := rw_timeout;
        -- ASC[7:4] = ulpi_beat[19:16]: a FAST ulpi-clk heartbeat (the nibble
        -- cycles every ~16 ms while ulpi_clk runs). If this digit is frozen
        -- across consecutive UART lines, ulpi_clk has stopped.
        -- ASC[3:0] = rw_timeout[15:12] (FSM countdown).
        progress_u <= std_logic_vector(ulpi_beat_u(19 downto 16)) &
                      std_logic_vector(timeout_v(15 downto 12));
        ulpi_data_dbg_u <= ulpi_data_i;
        -- Track DIR activity (sticky) so a single UART line proves whether the
        -- PHY ever releases the bus.  diag_sticky_u(7)=DIR high seen,
        -- (6)=DIR low seen.
        if ulpi_dir = '1' then
          diag_sticky_u(7) <= '1';
        else
          diag_sticky_u(6) <= '1';
        end if;
        if ulpi_dir = '1' and ulpi_nxt = '0' then
          -- ULPI RXCMD line state is commonly in bits[1:0]; some designs
          -- historically used bits[5:4]. Prefer [1:0] when it carries J/K.
          if ulpi_data_i(1 downto 0) = LS_J or ulpi_data_i(1 downto 0) = LS_K then
            line_state_u <= ulpi_data_i(1 downto 0);
          else
            line_state_u <= ulpi_data_i(5 downto 4);
          end if;
          bus_debug_u  <= ulpi_data_i;   -- latch last RXCMD for diagnostic
        end if;

        -- ---------------------------------------------------------------
        -- In-system ULPI bus capture.  Arm once; start recording when the
        -- host enters H_DETECT (where it samples the PHY RXCMD line state to
        -- decide FS vs LS).  Records 128 consecutive ulpi_clk cycles spanning
        -- detect + the start of bus reset, so we can see the actual RXCMD bytes
        -- the PHY reports (the speed decision was observed flip-flopping).
        -- ---------------------------------------------------------------
        if cap_idx < 128 then
          if ulpi_dir = '1' then
            cap_byte_v := ulpi_data_i;
          elsif data_oe_r = '1' then
            cap_byte_v := data_o_r;
          else
            cap_byte_v := x"00";
          end if;
          cap_mem(cap_idx) <=
            ulpi_dir & ulpi_nxt & data_oe_r & stp_r &
            host_phase_code(host_st) & cap_byte_v;
          if cap_idx = 127 then
            cap_done_u <= '1';
          end if;
          cap_idx <= cap_idx + 1;
        elsif cap_armed = '1' and host_st = H_DETECT then
          cap_idx   <= 0;
          cap_armed <= '0';
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
              rw_first  <= '1';   -- startup flag for H_REG_WRITE_NXT
              host_st   <= H_REG_WRITE_NXT;
            else
              data_oe_r <= '0';
              host_st <= H_REG_DIR_BLOCKED;
            end if;

          when H_REG_DIR_BLOCKED =>
            -- Do NOT reset rw_timeout here: the global timeout must count down
            -- across retries so we eventually reach H_ERROR if NXT never comes.
            data_oe_r <= '0';
            if ulpi_dir = '0' then
              host_st <= H_REG_WRITE;
            elsif rw_timeout = x"0000" then
              timer <= T_NAK_RETRY;
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
              rw_first  <= '0';
              if rw_timeout = x"0000" then
                timer <= T_NAK_RETRY;
                host_st <= H_ERROR;
              else
                rw_timeout <= rw_timeout - 1;
                host_st <= H_REG_WRITE;
              end if;
            elsif rw_first = '1' then
              -- First cycle after command placed on bus: give one ULPI clock for
              -- the data to propagate to pins before we start sampling NXT.
              data_oe_r <= '1';
              rw_first  <= '0';
              rw_timeout <= rw_timeout - 1;
            elsif ulpi_nxt = '1' then
              -- PHY accepted the TX CMD byte. Drive the write-data byte for
              -- exactly one ULPI cycle (NO STP yet), per the ULPI register-
              -- write protocol, then terminate with STP+0x00.
              data_o_r  <= rw_data_r;
              data_oe_r <= '1';
              host_st   <= H_REG_WRITE_DATA;
            elsif rw_timeout = x"0000" then
              data_oe_r <= '0';
              timer <= T_NAK_RETRY;
              host_st <= H_ERROR;
            else
              data_oe_r <= '1';
              rw_timeout <= rw_timeout - 1;
            end if;

          when H_REG_WRITE_DATA =>
            -- The write-data byte is on the bus this cycle. On the next cycle
            -- drive 0x00 and assert STP to terminate the write. ULPI requires
            -- STP to coincide with a NOP/00 byte, never with the data byte.
            data_o_r  <= (others => '0');
            data_oe_r <= '1';
            stp_r     <= '1';
            host_st   <= H_REG_WRITE_STP;

          when H_REG_WRITE_STP =>
            -- STP + 0x00 are on the bus this cycle; the register write
            -- completes. Keep driving the bus (NOP/00) and sequence onward.
            data_oe_r <= '1';
            diag_sticky_u(5) <= '1';   -- a register write completed at least once
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
              if rw_return_r = H_DETECT then
                timer <= T_DETECT_FALLBACK;
              end if;
              host_st     <= rw_return_r;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 3: Monitor RXCMD for device connect
          --   When PHY sees FS device (SE0->J) it reports LS=J in RXCMD
          -- -------------------------------------------------------------------
          when H_DETECT =>
            data_oe_r   <= '0';
            connected_u <= '0';
            diag_sticky_u(4) <= '1';   -- init register sequence completed
            -- ULPI RXCMD LineState[0]=D+, LineState[1]=D-.
            --   FS device idle (J) = D+ high  = LineState "01" -> full speed
            --   LS device idle (J) = D- high  = LineState "10" -> low speed
            -- (Simulation confirmed the old LS_J/LS_K constants inverted this,
            --  misclassifying a full-speed keyboard as low-speed.)
            -- Accept DIR=1 regardless of NXT to catch short RXCMD windows.
            if ulpi_dir = '1' then
              if ulpi_data_i(1 downto 0) = "01" or ulpi_data_i(5 downto 4) = "01" then
                low_speed_u <= '0';          -- D+ high -> full speed
                timer   <= T_BUS_RESET;
                host_st <= H_BUS_RST;
              elsif ulpi_data_i(1 downto 0) = "10" or ulpi_data_i(5 downto 4) = "10" then
                low_speed_u <= '1';          -- D- high -> low speed
                timer   <= T_BUS_RESET;
                host_st <= H_BUS_RST;
              end if;
            elsif line_state_u = "01" then
              low_speed_u <= '0';
              timer   <= T_BUS_RESET;
              host_st <= H_BUS_RST;
            elsif line_state_u = "10" then
              low_speed_u <= '1';
              timer   <= T_BUS_RESET;
              host_st <= H_BUS_RST;
            elsif timer = 0 then
              -- Fallback path: no explicit J/K observed, try FS reset probe.
              low_speed_u <= '0';
              timer   <= T_BUS_RESET;
              host_st <= H_BUS_RST;
            else
              timer <= timer - 1;
            end if;

          -- -------------------------------------------------------------------
          -- Phase 4: USB bus reset (drive SE0 for 50 ms)
          -- -------------------------------------------------------------------
          when H_BUS_RST =>
            rw_addr_r   <= REG_FUNC_CTRL;
            if low_speed_u = '1' then
              rw_data_r <= FUNC_LS_SE0;
            else
              rw_data_r <= FUNC_FS_SE0;
            end if;
            rw_return_r <= H_BUS_RST_WAIT;
            reg_seq_idx <= 0;         -- single register write, no sequence
            timer       <= T_BUS_RESET;
            rw_timeout  <= T_REG_DIR_WAIT_U;
            host_st     <= H_REG_WRITE;

          when H_BUS_RST_WAIT =>
            if timer = 0 then
              rw_addr_r   <= REG_FUNC_CTRL;
              if low_speed_u = '1' then
                rw_data_r <= FUNC_LS_NORMAL;
              else
                rw_data_r <= FUNC_FS_NORMAL;
              end if;
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
              enum_step     <= EN_GET_DEV_DESC;
              enum_retry    <= (others => '0');
              dev_addr      <= (others => '0');
              ctrl_toggle   <= '0';
              hid_toggle    <= '0';
              ctrl_need     <= 0;
              ctrl_count    <= 0;
              ctrl_last_pkt_len <= 0;
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
              tx_idx    <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r  <= "0100" & PID_SETUP(3 downto 0);  -- ULPI TXCMD + PID
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
                when EN_GET_DEV_DESC =>
                  -- GetDescriptor(Device, 8): bmRT=0x80 bReq=0x06 wVal=0x0100 wIdx=0 wLen=8
                  sv(1) := x"80"; sv(2) := x"06";
                  sv(3) := x"00"; sv(4) := x"01";
                  sv(5) := x"00"; sv(6) := x"00";
                  sv(7) := x"08"; sv(8) := x"00";
                  ctrl_need <= 8;
                  ctrl_count <= 0;
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
                when EN_SET_IDLE =>
                  -- SetIdle(0): bmRT=0x21 bReq=0x0A wVal=0x0000 wIdx=0 wLen=0
                  sv(1) := x"21"; sv(2) := x"0A";
                  sv(3) := x"00"; sv(4) := x"00";
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
              -- USB transmits the CRC16 residual MSB-first (crc(15) first on the
              -- wire); the byte serialiser is LSB-first, so bit-reverse before
              -- splitting into the two CRC bytes.  Same convention as CRC5.
              for bi in 0 to 15 loop
                crc16r(bi) := crc16v(15 - bi);
              end loop;
              sv(9)  := crc16r(7 downto 0);
              sv(10) := crc16r(15 downto 8);
              -- Now copy all to tx_buf signals
              for bi in 0 to 10 loop
                tx_buf(bi) <= sv(bi);
              end loop;
              tx_len     <= 11;
              tx_idx     <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r   <= "0100" & PID_DATA0(3 downto 0);  -- ULPI TXCMD + PID
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
                if enum_step = EN_GET_DEV_DESC then
                  host_st <= H_CTRL_IN;
                else
                  host_st <= H_STATUS_IN;
                end if;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              if enum_step = EN_GET_DEV_DESC then
                host_st <= H_CTRL_IN;
              else
                host_st <= H_STATUS_IN;
              end if;
            end if;

          -- CONTROL IN data phase for descriptor reads on endpoint 0.
          when H_CTRL_IN =>
            if timer > 0 then
              timer <= timer - 1;
            elsif ulpi_dir = '0' then
              tokv := token_bytes(dev_addr, "0000");
              tx_buf(0) <= PID_IN;
              tx_buf(1) <= tokv(7 downto 0);
              tx_buf(2) <= tokv(15 downto 8);
              tx_len    <= 3;
              tx_idx    <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r  <= "0100" & PID_IN(3 downto 0);  -- ULPI TXCMD + PID
              data_oe_r <= '1';
              host_st   <= H_CTRL_IN_TX;
            end if;

          when H_CTRL_IN_TX =>
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
                host_st    <= H_CTRL_DATA_WAIT;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r  <= '0';
              rx_len     <= 0;
              rx_active  <= '0';
              rx_timeout <= T_RX_TIMEOUT;
              host_st    <= H_CTRL_DATA_WAIT;
            end if;

          when H_CTRL_DATA_WAIT =>
            data_oe_r <= '0';
            if rx_timeout = 0 then
              host_st <= H_NAK_WAIT;
              timer   <= T_NAK_RETRY;
            elsif ulpi_dir = '1' then
              if ulpi_nxt = '1' then
                if rx_len = 0 then
                  rx_pid <= ulpi_data_i;
                  rx_len <= 1;
                elsif rx_len <= RX_BUF_BYTES then
                  rx_buf(rx_len - 1) <= ulpi_data_i;
                  rx_len <= rx_len + 1;
                end if;
              end if;
              rx_timeout <= rx_timeout - 1;
            elsif rx_len > 0 then
              if rx_pid = PID_DATA1 or rx_pid = PID_DATA0 then
                payload_len_v := 0;
                if rx_len >= 3 then
                  payload_len_v := rx_len - 3;
                end if;
                for bi in 0 to RX_BUF_BYTES - 1 loop
                  if bi < payload_len_v then
                    -- Descriptor buffer no longer needed, just track length
                    null;
                  end if;
                end loop;
                ctrl_count <= ctrl_count + payload_len_v;
                ctrl_last_pkt_len <= payload_len_v;
                tx_buf(0) <= PID_ACK;
                tx_len    <= 1;
                tx_idx    <= 1;   -- handshake: only the TXCMD+PID, no data
                data_o_r  <= "0100" & PID_ACK(3 downto 0);  -- ULPI TXCMD + PID
                data_oe_r <= '1';
                host_st   <= H_CTRL_ACK_TX;
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

          when H_CTRL_ACK_TX =>
            data_oe_r <= '1';
            if ulpi_nxt = '1' and ulpi_dir = '0' then
              if tx_idx < tx_len then
                data_o_r <= tx_buf(tx_idx);
                tx_idx   <= tx_idx + 1;
              else
                data_o_r  <= (others => '0');
                data_oe_r <= '1';
                stp_r     <= '1';
                if ctrl_last_pkt_len = ep0_maxpkt and ctrl_count < ctrl_need then
                  timer   <= T_SETUP_GAP;
                  host_st <= H_CTRL_IN;
                else
                  timer   <= T_SETUP_GAP;
                  host_st <= H_STATUS_OUT;
                end if;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              timer     <= T_SETUP_GAP;
              host_st   <= H_STATUS_OUT;
            end if;

          -- STATUS OUT phase for control reads: OUT token + zero-length DATA1.
          when H_STATUS_OUT =>
            if timer > 0 then
              timer <= timer - 1;
            elsif ulpi_dir = '0' then
              tokv := token_bytes(dev_addr, "0000");
              tx_buf(0) <= PID_OUT;
              tx_buf(1) <= tokv(7 downto 0);
              tx_buf(2) <= tokv(15 downto 8);
              tx_len    <= 3;
              tx_idx    <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r  <= "0100" & PID_OUT(3 downto 0);  -- ULPI TXCMD + PID
              data_oe_r <= '1';
              host_st   <= H_STATUS_OUT_TX;
            end if;

          when H_STATUS_OUT_TX =>
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
                host_st   <= H_STATUS_OUT_DATA;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              timer     <= T_SETUP_GAP;
              host_st   <= H_STATUS_OUT_DATA;
            end if;

          when H_STATUS_OUT_DATA =>
            if timer > 0 then
              timer <= timer - 1;
            elsif ulpi_dir = '0' then
              tx_buf(0) <= PID_DATA1;
              tx_buf(1) <= x"00";
              tx_buf(2) <= x"00";
              tx_len    <= 3;
              tx_idx    <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r  <= "0100" & PID_DATA1(3 downto 0);  -- ULPI TXCMD + PID
              data_oe_r <= '1';
              host_st   <= H_STATUS_OUT_DATA_TX;
            end if;

          when H_STATUS_OUT_DATA_TX =>
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
                rx_timeout <= T_RX_TIMEOUT;
                host_st   <= H_STATUS_OUT_WAIT;
              end if;
            elsif ulpi_dir = '1' then
              data_oe_r <= '0';
              rx_len    <= 0;
              rx_timeout <= T_RX_TIMEOUT;
              host_st   <= H_STATUS_OUT_WAIT;
            end if;

          when H_STATUS_OUT_WAIT =>
            data_oe_r <= '0';
            if rx_timeout = 0 then
              host_st <= H_NAK_WAIT;
              timer   <= T_NAK_RETRY;
            elsif ulpi_dir = '1' then
              if ulpi_nxt = '1' then
                rx_pid <= ulpi_data_i;
                rx_len <= 1;
              end if;
              rx_timeout <= rx_timeout - 1;
            elsif rx_len > 0 then
              if rx_pid = PID_ACK then
                case enum_step is
                  when EN_GET_DEV_DESC =>
                    -- Descriptor validation skipped for LUT savings; assume device is valid
                    if ctrl_count >= 8 then
                      -- Would check bcdUSB/bDeviceClass/bMaxPacketSize0 here if needed
                      enum_step  <= EN_SET_ADDR;
                      host_st    <= H_SETUP_TOKEN;
                    else
                      timer   <= T_NAK_RETRY;
                      host_st <= H_ERROR;
                    end if;
                  when others =>
                    timer   <= T_NAK_RETRY;
                    host_st <= H_ERROR;
                end case;
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
              tx_idx    <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r  <= "0100" & PID_IN(3 downto 0);  -- ULPI TXCMD + PID
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
              -- DIR=1, NXT=1 -> USB packet data byte.  Latch the PID from the
              -- FIRST byte only; later bytes (CRC) must not overwrite it, or a
              -- zero-length DATA1 status (PID + 00 00 CRC) is misread as 0x00.
              if ulpi_nxt = '1' then
                if rx_len = 0 then
                  rx_pid <= ulpi_data_i;
                end if;
                if rx_len <= RX_BUF_BYTES then
                  rx_len <= rx_len + 1;
                end if;
              end if;
              rx_timeout <= rx_timeout - 1;
            elsif rx_len > 0 then
              -- DIR de-asserted: packet received
              if rx_pid = PID_DATA1 or rx_pid = PID_DATA0 then
                -- Status phase complete - send ACK then advance
                tx_buf(0) <= PID_ACK;
                tx_len    <= 1;
                tx_idx    <= 1;   -- handshake: only the TXCMD+PID, no data
                data_o_r  <= "0100" & PID_ACK(3 downto 0);  -- ULPI TXCMD + PID
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
                  when EN_GET_DEV_DESC =>
                    host_st <= H_SETUP_TOKEN;
                  when EN_SET_ADDR =>
                    dev_addr  <= "0000001";
                    enum_step <= EN_SET_CFG;
                    host_st   <= H_SETUP_TOKEN;
                  when EN_SET_CFG =>
                    enum_step <= EN_SET_IDLE;
                    host_st   <= H_SETUP_TOKEN;
                  when EN_SET_IDLE =>
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
              tx_idx    <= 1;   -- skip tx_buf(0): PID is carried in the TXCMD
              data_o_r  <= "0100" & PID_IN(3 downto 0);  -- ULPI TXCMD + PID
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
                -- Byte 1 = modifier, Byte 2 = reserved, Bytes 3-8 = keycodes.
                -- Some devices prepend a report ID, shifting fields by +1.
                if rx_len >= 4 then
                  key_std_v := x"00";
                  key_rid_v := x"00";

                  -- Standard boot report layout (no report ID): key slots 2..7
                  if rx_buf(2) /= x"00" then
                    key_std_v := rx_buf(2);
                  elsif rx_buf(3) /= x"00" then
                    key_std_v := rx_buf(3);
                  elsif rx_buf(4) /= x"00" then
                    key_std_v := rx_buf(4);
                  elsif rx_buf(5) /= x"00" then
                    key_std_v := rx_buf(5);
                  elsif rx_buf(6) /= x"00" then
                    key_std_v := rx_buf(6);
                  elsif rx_buf(7) /= x"00" then
                    key_std_v := rx_buf(7);
                  end if;

                  -- Report-ID-prefixed layout: key slots shift to 3..8.
                  if rx_buf(3) /= x"00" then
                    key_rid_v := rx_buf(3);
                  elsif rx_buf(4) /= x"00" then
                    key_rid_v := rx_buf(4);
                  elsif rx_buf(5) /= x"00" then
                    key_rid_v := rx_buf(5);
                  elsif rx_buf(6) /= x"00" then
                    key_rid_v := rx_buf(6);
                  elsif rx_buf(7) /= x"00" then
                    key_rid_v := rx_buf(7);
                  elsif rx_buf(8) /= x"00" then
                    key_rid_v := rx_buf(8);
                  end if;

                  if key_std_v /= x"00" then
                    key_code_u <= key_std_v;
                    mod_v      := rx_buf(0);
                  else
                    key_code_u <= key_rid_v;
                    mod_v      := rx_buf(1);
                  end if;

                  key_mod_u <= mod_v;
                  if key_std_v /= x"00" or key_rid_v /= x"00" then
                    key_valid_u <= not key_valid_u;
                  end if;
                end if;
                -- Send ACK
                tx_buf(0) <= PID_ACK;
                tx_len    <= 1;
                tx_idx    <= 1;   -- handshake: only the TXCMD+PID, no data
                data_o_r  <= "0100" & PID_ACK(3 downto 0);  -- ULPI TXCMD + PID
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
              -- If we are still on the very first descriptor read and it keeps
              -- failing, the detected bus speed is probably wrong.  Flip the
              -- speed and re-run bus reset to reconfigure the PHY transceiver.
              if enum_step = EN_GET_DEV_DESC and enum_retry = "01111" then
                low_speed_u <= not low_speed_u;
                enum_retry  <= (others => '0');
                timer       <= T_BUS_RESET;
                host_st     <= H_BUS_RST;
              elsif enum_step = EN_POLL then
                host_st <= H_IN_TOKEN;
              else
                if enum_step = EN_GET_DEV_DESC then
                  enum_retry <= enum_retry + 1;
                end if;
                host_st <= H_SETUP_TOKEN;
              end if;
            else
              timer <= timer - 1;
            end if;

          when H_ERROR =>
            -- Wait T_NAK_RETRY then restart from H_PHY_RST so the full init
            -- sequence retries.  This makes PH briefly show F then 0 on each
            -- attempt, letting the UART diagnostic reveal whether we ever advance.
            data_oe_r <= '0';
            if timer = 0 then
              rw_timeout  <= T_REG_DIR_WAIT_U;
              rw_first    <= '0';
              reg_seq_idx <= 0;
              timer       <= T_PHY_RESET;
              host_st     <= H_PHY_RST;
            else
              timer <= timer - 1;
            end if;

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
        phy_rst_release    <= '0';
        phy_rst_cnt        <= 0;
        phy_clk_alive_prev <= '0';
        phy_clk_wdt        <= 0;
      else
        -- Keep PHY out of reset once system reset is released.
        phy_rst_release    <= '1';
        phy_clk_alive_prev <= progress_s(4);
        if progress_s(4) /= phy_clk_alive_prev then
          -- Clock beat detected: ulpi_beat_u[22] toggled. Clock is alive.
          phy_clk_wdt <= 0;
        elsif phy_clk_wdt = 5_400_000 then
          -- 200 ms elapsed with no observed beat. Keep PHY released instead of
          -- forcing a reset loop that can pin diagnostics at PH=0.
          -- Saturate watchdog counter; recovery is handled by host FSM retries.
          phy_clk_wdt <= phy_clk_wdt;
        else
          phy_clk_wdt <= phy_clk_wdt + 1;
        end if;
        -- Clock-stop recovery: if no ULPI beat for >50 ms the USB3317 has halted
        -- CLKOUT (low-power mode).  Pulse STP to wake it; the ULPI spec requires
        -- the link to drive STP to bring the PHY out of low-power and restart the
        -- clock.  A periodic pulse (~2.4 ms period) gives CLKOUT room to come up
        -- between assertions.  Cleared once beats resume.
        wake_div <= wake_div + 1;
        if phy_clk_wdt >= 1_350_000 then
          stp_wake_s <= wake_div(16);
        else
          stp_wake_s <= '0';
        end if;
        -- Clock-alive: '1' while the watchdog has not saturated (i.e. beats seen).
        if phy_clk_wdt = 5_400_000 then
          ulpi_clk_alive_s <= '0';
        else
          ulpi_clk_alive_s <= '1';
        end if;
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
      diag_sticky_m <= diag_sticky_u;
      enum_dbg_m <= enum_dbg_u;
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
      diag_sticky_s <= diag_sticky_m;
      enum_dbg_s <= enum_dbg_m;
      cap_done_m <= cap_done_u;
      cap_done_s <= cap_done_m;
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

  -- Diagnostic outputs: always expose the latest HID report fields so debug
  -- views do not appear as synthetic counters when the FIFO is empty.
  diag_connected <= connected_s;
  -- When disconnected, surface the exact ULPI host sub-state on the KEY field so
  -- the UART diagnostic pinpoints where bring-up stalls (82=H_REG_WRITE,
  -- 83=H_REG_WRITE_NXT, 86=H_REG_WRITE_DATA, 84=H_REG_WRITE_STP,
  -- 85=H_REG_DIR_BLOCKED, 10=H_DETECT, E0=H_ERROR). Show keycode when connected.
  diag_keycode   <= key_code_s when connected_s = '1' else state_code_s;
  -- When disconnected, MOD shows the enumeration step + speed so a single line
  -- reveals where enumeration stalls:
  --   MOD[7]=low-speed device, MOD[2:0]=enum step
  --   (0 GET_DEV_DESC,1 SET_ADDR,2 SET_CFG,3 SET_IDLE,4 SET_PROTO,5 POLL)
  diag_modif     <= key_mod_s when connected_s = '1' else enum_dbg_s;
  -- When a key is in the FIFO, show ASCII. When idle and PHY init is complete
  -- (we are past bring-up, at PH=3 enumeration), ASC shows the LAST received PID
  -- so a single line reveals why a transfer fails:
  --   00 = no response (token timed out / device never answered)
  --   5A = NAK (device alive but not ready)
  --   1E = STALL (request unsupported)
  --   C3/4B = DATA0/DATA1 (descriptor data actually arrived!)
  --   D2 = ACK
  diag_ascii     <= keycode_to_ascii(key_code_s, key_mod_s) when connected_s = '1'
                    else rx_pid_s;

  -- Key event toggle signal and polling status
  diag_key_event <= key_valid_s;
  diag_polling   <= '1' when enum_step = EN_POLL else '0';

  -- ULPI capture read port (clk domain).  cap_mem is frozen after one capture,
  -- so an asynchronous read from the clk domain is stable.  cap_done is 2-FF
  -- synchronised below into cap_done_s.
  diag_cap_data  <= cap_mem(to_integer(unsigned(diag_cap_addr)));
  diag_cap_ready <= cap_done_s;

end architecture;
