-- T65 SBC with internal RAM, SD-loaded 16 KB shadow ROM, and UART monitor bus master.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_t65_boot_monitor_top is
  generic (
    CLK_HZ : positive := 27_000_000;
    BAUD   : positive := 115_200
  );
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;
    boot_done    : in  std_logic;
    monitor_hold : in  std_logic := '0';
    monitor_mem_req   : in  std_logic := '0';
    monitor_mem_we    : in  std_logic := '0';
    monitor_mem_addr  : in  addr_t := (others => '0');
    monitor_mem_wdata : in  data_t := (others => '0');
    monitor_mem_rdata : out data_t;
    monitor_mem_ready : out std_logic;
    monitor_jump_req  : in  std_logic := '0';
    monitor_jump_addr : in  addr_t := (others => '0');

    rom_load_we   : in  std_logic;
    rom_load_addr : in  std_logic_vector(13 downto 0);
    rom_load_data : in  data_t;

    vga_r       : out std_logic_vector(4 downto 0);
    vga_g       : out std_logic_vector(5 downto 0);
    vga_b       : out std_logic_vector(4 downto 0);
    vga_hs      : out std_logic;
    vga_vs      : out std_logic;
    vga_de      : out std_logic;

    uart_rx       : in  std_logic;
    uart_tx_data  : out data_t;
    uart_tx_valid : out std_logic;
    uart_tx_busy  : in  std_logic := '0';

    via_portb   : out data_t;

    -- USB HID host (ULPI PHY interface, optional — tie to '0'/'Z' if absent)
    ulpi_clk     : in  std_logic := '0';
    ulpi_dir     : in  std_logic := '0';
    ulpi_nxt     : in  std_logic := '0';
    ulpi_data_i  : in  std_logic_vector(7 downto 0) := (others => '0');
    ulpi_data_o  : out std_logic_vector(7 downto 0);
    ulpi_data_oe : out std_logic;
    ulpi_stp     : out std_logic;
    ulpi_rst     : out std_logic;

    -- USB HID diagnostic outputs (for boot debug display)
    usb_connected : out std_logic;
    usb_keycode   : out std_logic_vector(7 downto 0);
    usb_modif     : out std_logic_vector(7 downto 0);
    usb_ascii     : out std_logic_vector(7 downto 0);
    usb_phase     : out std_logic_vector(3 downto 0);

    dbg_cpu_addr : out addr_t;
    dbg_cpu_data : out data_t;
    dbg_cpu_din  : out data_t;
    dbg_cpu_we   : out std_logic;
    dbg_cpu_sync : out std_logic
  );
end entity;

architecture rtl of sbc_t65_boot_monitor_top is
  signal cpu_reset_n : std_logic;
  signal cpu_reset_base_n : std_logic;
  signal cpu_addr    : addr_t := (others => '0');
  signal cpu_dout    : data_t := (others => '0');
  signal cpu_din     : data_t := (others => '0');
  signal cpu_we      : std_logic := '0';
  signal cpu_bus_we  : std_logic := '0';
  signal cpu_sync    : std_logic := '0';
  signal cpu_enable  : std_logic := '0';
  signal cpu_rdy     : std_logic := '1';
  signal cpu_irq_n   : std_logic := '1';
  signal usb_cs      : std_logic;
  signal dev_sel     : device_sel_t;

  signal zp_dout     : data_t;
  signal sram_dout   : data_t;
  signal rom_dout    : data_t;
  signal vram_dout   : data_t;
  signal vic_reg_dout : data_t;
  signal via_dout    : data_t;
  signal uart_dout   : data_t;

  signal zp_cs       : std_logic;
  signal zp_we       : std_logic;
  signal zp_we_mux   : std_logic;
  signal zp_addr_mux : std_logic_vector(8 downto 0);
  signal zp_din_mux  : data_t;
  signal sram_we     : std_logic;
  signal sram_we_mux : std_logic;
  signal sram_addr_mux : std_logic_vector(14 downto 0);
  signal sram_din_mux  : data_t;
  signal rom_addr_mux : std_logic_vector(13 downto 0);
  signal rom_load_we_mux   : std_logic;
  signal rom_load_addr_mux : std_logic_vector(13 downto 0);
  signal rom_load_data_mux : data_t;
  signal vram_we     : std_logic;
  signal vram_we_mux : std_logic;
  signal vic_reg_we  : std_logic;
  signal via_cs      : std_logic;
  signal via_cs_mux  : std_logic;
  signal via_we_mux  : std_logic;
  signal via_addr_mux : addr_t;
  signal via_din_mux : data_t;
  signal uart_cs     : std_logic;
  signal uart_cs_mux : std_logic;
  signal uart_we_mux : std_logic;
  signal uart_addr_mux : addr_t;
  signal uart_din_mux : data_t;

  signal vram_addr    : std_logic_vector(10 downto 0);
  signal vram_addr_mux : std_logic_vector(10 downto 0);
  signal vram_din_mux  : data_t;
  signal vic_addr     : addr_t;
  signal vic_stealing : std_logic;
  signal vic_cursor_x : std_logic_vector(5 downto 0) := (others => '0');
  signal vic_cursor_y : std_logic_vector(4 downto 0) := (others => '0');

  signal char_addr   : std_logic_vector(9 downto 0);
  signal char_data   : data_t;

  signal via_irq     : std_logic;
  signal uart_irq    : std_logic;
  signal usb_irq     : std_logic;
  signal usb_dout    : data_t;
  signal uart_rx_data  : data_t;
  signal uart_rx_valid : std_logic;
  signal uart_rx_valid_cpu : std_logic;
  signal mon_jump_vector        : addr_t := (others => '0');
  signal mon_jump_reset_cnt     : natural range 0 to 31 := 0;
  signal mon_jump_vector_active : std_logic := '0';

  type mon_mem_state_t is (
    M_IDLE, M_ZP_WAIT, M_ZP_READY,
    M_SRAM_WAIT, M_SRAM_READY,
    M_ROM_RD_WAIT, M_ROM_RD_READY, M_ROM_WR_WAIT,
    M_VRAM_RD_WAIT, M_VRAM_RD_READY, M_VRAM_WR_WAIT,
    M_VIA_WAIT, M_VIA_READY,
    M_UART_WAIT, M_UART_READY,
    M_READY
  );
  signal mon_mem_state       : mon_mem_state_t := M_IDLE;
  signal mon_addr_lat        : addr_t := (others => '0');
  signal mon_wdata_lat       : data_t := (others => '0');
  signal mon_we_lat          : std_logic := '0';
  signal mon_rdata_reg       : data_t := (others => '0');
  signal mon_ready_reg       : std_logic := '0';
begin
  cpu_reset_base_n <= reset_n and boot_done;
  cpu_reset_n <= cpu_reset_base_n when mon_jump_reset_cnt = 0 else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' or monitor_hold = '1' then
        cpu_enable <= '0';
      else
        cpu_enable <= not cpu_enable;
      end if;
    end if;
  end process;

  cpu_bus_we <= cpu_we and not cpu_enable;
  cpu_rdy    <= not vic_stealing and not monitor_hold;
  cpu_irq_n  <= not (via_irq or uart_irq or usb_irq);
  usb_cs     <= '1' when monitor_hold = '0' and dev_sel = DEV_USB else '0';

  zp_cs   <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 9) = "0000000" else '0';
  zp_we   <= cpu_bus_we when monitor_hold = '0' and zp_cs = '1' else '0';
  sram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_TEXT else '0';
  vic_reg_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_REG else '0';
  via_cs  <= '1'        when monitor_hold = '0' and dev_sel = DEV_VIA      else '0';
  uart_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_UART     else '0';

  zp_we_mux   <= '1' when monitor_hold = '1' and mon_mem_state = M_ZP_WAIT and mon_we_lat = '1' else zp_we;
  zp_addr_mux <= mon_addr_lat(8 downto 0) when monitor_hold = '1' and
                 (mon_mem_state = M_ZP_WAIT or mon_mem_state = M_ZP_READY) else cpu_addr(8 downto 0);
  zp_din_mux  <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_ZP_WAIT else cpu_dout;

  sram_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_SRAM_WAIT and mon_we_lat = '1' else sram_we;
  sram_addr_mux <= mon_addr_lat(14 downto 0) when monitor_hold = '1' and
                   (mon_mem_state = M_SRAM_WAIT or mon_mem_state = M_SRAM_READY) else cpu_addr(14 downto 0);
  sram_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_SRAM_WAIT else cpu_dout;

  rom_addr_mux <= mon_addr_lat(13 downto 0) when monitor_hold = '1' and
                  (mon_mem_state = M_ROM_RD_WAIT or mon_mem_state = M_ROM_RD_READY) else
                  cpu_addr(13 downto 0);
  rom_load_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT and mon_we_lat = '1' else
                     rom_load_we;
  rom_load_addr_mux <= mon_addr_lat(13 downto 0) when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT else
                       rom_load_addr;
  rom_load_data_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT else
                       rom_load_data;

  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1' else cpu_addr(10 downto 0);
  vram_addr_mux <= mon_addr_lat(10 downto 0) when monitor_hold = '1' and
                   (mon_mem_state = M_VRAM_RD_WAIT or mon_mem_state = M_VRAM_RD_READY or
                    mon_mem_state = M_VRAM_WR_WAIT) else
                   vram_addr;
  vram_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT and mon_we_lat = '1' else
                 '0' when vic_stealing = '1' else vram_we;
  vram_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT else cpu_dout;

  via_cs_mux <= '1' when monitor_hold = '1' and
                (mon_mem_state = M_VIA_WAIT or
                 (mon_mem_state = M_VIA_READY and mon_we_lat = '0')) else via_cs;
  via_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VIA_WAIT and mon_we_lat = '1' else cpu_bus_we;
  via_addr_mux <= mon_addr_lat when monitor_hold = '1' and
                  (mon_mem_state = M_VIA_WAIT or mon_mem_state = M_VIA_READY) else cpu_addr;
  via_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_VIA_WAIT else cpu_dout;

  uart_cs_mux <= '1' when monitor_hold = '1' and
                 (mon_mem_state = M_UART_WAIT or
                  (mon_mem_state = M_UART_READY and mon_we_lat = '0')) else uart_cs;
  uart_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_UART_WAIT and mon_we_lat = '1' else cpu_bus_we;
  uart_addr_mux <= mon_addr_lat when monitor_hold = '1' and
                   (mon_mem_state = M_UART_WAIT or mon_mem_state = M_UART_READY) else cpu_addr;
  uart_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_UART_WAIT else cpu_dout;

  monitor_mem_rdata <= mon_rdata_reg;
  monitor_mem_ready <= mon_ready_reg;
  uart_rx_valid_cpu <= uart_rx_valid when monitor_hold = '0' else '0';

  process(dev_sel, zp_cs, zp_dout, sram_dout, rom_dout, vram_dout, vic_reg_dout, via_dout,
          uart_dout, mon_jump_vector_active, mon_jump_vector, cpu_addr)
  begin
    case dev_sel is
      when DEV_SRAM =>
        if zp_cs = '1' then
          cpu_din <= zp_dout;
        else
          cpu_din <= sram_dout;
        end if;
      when DEV_ROM =>
        if mon_jump_vector_active = '1' and cpu_addr = x"FFFC" then
          cpu_din <= mon_jump_vector(7 downto 0);
        elsif mon_jump_vector_active = '1' and cpu_addr = x"FFFD" then
          cpu_din <= mon_jump_vector(15 downto 8);
        else
          cpu_din <= rom_dout;
        end if;
      when DEV_VIC_TEXT =>
        cpu_din <= vram_dout;
      when DEV_VIC_REG =>
        cpu_din <= vic_reg_dout;
      when DEV_VIA =>
        cpu_din <= via_dout;
      when DEV_UART =>
        cpu_din <= uart_dout;
      when DEV_USB =>
        cpu_din <= usb_dout;
      when others =>
        cpu_din <= x"FF";
    end case;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        vic_cursor_x <= (others => '0');
        vic_cursor_y <= (others => '0');
      elsif vic_reg_we = '1' then
        case cpu_addr(3 downto 0) is
          when x"1" =>
            if unsigned(cpu_dout(5 downto 0)) < to_unsigned(40, 6) then
              vic_cursor_x <= cpu_dout(5 downto 0);
            end if;
          when x"2" =>
            if unsigned(cpu_dout(4 downto 0)) < to_unsigned(25, 5) then
              vic_cursor_y <= cpu_dout(4 downto 0);
            end if;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  process(cpu_addr, vic_cursor_x, vic_cursor_y)
  begin
    case cpu_addr(3 downto 0) is
      when x"1" =>
        vic_reg_dout <= "00" & vic_cursor_x;
      when x"2" =>
        vic_reg_dout <= "000" & vic_cursor_y;
      when others =>
        vic_reg_dout <= x"00";
    end case;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        mon_jump_vector <= (others => '0');
        mon_jump_reset_cnt <= 0;
        mon_jump_vector_active <= '0';
      else
        if monitor_jump_req = '1' then
          mon_jump_vector <= monitor_jump_addr;
          mon_jump_reset_cnt <= 16;
          mon_jump_vector_active <= '1';
        elsif mon_jump_reset_cnt > 0 then
          mon_jump_reset_cnt <= mon_jump_reset_cnt - 1;
        elsif mon_jump_vector_active = '1' and cpu_addr = x"FFFD" and cpu_sync = '0' then
          mon_jump_vector_active <= '0';
        end if;
      end if;
    end if;
  end process;

  decode_i : entity work.bus_decode
    port map (addr => cpu_addr, sel => dev_sel);

  cpu_i : entity work.t65_adapter
    port map (
      clk      => clk,
      reset_n  => cpu_reset_n,
      enable   => cpu_enable,
      rdy      => cpu_rdy,
      irq_n    => cpu_irq_n,
      nmi_n    => '1',
      data_in  => cpu_din,
      addr     => cpu_addr,
      data_out => cpu_dout,
      we       => cpu_we,
      sync     => cpu_sync
    );

  zp_ram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 9, ASYNC_READ => false)
    port map (clk => clk, we => zp_we_mux,
              addr => zp_addr_mux, din => zp_din_mux, dout => zp_dout);

  sram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 15, ASYNC_READ => false)
    port map (clk => clk, we => sram_we_mux,
              addr => sram_addr_mux, din => sram_din_mux, dout => sram_dout);

  rom_i : entity work.boot_shadow_rom
    generic map (ADDR_WIDTH => 14)
    port map (
      clk       => clk,
      cpu_addr  => rom_addr_mux,
      cpu_dout  => rom_dout,
      load_we   => rom_load_we_mux,
      load_addr => rom_load_addr_mux,
      load_data => rom_load_data_mux
    );

  vram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 11, ASYNC_READ => false)
    port map (clk => clk, we => vram_we_mux,
              addr => vram_addr_mux, din => vram_din_mux, dout => vram_dout);

  via_i : entity work.via6522
    port map (
      clk       => clk,
      reset_n   => cpu_reset_n,
      cs        => via_cs_mux,
      we        => via_we_mux,
      addr      => via_addr_mux,
      din       => via_din_mux,
      dout      => via_dout,
      porta_in  => (others => '0'),
      portb_in  => (others => '0'),
      porta_out => open,
      portb_out => via_portb,
      irq       => via_irq
    );

  uart_i : entity work.uart6551
    port map (
      clk      => clk,
      reset_n  => cpu_reset_n,
      cs       => uart_cs_mux,
      we       => uart_we_mux,
      addr     => uart_addr_mux,
      din      => uart_din_mux,
      dout     => uart_dout,
      rx_data  => uart_rx_data,
      rx_valid => uart_rx_valid_cpu,
      tx_data  => uart_tx_data,
      tx_valid => uart_tx_valid,
      tx_busy  => uart_tx_busy,
      irq      => uart_irq
    );

  uart_rx_i : entity work.uart_rx_ser
    generic map (CLK_HZ => CLK_HZ, BAUD => BAUD)
    port map (
      clk     => clk,
      reset_n => cpu_reset_n,
      rx      => uart_rx,
      data    => uart_rx_data,
      valid   => uart_rx_valid
    );

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        mon_mem_state <= M_IDLE;
        mon_addr_lat <= (others => '0');
        mon_wdata_lat <= (others => '0');
        mon_we_lat <= '0';
        mon_rdata_reg <= (others => '0');
        mon_ready_reg <= '0';
      else
        mon_ready_reg <= '0';
        case mon_mem_state is
          when M_IDLE =>
            if monitor_hold = '1' and monitor_mem_req = '1' then
              mon_addr_lat <= monitor_mem_addr;
              mon_wdata_lat <= monitor_mem_wdata;
              mon_we_lat <= monitor_mem_we;
              if unsigned(monitor_mem_addr) >= ADDR_ROM_BASE then
                if monitor_mem_we = '1' then
                  mon_mem_state <= M_ROM_WR_WAIT;
                else
                  mon_mem_state <= M_ROM_RD_WAIT;
                end if;
              elsif unsigned(monitor_mem_addr) >= ADDR_VIC_TEXT_BASE and
                    unsigned(monitor_mem_addr) <= ADDR_VIC_TEXT_LAST then
                if monitor_mem_we = '1' then
                  mon_mem_state <= M_VRAM_WR_WAIT;
                else
                  mon_mem_state <= M_VRAM_RD_WAIT;
                end if;
              elsif unsigned(monitor_mem_addr) >= ADDR_VIA_BASE and
                    unsigned(monitor_mem_addr) <= ADDR_VIA_LAST then
                mon_mem_state <= M_VIA_WAIT;
              elsif unsigned(monitor_mem_addr) >= ADDR_UART_BASE and
                    unsigned(monitor_mem_addr) <= ADDR_UART_LAST then
                mon_mem_state <= M_UART_WAIT;
              elsif monitor_mem_addr(15) = '1' then
                mon_rdata_reg <= x"FF";
                mon_mem_state <= M_READY;
              elsif monitor_mem_addr(15 downto 9) = "0000000" then
                mon_mem_state <= M_ZP_WAIT;
              elsif monitor_mem_we = '1' then
                mon_mem_state <= M_SRAM_WAIT;
              else
                mon_mem_state <= M_SRAM_WAIT;
              end if;
            end if;

          when M_ZP_WAIT =>
            mon_mem_state <= M_ZP_READY;
          when M_ZP_READY =>
            mon_rdata_reg <= zp_dout;
            mon_mem_state <= M_READY;
          when M_SRAM_WAIT =>
            mon_mem_state <= M_SRAM_READY;
          when M_SRAM_READY =>
            mon_rdata_reg <= sram_dout;
            mon_mem_state <= M_READY;
          when M_ROM_RD_WAIT =>
            mon_mem_state <= M_ROM_RD_READY;
          when M_ROM_RD_READY =>
            mon_rdata_reg <= rom_dout;
            mon_mem_state <= M_READY;
          when M_ROM_WR_WAIT =>
            mon_mem_state <= M_READY;
          when M_VRAM_RD_WAIT =>
            mon_mem_state <= M_VRAM_RD_READY;
          when M_VRAM_RD_READY =>
            mon_rdata_reg <= vram_dout;
            mon_mem_state <= M_READY;
          when M_VRAM_WR_WAIT =>
            mon_mem_state <= M_READY;
          when M_VIA_WAIT =>
            mon_mem_state <= M_VIA_READY;
          when M_VIA_READY =>
            mon_rdata_reg <= via_dout;
            mon_mem_state <= M_READY;
          when M_UART_WAIT =>
            mon_mem_state <= M_UART_READY;
          when M_UART_READY =>
            mon_rdata_reg <= uart_dout;
            mon_mem_state <= M_READY;
          when M_READY =>
            mon_ready_reg <= '1';
            mon_mem_state <= M_IDLE;
          when others =>
            mon_mem_state <= M_IDLE;
        end case;
      end if;
    end if;
  end process;

  usb_hid_i : entity work.usb_hid_host
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
      cs             => usb_cs,
      we             => cpu_bus_we,
      addr           => cpu_addr(1 downto 0),
      dout           => usb_dout,
      irq            => usb_irq,
      diag_connected => usb_connected,
      diag_keycode   => usb_keycode,
      diag_modif     => usb_modif,
      diag_ascii     => usb_ascii,
      diag_phase     => usb_phase
    );

  char_i : entity work.char_rom
    port map (addr => char_addr, dout => char_data);

  vic_i : entity work.vic_vga
    generic map (
      CLK_DIV => 1,
      CURSOR_BLINK_DIV => 13_500_000
    )
    port map (
      clk          => clk,
      reset_n      => reset_n,
      vic_addr     => vic_addr,
      vram_data    => vram_dout,
      vic_stealing => vic_stealing,
      char_addr    => char_addr,
      char_data    => char_data,
      cursor_x     => vic_cursor_x,
      cursor_y     => vic_cursor_y,
      cursor_enable => '1',
      vga_hs       => vga_hs,
      vga_vs       => vga_vs,
      vga_de       => vga_de,
      vga_r        => vga_r,
      vga_g        => vga_g,
      vga_b        => vga_b
    );

  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_din  <= cpu_din;
  dbg_cpu_we   <= cpu_bus_we;
  dbg_cpu_sync <= cpu_sync;
end architecture;
