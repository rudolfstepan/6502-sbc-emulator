# PIX16 FPGA Tools — GUI Launcher

`fpga/tools/fpga_tools_gui.py` ist ein grafisches Frontend für alle Python-Werkzeuge im `fpga/tools/`-Verzeichnis.  Es ersetzt das manuelle Aufrufen der CLI-Skripte und bündelt Build, Upload, SD-Image-Erzeugung und Utilitys in einer einzigen Oberfläche.

## Starten

```powershell
python fpga/tools/fpga_tools_gui.py
```

Python 3.6+ und `tkinter` (in der Standard-Python-Distribution enthalten) sind die einzigen Abhängigkeiten.

## Aufbau der Oberfläche

```
┌──────────────────────────────────────────┐
│  PIX16 FPGA Tools          [Titelzeile]  │
├──────────────────────────────────────────┤
│  [ Build ] [ Upload ] [ SD Card ] [ Utilities ]  ← Tab-Leiste │
│  ┌────────────────────────────────────┐  │
│  │  Sektionen mit Optionen & Buttons  │  │
│  └────────────────────────────────────┘  │
├──────────────────────────────────────────┤
│  OUTPUT                          [Clear] │
│  ┌────────────────────────────────────┐  │
│  │  gestreamte Prozessausgabe         │  │
│  └────────────────────────────────────┘  │
├──────────────────────────────────────────┤
│  Status …                    [■  Stop]   │
└──────────────────────────────────────────┘
```

Das Fenster ist zweigeteilt: oben ein Notebook mit vier Tabs, unten ein scrollbares Ausgabe-Konsolenfenster.  Der **Stop**-Button bricht den laufenden Prozess jederzeit ab.  Es kann immer nur ein Prozess gleichzeitig laufen.

---

## Tab: Build

### Build EhBASIC ROM

Ruft `build_fpga_ehbasic.py` auf und assembliert `ehbasic_fpga.s` + `kernel.rom` zu `fpga/roms/fpga_ehbasic_16kb.rom` (16 KB, `$C000–$FFFF`).

| Option | Flag | Beschreibung |
|---|---|---|
| Upload to board | `--upload --port PORT` | Lädt das ROM nach dem Build per UART-Monitor hoch |
| Run after upload | `--run` | Sendet `G C000` an den Monitor |
| Also generate SD image | `--sd-image` | Erzeugt zusätzlich ein SD-Boot-Image (`.img`) |
| Verbose | `--verbose` | Zeigt Monitor-Antworten im Konsolenbereich |
| Port | `--port` | Serieller Port, z. B. `COM15` |
| Baud | `--baud` | Baudrate, Standard `115200` |

### Build SDRAM Diagnostic ROM

Ruft `build_diag_sdram.py` auf und assembliert `diag_sdram.s` → `diag_sdram.rom` (16 KB).  Testet den CPU→SDRAM-Schreibpfad auf der Hardware.

| Option | Flag | Beschreibung |
|---|---|---|
| Upload to board | `--upload --port PORT` | Hochladen nach Build |
| Verbose | `--verbose` | Ausführliche Ausgabe |
| Port | (Eingabefeld) | Serieller Port |

### Build Upload Demo ROM

Ruft `make_upload_demo_rom.py` ohne weitere Argumente auf.  Erzeugt `upload_demo.rom` mit LED-Blink, VGA-Text und UART-Banner.

---

## Tab: Upload

### Upload via UART Monitor

Ruft `upload_monitor_hex.py` (oder `upload_monitor_hex_enter.py` wenn *Send ENTER* aktiviert) auf.

> **Voraussetzung:** Zuerst **KEY0** auf dem Board drücken, um den Monitor-Modus zu aktivieren.

| Feld / Option | Flag | Beschreibung |
|---|---|---|
| ROM Image | (Pfadauswahl) | `.rom`-  oder `.bin`-Datei; Standardpfad `fpga/roms/fpga_ehbasic_16kb.rom` |
| Port | `--port` | Serieller Port |
| Baud | `--baud` | Baudrate |
| Address | `--address` | Zieladresse im RAM, Standard `0xC000` |
| Run after upload | `--run` | Springt nach dem Upload zur Adresse (`G <addr>`) |
| Send ENTER after run | — | Wechselt zum `_enter`-Skript, das nach dem Start ein CR sendet (EhBASIC Cold-Start) |
| Verbose | `--verbose` | Monitor-Antworten anzeigen |
| Build demo ROM first | `--build-demo` | Baut zuerst das Demo-ROM, dann Upload |

### Upload BASIC Program

Ruft `upload_basic_uart.py` auf.  EhBASIC muss bereits auf dem Board laufen und am Prompt warten.

| Feld / Option | Flag | Beschreibung |
|---|---|---|
| BASIC File | (Pfadauswahl) | `.bas`-Datei |
| Port | `--port` | Serieller Port |
| Baud | `--baud` | Baudrate |
| Send NEW before upload | `--new` | Löscht das aktuelle Programm |
| Send RUN after upload | `--run` | Startet das Programm direkt |
| Verbose | `--verbose` | BASIC-Antworten anzeigen |

---

## Tab: SD Card

### Create SD Boot Image

Ruft `make_sd_boot_image.py` auf und erzeugt ein rohes Disk-Image:

- **Sektor 0** — Boot-Header: Magic `SBCROM01` + CRC32
- **Sektoren 1–32** — 16 KB ROM-Payload

| Feld | Beschreibung |
|---|---|
| ROM File | Eingabe-ROM (`.rom`/`.bin`), Pfad-Browser verfügbar |
| Output Image | Ausgabepfad für das `.img`-File, Speichern-Dialog verfügbar |

Tipp: An den ROM-Pfad `@0x0000` anhängen, um das ROM an einem bestimmten Offset zu platzieren.

### Write to SD Card

Anleitungen zum Schreiben des Images auf eine SD-Karte (nur Anzeige, kein Button):

```
Linux / macOS:  dd if=fpga_ehbasic_16kb.img of=/dev/sdX bs=512
Windows:        Win32DiskImager  oder  tools\write_sd.bat <image>
```

---

## Tab: Utilities

### News to UART

Ruft `news_to_uart.py` auf.  Holt RSS/Atom-Schlagzeilen und sendet sie fortlaufend an die UART-Konsole des Boards.  EhBASIC oder ein UART-fähiges ROM muss laufen.

| Feld / Option | Flag | Beschreibung |
|---|---|---|
| Port | `--port` | Serieller Port |
| Baud | `--baud` | Baudrate, Standard `230400` |
| Interval (s) | `--interval` | Pause zwischen zwei Schlagzeilen in Sekunden |
| Refresh (s) | `--refresh` | Feed-Aktualisierungsintervall in Sekunden |
| Send one batch and exit | `--once` | Einmalig senden, dann beenden |

---

## Ausgabe-Konsole

Die Konsole streamt die Ausgabe des laufenden Prozesses in Echtzeit.  Farbkodierung:

| Farbe | Bedeutung |
|---|---|
| Grün | Erfolg / Exit-Code 0 |
| Rot | Fehler / Exit-Code ≠ 0 |
| Gelb | Warnungen |
| Blau (Accent) | Prozess-Header |
| Grau (dim) | Kommandozeile / Trennlinien |

Der **Clear**-Button leert die Konsole.

---

## Gleichzeitige Prozesse

Es läuft immer nur **ein Prozess** gleichzeitig.  Wird ein zweiter gestartet, bevor der erste beendet ist, erscheint eine Warnung in der Konsole.  Der **Stop**-Button (`■  Stop`) in der Statuszeile bricht den aktuellen Prozess ab (`SIGTERM`).

---

## Verwandte Werkzeuge (CLI)

| Skript | Funktion |
|---|---|
| `build_fpga_ehbasic.py` | EhBASIC-ROM assemblieren + optional hochladen |
| `build_diag_sdram.py` | SDRAM-Diagnose-ROM assemblieren |
| `make_upload_demo_rom.py` | Demo-ROM erzeugen |
| `upload_monitor_hex.py` | ROM per UART-Monitor hochladen |
| `upload_monitor_hex_enter.py` | Wie oben + automatisches CR nach Start |
| `upload_basic_uart.py` | BASIC-Programm per UART hochladen |
| `make_sd_boot_image.py` | SD-Boot-Image mit Header und CRC erzeugen |
| `news_to_uart.py` | RSS-Feed an UART senden |

Alle Skripte lassen sich weiterhin direkt auf der Kommandozeile aufrufen; das GUI ist nur ein bequemer Wrapper.

---

Siehe auch:
- [UART Monitor](./UART_MONITOR.md) — Monitor-Kommandos und Protokoll
- [SD Bootloader](./SD_BOOTLOADER_PLAN.md) — SD-Boot-Image-Format und Boot-Ablauf
- [Building & Synthesis](./03_BUILDING.md) — GHDL-Build und Synthese-Flow
