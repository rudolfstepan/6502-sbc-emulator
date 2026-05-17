# MS BASIC on SBC6502

## Overview

The default setup in [sbc.ini](../sbc.ini) boots a kernel ROM plus an MS BASIC ROM, wired to VIC display, VIA keyboard input, and DISK MVP for LOAD/SAVE.

## Start

```sh
./sbc6502 sbc.ini
```

You should see the BASIC banner and `READY.` prompt in the SDL window.

## Common Commands

```basic
10 PRINT "HELLO WORLD"
20 GOTO 10
RUN

LIST
NEW
```

## LOAD / SAVE

BASIC disk operations use host directory [data/disk](../data/disk):

```basic
SAVE
LOAD
```

## SBC-specific BASIC Addition

- `CLS`: clear screen and reset cursor

## Relevant Memory Areas

```text
$0000-$00FF   zero page
$0100-$01FF   stack
$0300-$7FFF   BASIC program + variables
$8000-$87FF   VIC text/color RAM
$8800-$880F   VIA 6522
$8810-$8813   UART 6551
$8820-$882F   DISK MVP
$8830-$8835   SOUND
$9000-$900F   VIC registers
$9010-$AF4F   VIC bitmap RAM
$C000-$CFFF   kernel ROM
$D000-$FFFF   MS BASIC ROM
```

## Rebuild BASIC ROM

```sh
bash tools/make_msbasic_rom.sh
```

## Source Locations

- port definitions: [tools/msbasic_port/defines_sbc6502.s](../tools/msbasic_port/defines_sbc6502.s)
- extra routines: [tools/msbasic_port/sbc6502_extra.s](../tools/msbasic_port/sbc6502_extra.s)
- load/save: [tools/msbasic_port/sbc6502_loadsave.s](../tools/msbasic_port/sbc6502_loadsave.s)
- iscntc hook: [tools/msbasic_port/sbc6502_iscntc.s](../tools/msbasic_port/sbc6502_iscntc.s)
