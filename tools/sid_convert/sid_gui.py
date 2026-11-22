"""Desktop frontend for building standalone SID ROMs."""

import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from rom_screen import DEFAULT_CREDIT, SCREEN_HEIGHT, SCREEN_WIDTH, title_screen
from sid_metadata import read_sid_metadata


BUILD_SCRIPT = Path(__file__).resolve().with_name("build_sid_rom.py")
ROOT = BUILD_SCRIPT.parents[2]


def read_integer(text, label, minimum, maximum):
    try:
        value = int(text)
    except ValueError as error:
        raise ValueError(
            f"{label} muss eine ganze Zahl von {minimum} bis {maximum} sein."
        ) from error
    if minimum <= value <= maximum:
        return value
    raise ValueError(f"{label} muss eine ganze Zahl von {minimum} bis {maximum} sein.")


class SidConverterWindow:
    def __init__(self, root):
        self.root = root
        root.title("SID-ROM-Konverter")
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.columnconfigure(0, weight=1)
        root.minsize(545, 0)
        root.resizable(True, False)

        self.input_path = tk.StringVar(value="")
        self.output_path = tk.StringVar(value="")
        self.title = tk.StringVar(value="")
        self.credit = tk.StringVar(value=DEFAULT_CREDIT)
        self.native = tk.BooleanVar(value=True)
        self.seconds = tk.StringVar(value="30")
        self.song = tk.StringVar(value="1")
        self.delay = tk.StringVar(value="200")
        self.status = tk.StringVar(value="SID-Datei und ROM-Ziel auswählen.")
        self.composer = ""
        self.songs = 1
        self.running = False
        self.results = queue.SimpleQueue()

        form = ttk.Frame(root, padding=20)
        form.grid(sticky="nsew")
        form.columnconfigure(0, weight=1)

        files = ttk.LabelFrame(form, text="Dateien", padding=10)
        files.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        files.columnconfigure(1, weight=1)
        for row, (label, variable, command) in enumerate((
            ("SID-Datei", self.input_path, self.choose_sid),
            ("ROM-Ziel", self.output_path, self.choose_output),
        )):
            ttk.Label(files, text=label).grid(row=row, column=0, sticky="w", pady=3)
            ttk.Entry(files, textvariable=variable, state="readonly").grid(
                row=row, column=1, sticky="ew", padx=8, pady=3,
            )
            button = ttk.Button(files, text="Auswählen …", command=command)
            button.grid(row=row, column=2, sticky="ew", pady=3)
            if row == 0:
                self.input_button = button
            else:
                self.output_button = button

        display = ttk.LabelFrame(form, text="Anzeige im ROM", padding=10)
        display.grid(row=1, column=0, sticky="ew", pady=(0, 10))
        display.columnconfigure(1, weight=1)
        ttk.Label(display, text="Spieltitel").grid(row=0, column=0, sticky="w", pady=3)
        self.title_entry = ttk.Entry(display, textvariable=self.title)
        self.title_entry.grid(row=0, column=1, sticky="ew", padx=(8, 0), pady=3)
        ttk.Label(display, text="Name im Hinweis").grid(row=1, column=0, sticky="w", pady=3)
        self.credit_entry = ttk.Entry(display, textvariable=self.credit)
        self.credit_entry.grid(row=1, column=1, sticky="ew", padx=(8, 0), pady=3)
        self.preview_button = ttk.Button(display, text="Vorschau …", command=self.show_preview)
        self.preview_button.grid(row=2, column=1, sticky="e", pady=3)

        playback = ttk.LabelFrame(form, text="Wiedergabe", padding=10)
        playback.grid(row=2, column=0, sticky="ew", pady=(0, 10))
        self.native_field = ttk.Checkbutton(
            playback, text="Original-SID an $D400 (sid.ini)", variable=self.native,
            command=self.update_controls,
        )
        self.native_field.grid(row=0, column=0, columnspan=2, sticky="w", pady=3)
        ttk.Label(playback, text="Ausschnitt in Sekunden").grid(row=1, column=0, sticky="w", pady=3)
        self.seconds_field = ttk.Spinbox(playback, from_=1, to=300, textvariable=self.seconds, width=8)
        self.seconds_field.grid(row=1, column=1, sticky="w", padx=10, pady=3)
        ttk.Label(playback, text="Stücknummer").grid(row=2, column=0, sticky="w", pady=3)
        self.song_field = ttk.Spinbox(playback, from_=1, to=1, textvariable=self.song, width=8)
        self.song_field.grid(row=2, column=1, sticky="w", padx=10, pady=3)
        ttk.Label(playback, text="Frame-Verzögerung in 0,1 ms").grid(
            row=3, column=0, sticky="w", pady=3,
        )
        self.delay_field = ttk.Spinbox(
            playback, from_=10, to=2000, increment=10, textvariable=self.delay, width=8,
        )
        self.delay_field.grid(row=3, column=1, sticky="w", padx=10, pady=3)

        actions = ttk.Frame(form)
        actions.grid(row=3, column=0, sticky="ew")
        actions.columnconfigure(0, weight=1)
        self.progress = ttk.Progressbar(actions, mode="indeterminate")
        self.progress.grid(row=0, column=0, sticky="ew", padx=(0, 12))
        self.progress.grid_remove()
        self.convert_button = ttk.Button(actions, text="ROM erstellen", command=self.convert)
        self.convert_button.grid(row=0, column=1, sticky="e")
        ttk.Label(form, textvariable=self.status, wraplength=495).grid(
            row=4, column=0, sticky="w", pady=(8, 0),
        )

        self.editable_widgets = (
            self.input_button, self.output_button, self.title_entry, self.credit_entry,
            self.preview_button,
            self.native_field, self.seconds_field, self.song_field, self.delay_field,
        )
        self.update_controls()
        self.input_button.focus_set()

    def update_controls(self):
        for widget in self.editable_widgets:
            widget.state(["disabled"] if self.running else ["!disabled"])
        if not self.input_path.get():
            self.output_button.state(["disabled"])
            self.title_entry.state(["disabled"])
            self.preview_button.state(["disabled"])
        if self.songs == 1:
            self.song_field.state(["disabled"])
        if self.native.get():
            self.seconds_field.state(["disabled"])
        ready = self.input_path.get() and self.output_path.get() and not self.running
        self.convert_button.state(["!disabled"] if ready else ["disabled"])

    def choose_sid(self):
        current = self.input_path.get()
        path = filedialog.askopenfilename(
            parent=self.root,
            title="SID-Datei öffnen",
            initialdir=str(Path(current).parent) if current else str(ROOT / "sid_demo"),
            filetypes=(("SID-Dateien", ("*.sid", "*.SID")), ("Alle Dateien", "*")),
        )
        if not path:
            return

        try:
            metadata = read_sid_metadata(Path(path))
        except (OSError, ValueError) as error:
            messagebox.showerror("SID-Datei konnte nicht geladen werden", str(error), parent=self.root)
            return

        self.input_path.set(path)
        self.output_path.set("")
        self.title.set(metadata.title)
        self.composer = metadata.composer
        self.songs = metadata.songs
        self.song.set(str(metadata.start_song))
        self.song_field.configure(to=self.songs)
        self.status.set("Ziel für das Standalone-ROM auswählen.")
        self.update_controls()

    def show_preview(self):
        screen = title_screen(self.title.get(), self.credit.get(), self.composer).decode("ascii")
        rows = [
            screen[offset:offset + SCREEN_WIDTH]
            for offset in range(0, len(screen), SCREEN_WIDTH)
        ]
        preview = tk.Toplevel(self.root)
        preview.title("ROM-Startbildschirm")
        preview.transient(self.root)
        preview.resizable(False, False)
        preview.bind("<Escape>", lambda event: preview.destroy())
        display = tk.Text(
            preview, width=SCREEN_WIDTH, height=SCREEN_HEIGHT, font="TkFixedFont",
            wrap="none", bg="#101410", fg="#a9ff9f", padx=12, pady=12, takefocus=False,
        )
        display.pack()
        display.insert("1.0", "\n".join(rows))
        display.configure(state="disabled")

    def choose_output(self):
        current = self.output_path.get() or self.input_path.get()
        path = filedialog.asksaveasfilename(
            parent=self.root,
            title="Standalone-ROM speichern",
            initialdir=str(Path(current).parent) if current else str(ROOT),
            initialfile=Path(current).with_suffix(".rom").name if current else "sid-player.rom",
            defaultextension=".rom",
            filetypes=(("ROM-Dateien", "*.rom"),),
            confirmoverwrite=False,
        )
        if path:
            self.output_path.set(path)
            self.status.set("Bereit zur Konvertierung.")
            self.update_controls()

    def convert(self):
        input_path = Path(self.input_path.get())
        output_path = Path(self.output_path.get())
        title = self.title.get().strip()
        credit = self.credit.get().strip()

        try:
            if not input_path.is_file():
                raise ValueError("Die ausgewählte SID-Datei ist nicht verfügbar.")
            if output_path.suffix.lower() != ".rom":
                raise ValueError("Das ROM-Ziel muss auf .rom enden.")
            if output_path.is_dir() or not output_path.parent.is_dir():
                raise ValueError("Bitte eine ROM-Datei in einem vorhandenen Ordner wählen.")
            output_exists = output_path.exists()
            if output_exists and output_path.samefile(input_path):
                raise ValueError("Die ROM-Datei muss sich von der SID-Datei unterscheiden.")
            if not 1 <= len(title) <= 64:
                raise ValueError("Der Spieltitel muss 1 bis 64 Zeichen lang sein.")
            if not 1 <= len(credit) <= 60:
                raise ValueError("Der Name im Hinweis muss 1 bis 60 Zeichen lang sein.")
            if not self.native.get():
                seconds = read_integer(self.seconds.get(), "Der Ausschnitt", 1, 300)
            song = read_integer(self.song.get(), "Die Stücknummer", 1, self.songs)
            delay = read_integer(self.delay.get(), "Die Frame-Verzögerung", 10, 2000)
        except (OSError, ValueError) as error:
            messagebox.showerror("Eingabe prüfen", str(error), parent=self.root)
            return

        if output_exists and not messagebox.askyesno(
            "ROM ersetzen",
            f"Soll die vorhandene Datei ersetzt werden?\n\n{output_path}",
            parent=self.root,
        ):
            return

        python = Path(sys.executable)
        if python.name.lower() == "pythonw.exe":
            python = python.with_name("python.exe")
        command = [
            str(python), str(BUILD_SCRIPT), str(input_path), str(output_path),
            f"--title={title}", f"--credit={credit}",
            "--song", str(song), "--delay", str(delay),
        ]
        if self.native.get():
            command.append("--native")
        else:
            command.extend(("--seconds", str(seconds)))
        self.running = True
        self.update_controls()
        self.status.set("SID wird konvertiert und das ROM assembliert …")
        self.progress.grid()
        self.progress.start(12)
        threading.Thread(target=self.run_build, args=(command,)).start()
        self.root.after(100, self.check_result)

    def run_build(self, command):
        try:
            result = subprocess.run(
                command,
                cwd=ROOT,
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"},
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except OSError as error:
            self.results.put((False, str(error)))
        else:
            details = result.stderr.strip() or result.stdout.strip()
            self.results.put((result.returncode == 0, details))

    def check_result(self):
        try:
            success, details = self.results.get_nowait()
        except queue.Empty:
            self.root.after(100, self.check_result)
            return

        self.progress.stop()
        self.progress.grid_remove()
        self.running = False
        self.update_controls()
        if success:
            self.status.set(f"ROM erstellt: {Path(self.output_path.get()).name}")
        else:
            self.status.set("Konvertierung fehlgeschlagen.")
            messagebox.showerror(
                "ROM konnte nicht erstellt werden",
                details or "Der ROM-Build wurde mit einem Fehler beendet.",
                parent=self.root,
            )

    def close(self):
        if self.running:
            messagebox.showinfo(
                "Konvertierung läuft",
                "Bitte warten, bis der ROM-Build abgeschlossen ist.",
                parent=self.root,
            )
        else:
            self.root.destroy()


def main():
    root = tk.Tk()
    SidConverterWindow(root)
    root.mainloop()


if __name__ == "__main__":
    main()
