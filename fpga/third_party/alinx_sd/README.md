# ALINX SD Card SPI Core

These Verilog files were copied from the PIX16 vendor demo:

`pix16/demo/20_2_sd_sdram_an430_lcd/src`

They provide a sector-level SD card SPI controller used by the SD bootloader
board top. The original source headers permit use and redistribution as long as
the copyright notice is retained.

Files:

- `spi_master.v`
- `sd_card_cmd.v`
- `sd_card_sec_read_write.v`
- `sd_card_top.v`
