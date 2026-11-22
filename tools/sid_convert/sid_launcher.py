"""Start local standalone SID ROMs in the 6502 SBC emulator."""

from pathlib import Path
import subprocess
import sys
import tkinter as tk
from tkinter import ttk


ROOT = Path(__file__).resolve().parents[2]
ROM_ROOT = ROOT / "roms" / "sid"
ROM_SIZE = 16 * 1024
PROFILES = (
    ("fpga", "Original-SID", "sid.ini"),
    ("fpga-titled", "Original-SID mit Titel", "sid.ini"),
    ("sbc", "SBC-Vierstimmenchip", "soundtest.ini"),
)


class SidLauncherWindow:
    def __init__(self, root):
        self.root = root
        self.roms = []
        self.visible_roms = {}
        self.player = None
        self.search = tk.StringVar()
        self.status = tk.StringVar()

        root.title("SID-ROM-Launcher")
        root.geometry("640x440")
        root.minsize(440, 280)
        root.protocol("WM_DELETE_WINDOW", self.close)

        panel = ttk.Frame(root, padding=12)
        panel.pack(fill="both", expand=True)
        panel.columnconfigure(1, weight=1)
        panel.rowconfigure(1, weight=1)
        ttk.Label(panel, text="Suchen").grid(row=0, column=0, sticky="w")
        search_field = ttk.Entry(panel, textvariable=self.search)
        search_field.grid(row=0, column=1, sticky="ew", padx=8)
        ttk.Button(panel, text="Aktualisieren", command=self.reload).grid(row=0, column=2)

        self.list = ttk.Treeview(panel, columns=("profile",), selectmode="browse")
        self.list.heading("#0", text="ROM")
        self.list.heading("profile", text="Wiedergabe")
        self.list.column("#0", width=330, minwidth=180)
        self.list.column("profile", width=170, minwidth=155, stretch=False)
        self.list.grid(row=1, column=0, columnspan=3, sticky="nsew", pady=8)
        scrollbar = ttk.Scrollbar(panel, orient="vertical", command=self.list.yview)
        scrollbar.grid(row=1, column=3, sticky="ns", pady=8)
        self.list.configure(yscrollcommand=scrollbar.set)
        self.list.bind("<<TreeviewSelect>>", self.update_buttons)
        self.list.bind("<Double-1>", self.play_clicked_row)
        self.list.bind("<Return>", self.play)

        self.play_button = ttk.Button(panel, text="Starten", command=self.play)
        self.play_button.grid(row=2, column=0, sticky="w")
        self.stop_button = ttk.Button(panel, text="Stoppen", command=self.stop)
        self.stop_button.grid(row=2, column=1, sticky="w", padx=8)
        ttk.Label(panel, textvariable=self.status, wraplength=415).grid(
            row=3, column=0, columnspan=4, sticky="w", pady=(8, 0),
        )

        self.search.trace_add("write", self.filter_roms)
        self.reload()
        search_field.focus_set()
        self.root.after(200, self.check_player)

    def reload(self):
        self.roms = []
        try:
            for folder, label, config in PROFILES:
                directory = ROM_ROOT / folder
                if not directory.is_dir():
                    continue
                for path in directory.iterdir():
                    if path.suffix.lower() == ".rom" and path.is_file():
                        title = path.stem.removeprefix("sound_").replace("_", " ")
                        self.roms.append((title, label, config, path))
        except OSError as error:
            self.filter_roms()
            self.status.set(f"ROM-Ordner konnte nicht gelesen werden. {error}")
            return
        self.roms.sort(key=lambda rom: rom[0].casefold())
        self.filter_roms()

    def filter_roms(self, *_):
        selected = self.list.selection()
        self.list.delete(*self.list.get_children())
        self.visible_roms.clear()
        query = self.search.get().strip().casefold()
        for title, label, config, path in self.roms:
            if query in title.casefold() or query in path.name.casefold():
                key = str(path)
                self.visible_roms[key] = (title, config, path)
                self.list.insert("", "end", iid=key, text=title, values=(label,))
        if selected and selected[0] in self.visible_roms:
            self.list.selection_set(selected[0])
            self.list.focus(selected[0])
        if self.player is None:
            if not self.roms:
                self.status.set("Keine ROMs in roms/sid gefunden.")
            elif not self.visible_roms:
                self.status.set("Keine passenden ROMs gefunden.")
            else:
                self.status.set(f"{len(self.visible_roms)} ROMs · Doppelklick zum Starten")
        self.update_buttons()

    def update_buttons(self, _event=None):
        self.play_button.state(["!disabled"] if self.list.selection() else ["disabled"])
        self.stop_button.state(["!disabled"] if self.player else ["disabled"])

    def play_clicked_row(self, event):
        row = self.list.identify_row(event.y)
        if row:
            self.list.selection_set(row)
            self.play()

    def play(self, _event=None):
        selected = self.list.selection()
        if not selected:
            return
        title, config, path = self.visible_roms[selected[0]]
        windows = sys.platform == "win32"
        executable = ROOT / "bin" / ("sbc6502.exe" if windows else "sbc6502")
        try:
            if not executable.is_file():
                raise FileNotFoundError(f"{executable.name} fehlt in bin/. Führen Sie make aus.")
            if not (ROOT / config).is_file():
                raise FileNotFoundError(f"{config} fehlt im Projektordner.")
            if path.stat().st_size != ROM_SIZE:
                raise ValueError(f"{path.name} muss 16 KiB groß sein.")
            self.stop_player()
            self.player = subprocess.Popen(
                [str(executable), config, "-r", str(path)],
                cwd=ROOT,
                stdin=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW if windows else 0,
            )
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            self.status.set(f"Start fehlgeschlagen. {error}")
        else:
            self.status.set(f"Spielt {title} · {config}")
        self.update_buttons()

    def stop_player(self):
        if self.player is not None:
            self.player.terminate()
            try:
                self.player.wait(timeout=0.3)
            except subprocess.TimeoutExpired:
                self.player.kill()
                self.player.wait(timeout=0.3)
            self.player = None

    def stop(self):
        try:
            self.stop_player()
        except (OSError, subprocess.TimeoutExpired) as error:
            self.status.set(f"Emulator konnte nicht beendet werden. {error}")
            return False
        self.status.set("Wiedergabe gestoppt.")
        self.update_buttons()
        return True

    def check_player(self):
        if self.player is not None:
            code = self.player.poll()
            if code is not None:
                self.player = None
                message = f"Emulator beendet (Code {code})." if code else "Wiedergabe beendet."
                self.status.set(message)
                self.update_buttons()
        self.root.after(200, self.check_player)

    def close(self):
        if self.stop():
            self.root.destroy()


def main():
    root = tk.Tk()
    SidLauncherWindow(root)
    root.mainloop()


if __name__ == "__main__":
    main()
