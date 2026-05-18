# Archived Bug Fixes - MS BASIC ROM (May 2026)

This note is preserved for historical context.
Some build/run commands in this document may reflect older workflows.

## Zusammenfassung

Drei kritische Bugs wurden behoben, die MS BASIC funktionsunfähig machten:

### Bug 1: IRQ-Crash beim ersten Rechenausdruck (KRITISCH)

**Problem:**  
- Kernel `INIT` setzte `VIA_IER = $82` → CA1-Interrupt aktiv
- MS BASIC ruft in `eval.s` (Gleitkomma) und `misc1.s` (Zeitgeber) `SEI…CLI` auf
- Nach `CLI`: anstehender CA1-IRQ vom letzten Tastendruck → Sprung zum IRQ-Vektor `$C000` (INIT)
- **→ Kompletter System-Reset bei jeder arithmetischen Operation**

**Lösung:**  
- `VIA_IER` bleibt `$00` (kein VIA-Interrupt aktiviert)
- Kernel pollt `VIA_IFR` direkt (`CHRIN_NB`), braucht keinen CPU-IRQ
- Neue RTI-Handler hinzugefügt: `NMI_HANDLER` (`$C01E`) und `IRQ_HANDLER` (`$C01F`)

**Dateien:**
- `tools/kernel/kernel.s`: IER-Initialisierung entfernt, RTI-Handler hinzugefügt

### Bug 2: Falsche IRQ/NMI-Vektoren

**Problem:**  
- NMI- und IRQ-Vektoren zeigten beide auf `$C000` (Reset)
- Unerwartete Interrupts → System-Reset

**Lösung:**  
- NMI-Vektor → `$C01E` (RTI)
- IRQ-Vektor → `$C01F` (RTI)  
- RESET-Vektor → `$C000` (INIT, unverändert)

**Dateien:**
- `tools/make_msbasic_rom.sh`: Vektoren in ROM korrigiert

### Bug 3: Verlust gepufferter Tasten

**Problem:**  
- In `via6522.c`: beim Lesen von `VIA_ORA` wurde CA1 gelöscht
- Wenn noch Tasten im Puffer lagen, sah der nächste `CHRIN_NB`-Aufruf kein CA1
- **→ Multi-Char-Eingaben (z.B. "PRINT") verloren Zeichen**

**Lösung:**  
- Nach `via_keyboard_pop()`: CA1 neu setzen wenn `kb_count > 0`
- Kernel sieht sofort, dass weitere Tasten verfügbar sind

**Dateien:**
- `src/via6522.c`: CA1-Re-Assertion nach Pop

### Bug 4: Gespiegelte Zeichen (Bonus-Fix)

**Problem:**  
- Font-Daten waren LSB-first encodiert (Bit 0 = links)
- Rendering nutzte MSB-first: `(0x80 >> px)`
- **→ Zeichen erschienen horizontal gespiegelt**

**Lösung:**  
- Font wird in `vic_init()` bit-reversed (alle Bytes)
- Rendering nutzt korrektes MSB-first: `(0x80 >> px)`

**Dateien:**
- `src/vic.c`: Bit-Reversal in `vic_init()`, Font nicht mehr `const`
- `src/vic_sdl.c`: Rendering auf MSB-first umgestellt

## Test

```bash
# ROMs neu bauen
make clean
bash tools/make_kernel_rom.sh
bash tools/make_msbasic_rom.sh
make

# Emulator starten (benötigt SDL2-Fenster)
./sbc6502

# Im Kernel-Prompt:
> BASIC

# Im MS BASIC:
PRINT 1+1
PRINT "HELLO WORLD"
10 FOR I=1 TO 10
20 PRINT I * I
30 NEXT I
RUN
```

## Geänderte Dateien

1. `tools/kernel/kernel.s` - VIA IER disabled, NMI/IRQ-Handler hinzugefügt
2. `tools/make_msbasic_rom.sh` - Vektoren korrigiert
3. `src/via6522.c` - CA1-Re-Assertion für buffered keys
4. `src/vic.c` - Font bit-reversal
5. `src/vic_sdl.c` - MSB-first rendering

## Verifikation

```bash
# Kernel-ROM: RTI-Handler an $C01E und $C01F
xxd roms/kernel.rom | grep "00c0 4040"
# Erwartung: 00000010: ... 4040  (RTI-Opcodes)

# MS BASIC ROM: Vektoren am Ende
xxd roms/msbasic.rom | tail -1
# Erwartung: 00002ff0: ... 1ec0 00c0 1fc0
#                         ^^^^ ^^^^ ^^^^
#                         NMI  RST  IRQ
```

## Symptome vorher

- **Kernel**: "BASIC" startet MS BASIC
- **MS BASIC**: Banner erscheint, "READY" prompt erscheint
- **Bug**: Bei `PRINT 1+1` → sofortiger Reset zum Kernel-Prompt
- **Bug**: Multi-Char-Commands wie "PRINT" oft als "PIT" oder "PRNT" verstanden
- **Bug**: Zeichen gespiegelt dargestellt

## Verhalten nachher

- **MS BASIC läuft stabil**
- Arithmetik funktioniert: `PRINT 1+1` → `2`
- Strings funktionieren: `PRINT "TEST"` → `TEST`
- FOR/NEXT-Schleifen funktionieren
- SAVE/LOAD funktionieren (Disk MVP)
- Zeichen korrekt dargestellt
