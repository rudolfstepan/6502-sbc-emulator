"""Check the kernel banner and MS BASIC prompt in SBC video RAM."""

import os
import re
import subprocess
import sys
from pathlib import Path


def main() -> None:
    emulator = Path(sys.argv[1]).resolve()
    env = os.environ.copy()
    env.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    result = subprocess.run(
        [str(emulator), "-d", "sbc.ini"],
        input="b D000\nb C006\nc\nm 8000 160\nbc 0\nc\nm 8000 1000\nq\n",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        timeout=5,
    )

    boot = result.stdout.split("hit at $D000")
    if result.returncode != 0 or len(boot) != 2 or "unknown opcode" in result.stdout:
        raise SystemExit(f"SBC kernel did not reach BASIC:\n{result.stdout[-2000:]}")

    screens = boot[1].split("hit at $C006")
    expected = (
        ("6502 SBC - 32K RAM SYSTEM", "KERNEL V1.0"),
        ("COPYRIGHT 1977 BY MICROSOFT CO.", "OK"),
    )
    if len(screens) != len(expected):
        raise SystemExit(f"MS BASIC did not reach keyboard input:\n{result.stdout[-2000:]}")
    for screen, messages in zip(screens, expected):
        text = "".join(re.findall(r"\|([^|]*)\|$", screen, re.MULTILINE))
        if any(message not in text for message in messages):
            raise SystemExit(f"Unexpected SBC video output:\n{text}")

    print("test_sbc_boot: ok")


if __name__ == "__main__":
    main()
