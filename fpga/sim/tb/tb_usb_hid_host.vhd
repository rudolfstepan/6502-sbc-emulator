-- Testbench for usb_hid_host: models a USB3317 ULPI PHY + a full-speed device
-- enough to observe the host's bring-up and enumeration on a waveform.
--
-- The goal of this TB is OBSERVABILITY, not full USB compliance: it lets us see
-- exactly what the host drives on the ULPI bus (TXCMD, PID, token bytes, CRC,
-- DATA payload, STP) and how it reacts to the PHY's RXCMD / DIR handshakes.
--
-- PHY model behaviour:
--   * Generates ulpi_clk continuously (the real USB3317 free-runs CLKOUT).
--   * Honours ULPI register writes (TXCMD bit7..6 = "10" = register write):
--     captures address + data so the TB can print/inspect FunctionControl etc.
--   * Periodically issues an RXCMD (DIR high, NXT low) reporting a FS idle
--     line state (J) once the host has started, so H_DETECT can advance.
--   * For a USB transmit (TXCMD bit7..6 = "01"): accepts the packet (asserts
--     NXT to clock each byte out), then after the host finishes (STP) optionally
--     turns the bus around (DIR high) to deliver a device response.
--
-- This is intentionally a behavioural skeleton: assertions print the decoded
-- host activity so a failing framing bit is visible in the transcript + GHW.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;

entity tb_usb_hid_host is
end entity;

architecture sim of tb_usb_hid_host is
  -- System / register-interface clock (27 MHz -> ~37 ns)
  signal clk      : std_logic := '0';
  -- ULPI clock (60 MHz -> ~16.667 ns), free-running like the real PHY
  signal ulpi_clk : std_logic := '0';
  signal reset_n  : std_logic := '0';

  -- ULPI bus
  signal ulpi_dir     : std_logic := '0';
  signal ulpi_nxt     : std_logic := '0';
  signal ulpi_data_i  : std_logic_vector(7 downto 0) := (others => '0');
  signal ulpi_data_o  : std_logic_vector(7 downto 0);
  signal ulpi_data_oe : std_logic;
  signal ulpi_stp     : std_logic;
  signal ulpi_rst     : std_logic;

  -- Register interface (unused here, tied off)
  signal cs   : std_logic := '0';
  signal we   : std_logic := '0';
  signal addr : std_logic_vector(1 downto 0) := "00";
  signal dout : std_logic_vector(7 downto 0);
  signal irq  : std_logic;

  -- Diagnostics
  signal diag_connected : std_logic;
  signal diag_keycode   : std_logic_vector(7 downto 0);
  signal diag_modif     : std_logic_vector(7 downto 0);
  signal diag_ascii     : std_logic_vector(7 downto 0);
  signal diag_phase     : std_logic_vector(3 downto 0);
  signal diag_key_event : std_logic;
  signal diag_polling   : std_logic;

  -- PHY-model state
  signal reg_func_ctrl : std_logic_vector(7 downto 0) := (others => 'U');
  signal reg_otg_ctrl  : std_logic_vector(7 downto 0) := (others => 'U');
  signal sim_done      : boolean := false;

  -- Convenience: the byte the host is currently driving (when it owns the bus)
  signal host_byte : std_logic_vector(7 downto 0);
begin
  host_byte <= ulpi_data_o when ulpi_data_oe = '1' else (others => 'Z');

  -- Free-running clocks
  ulpi_clk <= not ulpi_clk after 8.333 ns;   -- ~60 MHz
  clk      <= not clk      after 18.5 ns;    -- ~27 MHz

  dut : entity work.usb_hid_host
    generic map (
      SIM_SCALE => 1000   -- scale ms-timers down to feasible sim time
    )
    port map (
      clk          => clk,
      reset_n      => reset_n,
      ulpi_clk     => ulpi_clk,
      ulpi_dir     => ulpi_dir,
      ulpi_nxt     => ulpi_nxt,
      ulpi_data_i  => ulpi_data_i,
      ulpi_data_o  => ulpi_data_o,
      ulpi_data_oe => ulpi_data_oe,
      ulpi_stp     => ulpi_stp,
      ulpi_rst     => ulpi_rst,
      cs           => cs,
      we           => we,
      addr         => addr,
      dout         => dout,
      irq          => irq,
      diag_connected => diag_connected,
      diag_keycode   => diag_keycode,
      diag_modif     => diag_modif,
      diag_ascii     => diag_ascii,
      diag_phase     => diag_phase,
      diag_key_event => diag_key_event,
      diag_polling   => diag_polling
    );

  -- Release reset after a few us
  stim : process
  begin
    reset_n <= '0';
    wait for 2 us;
    reset_n <= '1';
    -- Run long enough to pass PHY init (T_PHY_RESET is scaled for 60 MHz; in
    -- sim we just need to observe the register writes and first transactions).
    wait for 400 us;
    report "tb_usb_hid_host: simulation time budget elapsed" severity note;
    sim_done <= true;
    finish;
  end process;

  -- =========================================================================
  -- PHY model: ULPI register-write capture + RXCMD line-state generation.
  --
  -- Runs on ulpi_clk.  When the host owns the bus (ulpi_data_oe=1) and is NOT
  -- in a turnaround we are driving (ulpi_dir=0), inspect the TXCMD on the first
  -- byte:
  --   bits[7:6]="10" -> register write: next host byte (after we pulse NXT) is
  --                     the data; capture into reg_* by address bits[5:0].
  --   bits[7:6]="01" -> USB transmit: pulse NXT to accept each byte until STP.
  -- For register writes the PHY must assert NXT to accept the address byte and
  -- the data byte.  We model that minimal handshake here.
  -- =========================================================================
  phy_model : process(ulpi_clk)
    type phy_state_t is (P_IDLE, P_REGW_DATA, P_TX_ACCEPT, P_RESPOND);
    type resp_arr_t is array (0 to 10) of std_logic_vector(7 downto 0);
    -- DATA1 PID (4B) + 8-byte GET_DESCRIPTOR(Device) payload + 2 dummy CRC bytes.
    constant DEV_DESC : resp_arr_t := (
      x"4B", x"12", x"01", x"00", x"02", x"00", x"00", x"00", x"08",
      x"00", x"00");
    variable st       : phy_state_t := P_IDLE;
    variable cmd      : std_logic_vector(7 downto 0);
    variable regaddr  : std_logic_vector(5 downto 0);
    variable rxcmd_div: integer := 0;
    variable started  : boolean := false;
    variable txn      : integer := 0;          -- transmit-packet counter
    variable bcnt     : integer := 0;          -- byte index within a transmit
    variable regw_prev: std_logic_vector(7 downto 0) := (others => '0');
    variable pid_nib  : std_logic_vector(3 downto 0) := (others => '0');
    variable resp_idx : integer := 0;
    variable resp_kind: integer := 0;   -- 0 = descriptor, 1 = ACK, 2 = zero-len DATA1
    variable last_breq: std_logic_vector(7 downto 0) := (others => '0');
    variable l        : line;
  begin
    if rising_edge(ulpi_clk) then
      if reset_n = '0' then
        st        := P_IDLE;
        ulpi_nxt  <= '0';
        ulpi_dir  <= '0';
        rxcmd_div := 0;
        started   := false;
      else
        ulpi_nxt <= '0';

        case st is
          when P_IDLE =>
            -- Periodically present a FS idle (J) RXCMD so H_DETECT can advance.
            -- RXCMD: DIR=1, NXT=0, data = line state. FS idle J = LineState 01.
            rxcmd_div := rxcmd_div + 1;
            if ulpi_data_oe = '1' then
              cmd := ulpi_data_o;
              ulpi_dir <= '0';
              if cmd(7 downto 6) = "10" then
                -- register write: this byte is "10"&addr[5:0]
                regaddr := cmd(5 downto 0);
                ulpi_nxt <= '1';          -- accept the command/addr byte
                st := P_REGW_DATA;
              elsif cmd(7 downto 6) = "01" then
                -- USB transmit. Log the PID nibble carried in the TXCMD.
                txn  := txn + 1;
                bcnt := 0;
                pid_nib := cmd(3 downto 0);   -- remember PID for response decision
                write(l, string'("TX#"));
                write(l, txn);
                write(l, string'(" TXCMD="));
                write(l, to_hstring(cmd));
                write(l, string'(" (PID nibble="));
                write(l, to_hstring(cmd(3 downto 0)));
                write(l, string'(") bytes:"));
                ulpi_nxt <= '1';          -- accept first transmit byte
                st := P_TX_ACCEPT;
              end if;
            elsif rxcmd_div >= 600 then
              rxcmd_div := 0;
              -- drive a one-cycle RXCMD with FS-J line state on bits[1:0]
              ulpi_dir    <= '1';
              ulpi_data_i <= "000000" & "01";   -- LineState=01 (FS idle J)
              started     := true;
            else
              ulpi_dir <= '0';
            end if;

          when P_REGW_DATA =>
            -- ULPI register write: after the cmd/addr byte the host drives the
            -- data byte for one cycle, then 0x00+STP.  The data byte is the last
            -- non-STP byte the host drives, so latch on the STP cycle using the
            -- value held the previous cycle.
            ulpi_nxt <= '1';
            if ulpi_stp = '1' then
              case regaddr is
                when "000100" => reg_func_ctrl <= regw_prev;  -- 0x04 FunctionCtrl
                when "001010" => reg_otg_ctrl  <= regw_prev;  -- 0x0A OTGControl
                when others   => null;
              end case;
              st := P_IDLE;
            elsif ulpi_data_oe = '1' then
              regw_prev := ulpi_data_o;   -- remember last driven byte (= data)
            end if;

          when P_TX_ACCEPT =>
            -- Accept and log every byte the host streams until STP.
            ulpi_nxt <= '1';
            if ulpi_stp = '1' then
              ulpi_nxt <= '0';
              writeline(output, l);
              -- Device responses:
              --   after an IN token (PID nibble 9): return DATA1 descriptor
              --   after a host DATA packet (nibble 3=DATA0, B=DATA1): return ACK
              if pid_nib = x"9" then
                -- IN token: descriptor data only for GET_DESCRIPTOR (bReq=06),
                -- otherwise a zero-length DATA1 status response.
                resp_idx := 0;
                if last_breq = x"06" then
                  resp_kind := 0;   -- descriptor
                else
                  resp_kind := 2;   -- zero-length DATA1 status
                end if;
                ulpi_dir  <= '1';
                st := P_RESPOND;
              elsif pid_nib = x"3" or pid_nib = x"B" then
                resp_idx  := 0;
                resp_kind := 1;
                ulpi_dir  <= '1';
                st := P_RESPOND;
              else
                st := P_IDLE;
              end if;
            elsif ulpi_data_oe = '1' then
              write(l, string'(" "));
              write(l, to_hstring(ulpi_data_o));
              -- Capture bRequest (3rd streamed byte: TXCMD, bmRequestType, bRequest)
              -- of a DATA0 SETUP payload so we know if the next IN has a data stage.
              if pid_nib = x"3" and bcnt = 2 then
                last_breq := ulpi_data_o;
              end if;
              bcnt := bcnt + 1;
            end if;

          when P_RESPOND =>
            -- Stream the device response.  DIR stays high.  First cycle is a
            -- turnaround (NXT=0); then NXT=1 with each byte; then DIR=0 to end.
            if resp_kind = 1 then
              -- ACK handshake: PID 0xD2 only.
              if resp_idx = 0 then
                ulpi_dir <= '1'; ulpi_nxt <= '0'; ulpi_data_i <= "01000000";
                resp_idx := 1;
              elsif resp_idx = 1 then
                ulpi_dir <= '1'; ulpi_nxt <= '1'; ulpi_data_i <= x"D2";
                resp_idx := 2;
              else
                ulpi_dir <= '0'; ulpi_nxt <= '0';
                st := P_IDLE;
              end if;
            elsif resp_kind = 2 then
              -- Zero-length DATA1 status: PID 0x4B + 2 CRC bytes, no payload.
              if resp_idx = 0 then
                ulpi_dir <= '1'; ulpi_nxt <= '0'; ulpi_data_i <= "01000000";
                resp_idx := 1;
              elsif resp_idx = 1 then
                ulpi_dir <= '1'; ulpi_nxt <= '1'; ulpi_data_i <= x"4B";
                resp_idx := 2;
              elsif resp_idx = 2 then
                ulpi_dir <= '1'; ulpi_nxt <= '1'; ulpi_data_i <= x"00";
                resp_idx := 3;
              elsif resp_idx = 3 then
                ulpi_dir <= '1'; ulpi_nxt <= '1'; ulpi_data_i <= x"00";
                resp_idx := 4;
              else
                ulpi_dir <= '0'; ulpi_nxt <= '0';
                st := P_IDLE;
              end if;
            else
              -- DATA1 descriptor packet.
              if resp_idx = 0 then
                ulpi_dir <= '1'; ulpi_nxt <= '0'; ulpi_data_i <= "01000000";
                resp_idx := 1;
              elsif resp_idx <= DEV_DESC'length then
                ulpi_dir <= '1'; ulpi_nxt <= '1';
                ulpi_data_i <= DEV_DESC(resp_idx - 1);
                resp_idx := resp_idx + 1;
              else
                ulpi_dir <= '0'; ulpi_nxt <= '0';
                st := P_IDLE;
              end if;
            end if;
        end case;
      end if;
    end if;
  end process;

  -- Report key milestones so the transcript shows how far bring-up got.
  monitor : process(clk)
    variable last_phase : std_logic_vector(3 downto 0) := "ZZZZ";
  begin
    if rising_edge(clk) then
      if diag_phase /= last_phase then
        report "PHASE -> " & to_hstring(diag_phase) &
               "  FuncCtrl=" & to_hstring(reg_func_ctrl) &
               "  OtgCtrl=" & to_hstring(reg_otg_ctrl);
        last_phase := diag_phase;
      end if;
      if diag_connected = '1' then
        report "DEVICE CONNECTED (enumeration complete)" severity note;
      end if;
    end if;
  end process;
end architecture;
