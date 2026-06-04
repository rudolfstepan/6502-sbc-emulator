-- SBC Top-Level: Complete Single-Board Computer integrating CPU, memory, and peripherals
-- This is the main system integration module that connects all components:
--  - CPU (6502-compatible test controller)
--  - Memory (32KB SRAM + 16KB ROM)
--  - Parallel I/O (VIA 6522)
--  - Serial I/O (UART 6551)
--  - Disk controller (stub)
--  - Video controller (stub)
--  - Audio synthesizer (stub)
-- All components share a common 16-bit address bus and 8-bit data bus with appropriate
-- chip select decoding for each peripheral based on address ranges.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sbc_top is
  generic (
    ROM_INIT_FILE : string := ""  -- Path to ROM image hex file for initialization
  );
  port (
    -- System clock and reset
    clk          : in  std_logic;   -- Master system clock (all components synchronous)
    reset_n      : in  std_logic;   -- Active-low synchronous reset to all modules

    -- Serial I/O
    uart_rx      : in  std_logic;   -- UART receive input (not connected in this version)
    uart_tx      : out std_logic;   -- UART transmit output (looped back to RX for testing)

    -- Interrupt output
    irq_out      : out std_logic;   -- Combined interrupt from all peripherals to external circuit

    -- Debug outputs: CPU bus state for waveform analysis
    dbg_cpu_addr : out addr_t;      -- CPU address bus (for debugging)
    dbg_cpu_data : out data_t;      -- CPU data output bus (for debugging)
    dbg_cpu_we   : out std_logic;   -- CPU write enable signal (for debugging)
    dbg_read_data  : out data_t;    -- Data read from memory (for debugging)
    dbg_read_valid : out std_logic  -- Read valid strobe (for debugging)
  );
end entity;

architecture rtl of sbc_top is
  -- CPU bus signals: Common address/data buses connecting all components
  signal cpu_addr   : addr_t := (others => '0');   -- 16-bit address bus from CPU
  signal cpu_dout   : data_t := (others => '0');   -- CPU output data (write data)
  signal cpu_din    : data_t := (others => '0');   -- CPU input data (read multiplexer output)
  signal cpu_we     : std_logic := '0';            -- CPU write enable signal
  signal dev_sel    : device_sel_t;                -- Decoded device selection from bus_decode

  -- Data bus signals: Output from each peripheral
  signal sram_dout  : data_t;       -- SRAM read data output
  signal rom_dout   : data_t;       -- ROM read data output
  signal via_dout   : data_t;       -- VIA 6522 read data output
  signal uart_dout  : data_t;       -- UART 6551 read data output
  signal disk_dout  : data_t;       -- Disk controller read data output
  signal vic_dout   : data_t;       -- VIC (video) controller read data output
  signal sound_dout : data_t;       -- Sound synthesizer read data output

  -- Interrupt signals: From peripherals to interrupt controller
  signal via_irq    : std_logic;    -- VIA 6522 interrupt request
  signal uart_irq   : std_logic;    -- UART 6551 interrupt request
  signal vic_irq    : std_logic;    -- VIC interrupt request

  -- VIA output lines: Parallel I/O ports (not fully connected)
  signal via_porta_out : data_t;    -- VIA Port A output (8 parallel lines)
  signal via_portb_out : data_t;    -- VIA Port B output (8 parallel lines)

  -- UART signals: Serial transmit interface to external world
  signal uart_tx_data : data_t;     -- Data to transmit on serial line
  signal uart_tx_valid : std_logic; -- Valid strobe for transmit data

  -- Chip select signals: Individual enables for each peripheral
  signal sram_we    : std_logic;    -- SRAM write enable (only when CPU accesses SRAM)
  signal via_cs     : std_logic;    -- VIA chip select (address range 0x8800-0x880F)
  signal uart_cs    : std_logic;    -- UART chip select (address range 0x8810-0x8813)
  signal disk_cs    : std_logic;    -- Disk controller chip select (address range 0x8820-0x882F)
  signal vic_cs     : std_logic;    -- VIC chip select (multiple video address ranges)
  signal sound_cs   : std_logic;    -- Sound chip select (audio address ranges)

  -- Interrupt and debug signals
  signal cpu_irq_n  : std_logic;    -- Active-low interrupt to CPU (inverted from irq_comb)
  signal irq_comb   : std_logic;    -- Combined interrupt from all sources (ORed together)
  signal cpu_read_data  : data_t;   -- Debug: Last read data from CPU accesses
  signal cpu_read_valid : std_logic; -- Debug: Read valid strobe for debugging

begin
  -- Chip select generation: Derive individual peripheral enables from decoded device selection
  -- SRAM write enable: Only assert on writes to SRAM address range
  sram_we  <= cpu_we when dev_sel = DEV_SRAM else '0';

  -- VIA chip select: Single address range
  via_cs   <= '1' when dev_sel = DEV_VIA else '0';

  -- UART chip select: Single address range
  uart_cs  <= '1' when dev_sel = DEV_UART else '0';

  -- Disk controller chip select: Single address range
  disk_cs  <= '1' when dev_sel = DEV_DISK else '0';

  -- VIC (video controller) chip select: Multiple address ranges
  -- Covers text memory, blit engine, sprites, sprite data, control registers, and bitmap
  vic_cs   <= '1' when dev_sel = DEV_VIC_TEXT or dev_sel = DEV_VIC_BLIT or
                   dev_sel = DEV_VIC_SPR or dev_sel = DEV_VIC_SPD or
                   dev_sel = DEV_VIC_REG or dev_sel = DEV_VIC_BMP else '0';

  -- Sound synthesizer chip select: Multiple address ranges (one per synthesis channel)
  sound_cs <= '1' when dev_sel = DEV_SOUND0 or dev_sel = DEV_SOUND1 or
                   dev_sel = DEV_SOUND2 or dev_sel = DEV_SOUND3 else '0';

  -- Address decoder: Translates 16-bit CPU address to device selection
  -- Checks CPU address against address ranges in sbc_pkg and outputs device_sel_t enumeration
  decode_i : entity work.bus_decode
    port map (
      addr => cpu_addr,
      sel  => dev_sel
    );

  -- CPU test controller: Simulates 6502 bus master for testing
  -- Replays pre-programmed sequences from ROM (write address, read address, etc.)
  cpu_i : entity work.cpu6502_slot
    port map (
      clk      => clk,
      reset_n  => reset_n,
      irq_n    => cpu_irq_n,
      data_in  => cpu_din,
      addr     => cpu_addr,
      data_out => cpu_dout,
      we       => cpu_we,
      dbg_read_data  => cpu_read_data,
      dbg_read_valid => cpu_read_valid
    );

  -- Static RAM: 32KB (0x0000-0x7FFF) - main program and data memory
  sram_i : entity work.sync_ram
    generic map (
      ADDR_WIDTH => 15  -- 2^15 = 32KB
    )
    port map (
      clk  => clk,
      we   => sram_we,
      addr => cpu_addr(14 downto 0),
      din  => cpu_dout,
      dout => sram_dout
    );

  -- Read-only memory: 16KB (0xC000-0xFFFF) - firmware and system code
  -- Initialized from hex file at synthesis time
  rom_i : entity work.rom
    generic map (
      ADDR_WIDTH => 14,           -- 2^14 = 16KB
      INIT_FILE  => ROM_INIT_FILE -- Path to ROM image file
    )
    port map (
      clk  => clk,
      addr => cpu_addr(13 downto 0),
      dout => rom_dout
    );

  -- VIA 6522: Versatile Interface Adapter - parallel I/O and timers
  via_i : entity work.via6522
    port map (
      clk       => clk,
      reset_n   => reset_n,
      cs        => via_cs,
      we        => cpu_we,
      addr      => cpu_addr,
      din       => cpu_dout,
      dout      => via_dout,
      porta_in  => (others => '0'),    -- Port A input not connected
      portb_in  => (others => '0'),    -- Port B input not connected
      porta_out => via_porta_out,      -- Port A output (for external use)
      portb_out => via_portb_out,      -- Port B output (for external use)
      irq       => via_irq             -- Interrupt to CPU on timer/handshake events
    );

  -- UART 6551: Asynchronous serial communications interface
  uart_i : entity work.uart6551
    port map (
      clk      => clk,
      reset_n  => reset_n,
      cs       => uart_cs,
      we       => cpu_we,
      addr     => cpu_addr,
      din      => cpu_dout,
      dout     => uart_dout,
      rx_data  => (others => '0'),     -- Serial RX not connected (test mode)
      rx_valid => '0',                 -- No RX data available
      tx_data  => uart_tx_data,        -- Transmit data to external serial
      tx_valid => uart_tx_valid,       -- Transmit strobe signal
      irq      => uart_irq             -- Interrupt to CPU on RX or TX events
    );

  -- Disk controller: Placeholder using generic register stub
  -- Currently supports 16 registers, not a real disk interface
  disk_i : entity work.reg_stub
    generic map (REG_COUNT => 16)
    port map (
      clk     => clk,
      reset_n => reset_n,
      cs      => disk_cs,
      we      => cpu_we,
      addr    => cpu_addr,
      din     => cpu_dout,
      dout    => disk_dout,
      irq     => open               -- No interrupts from disk controller
    );

  -- VIC video controller: Placeholder using generic register stub
  -- Supports 8192 registers for text memory, sprites, bitmap, etc.
  vic_i : entity work.reg_stub
    generic map (REG_COUNT => 8192)  -- Large register space for video RAM
    port map (
      clk     => clk,
      reset_n => reset_n,
      cs      => vic_cs,
      we      => cpu_we,
      addr    => cpu_addr,
      din     => cpu_dout,
      dout    => vic_dout,
      irq     => vic_irq            -- Video interrupt (e.g., vertical blank)
    );

  -- Sound synthesizer: Placeholder using generic register stub
  -- Supports 40 registers across 4 audio channels (10 bytes each)
  sound_i : entity work.reg_stub
    generic map (REG_COUNT => 40)   -- Registers for 4 synthesis channels
    port map (
      clk     => clk,
      reset_n => reset_n,
      cs      => sound_cs,
      we      => cpu_we,
      addr    => cpu_addr,
      din     => cpu_dout,
      dout    => sound_dout,
      irq     => open               -- No interrupts from sound chip
    );

  -- Data bus multiplexer: Select which peripheral's output drives the CPU read data
  -- Based on decoded device selection, route appropriate peripheral data to CPU input
  with dev_sel select cpu_din <=
    sram_dout  when DEV_SRAM,
    rom_dout   when DEV_ROM,
    via_dout   when DEV_VIA,
    uart_dout  when DEV_UART,
    disk_dout  when DEV_DISK,
    -- VIC has multiple address ranges, all mapped to single controller
    vic_dout   when DEV_VIC_TEXT | DEV_VIC_BLIT | DEV_VIC_SPR | DEV_VIC_SPD | DEV_VIC_REG | DEV_VIC_BMP,
    -- Sound has multiple address ranges, all mapped to single controller
    sound_dout when DEV_SOUND0 | DEV_SOUND1 | DEV_SOUND2 | DEV_SOUND3,
    x"FF"      when others;         -- Unmapped address: return 0xFF (typical for open bus)

  -- Interrupt control: Combine interrupts from all peripherals and invert for active-low CPU input
  irq_comb <= via_irq or uart_irq or vic_irq;  -- OR all interrupt sources
  irq_out <= irq_comb;                         -- Output to external interrupt handler
  cpu_irq_n <= not irq_comb;                   -- Active-low interrupt to CPU

  -- UART transmit output: Bit 0 of transmit data when valid, otherwise loopback receive
  uart_tx <= uart_tx_data(0) when uart_tx_valid = '1' else uart_rx;

  -- Debug outputs: Route CPU bus signals for external monitoring and analysis
  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_we <= cpu_we;
  dbg_read_data <= cpu_read_data;
  dbg_read_valid <= cpu_read_valid;
end architecture;
