-- Tang Primer 20K board top — 6502 SBC with HDMI output.
--
-- Clock: 27 MHz oscillator -> 270 MHz PLL root -> 135 MHz TMDS,
--   54 MHz SBC system clock, and 27 MHz pixel clock.
--
-- Video: vic_vga runs at CLK_DIV=1 (27 MHz pixel), 858x525 total (CEA 480p),
--   giving 640x480 @ 31.47 kHz H / 59.94 Hz V.  Encoded to DVI TMDS over HDMI.
--
-- KEY[0] = T5  (LVCMOS33, active-low reset button):
--                short press  -> CPU soft reset (restart program, keep ROM/boot)
--                long press >1s -> full board reset (re-run SD boot loader)
-- KEY[1] = T3  (LVCMOS33, active-low UART monitor enter / CPU hold)
-- LED[0]/LED[1] show boot status until boot_done, then LED[3:0] follow VIA PB[3:0].
library ieee;
use ieee.std_logic_1164.all;
use work.sbc_pkg.all;

entity tang20k_sbc_top is
  generic (
    BAUD          : positive := 115_200
  );
  port (
    clk_27mhz  : in  std_logic;
    key        : in  std_logic_vector(1 downto 0);
    led        : out std_logic_vector(3 downto 0);
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic;
    sd_dclk    : out std_logic;
    sd_ncs     : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic;
    -- PS/2 keyboard on PMOD GPIO (directly active-low, open-collector)
    ps2_clk    : in std_logic;
    ps2_data   : in std_logic;
    -- PT8211 audio DAC (dock board)
    dac_bck    : out std_logic;
    dac_ws     : out std_logic;
    dac_din    : out std_logic;
    pa_en      : out std_logic;   -- dock audio power-amplifier enable (active high)
    -- HDMI TMDS differential outputs
    tmds_clk_p : out std_logic;
    tmds_clk_n : out std_logic;
    tmds_d_p   : out std_logic_vector(2 downto 0);
    tmds_d_n   : out std_logic_vector(2 downto 0)
  );
end entity;

architecture rtl of tang20k_sbc_top is
  component sd_card_top
    generic (
      SPI_LOW_SPEED_DIV  : integer := 134;
      SPI_HIGH_SPEED_DIV : integer := 0
    );
    port (
      clk                    : in  std_logic;
      rst                    : in  std_logic;
      SD_nCS                 : out std_logic;
      SD_DCLK                : out std_logic;
      SD_MOSI                : out std_logic;
      SD_MISO                : in  std_logic;
      sd_init_done           : out std_logic;
      sd_sec_read            : in  std_logic;
      sd_sec_read_addr       : in  std_logic_vector(31 downto 0);
      sd_sec_read_data       : out data_t;
      sd_sec_read_data_valid : out std_logic;
      sd_sec_read_end        : out std_logic;
      sd_sec_write           : in  std_logic;
      sd_sec_write_addr      : in  std_logic_vector(31 downto 0);
      sd_sec_write_data      : in  data_t;
      sd_sec_write_data_req  : out std_logic;
      sd_sec_write_end       : out std_logic;
      debug_sec_state        : out std_logic_vector(4 downto 0);
      debug_cmd_state        : out std_logic_vector(3 downto 0);
      debug_cmd_error        : out std_logic
    );
  end component;

  component sd_rom_loader
    port (
      clk                    : in  std_logic;
      rst                    : in  std_logic;
      sd_init_done           : in  std_logic;
      sd_sec_read            : out std_logic;
      sd_sec_read_addr       : out std_logic_vector(31 downto 0);
      sd_sec_read_data       : in  data_t;
      sd_sec_read_data_valid : in  std_logic;
      sd_sec_read_end        : in  std_logic;
      rom_load_we            : out std_logic;
      rom_load_addr          : out std_logic_vector(13 downto 0);
      rom_load_data          : out data_t;
      boot_done              : out std_logic;
      boot_error             : out std_logic;
      dbg_state              : out std_logic_vector(3 downto 0)
    );
  end component;

  component rPLL is
    generic (
      FCLKIN         : string  := "100.0";
      DEVICE         : string  := "GW1N-1";
      IDIV_SEL       : integer := 0;
      FBDIV_SEL      : integer := 0;
      ODIV_SEL       : integer := 8;
      PSDA_SEL       : string  := "0000";
      DUTYDA_SEL     : string  := "1000";
      DYN_SDIV_SEL   : integer := 2;
      CLKFB_SEL      : string  := "internal";
      CLKOUT_BYPASS  : string  := "false";
      CLKOUTP_BYPASS : string  := "false";
      CLKOUTD_BYPASS : string  := "false";
      CLKOUTD_SRC    : string  := "CLKOUT"
    );
    port (
      CLKOUT  : out std_logic;
      LOCK    : out std_logic;
      CLKOUTP : out std_logic;
      CLKOUTD : out std_logic;
      RESET   : in  std_logic;
      RESET_P : in  std_logic;
      CLKIN   : in  std_logic;
      CLKFB   : in  std_logic;
      FBDSEL  : in  std_logic_vector(5 downto 0);
      IDSEL   : in  std_logic_vector(5 downto 0);
      ODSEL   : in  std_logic_vector(5 downto 0);
      PSDA    : in  std_logic_vector(3 downto 0);
      DUTYDA  : in  std_logic_vector(3 downto 0);
      FDLY    : in  std_logic_vector(3 downto 0)
    );
  end component;

  signal clk_sys      : std_logic;   -- 54 MHz from HDMI clock tree
  signal clk_pix      : std_logic;   -- 27 MHz HDMI pixel clock
  signal pll_lock     : std_logic;
  signal reset_n      : std_logic;
  signal rst          : std_logic;
  -- key(0) reset button: short press = CPU soft reset, long press = full board
  -- reset. Debounced and synchronised in the clk_sys domain.
  constant DB_MAX     : integer := 270_000;     -- ~5 ms debounce  @ 54 MHz
  constant LONG_MAX   : integer := 54_000_000;  -- ~1 s  long-press @ 54 MHz
  signal key0_sync    : std_logic_vector(2 downto 0) := (others => '1');
  signal key0_db      : std_logic := '1';        -- debounced level (1 = released)
  signal db_cnt       : integer range 0 to DB_MAX := 0;
  signal press_cnt    : integer range 0 to LONG_MAX := 0;
  signal soft_reset   : std_logic := '0';        -- CPU-only reset (short press)
  signal long_reset   : std_logic := '0';        -- full board reset (long press)
  signal uart_tx_data : data_t;
  signal uart_tx_valid: std_logic;
  signal uart_tx_busy : std_logic;
  signal uart_mux_data  : data_t;
  signal uart_mux_valid : std_logic;
  signal via_portb    : data_t;
  signal vga_r        : std_logic_vector(4 downto 0);
  signal vga_g        : std_logic_vector(5 downto 0);
  signal vga_b        : std_logic_vector(4 downto 0);
  signal vga_hs       : std_logic;
  signal vga_vs       : std_logic;
  signal vga_de       : std_logic;
  signal vga_mux_r    : std_logic_vector(4 downto 0);
  signal vga_mux_g    : std_logic_vector(5 downto 0);
  signal vga_mux_b    : std_logic_vector(4 downto 0);
  signal vga_mux_hs   : std_logic;
  signal vga_mux_vs   : std_logic;
  signal vga_mux_de   : std_logic;
  signal sbc_vga_r    : std_logic_vector(4 downto 0);
  signal sbc_vga_g    : std_logic_vector(5 downto 0);
  signal sbc_vga_b    : std_logic_vector(4 downto 0);
  signal sbc_vga_hs   : std_logic;
  signal sbc_vga_vs   : std_logic;
  signal sbc_vga_de   : std_logic;
  signal boot_vga_r   : std_logic_vector(4 downto 0);
  signal boot_vga_g   : std_logic_vector(5 downto 0);
  signal boot_vga_b   : std_logic_vector(4 downto 0);
  signal boot_vga_hs  : std_logic;
  signal boot_vga_vs  : std_logic;
  signal boot_vga_de  : std_logic;
  signal boot_vga_active : std_logic;
  signal sd_init_done       : std_logic;
  signal sd_sec_read        : std_logic;
  signal sd_sec_read_addr   : std_logic_vector(31 downto 0);
  signal sd_sec_read_data   : data_t;
  signal sd_sec_read_valid  : std_logic;
  signal sd_sec_read_end    : std_logic;
  signal sd_sec_state       : std_logic_vector(4 downto 0);
  signal sd_cmd_state       : std_logic_vector(3 downto 0);
  signal sd_cmd_error       : std_logic;
  signal sd_ncs_i           : std_logic;
  signal sd_dclk_i          : std_logic;
  signal sd_mosi_i          : std_logic;
  signal rom_load_we        : std_logic;
  signal rom_load_addr      : std_logic_vector(13 downto 0);
  signal rom_load_data      : data_t;
  signal boot_done          : std_logic;
  signal boot_error         : std_logic;
  signal loader_state       : std_logic_vector(3 downto 0);
  signal boot_dbg_data      : data_t;
  signal boot_dbg_valid     : std_logic;
  signal boot_dbg_active    : std_logic;
  signal monitor_rx_data    : data_t;
  signal monitor_rx_valid   : std_logic;
  signal monitor_tx_data    : data_t;
  signal monitor_tx_valid   : std_logic;
  signal monitor_active     : std_logic;
  signal monitor_button     : std_logic;
  signal monitor_mem_req    : std_logic;
  signal monitor_mem_we     : std_logic;
  signal monitor_mem_addr   : addr_t;
  signal monitor_mem_wdata  : data_t;
  signal monitor_mem_rdata  : data_t;
  signal monitor_mem_ready  : std_logic;
  signal monitor_jump_req   : std_logic;
  signal monitor_jump_addr  : addr_t;
  signal sd_seen_read_end   : std_logic := '0';
  signal usb_connected      : std_logic;
  signal usb_keycode        : std_logic_vector(7 downto 0);
  signal usb_modif          : std_logic_vector(7 downto 0);
  signal usb_ascii          : std_logic_vector(7 downto 0);
  signal usb_phase          : std_logic_vector(3 downto 0);
  signal usb_key_event      : std_logic;
  signal usb_polling        : std_logic;
  signal usb_cap_addr       : std_logic_vector(6 downto 0);
  signal usb_cap_data       : std_logic_vector(15 downto 0);
  signal usb_cap_ready      : std_logic;
begin
  -- key(0) is the reset button: a short press soft-resets only the CPU (the
  -- running program restarts via its reset vector, ROM/boot/SRAM kept), a long
  -- press (>1 s) asserts a full board reset. Debounced/synchronised on clk_sys,
  -- which stays alive because the HDMI PLL is no longer gated by the button.
  key_reset_proc : process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if pll_lock = '0' then
        key0_sync  <= (others => '1');
        key0_db    <= '1';
        db_cnt     <= 0;
        press_cnt  <= 0;
        soft_reset <= '0';
        long_reset <= '0';
      else
        key0_sync <= key0_sync(1 downto 0) & key(0);
        -- debounce: the synchronised level must hold steady DB_MAX cycles
        if key0_sync(2) = key0_db then
          db_cnt <= 0;
        elsif db_cnt = DB_MAX then
          key0_db <= key0_sync(2);
          db_cnt  <= 0;
        else
          db_cnt <= db_cnt + 1;
        end if;
        -- press duration: short -> soft_reset (CPU only), held >1 s -> full reset
        if key0_db = '0' then            -- pressed (active low)
          soft_reset <= '1';
          if press_cnt = LONG_MAX then
            long_reset <= '1';
          else
            press_cnt <= press_cnt + 1;
          end if;
        else                             -- released
          soft_reset <= '0';
          long_reset <= '0';
          press_cnt  <= 0;
        end if;
      end if;
    end if;
  end process;

  -- Full board reset on long press; also held until the PLL locks at power-on.
  reset_n <= (not long_reset) and pll_lock;
  rst <= not reset_n;
  monitor_button <= not key(1);
  pa_en <= '1';  -- keep dock audio power amplifier enabled (PT8211 PA_EN, active high)
  sd_ncs <= sd_ncs_i;
  sd_dclk <= sd_dclk_i;
  sd_mosi <= sd_mosi_i;
  boot_vga_active <= (not boot_done) or boot_error or monitor_active;

  vga_mux_r  <= boot_vga_r  when boot_vga_active = '1' else sbc_vga_r;
  vga_mux_g  <= boot_vga_g  when boot_vga_active = '1' else sbc_vga_g;
  vga_mux_b  <= boot_vga_b  when boot_vga_active = '1' else sbc_vga_b;
  vga_mux_hs <= boot_vga_hs when boot_vga_active = '1' else sbc_vga_hs;
  vga_mux_vs <= boot_vga_vs when boot_vga_active = '1' else sbc_vga_vs;
  vga_mux_de <= boot_vga_de when boot_vga_active = '1' else sbc_vga_de;

  -- Register the complete renderer output together before the related-clock
  -- handoff in tang20k_hdmi_tx. This removes long combinational 54->27 MHz
  -- paths while preserving RGB/sync/data-enable alignment.
  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if reset_n = '0' then
        vga_r  <= (others => '0');
        vga_g  <= (others => '0');
        vga_b  <= (others => '0');
        vga_hs <= '1';
        vga_vs <= '1';
        vga_de <= '0';
      else
        vga_r  <= vga_mux_r;
        vga_g  <= vga_mux_g;
        vga_b  <= vga_mux_b;
        vga_hs <= vga_mux_hs;
        vga_vs <= vga_mux_vs;
        vga_de <= vga_mux_de;
      end if;
    end if;
  end process;

  process(clk_sys)
  begin
    if rising_edge(clk_sys) then
      if reset_n = '0' then
        sd_seen_read_end <= '0';
      elsif sd_sec_read_end = '1' then
        sd_seen_read_end <= '1';
      end if;
    end if;
  end process;

  sd_i : sd_card_top
    generic map (
      SPI_LOW_SPEED_DIV  => 268,
      SPI_HIGH_SPEED_DIV => 2
    )
    port map (
      clk                    => clk_sys,
      rst                    => rst,
      SD_nCS                 => sd_ncs_i,
      SD_DCLK                => sd_dclk_i,
      SD_MOSI                => sd_mosi_i,
      SD_MISO                => sd_miso,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end        => sd_sec_read_end,
      sd_sec_write           => '0',
      sd_sec_write_addr      => (others => '0'),
      sd_sec_write_data      => (others => '0'),
      sd_sec_write_data_req  => open,
      sd_sec_write_end       => open,
      debug_sec_state        => sd_sec_state,
      debug_cmd_state        => sd_cmd_state,
      debug_cmd_error        => sd_cmd_error
    );

  loader_i : sd_rom_loader
    port map (
      clk                    => clk_sys,
      rst                    => rst,
      sd_init_done           => sd_init_done,
      sd_sec_read            => sd_sec_read,
      sd_sec_read_addr       => sd_sec_read_addr,
      sd_sec_read_data       => sd_sec_read_data,
      sd_sec_read_data_valid => sd_sec_read_valid,
      sd_sec_read_end        => sd_sec_read_end,
      rom_load_we            => rom_load_we,
      rom_load_addr          => rom_load_addr,
      rom_load_data          => rom_load_data,
      boot_done              => boot_done,
      boot_error             => boot_error,
      dbg_state              => loader_state
    );

  boot_debug_i : entity work.boot_debug_uart
    generic map (STATUS_DIV => 54_000_000)
    port map (
      clk             => clk_sys,
      reset_n         => reset_n,
      sd_init_done    => sd_init_done,
      sd_sec_read     => sd_sec_read,
      sd_sec_read_end => sd_sec_read_end,
      boot_done       => boot_done,
      boot_error      => boot_error,
      sd_ncs          => sd_ncs_i,
      sd_dclk         => sd_dclk_i,
      sd_mosi_o       => sd_mosi_i,
      sd_miso_i       => sd_miso,
      loader_state    => loader_state,
      sd_sec_state    => sd_sec_state,
      sd_cmd_state    => sd_cmd_state,
      sd_cmd_error    => sd_cmd_error,
      usb_connected   => usb_connected,
      usb_keycode     => usb_keycode,
      usb_modif       => usb_modif,
      usb_ascii       => usb_ascii,
      usb_phase       => usb_phase,
      uart_busy       => uart_tx_busy,
      uart_data       => boot_dbg_data,
      uart_valid      => boot_dbg_valid,
      active          => boot_dbg_active
    );


  monitor_rx_i : entity work.uart_rx_ser
    generic map (CLK_HZ => 54_000_000, BAUD => BAUD)
    port map (
      clk     => clk_sys,
      reset_n => reset_n,
      rx      => uart_rx,
      data    => monitor_rx_data,
      valid   => monitor_rx_valid
    );

  monitor_i : entity work.uart_debug_monitor
    port map (
      clk       => clk_sys,
      reset_n   => reset_n,
      enter_btn => monitor_button,
      rx_data   => monitor_rx_data,
      rx_valid  => monitor_rx_valid,
      tx_busy   => uart_tx_busy,
      tx_data   => monitor_tx_data,
      tx_valid  => monitor_tx_valid,
      active    => monitor_active,
      mem_req   => monitor_mem_req,
      mem_we    => monitor_mem_we,
      mem_addr  => monitor_mem_addr,
      mem_wdata => monitor_mem_wdata,
      mem_rdata => monitor_mem_rdata,
      mem_ready => monitor_mem_ready,
      jump_req  => monitor_jump_req,
      jump_addr => monitor_jump_addr,
      usb_connected => usb_connected,
      usb_keycode   => usb_keycode,
      usb_modif     => usb_modif,
      usb_ascii     => usb_ascii,
      usb_phase     => usb_phase,
      usb_key_event => usb_key_event,
      usb_polling   => usb_polling,
      usb_cap_addr  => usb_cap_addr,
      usb_cap_data  => usb_cap_data,
      usb_cap_ready => usb_cap_ready
    );

  sbc_i : entity work.sbc_t65_boot_monitor_top
    generic map (CLK_HZ => 54_000_000, BAUD => BAUD)
    port map (
      clk           => clk_sys,
      reset_n       => reset_n,
      boot_done     => boot_done,
      soft_reset    => soft_reset,
      monitor_hold  => monitor_active,
      monitor_mem_req   => monitor_mem_req,
      monitor_mem_we    => monitor_mem_we,
      monitor_mem_addr  => monitor_mem_addr,
      monitor_mem_wdata => monitor_mem_wdata,
      monitor_mem_rdata => monitor_mem_rdata,
      monitor_mem_ready => monitor_mem_ready,
      monitor_jump_req  => monitor_jump_req,
      monitor_jump_addr => monitor_jump_addr,
      rom_load_we   => rom_load_we,
      rom_load_addr => rom_load_addr,
      rom_load_data => rom_load_data,
      vga_r         => sbc_vga_r,
      vga_g         => sbc_vga_g,
      vga_b         => sbc_vga_b,
      vga_hs        => sbc_vga_hs,
      vga_vs        => sbc_vga_vs,
      vga_de        => sbc_vga_de,
      uart_rx       => uart_rx,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      via_portb     => via_portb,
      dac_bck       => dac_bck,
      dac_ws        => dac_ws,
      dac_din       => dac_din,
      ps2_clk       => ps2_clk,
      ps2_data      => ps2_data,
      usb_connected => usb_connected,
      usb_keycode   => usb_keycode,
      usb_modif     => usb_modif,
      usb_ascii     => usb_ascii,
      usb_phase     => usb_phase,
      usb_key_event => usb_key_event,
      usb_polling   => usb_polling,
      usb_cap_addr  => usb_cap_addr,
      usb_cap_data  => usb_cap_data,
      usb_cap_ready => usb_cap_ready,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  boot_vga_i : entity work.boot_vga_debug
    generic map (CLK_DIV => 2)
    port map (
      clk             => clk_sys,
      reset_n         => reset_n,
      sd_init_done    => sd_init_done,
      sd_sec_read     => sd_sec_read,
      sd_sec_read_end => sd_sec_read_end,
      boot_done       => boot_done,
      boot_error      => boot_error,
      sd_ncs          => sd_ncs_i,
      sd_dclk         => sd_dclk_i,
      sd_mosi_o       => sd_mosi_i,
      sd_miso_i       => sd_miso,
      loader_state    => loader_state,
      sd_sec_state    => sd_sec_state,
      sd_cmd_state    => sd_cmd_state,
      sd_cmd_error    => sd_cmd_error,
      usb_connected   => usb_connected,
      usb_keycode     => usb_keycode,
      usb_modif       => usb_modif,
      usb_ascii       => usb_ascii,
      usb_phase       => usb_phase,
      usb_key_event   => usb_key_event,
      usb_polling     => usb_polling,
      ram_test_active => '0',
      ram_test_done   => boot_done,
      ram_test_error  => '0',
      ram_test_phase  => x"0",
      ram_test_addr   => (others => '0'),
      ram_test_fail_addr => (others => '0'),
      ram_test_expected  => x"00",
      ram_test_actual    => x"00",
      vga_r           => boot_vga_r,
      vga_g           => boot_vga_g,
      vga_b           => boot_vga_b,
      vga_hs          => boot_vga_hs,
      vga_vs          => boot_vga_vs,
      vga_de          => boot_vga_de
    );

  uart_ser_i : entity work.uart_tx_ser
    generic map (CLK_HZ => 54_000_000, BAUD => BAUD)
    port map (
      clk     => clk_sys,
      reset_n => reset_n,
      data    => uart_mux_data,
      valid   => uart_mux_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

  uart_mux_data  <= monitor_tx_data when monitor_active = '1' else
                    boot_dbg_data   when boot_dbg_active = '1' else
                    uart_tx_data;
  uart_mux_valid <= monitor_tx_valid when monitor_active = '1' else
                    boot_dbg_valid   when boot_dbg_active = '1' else
                    uart_tx_valid;

  hdmi_i : entity work.tang20k_hdmi_tx
    port map (
      clk_in     => clk_27mhz,
      -- HDMI PLL is decoupled from the reset button so clk_sys keeps running
      -- during a CPU soft reset (and during a full reset, so video stays up).
      reset_n    => '1',
      vga_de     => vga_de,
      vga_hs     => vga_hs,
      vga_vs     => vga_vs,
      vga_r      => vga_r,
      vga_g      => vga_g,
      vga_b      => vga_b,
      clk_sys    => clk_sys,
      clk_pix    => clk_pix,
      pll_lock   => pll_lock,
      tmds_clk_p => tmds_clk_p,
      tmds_clk_n => tmds_clk_n,
      tmds_d_p   => tmds_d_p,
      tmds_d_n   => tmds_d_n
    );

  led(0) <= not (boot_done or sd_init_done) when boot_done = '0' else not via_portb(0);
  led(1) <= not (boot_error or sd_seen_read_end) when boot_done = '0' else not via_portb(1);
  led(2) <= not via_portb(2);
  led(3) <= not via_portb(3);

end architecture;
