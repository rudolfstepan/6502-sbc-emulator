# VIC Graphics Test

Umfassendes Test-Programm für den VIC Bitmap-Modus (320x200 Pixel).

## Schnellstart

```bash
# Programm ist bereits in data/disk/basic.prg
./sbc6502
```

Im Emulator:
```
BASIC
LOAD
RUN
```

## Was das Programm testet

Das Programm führt 6 verschiedene Grafik-Tests durch:

1. **Horizontale Linien** - Zeichnet horizontale Linien im Abstand von 20 Pixeln
2. **Vertikale Linien** - Zeichnet vertikale Linien im Abstand von 32 Pixeln
3. **Schachbrett-Muster** - Zeichnet ein Checkerboard-Muster
4. **Rechteck** - Zeichnet ein Rechteck (50,40) bis (270,160)
5. **Diagonale Linie** - Zeichnet eine Diagonale von oben-links nach unten-rechts
6. **Vollbild** - Füllt den gesamten Bildschirm mit weißen Pixeln

Jeder Test wird für ca. 2 Sekunden angezeigt, dann wird der Bildschirm gelöscht und der nächste Test startet.

## Technische Details

**Memory-Map:**
- VIC Control Register: `$9000` (36864)
  - Wert `0`: Text-Modus (40x25)
  - Wert `1`: Bitmap-Modus (320x200)
- Bitmap RAM: `$9010-$AF4F` (36880-44879, 8000 Bytes)

**Pixel-Formel:**
```basic
X = 0-319  (horizontal)
Y = 0-199  (vertikal)
BYTE_OFFSET = Y * 40 + X / 8
BIT_POSITION = X AND 7
ADDRESS = 36880 + BYTE_OFFSET
```

**Pixel setzen:**
```basic
POKE ADDRESS, PEEK(ADDRESS) OR (2^BIT_POSITION)
```

**Pixel löschen:**
```basic
POKE ADDRESS, PEEK(ADDRESS) AND (255 - 2^BIT_POSITION)
```

## Eigene Programme erstellen

**Von Text-Datei:**
```bash
# Programm in examples/mygfx.txt erstellen
nano examples/mygfx.txt

# Konvertieren
python3 tools/basic_convert.py examples/mygfx.txt data/disk/basic.prg

# Laden im Emulator
./sbc6502
BASIC
LOAD
RUN
```

**Minimales Beispiel:**
```basic
10 REM Switch to graphics
20 POKE 36864,1
30 REM Draw pixel at (100,50)
40 A=36880+(50*40+100/8)
50 POKE A,PEEK(A) OR (2^(100 AND 7))
60 REM Wait for key
70 GET K$: IF K$="" THEN 70
80 REM Back to text mode
90 POKE 36864,0
100 END
```

## Weitere Beispiele

- `examples/hello.txt` - Einfaches Hello World
- `examples/graphics.txt` - Interaktive Grafik-Demo
- `examples/gfxtest.txt` - Dieser automatische Test (154 Zeilen)

## Performance-Hinweise

- Das Zeichnen von vielen Pixeln ist langsam (BASIC interpretiert)
- Delay-Loops (`FOR W=1 TO 2000: NEXT W`) sind ungefähr, nicht exakt
- Für schnellere Grafik: Assembler-Routinen via `SYS` nutzen
