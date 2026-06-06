-- SBC Top-Level with T65 CPU: Full Single-Board Computer with cycle-accurate 6502 processor
-- This is an alternative to sbc_top that uses the real T65 CPU core instead of the test controller.
-- The T65 is a cycle-accurate VHDL implementation of the 6502 processor, allowing real firmware
-- to execute. This version includes clock division to properly interface the T65 (which runs
-- at full speed internally) to the rest of the system.
--
-- System Architecture (Minimal Core):
--  - T65 CPU: Cycle-accurate 6502 processor
--  - 4KB SRAM: Program and data memory (0x0000-0x0FFF)
--  - 2KB ROM: Boot code (0xF800-0xFFFF)
--  - VIC: Video display controller only
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
use ieee.numeric_std.all;

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
  signal vic_dout   : data_t;
  signal vic_irq    : std_logic;

  signal sram_we    : std_logic;
  signal vic_cs     : std_logic;
  signal cpu_irq_n  : std_logic;
  signal irq_comb   : std_logic;

  -- Boot sequence signals
  signal boot_counter : natural range 0 to 31 := 0;
  signal boot_done    : boolean := false;
  signal boot_vic_cs  : std_logic;
  signal boot_vic_we  : std_logic;
  signal boot_vic_addr : addr_t;
  signal boot_vic_din  : data_t;
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cpu_enable <= '0';
        boot_counter <= 0;
        boot_done <= false;
      else
        cpu_enable <= not cpu_enable;

        -- Boot sequence: Write "WELCOME TO 6502 SBC!" to VIC text RAM
        if not boot_done then
          boot_counter <= boot_counter + 1;
          if boot_counter >= 20 then
            boot_done <= true;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Boot message writer
  with boot_counter select boot_vic_din <=
    x"57" when 0,  -- W
    x"45" when 1,  -- E
    x"4C" when 2,  -- L
    x"43" when 3,  -- C
    x"4F" when 4,  -- O
    x"4D" when 5,  -- M
    x"45" when 6,  -- E
    x"20" when 7,  -- space
    x"54" when 8,  -- T
    x"4F" when 9,  -- O
    x"20" when 10, -- space
    x"36" when 11, -- 6
    x"35" when 12, -- 5
    x"30" when 13, -- 0
    x"32" when 14, -- 2
    x"20" when 15, -- space
    x"53" when 16, -- S
    x"42" when 17, -- B
    x"43" when 18, -- C
    x"21" when 19, -- !
    x"00" when others;

  boot_vic_addr <= std_logic_vector(to_unsigned(boot_counter, 16)) when boot_counter < 20 else (others => '0');
  boot_vic_cs <= '1' when not boot_done else '0';
  boot_vic_we <= '1' when not boot_done else '0';

  cpu_bus_we <= cpu_we and not cpu_enable;

  sram_we <= cpu_bus_we when dev_sel = DEV_SRAM else '0';

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
      ADDR_WIDTH => 12,
      ASYNC_READ => true
    )
    port map (
      clk  => clk,
      we   => sram_we,
      addr => cpu_addr(11 downto 0),
      din  => cpu_dout,
      dout => sram_dout
    );

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

  -- Minimal core: VIC display only, no other peripherals
  -- VIA, UART, Disk removed to reduce LUT usage

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
      raster_irq => open,
      pixel_text_addr => 0,
      pixel_text_data => open,
      pixel_color_addr => 0,
      pixel_color_data => open
    );

  -- Minimal data bus: Only RAM, ROM, and VIC
  with dev_sel select cpu_din <=
    sram_dout when DEV_SRAM,
    rom_dout  when DEV_ROM,
    vic_dout  when DEV_VIC_TEXT | DEV_VIC_BLIT | DEV_VIC_SPR | DEV_VIC_SPD | DEV_VIC_REG | DEV_VIC_BMP,
    x"FF"     when others;

  irq_comb <= vic_irq;
  irq_out <= irq_comb;
  cpu_irq_n <= not irq_comb;

  -- Debug outputs (stub)
  dbg_cpu_addr <= cpu_addr;
  dbg_cpu_data <= cpu_dout;
  dbg_cpu_din <= cpu_din;
  dbg_cpu_we <= cpu_bus_we;
  dbg_cpu_sync <= cpu_sync;
  dbg_uart_tx_data <= (others => '0');
  dbg_uart_tx_valid <= '0';
  dbg_via_portb_out <= (others => '0');
end architecture;
