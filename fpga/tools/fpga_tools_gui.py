#!/usr/bin/env python3
"""
PIX16 FPGA Tools — Graphical Launcher
Run with: python fpga/tools/fpga_tools_gui.py
"""
from __future__ import annotations

import subprocess
import sys
import threading
from pathlib import Path
import tkinter as tk
from tkinter import ttk, filedialog

ROOT  = Path(__file__).resolve().parent.parent.parent
TOOLS = ROOT / "fpga" / "tools"
ROMS  = ROOT / "fpga" / "roms"

# ── Catppuccin Mocha palette ───────────────────────────────────────────────
BG      = "#1e1e2e"
BG2     = "#24273a"
BG3     = "#313244"
FG      = "#cdd6f4"
FG2     = "#a6adc8"
ACCENT  = "#89b4fa"   # blue
GREEN   = "#a6e3a1"
RED     = "#f38ba8"
YELLOW  = "#f9e2af"
MAUVE   = "#cba6f7"
BORDER  = "#45475a"
SURFACE = "#2a2b3c"


# ── Helpers ────────────────────────────────────────────────────────────────

def _lbl(parent, text, fg=FG, font=("Segoe UI", 10), **kw):
    kw.setdefault("bg", parent["bg"])
    return tk.Label(parent, text=text, fg=fg, font=font, **kw)


def _sep(parent):
    tk.Frame(parent, bg=BORDER, height=1).pack(fill=tk.X, padx=12, pady=6)


# ══════════════════════════════════════════════════════════════════════════
class OutputConsole(tk.Frame):
    """Scrollable ANSI-less output pane."""

    def __init__(self, parent, **kw):
        super().__init__(parent, bg=BG, **kw)

        bar = tk.Frame(self, bg=BG2, pady=4)
        bar.pack(fill=tk.X)
        _lbl(bar, "  OUTPUT", fg=ACCENT, font=("Consolas", 9, "bold")).pack(side=tk.LEFT)
        tk.Button(bar, text="Clear", bg=BG3, fg=FG, relief=tk.FLAT,
                  padx=8, pady=1, cursor="hand2",
                  command=self.clear).pack(side=tk.RIGHT, padx=6)

        self._text = tk.Text(
            self, bg="#11111b", fg=FG, font=("Consolas", 10),
            state=tk.DISABLED, relief=tk.FLAT, wrap=tk.WORD, padx=8, pady=6,
        )
        sb = ttk.Scrollbar(self, orient=tk.VERTICAL, command=self._text.yview)
        self._text.configure(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        self._text.pack(fill=tk.BOTH, expand=True)

        for tag, color in (("ok", GREEN), ("err", RED), ("warn", YELLOW),
                           ("accent", ACCENT), ("dim", FG2)):
            self._text.tag_config(tag, foreground=color)

    def clear(self):
        self._text.configure(state=tk.NORMAL)
        self._text.delete("1.0", tk.END)
        self._text.configure(state=tk.DISABLED)

    def write(self, text: str, tag: str = ""):
        self._text.configure(state=tk.NORMAL)
        self._text.insert(tk.END, text, tag)
        self._text.see(tk.END)
        self._text.configure(state=tk.DISABLED)

    def writeln(self, text: str, tag: str = ""):
        self.write(text + "\n", tag)


# ══════════════════════════════════════════════════════════════════════════
class Section(tk.Frame):
    """A titled card inside a tab."""

    def __init__(self, parent, title: str, **kw):
        super().__init__(parent, bg=BG, **kw)
        hdr = tk.Frame(self, bg=BG)
        hdr.pack(fill=tk.X, padx=4, pady=(10, 4))
        _lbl(hdr, title, fg=ACCENT, font=("Segoe UI", 11, "bold")).pack(side=tk.LEFT)
        tk.Frame(hdr, bg=BORDER, height=1).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 4), pady=6
        )
        self.body = tk.Frame(self, bg=SURFACE, padx=14, pady=10)
        self.body.pack(fill=tk.X, padx=4, pady=(0, 6))

    def add_check(self, text: str) -> tk.BooleanVar:
        var = tk.BooleanVar()
        ttk.Checkbutton(self.body, text=text, variable=var).pack(anchor="w", pady=1)
        return var

    def add_field_row(self, *fields) -> list[ttk.Entry]:
        """fields = list of (label, default, width)"""
        row = tk.Frame(self.body, bg=SURFACE)
        row.pack(fill=tk.X, pady=(6, 2))
        entries = []
        for label, default, width in fields:
            _lbl(row, label + ":", bg=SURFACE, fg=FG2).pack(side=tk.LEFT, padx=(0, 3))
            e = ttk.Entry(row, width=width)
            e.insert(0, default)
            e.pack(side=tk.LEFT, padx=(0, 14))
            entries.append(e)
        return entries

    def add_file_row(self, label: str, default: str,
                     filetypes=None, save=False) -> tk.StringVar:
        row = tk.Frame(self.body, bg=SURFACE)
        row.pack(fill=tk.X, pady=(6, 2))
        _lbl(row, label, bg=SURFACE, fg=FG2, width=13, anchor="w").pack(side=tk.LEFT)
        var = tk.StringVar(value=default)
        ttk.Entry(row, textvariable=var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(4, 4)
        )
        def _browse():
            ft = filetypes or [("All files", "*.*")]
            p = (filedialog.asksaveasfilename(filetypes=ft) if save
                 else filedialog.askopenfilename(filetypes=ft))
            if p:
                var.set(p)
        tk.Button(row, text="…", bg=BG3, fg=FG, relief=tk.FLAT,
                  padx=6, cursor="hand2", command=_browse).pack(side=tk.LEFT)
        return var

    def add_note(self, text: str):
        _lbl(self.body, text, bg=SURFACE, fg=FG2,
             font=("Segoe UI", 9, "italic")).pack(anchor="w", pady=(4, 0))

    def add_button(self, text: str, cmd, color=ACCENT):
        tk.Button(
            self.body, text=text, command=cmd,
            bg=color, fg="#1e1e2e", font=("Segoe UI", 10, "bold"),
            relief=tk.FLAT, padx=16, pady=6, cursor="hand2",
        ).pack(anchor="w", pady=(10, 2))


# ══════════════════════════════════════════════════════════════════════════
class ScrollableTab(tk.Frame):
    """A tab whose content scrolls vertically."""

    def __init__(self, parent, **kw):
        super().__init__(parent, bg=BG, **kw)
        canvas = tk.Canvas(self, bg=BG, highlightthickness=0)
        sb = ttk.Scrollbar(self, orient=tk.VERTICAL, command=canvas.yview)
        canvas.configure(yscrollcommand=sb.set)
        sb.pack(side=tk.RIGHT, fill=tk.Y)
        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.inner = tk.Frame(canvas, bg=BG)
        win = canvas.create_window((0, 0), window=self.inner, anchor="nw")

        def _on_frame(e):
            canvas.configure(scrollregion=canvas.bbox("all"))
        def _on_canvas(e):
            canvas.itemconfig(win, width=e.width)

        self.inner.bind("<Configure>", _on_frame)
        canvas.bind("<Configure>", _on_canvas)
        canvas.bind_all("<MouseWheel>",
                        lambda e: canvas.yview_scroll(-1 * (e.delta // 120), "units"))


# ══════════════════════════════════════════════════════════════════════════
class App(tk.Tk):

    def __init__(self):
        super().__init__()
        self.title("PIX16 FPGA Tools")
        self.geometry("940x740")
        self.minsize(700, 500)
        self.configure(bg=BG)
        self._proc: subprocess.Popen | None = None
        self._setup_styles()
        self._build_ui()

    # ── ttk theme ──────────────────────────────────────────────────────────
    def _setup_styles(self):
        s = ttk.Style(self)
        s.theme_use("clam")
        s.configure("TNotebook",     background=BG,  borderwidth=0)
        s.configure("TNotebook.Tab", background=BG3, foreground=FG,
                    padding=[14, 7], font=("Segoe UI", 10))
        s.map("TNotebook.Tab",
              background=[("selected", BG2), ("active", BORDER)],
              foreground=[("selected", ACCENT)])
        s.configure("TFrame",       background=BG)
        s.configure("TLabel",       background=BG,  foreground=FG,
                    font=("Segoe UI", 10))
        s.configure("TCheckbutton", background=SURFACE, foreground=FG,
                    font=("Segoe UI", 10))
        s.map("TCheckbutton",
              background=[("active", SURFACE)],
              foreground=[("active", FG)])
        s.configure("TEntry",       fieldbackground=BG2, foreground=FG,
                    insertcolor=FG, borderwidth=1)
        s.configure("Vertical.TScrollbar", background=BG3,
                    troughcolor=BG, arrowcolor=FG2)

    # ── main layout ────────────────────────────────────────────────────────
    def _build_ui(self):
        # Title bar
        hdr = tk.Frame(self, bg=BG2, pady=10)
        hdr.pack(fill=tk.X)
        _lbl(hdr, "  PIX16 FPGA Tools", bg=BG2,
             fg=ACCENT, font=("Segoe UI", 14, "bold")).pack(side=tk.LEFT)
        _lbl(hdr, "6502 SBC development launcher  ", bg=BG2,
             fg=FG2, font=("Segoe UI", 10)).pack(side=tk.RIGHT)

        # PanedWindow: top = notebook, bottom = console
        pane = tk.PanedWindow(self, orient=tk.VERTICAL, bg=BORDER,
                              sashwidth=5, sashpad=0, relief=tk.FLAT)
        pane.pack(fill=tk.BOTH, expand=True)

        nb_wrap = tk.Frame(pane, bg=BG)
        pane.add(nb_wrap, minsize=320, height=460)

        self.nb = ttk.Notebook(nb_wrap)
        self.nb.pack(fill=tk.BOTH, expand=True, padx=6, pady=6)

        self._tab_build()
        self._tab_upload()
        self._tab_sdcard()
        self._tab_utilities()

        con_wrap = tk.Frame(pane, bg=BG)
        pane.add(con_wrap, minsize=120, height=200)

        self.console = OutputConsole(con_wrap)
        self.console.pack(fill=tk.BOTH, expand=True, padx=6, pady=(2, 6))

        # Status bar
        sb = tk.Frame(self, bg=BG2, pady=3)
        sb.pack(fill=tk.X, side=tk.BOTTOM)
        self._status = tk.StringVar(value="Ready")
        _lbl(sb, "", bg=BG2).pack(side=tk.LEFT, padx=4)
        tk.Label(sb, textvariable=self._status, bg=BG2, fg=FG2,
                 font=("Segoe UI", 9)).pack(side=tk.LEFT)
        self._stop_btn = tk.Button(
            sb, text="■  Stop", bg=RED, fg="#1e1e2e",
            font=("Segoe UI", 9, "bold"), relief=tk.FLAT,
            padx=10, pady=1, cursor="hand2",
            command=self._stop, state=tk.DISABLED,
        )
        self._stop_btn.pack(side=tk.RIGHT, padx=6, pady=2)

    # ── Build tab ──────────────────────────────────────────────────────────
    def _tab_build(self):
        page = ScrollableTab(self.nb)
        self.nb.add(page, text="  Build  ")
        p = page.inner

        # EhBASIC ROM
        s1 = Section(p, "Build EhBASIC ROM")
        s1.pack(fill=tk.X, padx=8)
        s1.add_note("Assembles ehbasic_fpga.s + kernel.rom → fpga_ehbasic_16kb.rom  (16 KB, $C000-$FFFF)")
        self._eb_upload  = s1.add_check("Upload to board via UART monitor after build")
        self._eb_run     = s1.add_check("Run after upload  (send G C000)")
        self._eb_sdimg   = s1.add_check("Also generate SD card boot image  (.img)")
        self._eb_verbose = s1.add_check("Verbose output")
        (self._eb_port,
         self._eb_baud)  = s1.add_field_row(("Port", "COM15", 10), ("Baud", "115200", 10))
        s1.add_button("▶  Build EhBASIC ROM", self._do_build_ehbasic, ACCENT)

        # SDRAM Diagnostic
        s2 = Section(p, "Build SDRAM Diagnostic ROM")
        s2.pack(fill=tk.X, padx=8)
        s2.add_note("Assembles diag_sdram.s → diag_sdram.rom  (16 KB).  Tests CPU→SDRAM write path.")
        self._diag_upload  = s2.add_check("Upload to board via UART monitor after build")
        self._diag_verbose = s2.add_check("Verbose output")
        (self._diag_port,) = s2.add_field_row(("Port", "COM15", 10))
        s2.add_button("▶  Build SDRAM Diagnostic ROM", self._do_build_diag, MAUVE)

        # Demo ROM
        s3 = Section(p, "Build Upload Demo ROM")
        s3.pack(fill=tk.X, padx=8)
        s3.add_note("Generates upload_demo.rom — LED blink + VGA text + UART banner.  No arguments needed.")
        s3.add_button("▶  Build Upload Demo ROM", self._do_make_demo, GREEN)

    # ── Upload tab ─────────────────────────────────────────────────────────
    def _tab_upload(self):
        page = ScrollableTab(self.nb)
        self.nb.add(page, text="  Upload  ")
        p = page.inner

        # UART monitor upload
        s1 = Section(p, "Upload via UART Monitor")
        s1.pack(fill=tk.X, padx=8)
        s1.add_note("Press KEY0 on the board first to enter monitor mode.")
        self._mon_image = s1.add_file_row(
            "ROM Image:", str(ROMS / "fpga_ehbasic_16kb.rom"),
            filetypes=[("ROM / BIN", "*.rom *.bin"), ("All", "*.*")],
        )
        (self._mon_port,
         self._mon_baud,
         self._mon_addr) = s1.add_field_row(
            ("Port", "COM15", 10), ("Baud", "115200", 10), ("Address", "0xC000", 10)
        )
        self._mon_run       = s1.add_check("Run after upload  (send G <address>)")
        self._mon_enter     = s1.add_check("Send ENTER over UART after run  (EhBASIC cold start)")
        self._mon_verbose   = s1.add_check("Verbose — print monitor responses")
        self._mon_bld_demo  = s1.add_check("Build demo ROM first  (--build-demo)")
        s1.add_button("▶  Upload via Monitor", self._do_upload_monitor, YELLOW)

        # BASIC program
        s2 = Section(p, "Upload BASIC Program")
        s2.pack(fill=tk.X, padx=8)
        s2.add_note("EhBASIC must already be running on the board and waiting at its prompt.")
        self._bas_file = s2.add_file_row(
            "BASIC File:", "",
            filetypes=[("BASIC", "*.bas"), ("All", "*.*")],
        )
        (self._bas_port,
         self._bas_baud) = s2.add_field_row(("Port", "COM15", 10), ("Baud", "115200", 10))
        self._bas_new     = s2.add_check("Send NEW before upload")
        self._bas_run     = s2.add_check("Send RUN after upload")
        self._bas_verbose = s2.add_check("Verbose — print BASIC responses")
        s2.add_button("▶  Upload BASIC Program", self._do_upload_basic, YELLOW)

    # ── SD Card tab ────────────────────────────────────────────────────────
    def _tab_sdcard(self):
        page = tk.Frame(self.nb, bg=BG)
        self.nb.add(page, text="  SD Card  ")

        s1 = Section(page, "Create SD Boot Image")
        s1.pack(fill=tk.X, padx=8)
        s1.add_note(
            "Writes a raw image: sector 0 = boot header (magic SBCROM01 + CRC32),\n"
            "sectors 1-32 = 16 KB ROM payload.  Flash to SD card with dd or Win32DiskImager."
        )
        self._sd_rom = s1.add_file_row(
            "ROM File:", str(ROMS / "fpga_ehbasic_16kb.rom"),
            filetypes=[("ROM / BIN", "*.rom *.bin"), ("All", "*.*")],
        )
        self._sd_out = s1.add_file_row(
            "Output Image:", str(ROMS / "fpga_ehbasic_16kb.img"),
            filetypes=[("Disk Image", "*.img"), ("All", "*.*")],
            save=True,
        )
        s1.add_note("Tip: append  @0x0000  to the ROM path to place it at a specific offset.")
        s1.add_button("▶  Create SD Boot Image", self._do_make_sd, GREEN)

        # Write hint
        hint = Section(page, "Write to SD Card")
        hint.pack(fill=tk.X, padx=8)
        lines = [
            "Linux / macOS:   dd if=fpga_ehbasic_16kb.img of=/dev/sdX bs=512",
            "Windows:         Win32DiskImager  or  tools\\write_sd.bat <image>",
        ]
        for l in lines:
            _lbl(hint.body, l, bg=SURFACE, fg=FG2,
                 font=("Consolas", 9)).pack(anchor="w", pady=1)

    # ── Utilities tab ──────────────────────────────────────────────────────
    def _tab_utilities(self):
        page = tk.Frame(self.nb, bg=BG)
        self.nb.add(page, text="  Utilities  ")

        s1 = Section(page, "News to UART")
        s1.pack(fill=tk.X, padx=8)
        s1.add_note(
            "Fetches RSS / Atom headlines and sends them to the FPGA UART console.\n"
            "EhBASIC or a UART-aware ROM must be running."
        )
        (self._news_port,
         self._news_baud) = s1.add_field_row(("Port", "COM15", 10), ("Baud", "230400", 10))
        (self._news_interval,
         self._news_refresh) = s1.add_field_row(
            ("Interval (s)", "5.0", 8), ("Refresh (s)", "300", 8)
        )
        self._news_once = s1.add_check("Send one batch and exit")
        s1.add_button("▶  Start News Feed", self._do_news, MAUVE)

    # ── Process runner ─────────────────────────────────────────────────────
    def _run(self, cmd: list[str], label: str):
        if self._proc and self._proc.poll() is None:
            self.console.writeln("A process is already running — stop it first.", "warn")
            return

        self.console.writeln(f"\n{'─'*60}", "dim")
        self.console.writeln(f"  {label}", "accent")
        self.console.write("  $ ", "dim")
        self.console.writeln(" ".join(str(c) for c in cmd), "dim")
        self.console.writeln(f"{'─'*60}", "dim")
        self._status.set(f"Running: {label}")
        self._stop_btn.configure(state=tk.NORMAL)

        def _worker():
            try:
                proc = subprocess.Popen(
                    [str(c) for c in cmd],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, bufsize=1, cwd=str(ROOT),
                )
                self._proc = proc
                for line in proc.stdout:
                    self.after(0, lambda l=line: self.console.write(l))
                proc.wait()
                rc = proc.returncode
                def _finish():
                    tag = "ok" if rc == 0 else "err"
                    self.console.writeln(f"\n  exit code: {rc}", tag)
                    self._status.set(f"Done  ({label})")
                    self._stop_btn.configure(state=tk.DISABLED)
                self.after(0, _finish)
            except Exception as exc:
                self.after(0, lambda: self.console.writeln(f"ERROR: {exc}", "err"))
                self.after(0, lambda: self._status.set("Error"))
                self.after(0, lambda: self._stop_btn.configure(state=tk.DISABLED))

        threading.Thread(target=_worker, daemon=True).start()

    def _stop(self):
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            self.console.writeln("\n  [process terminated by user]", "warn")
            self._status.set("Stopped")
        self._stop_btn.configure(state=tk.DISABLED)

    # ── Action handlers ────────────────────────────────────────────────────
    def _do_build_ehbasic(self):
        cmd = [sys.executable, TOOLS / "build_fpga_ehbasic.py"]
        if self._eb_upload.get():
            cmd += ["--upload", "--port", self._eb_port.get()]
            if self._eb_baud.get():
                cmd += ["--baud", self._eb_baud.get()]
        if self._eb_run.get():     cmd.append("--run")
        if self._eb_sdimg.get():   cmd.append("--sd-image")
        if self._eb_verbose.get(): cmd.append("--verbose")
        self._run(cmd, "Build EhBASIC ROM")

    def _do_build_diag(self):
        cmd = [sys.executable, TOOLS / "build_diag_sdram.py"]
        if self._diag_upload.get():
            cmd += ["--upload", "--port", self._diag_port.get()]
        if self._diag_verbose.get(): cmd.append("--verbose")
        self._run(cmd, "Build SDRAM Diagnostic ROM")

    def _do_make_demo(self):
        self._run([sys.executable, TOOLS / "make_upload_demo_rom.py"],
                  "Build Upload Demo ROM")

    def _do_upload_monitor(self):
        script = ("upload_monitor_hex_enter.py" if self._mon_enter.get()
                  else "upload_monitor_hex.py")
        cmd = [sys.executable, TOOLS / script]
        img = self._mon_image.get()
        if img:
            cmd.append(img)
        cmd += ["--port", self._mon_port.get(),
                "--baud", self._mon_baud.get(),
                "--address", self._mon_addr.get()]
        if self._mon_run.get():      cmd.append("--run")
        if self._mon_verbose.get():  cmd.append("--verbose")
        if self._mon_bld_demo.get(): cmd.append("--build-demo")
        self._run(cmd, "Upload via UART Monitor")

    def _do_upload_basic(self):
        path = self._bas_file.get().strip()
        if not path:
            self.console.writeln("ERROR: no BASIC file selected.", "err")
            return
        cmd = [sys.executable, TOOLS / "upload_basic_uart.py",
               path,
               "--port", self._bas_port.get(),
               "--baud", self._bas_baud.get()]
        if self._bas_new.get():     cmd.append("--new")
        if self._bas_run.get():     cmd.append("--run")
        if self._bas_verbose.get(): cmd.append("--verbose")
        self._run(cmd, "Upload BASIC Program")

    def _do_make_sd(self):
        rom = self._sd_rom.get().strip()
        out = self._sd_out.get().strip()
        if not rom or not out:
            self.console.writeln("ERROR: ROM file and output path are required.", "err")
            return
        self._run([sys.executable, TOOLS / "make_sd_boot_image.py",
                   "--output", out, rom],
                  "Create SD Boot Image")

    def _do_news(self):
        cmd = [sys.executable, TOOLS / "news_to_uart.py",
               "--port",     self._news_port.get(),
               "--baud",     self._news_baud.get(),
               "--interval", self._news_interval.get(),
               "--refresh",  self._news_refresh.get()]
        if self._news_once.get(): cmd.append("--once")
        self._run(cmd, "News to UART")


# ══════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    app = App()
    app.mainloop()
