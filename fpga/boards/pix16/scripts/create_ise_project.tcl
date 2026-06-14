#!/usr/bin/tclsh
# ISE Project Creation Script for PIX16 Board
# Run from fpga/boards/pix16/:
#   xtclsh scripts/create_ise_project.tcl

# Configuration
set project_name "pix16_display"
set device "XC6SLX9"
set package "FTG256"
set speed "-2"
set top_module "pix16_top"
set language "VHDL"

# Create project
project new $project_name

# Set device
project set device $device
project set device_package $package
project set device_speed_grade $speed
project set device_family Spartan6
project set device_speedgrade -2

# Set synthesis options
project set synthesis_tool XST
project set synthesize_xst.hdl_type VHDL
project set synthesize_xst.compiler VHDL_1993

# Set implementation options
project set implement_tool NgdBuild
project set map_tool MAP
project set place_and_route_tool PAR
project set simulator Modelsim

# Add constraint file
xfile add constraints/pix16.ucf

# Add RTL source files
xfile add rtl/pix16_top.vhd
xfile add rtl/pix16_board.vhd
xfile add ../../rtl/core/peripherals/vic_core.vhd
xfile add ../../rtl/core/peripherals/vic_pixel_gen.vhd
xfile add ../../rtl/core/mem/char_rom.vhd
xfile add ../../rtl/core/sbc_pkg.vhd

# Set top module
project set top_module_instance_name pix16_top
project set top_module $top_module

# Save project
project save

# Print summary
puts "ISE Project created: $project_name"
puts "Device: $device-$package$speed"
puts "Top module: $top_module"
puts "Language: $language"
puts ""
puts "Next steps:"
puts "1. Open project: ise $project_name.ise"
puts "2. Run: Process > Run All"
puts "3. Program FPGA with generated bitstream"
