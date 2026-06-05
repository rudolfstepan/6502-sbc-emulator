-- Minimales SBC Top-Level: T65 CPU + RAM + VRAM + ROM + VIC (Bus-Stealing)
--
-- Speicherkarte:
--   $0000-$0FFF  4 KB CPU-SRAM  (Stack, Zero-Page, Variablen)
--   $8000-$87FF  2 KB VRAM      (Zeichenpuffer, single-port, geteilt CPU/VIC)
--   $F800-$FFFF  2 KB ROM       (Kernel, Reset-Vektor)
--
-- Bus-Sharing (C64-Prinzip):
--   Waehrend H-Blank stiehlt der VIC 40 System-Takte vom CPU-Bus.
--   CPU wird via T65 RDY-Pin gehalten. Kein Dual-Port-RAM.
--   CPU-Overhead: 40 von 320 H-Blank-Takten = 12.5% pro Zeile.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_minimal_top is
  generic (
    ROM_INIT_FILE : string := ""
  );
  port (
    clk      : in  std_logic;
    reset_n  : in  std_logic;

    -- VGA-Ausgang (direkt vom VIC)
    vga_r    : out std_logic_vector(4 downto 0);
    vga_g    : out std_logic_vector(5 downto 0);
    vga_b    : out std_logic_vector(4 downto 0);
    vga_hs   : out std_logic;
    vga_vs   : out std_logic;

    -- Debug: CPU-Bus fuer Simulation und Logikanalysator
    dbg_cpu_addr : out addr_t;
    dbg_cpu_data : out data_t;
    dbg_cpu_din  : out data_t;
    dbg_cpu_we   : out std_logic;
    dbg_cpu_sync : out std_logic
  );
end entity;

architecture rtl of sbc_minimal_top is
  -- CPU-Bus
  signal cpu_addr   : addr_t   := (others => '0');
  signal cpu_dout   : data_t   := (others => '0');
  signal cpu_din    : data_t   := (others => '0');
  signal cpu_we     : std_logic := '0';
  signal cpu_sync   : std_logic := '0';
  signal cpu_enable : std_logic := '0';   -- T65 div-2 clock enable
  signal cpu_bus_we : std_logic := '0';   -- gegatetes Write-Enable
  signal cpu_rdy    : std_logic := '1';   -- '0' = CPU gehalten

  signal dev_sel    : device_sel_t;

  -- Speicher-Ausgaenge
  signal sram_dout  : data_t;
  signal vram_dout  : data_t;
  signal rom_dout   : data_t;

  -- Write-Enables
  signal sram_we    : std_logic;
  signal vram_we    : std_logic;
  signal vram_we_mux : std_logic;

  -- VRAM-Adresse (Bus-Mux: CPU oder VIC)
  signal vram_addr  : std_logic_vector(10 downto 0);

  -- VIC Bus-Steal-Signale
  signal vic_addr      : addr_t;
  signal vic_stealing  : std_logic;

  -- Char-ROM-Interface
  signal char_addr  : std_logic_vector(9 downto 0);
  signal char_data  : data_t;

begin
  -- T65 laeuft intern mit doppelter Frequenz: cpu_enable wechselt jeden Takt.
  -- Schreibzugriffe werden nur auf cpu_enable='0' committed (stabiler Bus).
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

  -- CPU wird gehalten wenn VIC den Bus benutzt
  cpu_rdy  <= not vic_stealing;

  -- Write-Enable je nach selektiertem Geraet
  sram_we <= cpu_bus_we when dev_sel = DEV_SRAM     else '0';
  vram_we <= cpu_bus_we when dev_sel = DEV_VIC_TEXT else '0';

  -- Bus-Mux fuer VRAM: VIC-Adresse hat Vorrang (CPU ist dabei gehalten)
  vram_addr   <= vic_addr(10 downto 0) when vic_stealing = '1'
                 else cpu_addr(10 downto 0);
  -- Waehrend VIC stiehlt: kein CPU-Schreibzugriff auf VRAM
  vram_we_mux <= '0'    when vic_stealing = '1' else vram_we;

  -- CPU-Daten-Multiplexer
  with dev_sel select cpu_din <=
    sram_dout when DEV_SRAM,
    rom_dout  when DEV_ROM,
    vram_dout when DEV_VIC_TEXT,
    x"FF"     when others;

  -- -------------------------------------------------------------------------
  -- Bus-Decoder
  -- -------------------------------------------------------------------------
  decode_i : entity work.bus_decode
    port map (addr => cpu_addr, sel => dev_sel);

  -- -------------------------------------------------------------------------
  -- T65 CPU mit RDY-Pin fuer Bus-Steal
  -- -------------------------------------------------------------------------
  cpu_i : entity work.t65_adapter
    port map (
      clk      => clk,
      reset_n  => reset_n,
      enable   => cpu_enable,
      rdy      => cpu_rdy,
      irq_n    => '1',
      nmi_n    => '1',
      data_in  => cpu_din,
      addr     => cpu_addr,
      data_out => cpu_dout,
      we       => cpu_we,
      sync     => cpu_sync
    );

  -- -------------------------------------------------------------------------
  -- 4 KB CPU-SRAM: Stack, Zero-Page, Variablen
  -- -------------------------------------------------------------------------
  sram_i : entity work.sync_ram
    generic map (ADDR_WIDTH => 12, ASYNC_READ => true)
    port map (
      clk  => clk,
      we   => sram_we,
      addr => cpu_addr(11 downto 0),
      din  => cpu_dout,
      dout => sram_dout
    );

  -- -------------------------------------------------------------------------
  -- 2 KB VRAM: Zeichenpuffer, single-port, zwischen CPU und VIC geteilt
  -- Adresse kommt vom Bus-Mux (CPU oder VIC)
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
  -- 2 KB ROM: Kernel, gemappt $F800-$FFFF via cpu_addr[10:0]
  -- -------------------------------------------------------------------------
  rom_i : entity work.rom
    generic map (
      ADDR_WIDTH => 11,
      INIT_FILE  => ROM_INIT_FILE,
      ASYNC_READ => true
    )
    port map (
      clk  => clk,
      addr => cpu_addr(10 downto 0),
      dout => rom_dout
    );

  -- -------------------------------------------------------------------------
  -- Char-ROM: 8x8 Pixel-Muster fuer ASCII 0x00-0x7F
  -- -------------------------------------------------------------------------
  char_i : entity work.char_rom
    port map (addr => char_addr, dout => char_data);

  -- -------------------------------------------------------------------------
  -- VIC VGA: Bus-Stealing + Zeilenpuffer + VGA-Ausgabe
  -- Liest VRAM waehrend H-Blank, CPU dabei per RDY gehalten
  -- -------------------------------------------------------------------------
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

  -- Debug-Ausgaenge
  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_din  <= cpu_din;
  dbg_cpu_we   <= cpu_bus_we;
  dbg_cpu_sync <= cpu_sync;

end architecture;
