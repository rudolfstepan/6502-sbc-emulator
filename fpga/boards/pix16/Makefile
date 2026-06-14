## PIX16 (Xilinx Spartan-6 XC6SLX16) — ISE build
## Run from this directory: make <target>

XTCLSH  ?= xtclsh
IMPACT  ?= impact

PROJECT_DIR := project
PROJECT_ISE := $(PROJECT_DIR)/pix16_sbc_sd_boot.ise

.PHONY: project build program clean

project:
	cd $(PROJECT_DIR) && $(XTCLSH) ../scripts/create_sd_boot_ise_project.tcl

build: $(PROJECT_ISE)
	@echo "Open $(PROJECT_ISE) in Xilinx ISE 14.7 and run Process > Run All"
	@echo "Or use xflow for batch synthesis+implementation."

program:
	@echo "Use Xilinx iMPACT to program:"
	@echo "  1. Connect JTAG"
	@echo "  2. impact -batch <impact_commands.cmd>"
	@echo "Or use a .mcs file from bitstreams/ via iMPACT directly."

clean:
	-rm -rf $(PROJECT_DIR)/xst/ $(PROJECT_DIR)/_ngo/ $(PROJECT_DIR)/_xmsgs/
	-rm -rf $(PROJECT_DIR)/iseconfig/ $(PROJECT_DIR)/xlnx_auto_*
	-rm -f $(PROJECT_DIR)/*.ngd $(PROJECT_DIR)/*.ngc $(PROJECT_DIR)/*.ncd
	-rm -f $(PROJECT_DIR)/*.pcf $(PROJECT_DIR)/*.bld $(PROJECT_DIR)/*.mrp
	-rm -f $(PROJECT_DIR)/*.map $(PROJECT_DIR)/*.par $(PROJECT_DIR)/*.twr
	-rm -f $(PROJECT_DIR)/*.twx $(PROJECT_DIR)/*.bit $(PROJECT_DIR)/*.drc
	-rm -f $(PROJECT_DIR)/*.srp $(PROJECT_DIR)/*.lso $(PROJECT_DIR)/*.xrpt
