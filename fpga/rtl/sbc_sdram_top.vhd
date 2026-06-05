-- SBC with SDRAM: T65 CPU + 32 KB SDRAM + 2 KB VRAM + ROM + VIC + VIA + UART
--
-- Memory map:
--   $0000-$01FF  512 B FPGA-RAM (Zero Page + Stack, no wait states)
--   $0200-$7FFF  SDRAM (with wait states via RDY)
--   $8000-$87FF   2 KB VRAM  (block RAM, shared with VIC via bus stealing)
--   $8800-$880F  VIA 6522    (Timer 1 IRQ, Port B)
--   $8810-$8813  UART 6551   (TX)
--   $F800-$FFFF   2 KB ROM   (kernel + reset vector)
--
-- SDRAM wait states: ~8 system clocks per access (~4 effective 6502 cycles).
-- cpu_rdy = sdram_rdy AND NOT vic_stealing; both stall sources use the RDY pin.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_sdram_top is
  generic (
    ROM_INIT_FILE : string := ""
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    -- VGA output
    vga_r    : out std_logic_vector(4 downto 0);
    vga_g    : out std_logic_vector(5 downto 0);
    vga_b    : out std_logic_vector(4 downto 0);
    vga_hs   : out std_logic;
    vga_vs   : out std_logic;

    -- UART serial keyboard input (from CH340C USB-UART, pin C11)
    uart_rx  : in  std_logic;

    -- SDRAM hardware pins (no clock: the board wrapper drives sdram_clk via ODDR2)
    sdram_cke   : out   std_logic;
    sdram_cs_n  : out   std_logic;
    sdram_ras_n : out   std_logic;
    sdram_cas_n : out   std_logic;
    sdram_we_n  : out   std_logic;
    sdram_ba    : out   std_logic_vector(1 downto 0);
    sdram_addr  : out   std_logic_vector(12 downto 0);
    sdram_dqm   : out   std_logic_vector(1 downto 0);
    sdram_dq    : inout std_logic_vector(15 downto 0);

    -- Peripherals
    via_portb     : out data_t;
    uart_tx_data  : out data_t;
    uart_tx_valid : out std_logic;
    uart_tx_busy  : in  std_logic := '0'  -- from uart_tx_ser.busy
  );
end entity;

architecture rtl of sbc_sdram_top is

  -- CPU bus
  signal cpu_addr   : addr_t;
  signal cpu_dout   : data_t;
  signal cpu_din    : data_t;
  signal cpu_we     : std_logic;
  signal cpu_sync   : std_logic;
  signal cpu_enable : std_logic := '0';
  signal cpu_bus_we : std_logic;
  signal cpu_rdy    : std_logic;
  signal cpu_irq_n  : std_logic;

  signal dev_sel  : device_sel_t;

  -- Device data outputs
  signal zp_dout    : data_t;
  signal sdram_dout : data_t;
  signal vram_dout  : data_t;
  signal rom_dout   : data_t;
  signal via_dout   : data_t;
  signal uart_dout  : data_t;

  -- Write enables / chip selects
  signal zp_cs      : std_logic;
  signal zp_we      : std_logic;
  signal sdram_cs   : std_logic;
  signal vram_we    : std_logic;
  signal vram_we_mux: std_logic;
  signal via_cs     : std_logic;
  signal uart_cs    : std_logic;

  -- VRAM bus mux (VIC bus steal)
  signal vram_addr    : std_logic_vector(10 downto 0);
  signal vic_addr     : addr_t;
  signal vic_stealing : std_logic;

  -- SDRAM wait-state signal
  signal sdram_rdy    : std_logic;
  signal sdram_rst    : std_logic;
  signal sdram_ctrl_idle : std_logic;

  -- SDRAM burst interface (sdram_if <-> sdram_ctrl)
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

  -- Character ROM
  signal char_addr : std_logic_vector(9 downto 0);
  signal char_data : data_t;

  -- IRQs
  signal via_irq  : std_logic;
  signal uart_irq : std_logic;

  -- UART RX (serial keyboard)
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
  -- Both SDRAM wait states and VIC bus stealing stall the CPU
  cpu_rdy    <= sdram_rdy and not vic_stealing;
  cpu_irq_n  <= not (via_irq or uart_irq);
  sdram_rst  <= not reset_n;

  -- Fast internal RAM for 6502 Zero Page ($0000-$00FF) and stack ($0100-$01FF).
  zp_cs   <= '1' when dev_sel = DEV_SRAM and cpu_addr(15 downto 9) = "0000000" else '0';
  zp_we   <= cpu_bus_we when zp_cs = '1' else '0';

  -- Chip selects / write enables
  sdram_cs <= '1'        when dev_sel = DEV_SRAM and zp_cs = '0' else '0';
  vram_we  <= cpu_bus_we when dev_sel = DEV_VIC_TEXT else '0';
  via_cs   <= '1'        when dev_sel = DEV_VIA      else '0';
  uart_cs  <= '1'        when dev_sel = DEV_UART     else '0';

  -- VRAM bus mux: VIC takes bus during steal
  vram_addr    <= vic_addr(10 downto 0) when vic_stealing = '1'
                  else cpu_addr(10 downto 0);
  vram_we_mux  <= '0' when vic_stealing = '1' else vram_we;

  -- CPU data mux
  process(dev_sel, zp_cs, zp_dout, sdram_dout, rom_dout, vram_dout, via_dout, uart_dout)
  begin
    case dev_sel is
      when DEV_SRAM =>
        if zp_cs = '1' then
          cpu_din <= zp_dout;
        else
          cpu_din <= sdram_dout;
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
    generic map (ADDR_WIDTH => 9, ASYNC_READ => true)
    port map (
      clk  => clk,
      we   => zp_we,
      addr => cpu_addr(8 downto 0),
      din  => cpu_dout,
      dout => zp_dout
    );

  -- -------------------------------------------------------------------------
  -- SDRAM interface: converts single-byte 6502 accesses to burst-1 requests
  -- -------------------------------------------------------------------------
  sdram_if_i : entity work.sdram_if
    port map (
      clk        => clk,
      reset_n    => reset_n,
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

  -- -------------------------------------------------------------------------
  -- SDRAM controller (50 MHz, 7.5 us refresh, CAS=3, burst=1)
  -- -------------------------------------------------------------------------
  sdram_ctrl_i : entity work.sdram_ctrl
    port map (
      clk               => clk,
      rst               => sdram_rst,
      wr_burst_req      => wr_burst_req,
      wr_burst_data     => wr_burst_data,
      wr_burst_len      => wr_burst_len,
      wr_burst_addr     => wr_burst_addr,
      wr_dqm            => wr_dqm,
      wr_burst_data_req => wr_burst_data_req,
      wr_burst_finish   => wr_burst_finish,
      rd_burst_req      => rd_burst_req,
      rd_burst_len      => rd_burst_len,
      rd_burst_addr     => rd_burst_addr,
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

  -- -------------------------------------------------------------------------
  -- VRAM (block RAM, single-port, shared CPU/VIC via bus mux)
  -- -------------------------------------------------------------------------
  vram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 11, ASYNC_READ => true)
    port map (
      clk  => clk,
      we   => vram_we_mux,
      addr => vram_addr,
      din  => cpu_dout,
      dout => vram_dout
    );

  -- -------------------------------------------------------------------------
  rom_i : entity work.rom
    generic map (ADDR_WIDTH => 11, INIT_FILE => ROM_INIT_FILE, ASYNC_READ => true)
    port map (clk => clk, addr => cpu_addr(10 downto 0), dout => rom_dout);

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

  -- -------------------------------------------------------------------------
  -- UART RX deserializer: CH340C TXD (pin C11) → 6502 keyboard input
  -- -------------------------------------------------------------------------
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
      vga_r        => vga_r,
      vga_g        => vga_g,
      vga_b        => vga_b
    );

end architecture;
