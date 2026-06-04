-- SBC Top-Level with T65 CPU: Full Single-Board Computer with cycle-accurate 6502 processor
-- This is an alternative to sbc_top that uses the real T65 CPU core instead of the test controller.
-- The T65 is a cycle-accurate VHDL implementation of the 6502 processor, allowing real firmware
-- to execute. This version includes clock division to properly interface the T65 (which runs
-- at full speed internally) to the rest of the system.
--
-- System Architecture:
--  - T65 CPU: Cycle-accurate 6502 processor with all instruction support
--  - 32KB SRAM: Program and data memory (0x0000-0x7FFF)
--  - 16KB ROM: Firmware and system code (0xC000-0xFFFF)
--  - VIA 6522: Parallel I/O controller with timers
--  - UART 6551: Serial communications interface
--  - VIC (stub): Video display controller
--  - Disk (stub): Disk drive interface
--  - Audio (stub): Sound synthesis engine
--
-- Clock Division: T65 runs at 2x system frequency. For every system clock cycle,
-- the T65 executes internal cycles on both clock edges. The cpu_enable signal
-- controls when the T65 proceeds to the next bus phase.
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;

entity sbc_t65_top is
  generic (
    ROM_INIT_FILE : string := ""  -- Path to ROM image hex file
  );
  port (
    -- System clock and reset
    clk          : in  std_logic;   -- Master system clock (T65 runs 2x internally)
    reset_n      : in  std_logic;   -- Active-low reset to CPU and all modules

    -- Serial I/O
    uart_rx      : in  std_logic;   -- Serial receive (not connected in test mode)
    uart_tx      : out std_logic;   -- Serial transmit output

    -- Interrupt output
    irq_out      : out std_logic;   -- Combined interrupt from all peripherals

    -- Debug outputs: Full visibility into CPU bus and key signals
    dbg_cpu_addr : out addr_t;      -- CPU address bus
    dbg_cpu_data : out data_t;      -- CPU output data bus
    dbg_cpu_din  : out data_t;      -- CPU input data bus (read values)
    dbg_cpu_we   : out std_logic;   -- CPU write enable signal
    dbg_cpu_sync : out std_logic;   -- CPU sync (instruction start)
    dbg_uart_tx_data  : out data_t; -- UART transmit data
    dbg_uart_tx_valid : out std_logic;  -- UART transmit strobe
    dbg_via_portb_out : out data_t  -- VIA Port B output (GPIO lines)
  );
end entity;

architecture rtl of sbc_t65_top is
  -- CPU bus signals: Shared between T65 and all peripherals
  signal cpu_addr   : addr_t := (others => '0');   -- 16-bit address bus
  signal cpu_dout   : data_t := (others => '0');   -- CPU output data (write)
  signal cpu_din    : data_t := (others => '0');   -- CPU input data (read multiplexer)
  signal cpu_we     : std_logic := '0';            -- CPU write enable
  signal cpu_bus_we : std_logic := '0';            -- Gated write enable with clock division
  signal cpu_sync   : std_logic := '0';            -- CPU sync (instruction boundary)
  signal cpu_enable : std_logic := '0';            -- Clock enable for T65 (2x divider)
  signal dev_sel    : device_sel_t;                -- Decoded device selection

  signal sram_dout  : data_t;
  signal rom_dout   : data_t;
  signal via_dout   : data_t;
  signal uart_dout  : data_t;
  signal disk_dout  : data_t;
  signal vic_dout   : data_t;
  signal sound_dout : data_t;

  signal via_irq      : std_logic;
  signal uart_irq     : std_logic;
  signal vic_irq      : std_logic;
  signal via_porta_out : data_t;
  signal via_portb_out : data_t;
  signal uart_tx_data  : data_t;
  signal uart_tx_valid : std_logic;

  signal sram_we    : std_logic;
  signal via_cs     : std_logic;
  signal uart_cs    : std_logic;
  signal disk_cs    : std_logic;
  signal vic_cs     : std_logic;
  signal sound_cs   : std_logic;
  signal cpu_irq_n  : std_logic;
  signal irq_comb   : std_logic;
begin
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

  sram_we  <= cpu_bus_we when dev_sel = DEV_SRAM else '0';
  via_cs   <= '1' when dev_sel = DEV_VIA else '0';
  uart_cs  <= '1' when dev_sel = DEV_UART else '0';
  disk_cs  <= '1' when dev_sel = DEV_DISK else '0';
  vic_cs   <= '1' when dev_sel = DEV_VIC_TEXT or dev_sel = DEV_VIC_BLIT or
                   dev_sel = DEV_VIC_SPR or dev_sel = DEV_VIC_SPD or
                   dev_sel = DEV_VIC_REG or dev_sel = DEV_VIC_BMP else '0';
  sound_cs <= '1' when dev_sel = DEV_SOUND0 or dev_sel = DEV_SOUND1 or
                   dev_sel = DEV_SOUND2 or dev_sel = DEV_SOUND3 else '0';

  decode_i : entity work.bus_decode
    port map (
      addr => cpu_addr,
      sel  => dev_sel
    );

  cpu_i : entity work.t65_adapter
    port map (
      clk      => clk,
      reset_n  => reset_n,
      enable   => cpu_enable,
      irq_n    => cpu_irq_n,
      nmi_n    => '1',
      data_in  => cpu_din,
      addr     => cpu_addr,
      data_out => cpu_dout,
      we       => cpu_we,
      sync     => cpu_sync
    );

  sram_i : entity work.sync_ram
    generic map (
      ADDR_WIDTH => 15,
      ASYNC_READ => true
    )
    port map (
      clk  => clk,
      we   => sram_we,
      addr => cpu_addr(14 downto 0),
      din  => cpu_dout,
      dout => sram_dout
    );

  rom_i : entity work.rom
    generic map (
      ADDR_WIDTH => 14,
      INIT_FILE  => ROM_INIT_FILE,
      ASYNC_READ => true
    )
    port map (
      clk  => clk,
      addr => cpu_addr(13 downto 0),
      dout => rom_dout
    );

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
      porta_out => via_porta_out,
      portb_out => via_portb_out,
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
      rx_data  => (others => '0'),
      rx_valid => '0',
      tx_data  => uart_tx_data,
      tx_valid => uart_tx_valid,
      irq      => uart_irq
    );

  disk_i : entity work.reg_stub
    generic map (REG_COUNT => 16)
    port map (
      clk     => clk,
      reset_n => reset_n,
      cs      => disk_cs,
      we      => cpu_bus_we,
      addr    => cpu_addr,
      din     => cpu_dout,
      dout    => disk_dout,
      irq     => open
    );

  vic_i : entity work.vic_core
    port map (
      clk       => clk,
      reset_n   => reset_n,
      cs        => vic_cs,
      we        => cpu_bus_we,
      addr      => cpu_addr,
      din       => cpu_dout,
      dout      => vic_dout,
      irq       => vic_irq,
      h_counter => open,
      v_counter => open,
      raster_irq => open
    );

  sound_i : entity work.reg_stub
    generic map (REG_COUNT => 40)
    port map (
      clk     => clk,
      reset_n => reset_n,
      cs      => sound_cs,
      we      => cpu_bus_we,
      addr    => cpu_addr,
      din     => cpu_dout,
      dout    => sound_dout,
      irq     => open
    );

  with dev_sel select cpu_din <=
    sram_dout  when DEV_SRAM,
    rom_dout   when DEV_ROM,
    via_dout   when DEV_VIA,
    uart_dout  when DEV_UART,
    disk_dout  when DEV_DISK,
    vic_dout   when DEV_VIC_TEXT | DEV_VIC_BLIT | DEV_VIC_SPR | DEV_VIC_SPD | DEV_VIC_REG | DEV_VIC_BMP,
    sound_dout when DEV_SOUND0 | DEV_SOUND1 | DEV_SOUND2 | DEV_SOUND3,
    x"FF"      when others;

  irq_comb <= via_irq or uart_irq or vic_irq;
  irq_out <= irq_comb;
  cpu_irq_n <= not irq_comb;
  uart_tx <= uart_tx_data(0) when uart_tx_valid = '1' else uart_rx;
  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_din <= cpu_din;
  dbg_cpu_we <= cpu_bus_we;
  dbg_cpu_sync <= cpu_sync;
  dbg_uart_tx_data <= uart_tx_data;
  dbg_uart_tx_valid <= uart_tx_valid;
  dbg_via_portb_out <= via_portb_out;
end architecture;
