-- SBC Package: Defines common types, constants, and utilities for the 6502 Single Board Computer
-- This package centralizes the memory map definitions and device selection logic
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package sbc_pkg is
  -- Standard address and data bus widths for 6502 architecture
  subtype addr_t is std_logic_vector(15 downto 0);  -- 16-bit address bus
  subtype data_t is std_logic_vector(7 downto 0);   -- 8-bit data bus

  -- Memory map constants: Define address ranges for all peripherals and memory regions
  -- The 6502 has a 64KB address space (0x0000 - 0xFFFF)

  -- SRAM: Primary RAM for program and data storage (32KB)
  constant ADDR_SRAM_BASE       : unsigned(15 downto 0) := x"0000";
  constant ADDR_SRAM_LAST       : unsigned(15 downto 0) := x"7FFF";

  -- VIC Chip: Video display controller text memory (2KB text buffer)
  constant ADDR_VIC_TEXT_BASE   : unsigned(15 downto 0) := x"8000";
  constant ADDR_VIC_TEXT_LAST   : unsigned(15 downto 0) := x"87FF";

  -- VIA: Versatile Interface Adapter for parallel I/O (16 bytes)
  constant ADDR_VIA_BASE        : unsigned(15 downto 0) := x"8800";
  constant ADDR_VIA_LAST        : unsigned(15 downto 0) := x"880F";

  -- UART: Serial communication interface (4 bytes)
  constant ADDR_UART_BASE       : unsigned(15 downto 0) := x"8810";
  constant ADDR_UART_LAST       : unsigned(15 downto 0) := x"8813";

  -- Disk controller: Floppy disk interface (16 bytes)
  constant ADDR_DISK_BASE       : unsigned(15 downto 0) := x"8820";
  constant ADDR_DISK_LAST       : unsigned(15 downto 0) := x"882F";

  -- Sound synthesizer channel 0 (10 bytes)
  constant ADDR_SOUND0_BASE     : unsigned(15 downto 0) := x"8830";
  constant ADDR_SOUND0_LAST     : unsigned(15 downto 0) := x"8839";

  -- VIC Blit engine: Hardware graphics blitter (16 bytes)
  constant ADDR_VIC_BLIT_BASE   : unsigned(15 downto 0) := x"8840";
  constant ADDR_VIC_BLIT_LAST   : unsigned(15 downto 0) := x"844F";

  -- VIC Sprite controller: Manages sprite graphics (64 bytes for 8 sprites)
  constant ADDR_VIC_SPR_BASE    : unsigned(15 downto 0) := x"8850";
  constant ADDR_VIC_SPR_LAST    : unsigned(15 downto 0) := x"888F";

  -- Sound synthesizer channel 1 (10 bytes)
  constant ADDR_SOUND1_BASE     : unsigned(15 downto 0) := x"8890";
  constant ADDR_SOUND1_LAST     : unsigned(15 downto 0) := x"8899";

  -- Sound synthesizer channel 2 (10 bytes)
  constant ADDR_SOUND2_BASE     : unsigned(15 downto 0) := x"889A";
  constant ADDR_SOUND2_LAST     : unsigned(15 downto 0) := x"88A3";

  -- Sound synthesizer channel 3 (10 bytes)
  constant ADDR_SOUND3_BASE     : unsigned(15 downto 0) := x"88A4";
  constant ADDR_SOUND3_LAST     : unsigned(15 downto 0) := x"88AD";

  -- VIC Sprite data: Sprite pattern storage (256 bytes)
  constant ADDR_VIC_SPD_BASE    : unsigned(15 downto 0) := x"8900";
  constant ADDR_VIC_SPD_LAST    : unsigned(15 downto 0) := x"89FF";

  -- VIC Control registers: Chip configuration and control (16 bytes)
  constant ADDR_VIC_REG_BASE    : unsigned(15 downto 0) := x"9000";
  constant ADDR_VIC_REG_LAST    : unsigned(15 downto 0) := x"900F";

  -- VIC Bitmap: Main video frame buffer (40KB for graphics display)
  constant ADDR_VIC_BMP_BASE    : unsigned(15 downto 0) := x"9010";
  constant ADDR_VIC_BMP_LAST    : unsigned(15 downto 0) := x"AF4F";

  -- ROM: Boot firmware and system ROM (16KB)
  constant ADDR_ROM_BASE        : unsigned(15 downto 0) := x"C000";
  constant ADDR_ROM_LAST        : unsigned(15 downto 0) := x"FFFF";

  -- Device selection enumeration: Used by bus decoder to identify which peripheral is active
  type device_sel_t is (
    DEV_NONE,      -- No device selected (invalid address)
    DEV_SRAM,      -- Main system RAM
    DEV_VIC_TEXT,  -- VIC text display memory
    DEV_VIA,       -- Parallel I/O controller
    DEV_UART,      -- Serial UART interface
    DEV_DISK,      -- Disk controller
    DEV_SOUND0,    -- Synthesis channel 0
    DEV_VIC_BLIT,  -- Hardware graphics blitter
    DEV_VIC_SPR,   -- Sprite register controller
    DEV_SOUND1,    -- Synthesis channel 1
    DEV_SOUND2,    -- Synthesis channel 2
    DEV_SOUND3,    -- Synthesis channel 3
    DEV_VIC_SPD,   -- Sprite pattern data
    DEV_VIC_REG,   -- VIC control registers
    DEV_VIC_BMP,   -- Bitmap frame buffer
    DEV_ROM        -- Read-only firmware
  );

  -- Utility function: Checks if an address falls within a specified range
  -- Used by the bus decoder to determine device selection
  function in_range(addr : addr_t; first_addr : unsigned; last_addr : unsigned)
    return boolean;
end package;

package body sbc_pkg is
  -- Function implementation: Address range checking utility
  -- Returns true if addr is within [first_addr, last_addr] inclusive
  -- Handles X (unknown) addresses safely by returning false
  function in_range(addr : addr_t; first_addr : unsigned; last_addr : unsigned)
    return boolean is
    variable a : unsigned(15 downto 0);
  begin
    -- Check for undefined/unknown bits in address (typical in simulation)
    if is_x(addr) then
      return false;
    end if;

    -- Convert address to unsigned and compare against range bounds
    a := unsigned(addr);
    return a >= first_addr and a <= last_addr;
  end function;
end package body;
