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

    -- PT8211 audio DAC (I2S-style serial output)
    dac_bck     : out std_logic;
    dac_ws      : out std_logic;
    dac_din     : out std_logic;

    -- PS/2 keyboard (directly on PMOD GPIO pins)
    ps2_clk  : in std_logic;
    ps2_data : in std_logic;

    -- Keyboard diagnostic outputs (for boot debug display)
    usb_connected : out std_logic;
    usb_keycode   : out std_logic_vector(7 downto 0);
    usb_modif     : out std_logic_vector(7 downto 0);
    usb_ascii     : out std_logic_vector(7 downto 0);
    usb_phase     : out std_logic_vector(3 downto 0);
    usb_key_event : out std_logic;
    usb_polling   : out std_logic;

    -- ULPI bus capture (stubbed — was ULPI debug; kept for backward compat)
    usb_cap_addr  : in  std_logic_vector(6 downto 0) := (others => '0');
    usb_cap_data  : out std_logic_vector(15 downto 0);
    usb_cap_ready : out std_logic;

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

  -- 4-voice sound chip (sound_chip4). One chip-select per voice; the voices
  -- live at $8830, $8890, $889A, $88A4 (not all 16-aligned) so the register
  -- offset is computed as cpu_addr - base for the selected voice.
  signal sound_cs     : std_logic_vector(3 downto 0);
  signal sound_we     : std_logic;
  signal sound_addr   : std_logic_vector(3 downto 0);
  signal sound_dout   : data_t;
  signal sound_sample : std_logic_vector(15 downto 0);

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
  signal vram_wr_pending : std_logic := '0';
  signal vram_wr_addr    : std_logic_vector(10 downto 0) := (others => '0');
  signal vram_wr_data    : data_t := (others => '0');
  signal vic_addr     : addr_t;
  signal vic_stealing : std_logic;
  signal vic_stealing_d : std_logic := '0';  -- steal delayed 1 clk (read-latency cushion)
  signal vic_cursor_x : std_logic_vector(5 downto 0) := (others => '0');
  signal vic_cursor_y : std_logic_vector(4 downto 0) := (others => '0');
  signal vic_text_color : data_t := x"01";
  signal vic_bg_color   : data_t := x"00";
  signal vic_mode_reg     : data_t := x"00";
  signal vic_fetch_bitmap : std_logic;
  signal bitmap_dout      : data_t;
  signal bitmap_addr      : std_logic_vector(12 downto 0);
  signal bitmap_we        : std_logic;
  signal bitmap_din_mux   : data_t;
  signal bitmap_cpu_we    : std_logic;
  signal bitmap_wr_pending : std_logic := '0';
  signal bitmap_wr_addr   : std_logic_vector(12 downto 0) := (others => '0');
  signal bitmap_wr_data   : data_t := (others => '0');
  signal vram_data_sel    : std_logic := '0';
  signal vram_data_mux    : data_t;

  signal char_addr   : std_logic_vector(9 downto 0);
  signal char_data   : data_t;

  signal via_irq     : std_logic;
  signal uart_irq    : std_logic;
  signal usb_irq     : std_logic;
  signal usb_dout    : data_t;
  signal uart_rx_data  : data_t;
  signal uart_rx_valid : std_logic;

  -- PS/2 -> UART injection
  signal kbd_ascii_i     : data_t := (others => '0');
  signal kbd_event_tog_i : std_logic := '0';
  signal kbd_event_prev  : std_logic := '0';
  signal kbd_inject      : std_logic := '0';
  signal merged_rx_data      : data_t;
  signal merged_rx_valid     : std_logic;
  signal merged_rx_valid_cpu : std_logic;
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
      -- One-cycle-delayed copy of the steal flag. The VRAM/bitmap RAMs are
      -- single-port with one cycle of read latency, so after a steal ends the
      -- RAM still presents the VIC's address for one more cycle. Holding the CPU
      -- stalled that extra cycle prevents it from latching the VIC's fetched byte
      -- (e.g. a colour value $01) as its own VRAM read — the bug that scrolled
      -- stray 'A' characters onto the screen. Proven by tb_vram_read_steal.
      vic_stealing_d <= vic_stealing;
    end if;
  end process;

  cpu_bus_we <= cpu_we and not cpu_enable;
  cpu_rdy    <= not vic_stealing and not vic_stealing_d and
                not vram_wr_pending and not bitmap_wr_pending and not monitor_hold;
  cpu_irq_n  <= not (via_irq or uart_irq or usb_irq);
  usb_cs     <= '1' when monitor_hold = '0' and dev_sel = DEV_USB else '0';

  zp_cs   <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 9) = "0000000" else '0';
  zp_we   <= cpu_bus_we when monitor_hold = '0' and zp_cs = '1' else '0';
  sram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_TEXT else '0';
  vic_reg_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_REG else '0';
  via_cs  <= '1'        when monitor_hold = '0' and dev_sel = DEV_VIA      else '0';
  uart_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_UART     else '0';

  -- Per-voice chip-selects, shared write strobe, and the register offset for
  -- whichever voice is currently addressed (cpu_addr - voice base).
  sound_cs(0) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND0 else '0';
  sound_cs(1) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND1 else '0';
  sound_cs(2) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND2 else '0';
  sound_cs(3) <= '1' when monitor_hold = '0' and dev_sel = DEV_SOUND3 else '0';
  sound_we    <= cpu_bus_we when monitor_hold = '0' else '0';

  sound_addr <=
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND0_BASE, 4)) when dev_sel = DEV_SOUND0 else
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND1_BASE, 4)) when dev_sel = DEV_SOUND1 else
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND2_BASE, 4)) when dev_sel = DEV_SOUND2 else
    std_logic_vector(resize(unsigned(cpu_addr) - ADDR_SOUND3_BASE, 4)) when dev_sel = DEV_SOUND3 else
    (others => '0');

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

  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1' and vic_fetch_bitmap = '0' else cpu_addr(10 downto 0);
  vram_addr_mux <= mon_addr_lat(10 downto 0) when monitor_hold = '1' and
                   (mon_mem_state = M_VRAM_RD_WAIT or mon_mem_state = M_VRAM_RD_READY or
                    mon_mem_state = M_VRAM_WR_WAIT) else
                   vram_wr_addr when vram_wr_pending = '1' and vic_stealing = '0' else
                   vram_addr;
  vram_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT and mon_we_lat = '1' else
                 '1' when vram_wr_pending = '1' and vic_stealing = '0' else
                 '0' when vic_stealing = '1' else vram_we;

  -- Bitmap RAM bus mux with deferred-write latch (mirrors VRAM mechanism):
  -- a CPU bitmap write that collides with a VIC steal is held in
  -- bitmap_wr_* and committed on the next non-steal cycle. The CPU is kept
  -- stalled via cpu_rdy until the deferred write completes, so no POKE is lost.
  bitmap_cpu_we <= cpu_bus_we when dev_sel = DEV_VIC_BMP else '0';

  bitmap_addr <= std_logic_vector(resize(unsigned(vic_addr) - x"9010", 13))
                 when vic_stealing = '1' and vic_fetch_bitmap = '1' else
                 bitmap_wr_addr when bitmap_wr_pending = '1' and vic_stealing = '0' else
                 std_logic_vector(resize(unsigned(cpu_addr) - x"9010", 13));
  bitmap_we   <= '1' when bitmap_wr_pending = '1' and vic_stealing = '0' else
                 '0' when vic_stealing = '1' else bitmap_cpu_we;
  bitmap_din_mux <= bitmap_wr_data when bitmap_wr_pending = '1' and vic_stealing = '0'
                    else cpu_dout;

  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' or monitor_hold = '1' then
        bitmap_wr_pending <= '0';
        bitmap_wr_addr    <= (others => '0');
        bitmap_wr_data    <= (others => '0');
      elsif bitmap_wr_pending = '1' and vic_stealing = '0' then
        bitmap_wr_pending <= '0';
      elsif bitmap_cpu_we = '1' and vic_stealing = '1' then
        bitmap_wr_pending <= '1';
        bitmap_wr_addr    <= std_logic_vector(resize(unsigned(cpu_addr) - x"9010", 13));
        bitmap_wr_data    <= cpu_dout;
      end if;
    end if;
  end process;

  -- VIC data mux: select bitmap or VRAM data (registered to match sync RAM latency)
  process(clk)
  begin
    if rising_edge(clk) then
      vram_data_sel <= vic_fetch_bitmap;
    end if;
  end process;
  vram_data_mux <= bitmap_dout when vram_data_sel = '1' else vram_dout;

  vram_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT else
                  vram_wr_data when vram_wr_pending = '1' and vic_stealing = '0' else
                  cpu_dout;

  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' or monitor_hold = '1' then
        vram_wr_pending <= '0';
        vram_wr_addr    <= (others => '0');
        vram_wr_data    <= (others => '0');
      elsif vram_wr_pending = '1' and vic_stealing = '0' then
        -- Commit the deferred write through vram_*_mux on this edge.
        vram_wr_pending <= '0';
      elsif vram_we = '1' and vic_stealing = '1' then
        -- A CPU write pulse would otherwise be masked while the VIC owns VRAM.
        vram_wr_pending <= '1';
        vram_wr_addr    <= cpu_addr(10 downto 0);
        vram_wr_data    <= cpu_dout;
      end if;
    end if;
  end process;

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
  merged_rx_valid_cpu <= merged_rx_valid when monitor_hold = '0' else '0';

  process(dev_sel, zp_cs, zp_dout, sram_dout, rom_dout, vram_dout, vic_reg_dout, via_dout,
          uart_dout, mon_jump_vector_active, mon_jump_vector, cpu_addr, bitmap_dout,
          sound_dout)
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
      when DEV_VIC_BMP =>
        cpu_din <= bitmap_dout;
      when DEV_SOUND0 | DEV_SOUND1 | DEV_SOUND2 | DEV_SOUND3 =>
        cpu_din <= sound_dout;
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
          when x"0" =>
            vic_mode_reg <= cpu_dout;
          when x"1" =>
            if unsigned(cpu_dout(5 downto 0)) < to_unsigned(40, 6) then
              vic_cursor_x <= cpu_dout(5 downto 0);
            end if;
          when x"2" =>
            if unsigned(cpu_dout(4 downto 0)) < to_unsigned(25, 5) then
              vic_cursor_y <= cpu_dout(4 downto 0);
            end if;
          when x"3" =>
            vic_text_color <= cpu_dout;
          when x"4" =>
            vic_bg_color <= cpu_dout;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  process(cpu_addr, vic_cursor_x, vic_cursor_y, vic_text_color, vic_bg_color, vic_mode_reg)
  begin
    case cpu_addr(3 downto 0) is
      when x"0" =>
        vic_reg_dout <= vic_mode_reg;
      when x"1" =>
        vic_reg_dout <= "00" & vic_cursor_x;
      when x"2" =>
        vic_reg_dout <= "000" & vic_cursor_y;
      when x"3" =>
        vic_reg_dout <= vic_text_color;
      when x"4" =>
        vic_reg_dout <= vic_bg_color;
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

  bitmap_ram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 13, ASYNC_READ => false)
    port map (clk => clk, we => bitmap_we,
              addr => bitmap_addr, din => bitmap_din_mux, dout => bitmap_dout);

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

  -- ── Sound: 4-voice synth (ADSR + 5 waveforms) + PT8211 DAC ────────────
  sound_i : entity work.sound_chip4
    generic map (CLK_HZ => CLK_HZ)
    port map (
      clk        => clk,
      reset_n    => cpu_reset_n,
      cs         => sound_cs,
      we         => sound_we,
      addr       => sound_addr,
      din        => cpu_dout,
      dout       => sound_dout,
      sample_out => sound_sample,
      active     => open
    );

  dac_i : entity work.pt8211_dac
    port map (
      clk     => clk,
      reset_n => cpu_reset_n,
      sample  => sound_sample,
      dac_bck => dac_bck,
      dac_ws  => dac_ws,
      dac_din => dac_din
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
      rx_data  => merged_rx_data,
      rx_valid => merged_rx_valid_cpu,
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

  -- PS/2 keyboard -> UART injection: detect new keypress and inject ASCII
  process(clk)
  begin
    if rising_edge(clk) then
      kbd_inject    <= '0';
      kbd_event_prev <= kbd_event_tog_i;
      if reset_n = '0' then
        kbd_event_prev <= '0';
      elsif kbd_event_tog_i /= kbd_event_prev and kbd_ascii_i /= x"00" then
        kbd_inject <= '1';
      end if;
    end if;
  end process;

  merged_rx_data  <= kbd_ascii_i when kbd_inject = '1' else uart_rx_data;
  merged_rx_valid <= kbd_inject or uart_rx_valid;

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

  ps2_kbd_i : entity work.ps2_keyboard
    generic map (
      CLK_HZ => CLK_HZ
    )
    port map (
      clk            => clk,
      reset_n        => reset_n,
      ps2_clk        => ps2_clk,
      ps2_data       => ps2_data,
      cs             => usb_cs,
      we             => cpu_bus_we,
      addr           => cpu_addr(1 downto 0),
      dout           => usb_dout,
      irq            => usb_irq,
      diag_connected => usb_connected,
      diag_keycode   => usb_keycode,
      diag_modif     => usb_modif,
      diag_ascii     => kbd_ascii_i,
      diag_phase     => usb_phase,
      diag_key_event => kbd_event_tog_i,
      diag_polling   => usb_polling
    );

  usb_ascii     <= kbd_ascii_i;
  usb_key_event <= kbd_event_tog_i;

  -- Bus-capture feature removed (was ULPI-specific); tie off outputs.
  usb_cap_data  <= (others => '0');
  usb_cap_ready <= '0';

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
      vram_data    => vram_data_mux,
      vic_stealing => vic_stealing,
      char_addr    => char_addr,
      char_data    => char_data,
      cursor_x     => vic_cursor_x,
      cursor_y     => vic_cursor_y,
      cursor_enable => '1',
      bitmap_mode      => vic_mode_reg(0),
      vic_fetch_bitmap => vic_fetch_bitmap,
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
