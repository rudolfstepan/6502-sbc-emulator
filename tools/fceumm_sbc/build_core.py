"""Build an optional FCEUmm libretro core with the project's 2A03 executor."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.request import urlopen
from zipfile import ZipFile


TOOL_DIR = Path(__file__).resolve().parent
ROOT = TOOL_DIR.parents[1]
REVISION = "77468e568d9fe9c48d684ca911f1a3fe7259fdf7"
ARCHIVE_HASH = "79ee659f702e9ebdeb9cc7d00185cc787a1c43dd082bfb117dc23ea8b018ccd0"
ARCHIVE_URL = f"https://codeload.github.com/libretro/libretro-fceumm/zip/{REVISION}"


def source_archive(archive):
    if archive is None:
        archive = ROOT / "build" / f"fceumm-{REVISION}.zip"
        if not archive.is_file():
            print(f"Downloading FCEUmm {REVISION}", flush=True)
            with TemporaryDirectory(dir=archive.parent) as temporary:
                download = Path(temporary) / archive.name
                with urlopen(ARCHIVE_URL, timeout=60) as response, download.open("wb") as out:
                    shutil.copyfileobj(response, out)
                verify_archive(download)
                download.replace(archive)
    verify_archive(archive)
    return archive


def verify_archive(archive):
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != ARCHIVE_HASH:
        raise ValueError(f"unexpected SHA-256 for {archive}; expected the archive of {REVISION}")


def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f"FCEUmm source does not match the expected integration point: {before!r}")
    return text.replace(before, after, 1)


def integrate(upstream):
    source = upstream / "src"
    for filename in ("cpu6502.c", "cpu6502.h", "disasm.c", "disasm.h", "bus.c", "bus.h"):
        shutil.copyfile(ROOT / "src" / filename, source / filename)
    shutil.copyfile(TOOL_DIR / "cpu_adapter.inc", source / "sbc_cpu_adapter.inc")

    path = source / "x6502.c"
    code = path.read_text(encoding="utf-8")
    code = replace_once(code, "void X6502_Power(void) {",
                        '#include "sbc_cpu_adapter.inc"\n\nvoid X6502_Power(void) {\n\tsbc_cpu_power();')
    dispatch = "\t\t_PC++;\n\t\tif (encryptOpcodes)"
    adapted = """\
		/* Keep FCEUmm's unofficial, jammed and encrypted opcode paths. */
		if (!encryptOpcodes && !_jammed && disasm_is_official_6502_opcode(b1)) {
			int used = sbc_cpu_step(_PC, b1);
			_PC = sbc_adapter.cpu.PC;
			ADDCYC(used - CycTable[b1]);
			continue;
		}

"""
    path.write_text(replace_once(code, dispatch, adapted + dispatch), encoding="utf-8")

    libretro = source / "drivers" / "libretro" / "libretro.c"
    code = libretro.read_text(encoding="utf-8")
    code = replace_once(code, 'info->library_name     = "FCEUmm";',
                        'info->library_name     = "FCEUmm (SBC CPU)";')
    libretro.write_text(code, encoding="utf-8")

    with (upstream / "Makefile.common").open("a", encoding="utf-8") as build:
        build.write("\nSOURCES_C += src/cpu6502.c src/disasm.c src/bus.c\n")


def build_core(args):
    build_dir = ROOT / "build"
    build_dir.mkdir(exist_ok=True)
    archive = source_archive(args.archive)
    platform, suffix = {"win32": ("win", ".dll"), "darwin": ("osx", ".dylib")}.get(
        sys.platform, ("unix", ".so")
    )
    destination = ROOT / "bin" / "cores" / ("fceumm_sbc_cpu_libretro" + suffix)
    with TemporaryDirectory(prefix="fceumm-sbc-", dir=build_dir) as temporary:
        with ZipFile(archive) as source:
            source.extractall(temporary)
        upstream = Path(temporary) / f"libretro-fceumm-{REVISION}"
        integrate(upstream)
        env = os.environ.copy()
        env.pop("MAKEFLAGS", None)
        env.pop("MFLAGS", None)
        subprocess.run(
            [args.make, "-s", "-f", "Makefile.libretro", f"-j{args.jobs}",
             f"platform={platform}", f"CC={args.cc}", f'GIT_VERSION=" {REVISION[:8]}"'],
            cwd=upstream, env=env, check=True,
        )
        destination.parent.mkdir(parents=True, exist_ok=True)
        binary = upstream / ("fceumm_libretro" + suffix)
        with TemporaryDirectory(dir=destination.parent) as install:
            staged = Path(install) / destination.name
            shutil.copyfile(binary, staged)
            staged.replace(destination)
    print(f"Installed {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="use the pinned source ZIP from disk")
    parser.add_argument("--make", default="make")
    parser.add_argument("--cc", default="gcc")
    parser.add_argument("-j", "--jobs", type=int, default=min(os.cpu_count() or 1, 8))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    try:
        build_core(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"FCEUmm SBC CPU build failed: {error}\n")


if __name__ == "__main__":
    main()
