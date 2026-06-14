-- T65 CPU Adapter: Interface wrapper for the T65 6502 CPU core
-- Adapts the T65 VHDL processor core to the standard system bus interface
-- The T65 is a cycle-accurate 6502 emulation. This adapter:
--  - Translates T65 control signals to standard bus signals
--  - Truncates 24-bit T65 addresses to 16-bit bus addresses
--  - Generates write-enable signal from R/W_n and VDA (Valid Data Address)
--  - Connects interrupt inputs directly to CPU
library ieee;
use ieee.std_logic_1164.all;

use work.sbc_pkg.all;
use work.T65_Pack.all;  -- T65 CPU core package definitions

entity t65_adapter is
  port (
    -- System clock and reset
    clk      : in  std_logic;      -- Master system clock
    reset_n  : in  std_logic;      -- Active-low reset to CPU
    enable   : in  std_logic;      -- Clock enable: 1=CPU runs, 0=CPU halted
    rdy      : in  std_logic := '1'; -- Ready: '0' haelt CPU zwischen Zyklen (Bus-Steal)

    -- Interrupt inputs
    irq_n    : in  std_logic;      -- Active-low Interrupt Request from peripherals
    nmi_n    : in  std_logic;      -- Active-low Non-Maskable Interrupt

    -- System bus interface
    data_in  : in  data_t;         -- Data from memory/peripherals to CPU
    addr     : out addr_t;         -- CPU address bus (16-bit, 6502 native)
    data_out : out data_t;         -- CPU data output to memory/peripherals
    we       : out std_logic;      -- Write Enable: 1=CPU writing, 0=CPU reading
    sync     : out std_logic       -- Sync signal: 1=start of new instruction
  );
end entity;

architecture rtl of t65_adapter is
  -- T65 internal signals: Widebus interface
  signal t65_addr      : std_logic_vector(23 downto 0);  -- 24-bit address (8080 compatibility)
  signal t65_din       : data_t;                          -- T65 data input
  signal t65_dout      : data_t;                          -- T65 data output
  signal t65_r_w_n     : std_logic;                       -- T65 read/write signal (1=read, 0=write)
  signal t65_vda       : std_logic;                       -- Valid Data Address (processor is accessing memory)

  -- Unused T65 signals (for debugging/extended features not used in basic 6502)
  signal unused_debug  : T_t65_dbg;                       -- Debug information (unused)
  signal unused_regs   : std_logic_vector(63 downto 0);   -- CPU register dump (unused)
  signal unused_ef     : std_logic;                       -- Extended flags (unused)
  signal unused_mf     : std_logic;                       -- Memory fetch indicator (unused)
  signal unused_xf     : std_logic;                       -- Extended flags (unused)
  signal unused_ml_n   : std_logic;                       -- Memory lock (unused)
  signal unused_vp_n   : std_logic;                       -- Vector pull (unused)
  signal unused_vpa    : std_logic;                       -- Valid Program Address (unused)
  signal unused_nmi_ack : std_logic;                      -- NMI acknowledge (unused)

begin
  -- Input connections: Pass system bus to T65
  t65_din <= data_in;

  -- Output connections: T65 to system bus
  addr <= t65_addr(15 downto 0);                     -- Use lower 16 bits of T65 address
  data_out <= t65_dout;                              -- CPU output data passes through
  -- Write enable: Active when T65 is writing (R_W_n='0') AND valid data address (VDA='1')
  we <= (not t65_r_w_n) and t65_vda;

  -- Instantiate T65 CPU core
  -- This is the main 6502 processor with cycle-accurate instruction execution
  core_i : entity work.T65
    port map (
      -- CPU mode and configuration
      Mode    => "00",           -- 6502 emulation mode (not 65C02 or 65816)
      BCD_en  => '1',            -- Enable Binary-Coded-Decimal arithmetic

      -- System clock and control
      Res_n   => reset_n,        -- CPU reset (active-low)
      Enable  => enable,         -- Clock enable (gating for external clock control)
      Clk     => clk,            -- Master clock input

      -- Bus control
      Rdy     => rdy,            -- Ready: '0' haelt CPU (Bus-Steal durch VIC)
      Abort_n => '1',            -- Abort signal (not used, always active)

      -- Interrupt inputs
      IRQ_n   => irq_n,          -- Maskable interrupt (active-low)
      NMI_n   => nmi_n,          -- Non-maskable interrupt (active-low)
      SO_n    => '1',            -- Set Overflow input (not used, disabled)

      -- Bus signals
      R_W_n   => t65_r_w_n,      -- Read/Write control (1=read, 0=write)
      Sync    => sync,           -- Sync output (1=start of instruction)

      -- Extended signals (mostly unused for basic 6502)
      EF      => unused_ef,           -- Extended fetch (unused)
      MF      => unused_mf,           -- Memory fetch (unused)
      XF      => unused_xf,           -- Extended flags (unused)
      ML_n    => unused_ml_n,         -- Memory lock (unused)
      VP_n    => unused_vp_n,         -- Vector pull (unused)
      VDA     => t65_vda,             -- Valid Data Address (signals memory access phase)
      VPA     => unused_vpa,          -- Valid Program Address (unused)

      -- Address and data buses
      A       => t65_addr,       -- 24-bit address bus
      DI      => t65_din,        -- Data input from memory
      DO      => t65_dout,       -- Data output to memory

      -- Debug interface (unused in simulation, could be used for waveform analysis)
      Regs    => unused_regs,    -- Register state dump (for debugging)
      DEBUG   => unused_debug,   -- Debug signals (for analysis)
      NMI_ack => unused_nmi_ack  -- NMI acknowledge (used for edge detection)
    );
end architecture;
