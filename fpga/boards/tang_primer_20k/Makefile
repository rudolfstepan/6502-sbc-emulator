## Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7) — GowinEDA build
## Run from this directory: make <target>

TOP_MODULE  := tang20k_sbc_top
PROJECT_FILE := project/tang_sbc.gprj

GOWIN       ?= gw_sh
OPENLOAD    ?= openFPGALoader

.PHONY: build fix-pnr program clean

build:
	$(GOWIN) -d $(PROJECT_FILE) -run all

fix-pnr:
	powershell -ExecutionPolicy Bypass -File scripts/fix_gowin_dual_purpose.ps1

program:
	$(OPENLOAD) -b tang_primer_20k project/impl/pnr/$(TOP_MODULE).fs

clean:
	-rm -rf project/impl/ project/tmp/
