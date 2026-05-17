# Keyboard Integration für 6502 SBC

## Übersicht

Das Keyboard-System ist jetzt vollständig in den 6502 SBC Emulator integriert. Es verwendet den VIA6522 (Versatile Interface Adapter) Port A für die Tastatureingabe.

## Hardware-Architektur

### VIA6522 Keyboard-Interface
- **Adresse**: `$8800` (VIA_BASE)
- **Port A** (`$8801`): Keyboard-Eingabe (DDRA = $00 für Input)
- **Interrupt**: CA1 wird gesetzt wenn Taste verfügbar

### Keyboard-Puffer
- **Größe**: 16 Zeichen FIFO-Ringpuffer
- **Interrupt**: CA1 Interrupt signalisiert verfügbare Tasten
- **Auto-Echo**: Tastatureingaben werden automatisch auf dem VIC-Display angezeigt

## Software-Komponenten

### 1. VIA6522 Erweiterungen
**Dateien**: `src/via6522.h`, `src/via6522.c`

Neue Funktionen:
- `via_keyboard_push()` - Fügt Zeichen zum Puffer hinzu
- `via_keyboard_available()` - Prüft ob Zeichen verfügbar
- `via_keyboard_pop()` - Liest Zeichen aus dem Puffer

### 2. SDL Keyboard-Handler
**Datei**: `src/vic_sdl.c`

- Konvertiert SDL-Tastatur-Events zu ASCII
- Unterstützt: Buchstaben, Zahlen, Sonderzeichen
- Auto-Echo zum VIC-Display
- ESC-Taste zum Beenden

### 3. Keyboard-API
**Datei**: `src/keyboard.h`

- `get_keyboard_via()` - Gibt VIA-Pointer für Keyboard zurück

## 6502 Programmierung

### Assembly-Beispiel
Siehe: `examples/keyboard_io.s`

```assembly
; Keyboard initialisieren
jsr init_io

; Zeichen lesen (blockierend)
loop:
    jsr getchar          ; Liest Zeichen in A
    bcc loop             ; Kein Zeichen? Weiter warten
    jsr putchar          ; Zeichen ausgeben
    jmp loop
```

### C-Beispiel
Siehe: `examples/keyboard_io.c`

```c
#include "keyboard_io.h"

void main(void) {
    uint8_t ch;
    
    init_io();
    println("Hello World!");
    
    while (1) {
        ch = getchar();      // Blockierend lesen
        if (ch == 0x1B) break; // ESC zum Beenden
        putchar(ch);         // Echo
    }
}
```

## API-Referenz

### Assembly-Routinen

#### `init_io`
Initialisiert VIA und VIC für I/O
- **Input**: Keine
- **Output**: Keine
- **Verändert**: A, X, Y

#### `getchar`
Liest ein Zeichen vom Keyboard (nicht blockierend)
- **Input**: Keine
- **Output**: A = ASCII-Zeichen (0 wenn keins verfügbar)
- **Carry**: Gesetzt wenn Zeichen verfügbar

#### `putchar`
Schreibt ein Zeichen zum VIC-Display
- **Input**: A = ASCII-Zeichen
- **Output**: Keine
- **Verändert**: A, X, Y
- **Unterstützt**: `\r`, `\n`, `\b` (Backspace)

#### `clear_screen`
Löscht den VIC-Bildschirm
- **Input**: Keine
- **Output**: Keine
- **Verändert**: A, X, Y

#### `scroll_up`
Scrollt Bildschirm eine Zeile nach oben
- **Input**: Keine
- **Output**: Keine
- **Verändert**: A, X

### C-Funktionen

```c
void init_io(void);                  // Initialisierung
void clear_screen(void);             // Bildschirm löschen
uint8_t getchar(void);               // Zeichen lesen (blockierend)
uint8_t getchar_nb(void);            // Zeichen lesen (nicht blockierend)
bool kbhit(void);                    // Prüft ob Taste gedrückt
void putchar(uint8_t ch);            // Zeichen ausgeben
void print(const char *str);         // String ausgeben
void println(const char *str);       // String mit Newline
void gotoxy(uint8_t x, uint8_t y);   // Cursor setzen
void scroll_up(void);                // Nach oben scrollen
```

## Memory Map

```
$0000-$7FFF   SRAM (32KB)
$8000-$87FF   VIC Video RAM (2KB, 40x25 Text)
$8800-$880F   VIA 6522 (Keyboard auf Port A)
$8810-$8813   UART 6551
$8820-$882F   DISK MVP
$C000-$FFFF   ROM (16KB, MS BASIC)
```

## VIA Register-Nutzung für Keyboard

| Register | Adresse | Zweck |
|----------|---------|-------|
| ORA      | $8801   | Port A Data (Keyboard lesen) |
| DDRA     | $8803   | Port A Direction ($00 = Input) |
| IFR      | $880D   | Interrupt Flags (Bit 1 = CA1/Keyboard) |
| IER      | $880E   | Interrupt Enable ($82 = Enable CA1) |

## Kompilieren von Beispielen

### Mit cc65 (C-Compiler für 6502):
```bash
cl65 -t none -O examples/keyboard_io.c -o keyboard.bin
```

### Mit ca65 (Assembler):
```bash
ca65 examples/keyboard_io.s -o keyboard.o
ld65 keyboard.o -o keyboard.bin
```

## Testen

1. Emulator starten:
   ```bash
   ./sbc6502 sbc.ini
   ```

2. Ein SDL-Fenster öffnet sich mit VIC-Display

3. Tippen Sie Text - er erscheint auf dem Bildschirm

4. ESC zum Beenden

## Tastatur-Mapping

| Taste | ASCII | Beschreibung |
|-------|-------|--------------|
| A-Z   | $41-$5A | Großbuchstaben (mit Shift) |
| a-z   | $61-$7A | Kleinbuchstaben |
| 0-9   | $30-$39 | Zahlen |
| Space | $20   | Leerzeichen |
| Enter | $0D   | Carriage Return |
| Backspace | $08 | Rücktaste |
| ESC   | $1B   | Escape (beendet Emulator) |

## Troubleshooting

### Keine Tastatureingabe
- Prüfen Sie, dass VIA bei $8800 konfiguriert ist
- Stellen Sie sicher, dass DDRA = $00 (Input-Modus)
- Aktivieren Sie CA1 Interrupt mit IER = $82

### Zeichen erscheinen nicht
- VIC Video RAM bei $8000 überprüfen
- Cursor-Position validieren (0-39, 0-24)

### Puffer-Überlauf
- Keyboard-Puffer fasst 16 Zeichen
- Lesen Sie regelmäßig mit `getchar()`

## Zukünftige Erweiterungen

- [ ] IRQ-Handler für asynchrones Keyboard-Processing
- [ ] Unterstützung für Funktionstasten (F1-F12)
- [ ] Cursor-Tasten (Pfeiltasten)
- [ ] Ctrl/Alt Modifier-Keys
- [ ] Konfigurierbare Tastatur-Layouts

## Autor

Rudolf - Mai 2026

## Siehe auch

- `docs/VIC.md` - VIC Video Interface Controller
- `docs/ARCHITECTURE.md` - System-Architektur
- `src/via6522.h` - VIA Hardware-Interface
