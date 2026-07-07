#!/usr/bin/env python3
"""Run FPGA-compatible software in the emulator and capture screenshots."""

from __future__ import annotations

import argparse
import datetime as _dt
import os
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_CASES = [
    {"name": "fpga-ehbasic-16kb", "files": ["fpga_ehbasic_16kb.rom"]},
    {"name": "raster-test", "files": ["raster_test.rom"]},
    {"name": "fb16-test", "files": ["fb16_test.rom"]},
    {"name": "ich-image", "files": ["ich_image.rom"]},
    {"name": "mandelbrot-bitmap", "files": ["mandelbrot_bitmap.rom"], "long": True},
    {"name": "mandelbrot-hires", "files": ["mandelbrot_hires.bin"], "long": True},
    {"name": "mandelbrot-true", "files": ["mandelbrot_true.bin"], "long": True},
    {"name": "cia-test", "files": ["cia_test.rom"]},
    {"name": "showimg-img0", "files": ["img0.prg", "showimg.prg"]},
]


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def slug(path: Path) -> str:
    name = path.stem.lower()
    name = re.sub(r"[^a-z0-9]+", "-", name).strip("-")
    return name or "software"


def find_default_fpga_root(root: Path) -> Path:
    sibling = root.parent / "6502-sbc-fpga"
    return sibling if sibling.exists() else root / "fpga"


def discover(fpga_root: Path, explicit: list[str], limit: int | None) -> list[dict[str, object]]:
    if explicit:
        cases = []
        for p in explicit:
            path = Path(p).resolve()
            cases.append({
                "name": slug(path),
                "files": [path],
                "long": "mandelbrot" in path.name.lower(),
            })
    else:
        search_roots = [
            fpga_root / "roms" / "6502",
            fpga_root / "build",
            fpga_root / ".tmp",
        ]
        by_name: dict[str, Path] = {}
        for base in search_roots:
            if not base.exists():
                continue
            for pattern in ("*.rom", "*.bin", "*.prg"):
                for path in base.rglob(pattern):
                    by_name.setdefault(path.name, path.resolve())
        cases = []
        for case_def in DEFAULT_CASES:
            case_name = str(case_def["name"])
            names = list(case_def["files"])
            paths = [by_name[name] for name in names if name in by_name]
            if len(paths) == len(names):
                cases.append({
                    "name": case_name,
                    "files": paths,
                    "long": bool(case_def.get("long", False)),
                })

    if limit is not None:
        cases = cases[:limit]
    return cases


def frames_for_case(case: dict[str, object], normal_frames: int, long_frames: int) -> int:
    if bool(case.get("long", False)):
        return long_frames
    return normal_frames


def timeout_for_frames(frames: int, minimum_timeout: int) -> int:
    # The emulator renders about once per 10 ms throttled batch.
    return max(minimum_timeout, int(frames / 100) + 30)


def build_command(exe: Path, config: Path, files: list[Path], screenshot: Path,
                  frames: int) -> list[str]:
    cmd = [str(exe)]
    for path in files[:-1]:
        cmd.extend(["--load-data", str(path)])
    cmd.extend(["--load", str(files[-1])])
    cmd.extend([
        "--screenshot",
        str(screenshot),
        "--screenshot-frames",
        str(frames),
        str(config),
    ])
    return cmd


def run_one(command: list[str], cwd: Path, visible: bool, timeout: int) -> tuple[int, str]:
    env = os.environ.copy()
    env.setdefault("SDL_AUDIODRIVER", "dummy")
    if not visible:
        env.setdefault("SDL_VIDEODRIVER", "dummy")

    proc = subprocess.run(
        command,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, proc.stdout


def write_markdown(md_path: Path, rows: list[dict[str, str]], fpga_root: Path,
                   frames: int, mandelbrot_frames: int) -> None:
    now = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        "# FPGA Software Test",
        "",
        f"Generated: {now}",
        "",
        f"- Config: `fpga.ini`",
        f"- FPGA software root: `{fpga_root}`",
        f"- Standard screenshot delay: `{frames}` rendered frames",
        f"- Mandelbrot screenshot delay: `{mandelbrot_frames}` rendered frames",
        "",
        "| Status | Software | Type | Wait | Screenshot |",
        "|---|---|---|---:|---|",
    ]
    for row in rows:
        rel = os.path.relpath(row["screenshot"], md_path.parent).replace("\\", "/")
        lines.append(
            f"| {row['status']} | {row['software']} | `{row['type']}` | "
            f"`{row['frames']}` | "
            f"![{row['name']}]({rel}) |"
        )
    lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    root = repo_root()
    parser = argparse.ArgumentParser()
    parser.add_argument("--fpga-root", type=Path, default=find_default_fpga_root(root))
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--mandelbrot-frames", type=int, default=6000)
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--visible", action="store_true")
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("software", nargs="*")
    args = parser.parse_args()

    exe = root / "bin" / ("sbc6502.exe" if os.name == "nt" else "sbc6502")
    config = root / "bin" / "fpga.ini"
    if not exe.exists() or not config.exists():
        print("Build first with `make` so bin/sbc6502 and bin/fpga.ini exist.", file=sys.stderr)
        return 2

    screenshots_dir = root / "docs" / "software-test" / "screenshots"
    screenshots_dir.mkdir(parents=True, exist_ok=True)
    for old in list(screenshots_dir.glob("*.bmp")) + list(screenshots_dir.glob("*.log")):
        old.unlink()

    cases = discover(args.fpga_root.resolve(), args.software, args.limit)
    if not cases:
        print("No FPGA software files found.", file=sys.stderr)
        return 2

    rows: list[dict[str, str]] = []
    failures = 0
    used_names: set[str] = set()

    for case in cases:
        files = [Path(p) for p in case["files"]]
        base = str(case["name"])
        unique = base
        n = 2
        while unique in used_names:
            unique = f"{base}-{n}"
            n += 1
        used_names.add(unique)

        frames = frames_for_case(case, args.frames, args.mandelbrot_frames)
        timeout = timeout_for_frames(frames, args.timeout)
        screenshot = screenshots_dir / f"{unique}.bmp"
        command = build_command(exe, config, files, screenshot, frames)
        print(f"[software-test] {unique} ({frames} frames)")
        try:
            rc, output = run_one(command, root / "bin", args.visible, timeout)
        except subprocess.TimeoutExpired:
            rc, output = 124, "timeout"

        if rc != 0 or not screenshot.exists():
            failures += 1
            status = "FAIL"
        else:
            status = "PASS"

        log = screenshots_dir / f"{unique}.log"
        log.write_text(output, encoding="utf-8", errors="replace")
        software = "<br>".join(f"`{path}`" for path in files)
        types = "+".join(path.suffix.lower().lstrip(".") for path in files)
        rows.append({
            "status": status,
            "software": software,
            "type": types,
            "name": unique,
            "frames": str(frames),
            "screenshot": str(screenshot),
        })

    md_path = root / "docs" / "software-test.md"
    write_markdown(md_path, rows, args.fpga_root.resolve(),
                   args.frames, args.mandelbrot_frames)
    print(f"[software-test] wrote {md_path}")

    if failures:
        print(f"[software-test] {failures} item(s) failed")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
