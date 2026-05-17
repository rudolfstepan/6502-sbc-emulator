# MS BASIC für 6502 SBC

## Übersicht

Das MS BASIC ROM ist jetzt vollständig in den 6502 SBC Emulator integriert und verwendet die VIA6522/VIC-Hardware für Keyboard-Eingabe und Bildschirm-Ausgabe.

## Schnellstart

```bash
cd /home/rudolf/repos/6502
./sbc6502 sbc.ini
```

Das SDL-Fenster öffnet sich und MS BASIC startet automatisch mit:

```
6502 SBC - MS BASIC V2
KEYBOARD & VIC READY

XXXX BYTES FREE

READY.
```

## Verwendung

### Grundlegende BASIC-Befehle

```basic
10 PRINT "HELLO WORLD"
20 GOTO 10
RUN

LIST
NEW
```

### Programmierung

```basic
10 FOR I=1 TO 10
20 PRINT "NUMBER: "; I
30 NEXT I
RUN
```

### Speichern und Laden

MS BASIC unterstützt LOAD/SAVE über das DISK MVP-System:

```basic
SAVE
LOAD
```

Programme werden im Verzeichnis `data/disk/` als Dateien gespeichert.

## Hardware-Integration

### Keyboard (VIA6522 Port A)
- **Adresse**: `$8801` (VIA_ORA)
- **Modus**: Input (DDRA = $00)
- **Interrupt**: CA1 signalisiert verfügbare Tasten
- **Puffer**: 16-Zeichen FIFO im VIA

### Bildschirm (VIC)
- **Video RAM**: `$8000-$87FF` (2KB)
- **Auflösung**: 40 Zeichen x 25 Zeilen
- **Cursor**: Wird automatisch verwaltet
- **Auto-Scroll**: Bei Zeilenende

### I/O-Routinen (Assembly)

MS BASIC verwendet diese Routinen für I/O:

```assembly
MONRDKEY_NB:  ; Nicht-blockierendes Lesen (A=char, Carry=status)
MONRDKEY:     ; Blockierendes Lesen mit Echo
MONCOUT:      ; Zeichen ausgeben (A=char)
```

## Tastatur-Steuerung

| Taste | Funktion |
|-------|----------|
| Enter | Zeile ausführen / Eingabe bestätigen |
| Backspace | Zeichen löschen |
| ESC | Emulator beenden |
| A-Z, 0-9 | Normaler Text |

## Beispiel-Programme

### Endlos-Schleife
```basic
10 PRINT "HELLO"
20 GOTO 10
RUN
```

Zum Stoppen: Schließen Sie das SDL-Fenster oder drücken Sie ESC.

### Zähler
```basic
10 FOR I=1 TO 100
20 PRINT I;" ";
30 NEXT I
RUN
```

### Eingabe
```basic
10 INPUT "YOUR NAME"; N$
20 PRINT "HELLO "; N$
RUN
```

### Multiplikationstabelle
```basic
10 FOR I=1 TO 10
20 FOR J=1 TO 10
30 PRINT I*J; " ";
40 NEXT J
50 PRINT
60 NEXT I
RUN
```

## Bekannte Einschränkungen

1. **Keine Ctrl+C Unterbrechung**: Programme können nicht mit Ctrl+C gestoppt werden (nur durch Schließen des Fensters)
2. **40-Zeichen-Breite**: Zeilen werden nach 40 Zeichen umgebrochen
3. **Auto-Scroll**: Bildschirm scrollt automatisch nach unten
4. **Keine Cursor-Tasten**: Pfeiltasten werden noch nicht unterstützt

## Technische Details

### Memory Map
```
$0000-$00FF   Zero Page (BASIC-Variablen)
$0100-$01FF   Stack
$0300-$7FFF   BASIC-Programm und Variablen
$8000-$87FF   VIC Video RAM (dual-port)
$8800-$880F   VIA 6522 (Keyboard)
$8810-$8813   UART 6551 (unbenutzt in BASIC)
$8820-$882F   DISK MVP (LOAD/SAVE)
$C000-$FFFF   MS BASIC ROM
```

### BASIC-Variablen

- **TXTTAB**: Start des BASIC-Programms (`$0300`)
- **VARTAB**: Start der Variablen
- **MEMSIZ**: Ende des verfügbaren RAM
- **Freier Speicher**: ca. 30KB für Programme

## Neues ROM erstellen

Falls Sie Änderungen an den I/O-Routinen vornehmen:

```bash
cd /home/rudolf/repos/6502
bash tools/make_msbasic_rom.sh
./sbc6502 sbc.ini
```

## Source-Code

- **I/O-Routinen**: `tools/msbasic_port/sbc6502_extra.s`
- **Konfiguration**: `tools/msbasic_port/defines_sbc6502.s`
- **LOAD/SAVE**: `tools/msbasic_port/sbc6502_loadsave.s`
- **Interrupt Check**: `tools/msbasic_port/sbc6502_iscntc.s`
- **Linker Config**: `tools/msbasic_port/sbc6502.cfg`

## Upstream

MS BASIC basiert auf [mist64/msbasic](https://github.com/mist64/msbasic) - Microsoft BASIC für verschiedene 6502-Systeme.

## Fehlersuche

### BASIC startet nicht
- Prüfen Sie, dass `roms/msbasic.rom` existiert und 16KB groß ist
- Starten Sie mit `-d` Flag für Debug-Modus: `./sbc6502 -d sbc.ini`

### Keine Tastatureingabe
- VIA muss bei `$8800` konfiguriert sein (siehe `sbc.ini`)
- Port A muss als Input konfiguriert sein (DDRA = $00)
- CA1 Interrupt muss aktiviert sein (IER = $82)

### Bildschirm bleibt leer
- VIC Video RAM muss bei `$8000` sein
- SDL2 muss korrekt initialisiert sein
- Prüfen Sie die Konsolen-Ausgabe auf Fehlermeldungen

## Weitere Informationen

- [docs/KEYBOARD.md](../docs/KEYBOARD.md) - Keyboard-Programmierung
- [docs/VIC.md](../docs/VIC.md) - VIC-Dokumentation
- [README.md](../README.md) - Hauptdokumentation

## Viel Spaß mit MS BASIC!

```
READY.
_
```
