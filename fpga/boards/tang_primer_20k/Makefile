## Tang Primer 20K — GowinEDA build

BOARD       := tang_primer_20k
DEVICE      := GW2A-LV18PG256C8/I7
TOP_MODULE  := tang20k_sbc_top

GOWIN       ?= gw_sh
OPENLOAD    ?= openFPGALoader

RTL_CORE    := ../../rtl/core
RTL_BOARD   := rtl
CONSTRAINTS := constraints/tang20k_sbc.cst
PROJECT_DIR := project

.PHONY: project build bitstream program clean

project:
	@echo "GowinEDA project creation not yet implemented."
	@echo "Open GowinEDA and add source files from:"
	@echo "  Board RTL:  $(RTL_BOARD)/"
	@echo "  Core RTL:   $(RTL_CORE)/"
	@echo "  Third party: ../../third_party/"

build:
	@echo "GowinEDA batch build not yet implemented."

bitstream: build
	@echo "Bitstream generation not yet implemented."

program:
	$(OPENLOAD) -b tang_primer_20k bitstreams/$(TOP_MODULE).fs

clean:
	-rm -rf project/impl/
