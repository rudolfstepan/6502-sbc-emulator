-- T65 SBC core with a boot-loaded 16 KB shadow ROM at $C000-$FFFF.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_t65_boot_top is
  port (
    clk          : in  std_logic;
    reset_n      : in  std_logic;
    boot_done    : in  std_logic;

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

    via_portb   : out data_t;

    dbg_cpu_addr : out addr_t;
    dbg_cpu_data : out data_t;
    dbg_cpu_din  : out data_t;
    dbg_cpu_we   : out std_logic;
    dbg_cpu_sync : out std_logic
  );
end entity;

architecture rtl of sbc_t65_boot_top is
  signal cpu_reset_n : std_logic;
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
  signal sram_dout   : data_t;
  signal rom_dout    : data_t;
  signal vram_dout   : data_t;
  signal vic_reg_dout : data_t;
  signal via_dout    : data_t;
  signal uart_dout   : data_t;

  signal zp_cs       : std_logic;
  signal zp_we       : std_logic;
  signal sram_we     : std_logic;
  signal vram_we     : std_logic;
  signal vram_we_mux : std_logic;
  signal vic_reg_we  : std_logic;
  signal via_cs      : std_logic;
  signal uart_cs     : std_logic;

  signal vram_addr   : std_logic_vector(10 downto 0);
  signal vic_addr    : addr_t;
  signal vic_stealing : std_logic;
  signal vic_cursor_x : std_logic_vector(5 downto 0) := (others => '0');
  signal vic_cursor_y : std_logic_vector(4 downto 0) := (others => '0');

  signal char_addr   : std_logic_vector(9 downto 0);
  signal char_data   : data_t;

  signal via_irq     : std_logic;
  signal uart_irq    : std_logic;
  signal uart_rx_data  : data_t;
  signal uart_rx_valid : std_logic;
begin
  cpu_reset_n <= reset_n and boot_done;

  process(clk)
  begin
    if rising_edge(clk) then
      if cpu_reset_n = '0' then
        cpu_enable <= '0';
      else
        cpu_enable <= not cpu_enable;
      end if;
    end if;
  end process;

  cpu_bus_we <= cpu_we and not cpu_enable;
  cpu_rdy    <= not vic_stealing;
  cpu_irq_n  <= not (via_irq or uart_irq);

  zp_cs   <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 9) = "0000000" else '0';
  zp_we   <= cpu_bus_we when zp_cs = '1' else '0';
  sram_we <= cpu_bus_we when dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we <= cpu_bus_we when dev_sel = DEV_VIC_TEXT else '0';
  vic_reg_we <= cpu_bus_we when dev_sel = DEV_VIC_REG else '0';
  via_cs  <= '1'        when dev_sel = DEV_VIA      else '0';
  uart_cs <= '1'        when dev_sel = DEV_UART     else '0';

  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1'
                 else cpu_addr(10 downto 0);
  vram_we_mux <= '0' when vic_stealing = '1' else vram_we;

  process(dev_sel, zp_cs, zp_dout, sram_dout, rom_dout, vram_dout, vic_reg_dout, via_dout, uart_dout)
  begin
    case dev_sel is
      when DEV_SRAM =>
        if zp_cs = '1' then
          cpu_din <= zp_dout;
        else
          cpu_din <= sram_dout;
        end if;
      when DEV_ROM =>
        cpu_din <= rom_dout;
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
    port map (clk => clk, we => zp_we,
              addr => cpu_addr(8 downto 0), din => cpu_dout, dout => zp_dout);

  sram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 15, ASYNC_READ => false)
    port map (clk => clk, we => sram_we,
              addr => cpu_addr(14 downto 0), din => cpu_dout, dout => sram_dout);

  rom_i : entity work.boot_shadow_rom
    generic map (ADDR_WIDTH => 14)
    port map (
      clk       => clk,
      cpu_addr  => cpu_addr(13 downto 0),
      cpu_dout  => rom_dout,
      load_we   => rom_load_we,
      load_addr => rom_load_addr,
      load_data => rom_load_data
    );

  vram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 11, ASYNC_READ => false)
    port map (clk => clk, we => vram_we_mux,
              addr => vram_addr, din => cpu_dout, dout => vram_dout);

  via_i : entity work.via6522
    port map (
      clk       => clk,
      reset_n   => cpu_reset_n,
      cs        => via_cs,
      we        => cpu_bus_we,
      addr      => cpu_addr,
      din       => cpu_dout,
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
      cs       => uart_cs,
      we       => cpu_bus_we,
      addr     => cpu_addr,
      din      => cpu_dout,
      dout     => uart_dout,
      rx_data  => uart_rx_data,
      rx_valid => uart_rx_valid,
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
      reset_n      => cpu_reset_n,
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
end architecture;
