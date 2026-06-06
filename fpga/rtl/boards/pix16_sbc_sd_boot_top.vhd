-- PIX16 board top for SD-loaded SBC firmware.
library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

use work.sbc_pkg.all;

entity pix16_sbc_sd_boot_top is
  port (
    clk        : in  std_logic;
    reset_n    : in  std_logic;
    vga_out_r  : out std_logic_vector(4 downto 0);
    vga_out_g  : out std_logic_vector(5 downto 0);
    vga_out_b  : out std_logic_vector(4 downto 0);
    vga_out_hs : out std_logic;
    vga_out_vs : out std_logic;
    key        : in  std_logic_vector(3 downto 0);
    led        : out std_logic_vector(1 downto 0);
    uart_tx    : out std_logic;
    uart_rx    : in  std_logic;
    sd_dclk    : out std_logic;
    sd_ncs     : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic;
    sdram_clk   : out   std_logic;
    sdram_cke   : out   std_logic;
    sdram_cs_n  : out   std_logic;
    sdram_ras_n : out   std_logic;
    sdram_cas_n : out   std_logic;
    sdram_we_n  : out   std_logic;
    sdram_ba    : out   std_logic_vector(1 downto 0);
    sdram_addr  : out   std_logic_vector(12 downto 0);
    sdram_dqm   : out   std_logic_vector(1 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of pix16_sbc_sd_boot_top is
  component sd_card_top
    generic (
      SPI_LOW_SPEED_DIV  : integer := 248;
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

  signal rst                : std_logic;
  signal sd_init_done       : std_logic;
  signal sd_sec_read        : std_logic;
  signal sd_sec_read_addr   : std_logic_vector(31 downto 0);
  signal sd_sec_read_data   : data_t;
  signal sd_sec_read_valid  : std_logic;
  signal sd_sec_read_end    : std_logic;
  signal rom_load_we        : std_logic;
  signal rom_load_addr      : std_logic_vector(13 downto 0);
  signal rom_load_data      : data_t;
  signal boot_done          : std_logic;
  signal boot_error         : std_logic;
  signal loader_state       : std_logic_vector(3 downto 0);
  signal sd_sec_state       : std_logic_vector(4 downto 0);
  signal sd_cmd_state       : std_logic_vector(3 downto 0);
  signal sd_cmd_error       : std_logic;
  signal via_portb          : data_t;
  signal uart_tx_data       : data_t;
  signal uart_tx_valid      : std_logic;
  signal uart_tx_busy       : std_logic;
  signal boot_dbg_data      : data_t;
  signal boot_dbg_valid     : std_logic;
  signal boot_dbg_active    : std_logic;
  signal uart_mux_data      : data_t;
  signal uart_mux_valid     : std_logic;
  signal clk_n              : std_logic;
  signal sd_seen_read_end   : std_logic := '0';
  signal sd_ncs_i           : std_logic;
  signal sd_dclk_i          : std_logic;
  signal sd_mosi_i          : std_logic;
begin
  rst <= not reset_n;
  clk_n <= not clk;
  sd_ncs <= sd_ncs_i;
  sd_dclk <= sd_dclk_i;
  sd_mosi <= sd_mosi_i;

  led(0) <= boot_done or sd_init_done;
  led(1) <= boot_error or sd_seen_read_end when boot_done = '0' else via_portb(0);

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        sd_seen_read_end <= '0';
      elsif sd_sec_read_end = '1' then
        sd_seen_read_end <= '1';
      end if;
    end if;
  end process;

  sdram_clk_oddr : ODDR2
    generic map (DDR_ALIGNMENT => "NONE", INIT => '0', SRTYPE => "SYNC")
    port map (
      Q  => sdram_clk,
      C0 => clk,  C1 => clk_n,
      CE => '1',
      D0 => '1',  D1 => '0',
      R  => '0',  S  => '0'
    );

  sd_i : sd_card_top
    port map (
      clk                    => clk,
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
      clk                    => clk,
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
    port map (
      clk             => clk,
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
      uart_busy       => uart_tx_busy,
      uart_data       => boot_dbg_data,
      uart_valid      => boot_dbg_valid,
      active          => boot_dbg_active
    );

  sbc_i : entity work.sbc_t65_sdram_boot_top
    port map (
      clk           => clk,
      reset_n       => reset_n,
      boot_done     => boot_done,
      rom_load_we   => rom_load_we,
      rom_load_addr => rom_load_addr,
      rom_load_data => rom_load_data,
      vga_r         => vga_out_r,
      vga_g         => vga_out_g,
      vga_b         => vga_out_b,
      vga_hs        => vga_out_hs,
      vga_vs        => vga_out_vs,
      uart_rx       => uart_rx,
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => uart_tx_busy,
      sdram_cke     => sdram_cke,
      sdram_cs_n    => sdram_cs_n,
      sdram_ras_n   => sdram_ras_n,
      sdram_cas_n   => sdram_cas_n,
      sdram_we_n    => sdram_we_n,
      sdram_ba      => sdram_ba,
      sdram_addr    => sdram_addr,
      sdram_dqm     => sdram_dqm,
      sdram_dq      => sdram_dq,
      via_portb     => via_portb,
      dbg_cpu_addr  => open,
      dbg_cpu_data  => open,
      dbg_cpu_din   => open,
      dbg_cpu_we    => open,
      dbg_cpu_sync  => open
    );

  uart_ser : entity work.uart_tx_ser
    port map (
      clk     => clk,
      reset_n => reset_n,
      data    => uart_mux_data,
      valid   => uart_mux_valid,
      tx      => uart_tx,
      busy    => uart_tx_busy
    );

  uart_mux_data  <= boot_dbg_data when boot_dbg_active = '1' else uart_tx_data;
  uart_mux_valid <= boot_dbg_valid when boot_dbg_active = '1' else uart_tx_valid;
end architecture;
