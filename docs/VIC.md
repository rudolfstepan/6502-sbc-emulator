# VIC - Video Interface Controller

## Übersicht

Der VIC (Video Interface Controller) ist ein einfacher Text-Modus-Videochip für das 6502 SBC-System. Er stellt einen 40x25 Zeichen-Bildschirm mit einem eingebauten 8x8-Pixel-Zeichensatz bereit.

**NEU**: Der VIC unterstützt jetzt SDL2-basiertes grafisches Rendering in einem eigenen Fenster!

## Hardware-Spezifikationen

### Video RAM (Dual-Port)
- **Adresse**: $8000-$87FF (2KB)
- **Größe**: 2048 Bytes
- **Zugriff**: CPU und VIC können gleichzeitig darauf zugreifen (Dual-Port RAM)
- **Layout**: Linear, 40 Zeichen pro Zeile, 25 Zeilen

### Charakter ROM
- **8x8 Pixel Font**
- **256 ASCII-Zeichen** (0x00-0xFF)
- **Fest eingebaut** (nicht vom CPU aus änderbar)
- **Vollständiger ASCII-Zeichensatz** (0x20-0x7E)

### Bildschirm-Modus
- **Text-Modus**: 40 Spalten × 25 Zeilen
- **Gesamt**: 1000 Zeichen pro Bildschirm
- **Farbunterstützung**: Vorbereitet (aktuell nicht implementiert)

## Memory Map

### Video RAM Layout

```
Zeile  Adressbereich          Bytes
--------------------------------------------
  0    $8000 - $8027          40 (0x28)
  1    $8028 - $804F          40
  2    $8050 - $8077          40
  3    $8078 - $809F          40
  ...
 24    $83D0 - $83F7          40
--------------------------------------------
Total: 1000 Bytes (0x3E8)
```

Die verbleibenden 1048 Bytes ($83F8-$87FF) sind reserviert für zukünftige Erweiterungen (z.B. Farb-RAM, Attribute).

## Programmierung

### SDL2 Grafische Ausgabe

Der VIC unterstützt SDL2-basiertes grafisches Rendering. Wenn SDL2 verfügbar ist, wird automatisch ein Fenster mit 640x400 Pixeln (2x skaliert) geöffnet, das den VIC-Bildschirm anzeigt.

**Features:**
- **Auflösung**: 640x400 Pixel (40x25 Zeichen à 8x8 Pixel, 2x skaliert)
- **Farben**: C64-inspiriertes Farbschema (blauer Hintergrund, hellblaue Schrift)
- **Refresh-Rate**: ~100 FPS (synchronisiert mit CPU-Taktung)
- **Window-Titel**: "6502 SBC - VIC Display"
- **Steuerung**: ESC-Taste oder Fenster schließen zum Beenden

**Systemanforderungen:**
- SDL2 Library (`libsdl2-dev` auf Debian/Ubuntu)
- Grafische Desktop-Umgebung (X11, Wayland, etc.)

**Installation auf Linux:**
```bash
sudo apt-get install libsdl2-dev
```

**Fallback:**
Wenn SDL2 nicht verfügbar ist oder die Initialisierung fehlschlägt, fällt das System automatisch auf Text-Ausgabe zurück.

### Von C aus

```c
#include "vic.h"

// VIC initialisieren
vic_init();

// Bildschirm löschen
vic_clear_screen();

// Text schreiben
vic_write_string("Hello, World!\n");

// Einzelnes Zeichen schreiben
vic_write_char('A');

// Cursor positionieren
vic_set_cursor(10, 5);  // Spalte 10, Zeile 5

// Direkt ins Video RAM schreiben
vic_write_video_ram(0, 'H');  // Erstes Zeichen

// Aus Video RAM lesen
uint8_t ch = vic_read_video_ram(0);

// Bildschirm rendern (für Debugging)
vic_render_screen();
```

### Von 6502 Assembly aus

```asm
; Video RAM Basis-Adresse
VIC_BASE = $8000

; Zeichen 'A' an Position (0,0) schreiben
LDA #'A'
STA VIC_BASE

; "HELLO" an den Anfang schreiben
LDX #0
LDA #'H'
STA VIC_BASE,X
INX
LDA #'E'
STA VIC_BASE,X
; ... usw.

; Zeichen an Position (Column, Row) schreiben
; Position = Row * 40 + Column
; Beispiel: (5, 2) = 2 * 40 + 5 = 85 = $55
LDA #'X'
STA VIC_BASE+$55

; Ganze Zeile mit Zeichen füllen
LDX #0
LDA #'-'
loop:
    STA VIC_BASE,X
    INX
    CPX #40
    BNE loop

; Bildschirm löschen (mit Leerzeichen füllen)
LDA #$20        ; Space
LDX #$00
clear_loop:
    STA VIC_BASE,X
    STA VIC_BASE+$100,X
    STA VIC_BASE+$200,X
    STA VIC_BASE+$300,X
    INX
    BNE clear_loop
```

## API-Referenz

### Initialisierung

```c
void vic_init(void);
```
Initialisiert den VIC, löscht das Video RAM und setzt den Cursor auf (0,0).

### Zeichen- und String-Ausgabe

```c
void vic_write_char(char ch);
```
Schreibt ein Zeichen an der aktuellen Cursor-Position und bewegt den Cursor weiter.
Unterstützt: `\n` (neue Zeile), `\r` (Wagenrücklauf), `\b` (Rücktaste).

```c
void vic_write_string(const char* str);
```
Schreibt einen nullterminierten String an der aktuellen Cursor-Position.

### Bildschirm-Kontrolle

```c
void vic_clear_screen(void);
```
Löscht den gesamten Bildschirm (füllt mit Leerzeichen) und setzt den Cursor auf (0,0).

```c
void vic_scroll_up(void);
```
Scrollt den Bildschirm um eine Zeile nach oben. Die unterste Zeile wird gelöscht.

### Cursor-Kontrolle

```c
void vic_set_cursor(uint8_t x, uint8_t y);
```
Setzt den Cursor auf die angegebene Position (x = Spalte, y = Zeile).
Gültige Werte: x = 0-39, y = 0-24.

```c
void vic_get_cursor(uint8_t* x, uint8_t* y);
```
Liest die aktuelle Cursor-Position.

### Direkter Video RAM Zugriff

```c
void vic_write_video_ram(uint16_t address, uint8_t data);
```
Schreibt direkt ins Video RAM (Adresse relativ zu $8000).

```c
uint8_t vic_read_video_ram(uint16_t address);
```
Liest direkt aus dem Video RAM (Adresse relativ zu $8000).

### Charakter ROM

```c
const uint8_t* vic_get_char_pattern(uint8_t char_code);
```
Gibt einen Zeiger auf das 8x8 Pixel-Muster für ein Zeichen zurück.
Jedes Muster ist ein Array von 8 Bytes (ein Byte pro Zeile).

### Rendering

```c
void vic_render_screen(void);
```
Rendert den Bildschirm (für Debugging, gibt den Inhalt auf die Konsole aus).

## SDL2 Display API

### Initialisierung und Verwaltung

```c
int vic_sdl_init(void);
```
Initialisiert SDL2-Rendering für den VIC.
- Rückgabe: 0 bei Erfolg, -1 bei Fehler
- Erstellt ein 640x400 Pixel Fenster
- Allokiert Framebuffer und Texturen

```c
void vic_sdl_shutdown(void);
```
Fährt SDL2-Rendering herunter und gibt Ressourcen frei.

```c
void vic_sdl_render(void);
```
Rendert den VIC-Bildschirm in das SDL-Fenster.
- Liest Video-RAM
- Konvertiert Zeichen zu Pixeln mittels Charakter-ROM
- Aktualisiert SDL-Fenster

```c
bool vic_sdl_handle_events(void);
```
Verarbeitet SDL-Events (Tastatur, Fenster-Schließen).
- Rückgabe: `true` zum Fortfahren, `false` zum Beenden
- ESC-Taste beendet die Anwendung
- Fenster-Schließen-Button beendet die Anwendung

```c
bool vic_sdl_enabled(void);
```
Prüft, ob SDL-Rendering aktiv ist.
- Rückgabe: `true` wenn SDL aktiv, `false` sonst

### Interne Funktionen

Die SDL2-Implementation verwendet:
- **Framebuffer**: 640x400 Pixel, ARGB8888 Format
- **Texture Streaming**: Für performantes Rendering
- **Hardware-beschleunigtes Rendering**: Wenn verfügbar
- **2x Pixel-Skalierung**: Für bessere Lesbarkeit auf modernen Displays

## Bus-Integration

Der VIC ist in den System-Bus integriert und kann von der CPU über normale Speicherzugriffe verwendet werden:

```c
// Bus-Callback-Funktionen
uint8_t vic_bus_read(void *dev, uint16_t offset);
void vic_bus_write(void *dev, uint16_t offset, uint8_t val);
void vic_bus_tick(void *dev, uint32_t cycles);
```

Registrierung im Bus (in main.c):
```c
bus_register(&bus, "VIC-VIDEO", NULL,
             0x8000, 2048,
             vic_bus_read, vic_bus_write, vic_bus_tick);
```

## Charakter-Set

Der VIC enthält ein vollständiges 8x8-Pixel-Font für alle 256 ASCII-Zeichen:

- **0x00-0x1F**: Steuerzeichen (leer angezeigt)
- **0x20**: Leerzeichen
- **0x21-0x7E**: Druckbare ASCII-Zeichen (!-~)
  - 0x21-0x2F: Sonderzeichen (!"#$%&'()*+,-./)
  - 0x30-0x39: Ziffern (0-9)
  - 0x3A-0x40: Sonderzeichen (:;<=>?@)
  - 0x41-0x5A: Großbuchstaben (A-Z)
  - 0x5B-0x60: Sonderzeichen ([\]^_`)
  - 0x61-0x7A: Kleinbuchstaben (a-z)
  - 0x7B-0x7E: Sonderzeichen ({|}~)
- **0x7F**: Delete (leer)
- **0x80-0xFF**: Erweitert (reserviert, aktuell leer)

## Beispiele

### Beispiel 1: "Hello, World!"

```c
vic_init();
vic_clear_screen();
vic_write_string("Hello, World!\n");
vic_render_screen();
```

### Beispiel 2: Bildschirm-Layout

```c
vic_init();
vic_clear_screen();
vic_write_string("6502 SBC - Video Interface Controller\n");
vic_write_string("======================================\n\n");
vic_write_string("System ready.\n");
```

### Beispiel 3: Direkte Positionierung

```c
vic_init();
vic_clear_screen();

// Schreibe "TOP LEFT" oben links
vic_set_cursor(0, 0);
vic_write_string("TOP LEFT");

// Schreibe "CENTER" in der Mitte
vic_set_cursor(17, 12);
vic_write_string("CENTER");

// Schreibe "BOTTOM RIGHT" unten rechts
vic_set_cursor(27, 24);
vic_write_string("BOTTOM RIGHT");
```

### Beispiel 4: Rahmen zeichnen

```c
vic_init();
vic_clear_screen();

// Obere Linie
vic_set_cursor(0, 0);
for (int i = 0; i < 40; i++) {
    vic_write_char('-');
}

// Untere Linie
vic_set_cursor(0, 24);
for (int i = 0; i < 40; i++) {
    vic_write_char('-');
}

// Seitliche Linien
for (int y = 1; y < 24; y++) {
    vic_set_cursor(0, y);
    vic_write_char('|');
    vic_set_cursor(39, y);
    vic_write_char('|');
}

// Titel
vic_set_cursor(15, 12);
vic_write_string("FRAMED!");
```

## Zukünftige Erweiterungen

Mögliche zukünftige Verbesserungen:

1. **Farb-RAM**: Zweites 1KB RAM für Zeichenfarben
2. **Hardware-Cursor**: Blinkender Cursor
3. **Hardware-Scrolling**: Automatisches Scrolling bei Zeilenüberlauf
4. **Sprite-Unterstützung**: Einfache bewegliche Objekte
5. **Grafikmodus**: Pixel-basierter Modus (z.B. 320x200)
6. **Mehrere Zeichensätze**: Umschaltbare Font-Sets
7. **Video-Interrupts**: IRQ bei VSync/Refresh

## Dateien

- `src/vic.c` - VIC-Implementierung (Kern-Funktionalität)
- `src/vic.h` - VIC-Header
- `src/vic_sdl.c` - SDL2-Rendering-Implementierung
- `src/vic_sdl.h` - SDL2-Rendering-Header
- `examples/vic_demo.c` - C Demo-Programm
- `examples/vic_test.s` - Assembly Test-Programm
- `docs/VIC.md` - Diese Dokumentation

## Kompilierung

Das Projekt benötigt SDL2 zum Kompilieren:

```bash
# SDL2 installieren (Debian/Ubuntu)
sudo apt-get install libsdl2-dev

# Projekt kompilieren
make clean && make

# Ausführen
./sbc6502
```

Das Makefile erkennt SDL2 automatisch und linkt die Bibliothek ein.

## Siehe auch

- [ARCHITECTURE.md](ARCHITECTURE.md) - Gesamt-Systemarchitektur
- [README.md](../README.md) - Projekt-Übersicht
