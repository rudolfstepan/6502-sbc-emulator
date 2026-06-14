## Tang Primer 20K (Gowin GW2A-LV18PG256C8/I7) — GowinEDA build
## Run from this directory: make <target>

BITSTREAM   := project/impl/pnr/tang_sbc.fs

GOWIN       ?= gw_sh
OPENLOAD    ?= openFPGALoader

.PHONY: build program clean

build:
	cd project && $(GOWIN) build.tcl

program:
	$(OPENLOAD) -b tang_primer_20k $(BITSTREAM)

clean:
	-rm -rf project/impl/ project/tmp/
