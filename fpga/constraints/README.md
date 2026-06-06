# Constraints

Board-specific pin assignments live here.

Keep the generic RTL board-neutral. Add one constraints file per FPGA board, for
example:

- `de10_lite.sdc`
- `arty_a7.xdc`
- `ulx3s.lpf`

PIX16-specific files in this tree:

- `pix16.ucf` - VGA/UART/buttons/LEDs for the minimal board top
- `pix16_sdram.ucf` - SDRAM-enabled board top
- `pix16_sd.ucf` - SD card SPI pins for the SD boot path
- `pix16_sd_boot.ucf` - complete PIX16 pinout for `pix16_sbc_sd_boot_top`
