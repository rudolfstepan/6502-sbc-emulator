-- Minimales SBC Top-Level: T65 CPU + RAM + VRAM + ROM + VIC + VIA + UART
--
-- Speicherkarte:
--   $0000-$01FF  512 B FPGA-RAM (Zero Page + Stack)
--   $0200-$0FFF  CPU-SRAM
--   $8000-$87FF  2 KB VRAM      (single-port, geteilt zwischen CPU und VIC)
--   $8800-$880F  VIA 6522       (Timer 1 -> IRQ, Port B)
--   $8810-$8813  UART 6551      (TX)
--   $F800-$FFFF  2 KB ROM       (Kernel, Reset-Vektor)
--
-- Bus-Sharing (C64-Prinzip):
--   VIC stiehlt 40 System-Takte pro H-Blank vom CPU-Bus (RDY-Pin).
--   CPU-Overhead: ~2.5% der Gesamttakte.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_minimal_top is
  generic (
    ROM_INIT_FILE : string  := "";
    CLK_DIV       : natural := 2   -- vic_vga pixel-clock divisor (2=50 MHz, 1=27 MHz)
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    -- VGA output (from VIC)
    vga_r    : out std_logic_vector(4 downto 0);
    vga_g    : out std_logic_vector(5 downto 0);
    vga_b    : out std_logic_vector(4 downto 0);
    vga_hs   : out std_logic;
    vga_vs   : out std_logic;
    vga_de   : out std_logic;   -- data enable: '1' during active video

    -- VIA Port B output (exposed for board LEDs etc.)
    via_portb : out data_t;

    -- UART (serial keyboard in / echo out)
    uart_rx       : in  std_logic;
    uart_tx_data  : out data_t;
    uart_tx_valid : out std_logic;
    uart_tx_busy  : in  std_logic := '0';  -- from uart_tx_ser.busy

    -- Debug bus
    dbg_cpu_addr : out addr_t;
    dbg_cpu_data : out data_t;
    dbg_cpu_din  : out data_t;
    dbg_cpu_we   : out std_logic;
    dbg_cpu_sync : out std_logic
  );
end entity;

architecture rtl of sbc_minimal_top is
  -- CPU bus
  signal cpu_addr   : addr_t   := (others => '0');
  signal cpu_dout   : data_t   := (others => '0');
  signal cpu_din    : data_t   := (others => '0');
  signal cpu_we     : std_logic := '0';
  signal cpu_sync   : std_logic := '0';
  signal cpu_enable : std_logic := '0';
  signal cpu_bus_we : std_logic := '0';
  signal cpu_rdy    : std_logic := '1';
  signal cpu_irq_n  : std_logic := '1';

  signal dev_sel : device_sel_t;

  -- Memory outputs
  signal zp_dout   : data_t;
  signal sram_dout : data_t;
  signal vram_dout : data_t;
  signal rom_dout  : data_t;
  signal via_dout  : data_t;
  signal uart_dout : data_t;

  -- Write enables
  signal zp_cs      : std_logic;
  signal zp_we      : std_logic;
  signal sram_we    : std_logic;
  signal vram_we    : std_logic;
  signal vram_we_mux : std_logic;
  signal via_cs     : std_logic;
  signal uart_cs    : std_logic;

  -- VRAM bus mux
  signal vram_addr : std_logic_vector(10 downto 0);

  -- VIC bus steal
  signal vic_addr     : addr_t;
  signal vic_stealing : std_logic;

  -- Char ROM
  signal char_addr : std_logic_vector(9 downto 0);
  signal char_data : data_t;

  -- IRQs
  signal via_irq  : std_logic;
  signal uart_irq : std_logic;

  -- UART RX
  signal uart_rx_data  : data_t;
  signal uart_rx_valid : std_logic;

begin
  -- T65 div-2 clock enable
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cpu_enable <= '0';
      else
        cpu_enable <= not cpu_enable;
      end if;
    end if;
  end process;

  cpu_bus_we <= cpu_we and not cpu_enable;
  cpu_rdy    <= not vic_stealing;
  cpu_irq_n  <= not (via_irq or uart_irq);

  -- Fast internal RAM for 6502 Zero Page ($0000-$00FF) and stack ($0100-$01FF).
  zp_cs   <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 9) = "0000000" else '0';
  zp_we   <= cpu_bus_we when zp_cs = '1' else '0';

  -- Write enables
  sram_we <= cpu_bus_we when dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we <= cpu_bus_we when dev_sel = DEV_VIC_TEXT else '0';
  via_cs  <= '1'        when dev_sel = DEV_VIA      else '0';
  uart_cs <= '1'        when dev_sel = DEV_UART     else '0';

  -- VRAM bus mux: VIC takes over during steal
  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1'
                 else cpu_addr(10 downto 0);
  vram_we_mux <= '0' when vic_stealing = '1' else vram_we;

  -- CPU data mux
  process(dev_sel, zp_cs, zp_dout, sram_dout, rom_dout, vram_dout, via_dout, uart_dout)
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
      when DEV_VIA =>
        cpu_din <= via_dout;
      when DEV_UART =>
        cpu_din <= uart_dout;
      when others =>
        cpu_din <= x"FF";
    end case;
  end process;

  -- -------------------------------------------------------------------------
  decode_i : entity work.bus_decode
    port map (addr => cpu_addr, sel => dev_sel);

  cpu_i : entity work.t65_adapter
    port map (
      clk      => clk,
      reset_n  => reset_n,
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
    generic map (ADDR_WIDTH => 12, ASYNC_READ => false)
    port map (clk => clk, we => sram_we,
              addr => cpu_addr(11 downto 0), din => cpu_dout, dout => sram_dout);

  vram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 11, ASYNC_READ => false)
    port map (clk => clk, we => vram_we_mux,
              addr => vram_addr, din => cpu_dout, dout => vram_dout);

  rom_i : entity work.rom
    generic map (ADDR_WIDTH => 11, INIT_FILE => ROM_INIT_FILE, ASYNC_READ => false)
    port map (clk => clk, addr => cpu_addr(10 downto 0), dout => rom_dout);

  -- -------------------------------------------------------------------------
  -- VIA 6522: Timer 1 generates IRQ; Port B goes to board LEDs
  -- -------------------------------------------------------------------------
  via_i : entity work.via6522
    port map (
      clk       => clk,
      reset_n   => reset_n,
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

  -- -------------------------------------------------------------------------
  -- UART 6551: TX only for this demo (RX not connected)
  -- -------------------------------------------------------------------------
  uart_i : entity work.uart6551
    port map (
      clk      => clk,
      reset_n  => reset_n,
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
      reset_n => reset_n,
      rx      => uart_rx,
      data    => uart_rx_data,
      valid   => uart_rx_valid
    );

  -- -------------------------------------------------------------------------
  char_i : entity work.char_rom
    port map (addr => char_addr, dout => char_data);

  vic_i : entity work.vic_vga
    generic map (CLK_DIV => CLK_DIV)
    port map (
      clk          => clk,
      reset_n      => reset_n,
      vic_addr     => vic_addr,
      vram_data    => vram_dout,
      vic_stealing => vic_stealing,
      char_addr    => char_addr,
      char_data    => char_data,
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
