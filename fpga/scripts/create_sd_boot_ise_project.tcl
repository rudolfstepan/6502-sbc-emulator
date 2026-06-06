#!/usr/bin/tclsh
# ISE project creation script for the PIX16 SD-boot 6502 SBC.

set project_name "pix16_sbc_sd_boot"
set device "XC6SLX16"
set package "FTG256"
set speed "-2"
set top_module "pix16_sbc_sd_boot_top"

project new $project_name

project set device $device
project set device_package $package
project set device_speed_grade $speed
project set device_family Spartan6
project set device_speedgrade -2

project set synthesis_tool XST
project set synthesize_xst.hdl_type Mixed
project set synthesize_xst.compiler VHDL_1993

project set implement_tool NgdBuild
project set map_tool MAP
project set place_and_route_tool PAR
project set simulator Modelsim

xfile add constraints/pix16_sd_boot.ucf

xfile add third_party/t65/rtl/T65_Pack.vhd
xfile add third_party/t65/rtl/T65_ALU.vhd
xfile add third_party/t65/rtl/T65_MCode.vhd
xfile add third_party/t65/rtl/T65.vhd

xfile add rtl/sbc_pkg.vhd
xfile add rtl/bus_decode.vhd
xfile add rtl/mem/sync_ram.vhd
xfile add rtl/mem/boot_shadow_rom.vhd
xfile add rtl/mem/sdram_if.vhd
xfile add rtl/mem/sdram_ctrl.vhd
xfile add rtl/mem/char_rom.vhd
xfile add rtl/peripherals/via6522.vhd
xfile add rtl/peripherals/uart6551.vhd
xfile add rtl/peripherals/uart_rx_ser.vhd
xfile add rtl/peripherals/uart_tx_ser.vhd
xfile add rtl/peripherals/vic_vga.vhd
xfile add rtl/boot/boot_debug_uart.vhd
xfile add rtl/boot/boot_vga_debug.vhd
xfile add rtl/boot/boot_sdram_test.vhd
xfile add rtl/cpu/t65_adapter.vhd
xfile add rtl/sbc_t65_boot_top.vhd
xfile add rtl/sbc_t65_sdram_boot_top.vhd
xfile add rtl/boards/pix16_sbc_sd_boot_top.vhd

xfile add third_party/alinx_sd/spi_master.v
xfile add third_party/alinx_sd/sd_card_cmd.v
xfile add third_party/alinx_sd/sd_card_sec_read_write.v
xfile add third_party/alinx_sd/sd_card_top.v
xfile add rtl/boot/sd_rom_loader.v

project set top_module_instance_name $top_module
project set top_module $top_module

project save

puts "ISE project created: $project_name"
puts "Device: $device-$package$speed"
puts "Top module: $top_module"
puts ""
puts "Next steps:"
puts "1. Open project: ise $project_name.ise"
puts "2. Run: Process > Run All"
puts "3. Program FPGA with generated bitstream"
puts "4. Write sim/generated/sbc_ehbasic_sd.img to the SD card"
