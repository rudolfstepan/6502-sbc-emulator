-- Bus Decoder: Address-to-device mapper
-- Decodes the CPU address bus to determine which peripheral or memory device is active
-- This is a combinational logic module with no clock dependency
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity bus_decode is
  port (
    addr : in  addr_t;           -- 16-bit address from CPU address bus
    sel  : out device_sel_t       -- Device selection output (which peripheral is active)
  );
end entity;

architecture rtl of bus_decode is
begin
  -- Combinational address decoder process
  -- Evaluates the incoming address and determines which device it maps to
  -- Priority order is from lowest to highest address ranges
  process(addr)
  begin
    -- Default: no device selected (invalid/unmapped address)
    sel <= DEV_NONE;

    -- Check each address range in priority order (lowest to highest)
    -- The CPU will use this signal to enable the appropriate peripheral

    -- 0x0000-0x7FFF: Main system RAM (32KB)
    if in_range(addr, ADDR_SRAM_BASE, ADDR_SRAM_LAST) then
      sel <= DEV_SRAM;
    -- 0x8000-0x87FF: VIC text display memory (2KB)
    elsif in_range(addr, ADDR_VIC_TEXT_BASE, ADDR_VIC_TEXT_LAST) then
      sel <= DEV_VIC_TEXT;
    -- 0x8800-0x880F: VIA parallel I/O controller (16 bytes)
    elsif in_range(addr, ADDR_VIA_BASE, ADDR_VIA_LAST) then
      sel <= DEV_VIA;
    -- 0x8810-0x8813: UART serial interface (4 bytes)
    elsif in_range(addr, ADDR_UART_BASE, ADDR_UART_LAST) then
      sel <= DEV_UART;
    -- 0x8820-0x8823: USB HID host keyboard (4 bytes)
    elsif in_range(addr, ADDR_USB_BASE, ADDR_USB_LAST) then
      sel <= DEV_USB;
    -- 0x8824-0x882F: Disk controller (12 bytes)
    elsif in_range(addr, ADDR_DISK_BASE, ADDR_DISK_LAST) then
      sel <= DEV_DISK;
    -- 0x8830-0x8839: Sound synthesizer channel 0 (10 bytes)
    elsif in_range(addr, ADDR_SOUND0_BASE, ADDR_SOUND0_LAST) then
      sel <= DEV_SOUND0;
    -- 0x8840-0x844F: VIC hardware blitter (16 bytes)
    elsif in_range(addr, ADDR_VIC_BLIT_BASE, ADDR_VIC_BLIT_LAST) then
      sel <= DEV_VIC_BLIT;
    -- 0x8850-0x888F: VIC sprite controller (64 bytes for 8 sprites)
    elsif in_range(addr, ADDR_VIC_SPR_BASE, ADDR_VIC_SPR_LAST) then
      sel <= DEV_VIC_SPR;
    -- 0x8890-0x8899: Sound synthesizer channel 1 (10 bytes)
    elsif in_range(addr, ADDR_SOUND1_BASE, ADDR_SOUND1_LAST) then
      sel <= DEV_SOUND1;
    -- 0x889A-0x88A3: Sound synthesizer channel 2 (10 bytes)
    elsif in_range(addr, ADDR_SOUND2_BASE, ADDR_SOUND2_LAST) then
      sel <= DEV_SOUND2;
    -- 0x88A4-0x88AD: Sound synthesizer channel 3 (10 bytes)
    elsif in_range(addr, ADDR_SOUND3_BASE, ADDR_SOUND3_LAST) then
      sel <= DEV_SOUND3;
    -- 0x8900-0x89FF: VIC sprite pattern data storage (256 bytes)
    elsif in_range(addr, ADDR_VIC_SPD_BASE, ADDR_VIC_SPD_LAST) then
      sel <= DEV_VIC_SPD;
    -- 0x9000-0x900F: VIC control and status registers (16 bytes)
    elsif in_range(addr, ADDR_VIC_REG_BASE, ADDR_VIC_REG_LAST) then
      sel <= DEV_VIC_REG;
    -- 0x9010-0xAF4F: VIC bitmap frame buffer - video RAM (40KB)
    elsif in_range(addr, ADDR_VIC_BMP_BASE, ADDR_VIC_BMP_LAST) then
      sel <= DEV_VIC_BMP;
    -- 0xC000-0xFFFF: Read-only firmware and system ROM (16KB)
    elsif in_range(addr, ADDR_ROM_BASE, ADDR_ROM_LAST) then
      sel <= DEV_ROM;
    end if;
  end process;
end architecture;

