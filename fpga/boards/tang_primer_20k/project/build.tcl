set_device GW2A-LV18PG256C8/I7 -name GW2A-18C

add_file -type vhdl {../../../rtl/core/sbc_pkg.vhd}
add_file -type vhdl {../../../third_party/t65/rtl/T65_Pack.vhd}
add_file -type vhdl {../../../third_party/t65/rtl/T65_MCode.vhd}
add_file -type vhdl {../../../third_party/t65/rtl/T65_ALU.vhd}
add_file -type vhdl {../../../third_party/t65/rtl/T65.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/via6522.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/uart_tx_ser.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/uart_rx_ser.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/uart6551.vhd}
add_file -type vhdl {../../../rtl/core/peripherals/vic_vga.vhd}
add_file -type vhdl {../../../rtl/core/mem/sync_ram.vhd}
add_file -type vhdl {../../../rtl/core/mem/char_rom.vhd}
add_file -type vhdl {../../../rtl/core/mem/boot_shadow_rom.vhd}
add_file -type verilog {../../../rtl/core/boot/sd_rom_loader.v}
add_file -type vhdl {../../../rtl/core/usb/usb_hid_host.vhd}
add_file -type verilog {../../../third_party/usb_hid_host/usb_hid_host_nm.v}
add_file -type verilog {../../../third_party/usb_hid_host/usb_hid_host_rom.v}
add_file -type vhdl {../../../rtl/core/boot/boot_debug_uart.vhd}
add_file -type vhdl {../../../rtl/core/boot/boot_vga_debug.vhd}
add_file -type vhdl {../../../rtl/core/boot/uart_debug_monitor.vhd}
add_file -type verilog {../../../third_party/alinx_sd/spi_master.v}
add_file -type verilog {../../../third_party/alinx_sd/sd_card_cmd.v}
add_file -type verilog {../../../third_party/alinx_sd/sd_card_sec_read_write.v}
add_file -type verilog {../../../third_party/alinx_sd/sd_card_top.v}
add_file -type vhdl {../../../rtl/core/cpu/t65_adapter.vhd}
add_file -type vhdl {../../../rtl/core/bus_decode.vhd}
add_file -type vhdl {../../../rtl/core/sbc_t65_boot_monitor_top.vhd}
add_file -type vhdl {../../../rtl/core/hdmi/tmds_encoder.vhd}
add_file -type vhdl {../rtl/tang20k_hdmi_tx.vhd}
add_file -type vhdl {../rtl/tang20k_sbc_top.vhd}
add_file -type cst {../constraints/tang20k_sbc.cst}
add_file -type sdc {../constraints/tang20k_sbc.sdc}

set_option -use_sspi_as_gpio 1
set_option -use_mspi_as_gpio 1
set_option -output_base_name tang_sbc
set_option -vhdl_std vhd1993
set_option -timing_driven 1
set_option -cst_warn_to_error 1
set_option -route_maxfan 23

run all
