# MS BASIC Text Converter

Tool zum Konvertieren zwischen tokenisierten `.prg` Dateien und lesbaren `.txt` Dateien.

## Verwendung

### PRG → Text (Detokenisieren)
```bash
python3 tools/basic_convert.py data/disk/basic.prg program.txt
```

### Text → PRG (Tokenisieren)
```bash
python3 tools/basic_convert.py program.txt data/disk/basic.prg
```

## Beispiel

**program.txt erstellen:**
```basic
10 REM HELLO WORLD
20 PRINT "HELLO, WORLD!"
30 FOR I=1 TO 10
40 PRINT I
50 NEXT I
60 END
```

**Konvertieren und laden:**
```bash
# Text zu PRG konvertieren
python3 tools/basic_convert.py program.txt data/disk/basic.prg

# Im Emulator laden
./sbc6502
BASIC
LOAD
LIST
RUN
```

## Workflow: Programme außerhalb des Emulators bearbeiten

1. **Exportieren:** Programm im Emulator mit `SAVE` speichern
2. **Konvertieren:** `python3 tools/basic_convert.py data/disk/basic.prg program.txt`
3. **Bearbeiten:** `program.txt` in einem Editor öffnen
4. **Konvertieren:** `python3 tools/basic_convert.py program.txt data/disk/basic.prg`
5. **Laden:** Im Emulator mit `LOAD` laden

## Unterstützte Tokens

Alle MS BASIC V2 Befehle (wie C64/PET/Apple II):
- Befehle: `END`, `FOR`, `NEXT`, `DATA`, `INPUT`, `DIM`, `READ`, `LET`, `GOTO`, `RUN`, `IF`, `RESTORE`, `GOSUB`, `RETURN`, `REM`, `STOP`, `ON`, `WAIT`, `LOAD`, `SAVE`, `PRINT`, `LIST`, `CLR`, `SYS`, `NEW`, etc.
- Funktionen: `TAB`, `FN`, `SPC`, `SGN`, `INT`, `ABS`, `FRE`, `POS`, `SQR`, `RND`, `LOG`, `EXP`, `COS`, `SIN`, `TAN`, `ATN`, `PEEK`, `LEN`, `STR$`, `VAL`, `ASC`, `CHR$`, `LEFT$`, `RIGHT$`, `MID$`, etc.
- Operatoren: `+`, `-`, `*`, `/`, `^`, `AND`, `OR`, `NOT`, `>`, `=`, `<`, `TO`, `THEN`, `STEP`

## Format

### Text-Datei (.txt)
- Eine Zeile pro BASIC-Zeile
- Format: `<Zeilennummer> <Code>`
- Kommentare mit `#` am Zeilenanfang werden ignoriert
- Leerzeilen werden ignoriert

### PRG-Datei (.prg)
- Tokenisiertes Binärformat
- Link-Adresse + Zeilennummer + Tokens + 0x00
- Ende-Marker: 0x00 0x00
