-- T65 SBC core with board SDRAM for main RAM and SD-loaded shadow ROM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_t65_sdram_boot_top is
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
    ram_test_active : out std_logic;
    ram_test_done   : out std_logic;
    ram_test_error  : out std_logic;
    ram_test_phase  : out std_logic_vector(3 downto 0);
    ram_test_addr   : out std_logic_vector(14 downto 0);
    ram_test_fail_addr : out std_logic_vector(14 downto 0);
    ram_test_expected  : out data_t;
    ram_test_actual    : out data_t;

    rom_load_we   : in  std_logic;
    rom_load_addr : in  std_logic_vector(13 downto 0);
    rom_load_data : in  data_t;

    vga_r       : out std_logic_vector(4 downto 0);
    vga_g       : out std_logic_vector(5 downto 0);
    vga_b       : out std_logic_vector(4 downto 0);
    vga_hs      : out std_logic;
    vga_vs      : out std_logic;

    uart_rx       : in  std_logic;
    uart_tx_data  : out data_t;
    uart_tx_valid : out std_logic;
    uart_tx_busy  : in  std_logic := '0';

    sdram_cke   : out   std_logic;
    sdram_cs_n  : out   std_logic;
    sdram_ras_n : out   std_logic;
    sdram_cas_n : out   std_logic;
    sdram_we_n  : out   std_logic;
    sdram_ba    : out   std_logic_vector(1 downto 0);
    sdram_addr  : out   std_logic_vector(12 downto 0);
    sdram_dqm   : out   std_logic_vector(1 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0);

    via_portb   : out data_t;

    dbg_cpu_addr : out addr_t;
    dbg_cpu_data : out data_t;
    dbg_cpu_din  : out data_t;
    dbg_cpu_we   : out std_logic;
    dbg_cpu_sync : out std_logic
  );
end entity;

architecture rtl of sbc_t65_sdram_boot_top is
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
  signal dev_sel     : device_sel_t;

  signal zp_dout     : data_t;
  signal sdram_dout  : data_t;
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
  signal rom_addr_mux : std_logic_vector(13 downto 0);
  signal rom_load_we_mux   : std_logic;
  signal rom_load_addr_mux : std_logic_vector(13 downto 0);
  signal rom_load_data_mux : data_t;
  signal sdram_cs    : std_logic;
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
  signal vic_cursor_x : std_logic_vector(5 downto 0) := (others => '0');
  signal vic_cursor_y : std_logic_vector(4 downto 0) := (others => '0');
  signal vic_text_color : data_t := x"01";
  signal vic_bg_color   : data_t := x"00";

  signal sdram_rdy       : std_logic;
  signal sdram_rst       : std_logic;
  signal sdram_ctrl_idle : std_logic;

  signal wr_burst_req      : std_logic;
  signal wr_burst_data     : std_logic_vector(15 downto 0);
  signal wr_burst_len      : std_logic_vector(9 downto 0);
  signal wr_burst_addr     : std_logic_vector(23 downto 0);
  signal wr_dqm            : std_logic_vector(1 downto 0);
  signal wr_burst_data_req : std_logic;
  signal wr_burst_finish   : std_logic;
  signal rd_burst_req      : std_logic;
  signal rd_burst_len      : std_logic_vector(9 downto 0);
  signal rd_burst_addr     : std_logic_vector(23 downto 0);
  signal rd_burst_data     : std_logic_vector(15 downto 0);
  signal rd_burst_data_valid : std_logic;
  signal rd_burst_finish   : std_logic;

  signal ctrl_wr_burst_req      : std_logic;
  signal ctrl_wr_burst_data     : std_logic_vector(15 downto 0);
  signal ctrl_wr_burst_len      : std_logic_vector(9 downto 0);
  signal ctrl_wr_burst_addr     : std_logic_vector(23 downto 0);
  signal ctrl_wr_dqm            : std_logic_vector(1 downto 0);
  signal ctrl_rd_burst_req      : std_logic;
  signal ctrl_rd_burst_len      : std_logic_vector(9 downto 0);
  signal ctrl_rd_burst_addr     : std_logic_vector(23 downto 0);

  signal test_wr_burst_req      : std_logic;
  signal test_wr_burst_data     : std_logic_vector(15 downto 0);
  signal test_wr_burst_len      : std_logic_vector(9 downto 0);
  signal test_wr_burst_addr     : std_logic_vector(23 downto 0);
  signal test_wr_dqm            : std_logic_vector(1 downto 0);
  signal test_rd_burst_req      : std_logic;
  signal test_rd_burst_len      : std_logic_vector(9 downto 0);
  signal test_rd_burst_addr     : std_logic_vector(23 downto 0);
  signal ram_test_active_i      : std_logic;
  signal ram_test_done_i        : std_logic;
  signal ram_test_error_i       : std_logic;

  type mon_mem_state_t is (
    M_IDLE, M_ZP_WAIT, M_ZP_READY,
    M_ROM_RD_WAIT, M_ROM_RD_READY, M_ROM_WR_WAIT,
    M_VRAM_RD_WAIT, M_VRAM_RD_READY, M_VRAM_WR_WAIT,
    M_VIA_WAIT, M_VIA_READY,
    M_UART_WAIT, M_UART_READY,
    M_SDR_WR_REQ, M_SDR_WR_WAIT,
    M_SDR_RD_REQ, M_SDR_RD_WAIT,
    M_READY
  );
  signal mon_mem_state       : mon_mem_state_t := M_IDLE;
  signal mon_addr_lat        : addr_t := (others => '0');
  signal mon_wdata_lat       : data_t := (others => '0');
  signal mon_we_lat          : std_logic := '0';
  signal mon_rdata_reg       : data_t := (others => '0');
  signal mon_ready_reg       : std_logic := '0';
  signal mon_ctrl_active     : std_logic := '0';
  signal mon_wr_burst_req    : std_logic := '0';
  signal mon_wr_burst_data   : std_logic_vector(15 downto 0) := (others => '0');
  signal mon_wr_burst_addr   : std_logic_vector(23 downto 0) := (others => '0');
  signal mon_rd_burst_req    : std_logic := '0';
  signal mon_rd_burst_addr   : std_logic_vector(23 downto 0) := (others => '0');

  signal char_addr   : std_logic_vector(9 downto 0);
  signal char_data   : data_t;

  signal via_irq     : std_logic;
  signal uart_irq    : std_logic;
  signal uart_rx_data  : data_t;
  signal uart_rx_valid : std_logic;
  signal uart_rx_valid_cpu : std_logic;
  signal mon_jump_vector        : addr_t := (others => '0');
  signal mon_jump_reset_cnt     : natural range 0 to 31 := 0;
  signal mon_jump_vector_active : std_logic := '0';
begin
  cpu_reset_base_n <= reset_n and boot_done and ram_test_done_i and not ram_test_error_i;
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
  cpu_rdy    <= sdram_rdy and not vic_stealing and not vram_wr_pending and not monitor_hold;
  cpu_irq_n  <= not (via_irq or uart_irq);
  sdram_rst  <= not reset_n;

  zp_cs    <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 9) = "0000000" else '0';
  zp_we    <= cpu_bus_we when zp_cs = '1' else '0';
  -- Monitor muxes: while monitor_hold is asserted the CPU is stopped and the
  -- UART monitor becomes a one-byte bus master. Each target keeps the minimum
  -- latency it needs: BRAM-like blocks wait one cycle, VIA/UART get a selected
  -- register cycle, and SDRAM goes through the byte bridge below.
  zp_we_mux   <= '1' when monitor_hold = '1' and mon_mem_state = M_ZP_WAIT and mon_we_lat = '1' else
                 zp_we when monitor_hold = '0' else '0';
  zp_addr_mux <= mon_addr_lat(8 downto 0) when monitor_hold = '1' else cpu_addr(8 downto 0);
  zp_din_mux  <= mon_wdata_lat when monitor_hold = '1' else cpu_dout;
  rom_addr_mux <= mon_addr_lat(13 downto 0) when monitor_hold = '1' and
                  (mon_mem_state = M_ROM_RD_WAIT or mon_mem_state = M_ROM_RD_READY) else
                  cpu_addr(13 downto 0);
  rom_load_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT and mon_we_lat = '1' else
                     rom_load_we;
  rom_load_addr_mux <= mon_addr_lat(13 downto 0) when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT else
                       rom_load_addr;
  rom_load_data_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_ROM_WR_WAIT else
                       rom_load_data;
  sdram_cs <= '1'        when monitor_hold = '0' and dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we  <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_TEXT else '0';
  vic_reg_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_REG else '0';
  via_cs   <= '1'        when monitor_hold = '0' and dev_sel = DEV_VIA      else '0';
  uart_cs  <= '1'        when monitor_hold = '0' and dev_sel = DEV_UART     else '0';

  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1'
                 else cpu_addr(10 downto 0);
  vram_addr_mux <= mon_addr_lat(10 downto 0) when monitor_hold = '1' and
                   (mon_mem_state = M_VRAM_RD_WAIT or mon_mem_state = M_VRAM_RD_READY or
                    mon_mem_state = M_VRAM_WR_WAIT) else
                   vram_wr_addr when vram_wr_pending = '1' and vic_stealing = '0' else
                   vram_addr;
  vram_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VRAM_WR_WAIT and mon_we_lat = '1' else
                 '1' when vram_wr_pending = '1' and vic_stealing = '0' else
                 '0' when vic_stealing = '1' else vram_we;
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
                 (mon_mem_state = M_VIA_READY and mon_we_lat = '0')) else
                via_cs;
  via_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_VIA_WAIT and mon_we_lat = '1' else
                cpu_bus_we;
  via_addr_mux <= mon_addr_lat when monitor_hold = '1' and
                  (mon_mem_state = M_VIA_WAIT or mon_mem_state = M_VIA_READY) else
                  cpu_addr;
  via_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_VIA_WAIT else
                 cpu_dout;

  uart_cs_mux <= '1' when monitor_hold = '1' and
                 (mon_mem_state = M_UART_WAIT or
                  (mon_mem_state = M_UART_READY and mon_we_lat = '0')) else
                 uart_cs;
  uart_we_mux <= '1' when monitor_hold = '1' and mon_mem_state = M_UART_WAIT and mon_we_lat = '1' else
                 cpu_bus_we;
  uart_addr_mux <= mon_addr_lat when monitor_hold = '1' and
                   (mon_mem_state = M_UART_WAIT or mon_mem_state = M_UART_READY) else
                   cpu_addr;
  uart_din_mux <= mon_wdata_lat when monitor_hold = '1' and mon_mem_state = M_UART_WAIT else
                  cpu_dout;

  ctrl_wr_burst_req  <= test_wr_burst_req  when ram_test_active_i = '1' else
                        mon_wr_burst_req   when mon_ctrl_active = '1' else wr_burst_req;
  ctrl_wr_burst_data <= test_wr_burst_data when ram_test_active_i = '1' else
                        mon_wr_burst_data  when mon_ctrl_active = '1' else wr_burst_data;
  ctrl_wr_burst_len  <= test_wr_burst_len  when ram_test_active_i = '1' else
                        std_logic_vector(to_unsigned(1, 10)) when mon_ctrl_active = '1' else wr_burst_len;
  ctrl_wr_burst_addr <= test_wr_burst_addr when ram_test_active_i = '1' else
                        mon_wr_burst_addr  when mon_ctrl_active = '1' else wr_burst_addr;
  ctrl_wr_dqm        <= test_wr_dqm        when ram_test_active_i = '1' else
                        "10"              when mon_ctrl_active = '1' else wr_dqm;
  ctrl_rd_burst_req  <= test_rd_burst_req  when ram_test_active_i = '1' else
                        mon_rd_burst_req   when mon_ctrl_active = '1' else rd_burst_req;
  ctrl_rd_burst_len  <= test_rd_burst_len  when ram_test_active_i = '1' else
                        std_logic_vector(to_unsigned(1, 10)) when mon_ctrl_active = '1' else rd_burst_len;
  ctrl_rd_burst_addr <= test_rd_burst_addr when ram_test_active_i = '1' else
                        mon_rd_burst_addr  when mon_ctrl_active = '1' else rd_burst_addr;

  monitor_mem_rdata <= mon_rdata_reg;
  monitor_mem_ready <= mon_ready_reg;
  uart_rx_valid_cpu <= uart_rx_valid when monitor_hold = '0' else '0';

  process(dev_sel, zp_cs, zp_dout, sdram_dout, rom_dout, vram_dout, vic_reg_dout, via_dout,
          uart_dout, mon_jump_vector_active, mon_jump_vector, cpu_addr)
  begin
    case dev_sel is
      when DEV_SRAM =>
        if zp_cs = '1' then
          cpu_din <= zp_dout;
        else
          cpu_din <= sdram_dout;
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

  process(cpu_addr, vic_cursor_x, vic_cursor_y, vic_text_color, vic_bg_color)
  begin
    case cpu_addr(3 downto 0) is
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

  sdram_if_i : entity work.sdram_if
    port map (
      clk        => clk,
      reset_n    => cpu_reset_n,
      addr       => cpu_addr(14 downto 0),
      din        => cpu_dout,
      dout       => sdram_dout,
      cs         => sdram_cs,
      cpu_we     => cpu_we,
      cpu_bus_we => cpu_bus_we,
      rdy        => sdram_rdy,
      ctrl_idle  => sdram_ctrl_idle,
      wr_burst_req       => wr_burst_req,
      wr_burst_data      => wr_burst_data,
      wr_burst_len       => wr_burst_len,
      wr_burst_addr      => wr_burst_addr,
      wr_dqm             => wr_dqm,
      wr_burst_data_req  => wr_burst_data_req,
      wr_burst_finish    => wr_burst_finish,
      rd_burst_req       => rd_burst_req,
      rd_burst_len       => rd_burst_len,
      rd_burst_addr      => rd_burst_addr,
      rd_burst_data      => rd_burst_data,
      rd_burst_data_valid=> rd_burst_data_valid,
      rd_burst_finish    => rd_burst_finish
    );

  ram_test_i : entity work.boot_sdram_test
    generic map (
      START_ADDR => 16#0200#,
      END_ADDR   => 16#7FFF#
    )
    port map (
      clk                 => clk,
      reset_n             => reset_n,
      start               => boot_done,
      ctrl_idle           => sdram_ctrl_idle,
      wr_burst_req        => test_wr_burst_req,
      wr_burst_data       => test_wr_burst_data,
      wr_burst_len        => test_wr_burst_len,
      wr_burst_addr       => test_wr_burst_addr,
      wr_dqm              => test_wr_dqm,
      wr_burst_data_req   => wr_burst_data_req,
      wr_burst_finish     => wr_burst_finish,
      rd_burst_req        => test_rd_burst_req,
      rd_burst_len        => test_rd_burst_len,
      rd_burst_addr       => test_rd_burst_addr,
      rd_burst_data       => rd_burst_data,
      rd_burst_data_valid => rd_burst_data_valid,
      rd_burst_finish     => rd_burst_finish,
      active              => ram_test_active_i,
      done                => ram_test_done_i,
      error               => ram_test_error_i,
      phase               => ram_test_phase,
      progress_addr       => ram_test_addr,
      fail_addr           => ram_test_fail_addr,
      expected            => ram_test_expected,
      actual              => ram_test_actual
    );

  sdram_ctrl_i : entity work.sdram_ctrl
    port map (
      clk               => clk,
      rst               => sdram_rst,
      wr_burst_req      => ctrl_wr_burst_req,
      wr_burst_data     => ctrl_wr_burst_data,
      wr_burst_len      => ctrl_wr_burst_len,
      wr_burst_addr     => ctrl_wr_burst_addr,
      wr_dqm            => ctrl_wr_dqm,
      wr_burst_data_req => wr_burst_data_req,
      wr_burst_finish   => wr_burst_finish,
      rd_burst_req      => ctrl_rd_burst_req,
      rd_burst_len      => ctrl_rd_burst_len,
      rd_burst_addr     => ctrl_rd_burst_addr,
      rd_burst_data     => rd_burst_data,
      rd_burst_data_valid => rd_burst_data_valid,
      rd_burst_finish   => rd_burst_finish,
      sdram_cke         => sdram_cke,
      sdram_cs_n        => sdram_cs_n,
      sdram_ras_n       => sdram_ras_n,
      sdram_cas_n       => sdram_cas_n,
      sdram_we_n        => sdram_we_n,
      sdram_ba          => sdram_ba,
      sdram_addr        => sdram_addr,
      sdram_dqm         => sdram_dqm,
      sdram_dq          => sdram_dq,
      ctrl_idle         => sdram_ctrl_idle
    );

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        mon_mem_state     <= M_IDLE;
        mon_addr_lat      <= (others => '0');
        mon_wdata_lat     <= (others => '0');
        mon_we_lat        <= '0';
        mon_rdata_reg     <= (others => '0');
        mon_ready_reg     <= '0';
        mon_ctrl_active   <= '0';
        mon_wr_burst_req  <= '0';
        mon_wr_burst_data <= (others => '0');
        mon_wr_burst_addr <= (others => '0');
        mon_rd_burst_req  <= '0';
        mon_rd_burst_addr <= (others => '0');
      else
        mon_ready_reg    <= '0';
        mon_wr_burst_req <= '0';
        mon_rd_burst_req <= '0';

        -- Decode one monitor memory transaction into the same physical targets
        -- the CPU uses. This keeps the monitor view honest: VRAM edits update
        -- VGA immediately, VIA writes drive LEDs, and ROM writes patch the
        -- loaded shadow-ROM image.
        case mon_mem_state is
          when M_IDLE =>
            mon_ctrl_active <= '0';
            if monitor_hold = '1' and monitor_mem_req = '1' then
              mon_addr_lat  <= monitor_mem_addr;
              mon_wdata_lat <= monitor_mem_wdata;
              mon_we_lat    <= monitor_mem_we;
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
                mon_wr_burst_data <= x"00" & monitor_mem_wdata;
                mon_wr_burst_addr <= "000000000" & monitor_mem_addr(14 downto 0);
                mon_mem_state     <= M_SDR_WR_REQ;
              else
                mon_rd_burst_addr <= "000000000" & monitor_mem_addr(14 downto 0);
                mon_mem_state    <= M_SDR_RD_REQ;
              end if;
            end if;

          when M_ZP_WAIT =>
            mon_mem_state <= M_ZP_READY;

          when M_ZP_READY =>
            mon_rdata_reg <= zp_dout;
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

          when M_SDR_WR_REQ =>
            if sdram_ctrl_idle = '1' and sdram_rdy = '1' then
              mon_ctrl_active  <= '1';
              mon_wr_burst_req <= '1';
              if wr_burst_data_req = '1' then
                mon_mem_state <= M_SDR_WR_WAIT;
              end if;
            end if;

          when M_SDR_WR_WAIT =>
            mon_ctrl_active <= '1';
            if sdram_ctrl_idle = '1' then
              mon_mem_state <= M_READY;
            end if;

          when M_SDR_RD_REQ =>
            if sdram_ctrl_idle = '1' and sdram_rdy = '1' then
              mon_ctrl_active <= '1';
              mon_rd_burst_req <= '1';
              if rd_burst_data_valid = '1' then
                mon_rdata_reg <= rd_burst_data(7 downto 0);
                mon_mem_state <= M_SDR_RD_WAIT;
              end if;
            end if;

          when M_SDR_RD_WAIT =>
            mon_ctrl_active <= '1';
            if sdram_ctrl_idle = '1' then
              mon_mem_state <= M_READY;
            end if;

          when M_READY =>
            mon_ready_reg <= '1';
            mon_ctrl_active <= '0';
            mon_mem_state <= M_IDLE;

          when others =>
            mon_mem_state <= M_IDLE;
        end case;
      end if;
    end if;
  end process;

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
    port map (
      clk     => clk,
      reset_n => cpu_reset_n,
      rx      => uart_rx,
      data    => uart_rx_data,
      valid   => uart_rx_valid
    );

  char_i : entity work.char_rom
    port map (addr => char_addr, dout => char_data);

  vic_i : entity work.vic_vga
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
      vga_de       => open,
      vga_r        => vga_r,
      vga_g        => vga_g,
      vga_b        => vga_b
    );

  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_din  <= cpu_din;
  dbg_cpu_we   <= cpu_bus_we;
  dbg_cpu_sync <= cpu_sync;
  ram_test_active <= ram_test_active_i;
  ram_test_done   <= ram_test_done_i;
  ram_test_error  <= ram_test_error_i;
end architecture;
