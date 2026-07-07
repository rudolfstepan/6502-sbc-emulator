#!/usr/bin/env python3
"""
Build Sheet64 as an EhBASIC PRG with a real PRG load header.

The visible BASIC program is only:
  10 CALL <machine_code_addr>:GOTO 10

Everything after the BASIC end marker is machine code / hidden data, so LIST
does not show the spreadsheet source as a BASIC program.
"""

from pathlib import Path
import argparse
import re
import sys

import make_ehbasic_prg

BASIC_ADDR = make_ehbasic_prg.PROG_START
LOAD_ADDR = BASIC_ADDR - 3
INSTALL_ADDR = 0x1000
KERNEL_REPLAY_BUF = 0x7000
SCREEN_REPLAY_POS = 0x02F1
SCREEN_REPLAY_LEN = 0x02F2
SCREEN_REPLAY_CHAR = 0x02F3
SCREEN_FLUSH = 0x02F9
EHBASIC_WARM_READY = 0xA4AF

# JMP direct_entry lives at $02FE..$0300, so direct PRG execution works while
# the tokenized BASIC program still starts at EhBASIC's normal $0301.
BOOT_STUB_LEN = 3
DIRECT_ENTRY_LEN = 42


def shift_line_refs(body: str, delta: int) -> str:
    def repl(match: re.Match) -> str:
        return f"{match.group(1)} {int(match.group(2)) + delta}"

    body = re.sub(r"\b(GOTO|GOSUB)\s+(\d+)\b", repl, body, flags=re.IGNORECASE)
    body = re.sub(r"\b(THEN)\s+(\d+)\b", repl, body, flags=re.IGNORECASE)
    return body


def call_stub_source(call_addr: int) -> str:
    return f"10 CALL {call_addr}:GOTO 10\n"


def shifted_spreadsheet_source(source: str, delta: int = 0) -> str:
    lines = []

    for raw in source.splitlines():
        stripped = raw.strip()
        if not stripped:
            continue

        match = re.match(r"^(\d+)\s*(.*)$", stripped)
        if not match:
            raise ValueError(f"line without number: {raw!r}")

        line_no = int(match.group(1))
        body = match.group(2)

        if line_no < 10:
            continue

        lines.append(f"{line_no + delta} {shift_line_refs(body, delta)}")

    return "\n".join(lines) + "\n"


def encode_loader(code_addr: int, install_addr: int, hidden_addr: int, hidden_len: int) -> bytes:
    dst = INSTALL_ADDR
    end = INSTALL_ADDR + hidden_len

    code = bytearray()

    # direct_entry: install the hidden BASIC program, queue RUN through the
    # kernel replay buffer, then re-enter EhBASIC's warm command loop.
    code += bytes([0x20, install_addr & 0xFF, install_addr >> 8])  # JSR install
    for i, ch in enumerate(b"RUN\r"):
        code += bytes([0xA9, ch, 0x8D, (KERNEL_REPLAY_BUF + i) & 0xFF,
                       (KERNEL_REPLAY_BUF + i) >> 8])
    code += bytes([0xA9, 0x00])
    code += bytes([0x8D, SCREEN_REPLAY_POS & 0xFF, SCREEN_REPLAY_POS >> 8])
    code += bytes([0x8D, SCREEN_REPLAY_CHAR & 0xFF, SCREEN_REPLAY_CHAR >> 8])
    code += bytes([0x8D, SCREEN_FLUSH & 0xFF, SCREEN_FLUSH >> 8])
    code += bytes([0xA9, 0x04])
    code += bytes([0x8D, SCREEN_REPLAY_LEN & 0xFF, SCREEN_REPLAY_LEN >> 8])
    code += bytes([0x4C, EHBASIC_WARM_READY & 0xFF, EHBASIC_WARM_READY >> 8])
    if len(code) != DIRECT_ENTRY_LEN:
        raise RuntimeError(f"direct entry length changed: {len(code)}")

    if code_addr + len(code) != install_addr:
        raise RuntimeError("install entry layout mismatch")

    # install_entry: callable by the BASIC stub as CALL <install_addr>.
    code += bytes([0x78])                                # SEI
    code += bytes([0xA2, 0x00])                          # LDX #0
    code += bytes([0xBD, hidden_addr & 0xFF, hidden_addr >> 8])
    code += bytes([0x9D, dst & 0xFF, dst >> 8])
    code += bytes([0xE8])                                # INX
    code += bytes([0xD0, 0xF7])                          # BNE loop
    copied = 0x100
    while copied < hidden_len:
        chunk = min(0x100, hidden_len - copied)
        src_page = hidden_addr + copied
        dst_page = dst + copied
        code += bytes([0xA2, 0x00])                      # LDX #0
        code += bytes([0xBD, src_page & 0xFF, src_page >> 8])
        code += bytes([0x9D, dst_page & 0xFF, dst_page >> 8])
        code += bytes([0xE8])                            # INX
        if chunk == 0x100:
            code += bytes([0xD0, 0xF7])                  # BNE loop
        else:
            code += bytes([0xE0, chunk, 0xD0, 0xF5])     # CPX #chunk / BNE loop
        copied += chunk

    # Update EhBASIC program start to the installed copy.
    code += bytes([0xA9, dst & 0xFF, 0x85, 0x79])
    code += bytes([0xA9, dst >> 8, 0x85, 0x7A])

    # Update variable/array pointers to the end of the copied BASIC program.
    for zp in (0x7B, 0x7D, 0x7F):  # Svarl/Sarryl/Earryl
        code += bytes([0xA9, end & 0xFF, 0x85, zp])
        code += bytes([0xA9, end >> 8, 0x85, zp + 1])

    code += bytes([0x58])                                # CLI

    # A manual CALL of the visible stub should start Sheet64 too. Queue RUN and
    # re-enter EhBASIC instead of returning silently to READY.
    for i, ch in enumerate(b"RUN\r"):
        code += bytes([0xA9, ch, 0x8D, (KERNEL_REPLAY_BUF + i) & 0xFF,
                       (KERNEL_REPLAY_BUF + i) >> 8])
    code += bytes([0xA9, 0x00])
    code += bytes([0x8D, SCREEN_REPLAY_POS & 0xFF, SCREEN_REPLAY_POS >> 8])
    code += bytes([0x8D, SCREEN_REPLAY_CHAR & 0xFF, SCREEN_REPLAY_CHAR >> 8])
    code += bytes([0x8D, SCREEN_FLUSH & 0xFF, SCREEN_FLUSH >> 8])
    code += bytes([0xA9, 0x04])
    code += bytes([0x8D, SCREEN_REPLAY_LEN & 0xFF, SCREEN_REPLAY_LEN >> 8])
    code += bytes([0x4C, EHBASIC_WARM_READY & 0xFF, EHBASIC_WARM_READY >> 8])
    return bytes(code)


def build_prg(source: str) -> tuple[bytes, int]:
    old_prog_start = make_ehbasic_prg.PROG_START
    try:
        make_ehbasic_prg.PROG_START = INSTALL_ADDR
        hidden_basic = make_ehbasic_prg.tokenize(shifted_spreadsheet_source(source))
    finally:
        make_ehbasic_prg.PROG_START = old_prog_start

    # The CALL address is embedded in the visible BASIC text. Iterate until
    # the number of digits no longer changes the stub/code layout.
    call_addr = BASIC_ADDR
    for _ in range(8):
        visible_basic = make_ehbasic_prg.tokenize(call_stub_source(call_addr))
        hidden_addr = BASIC_ADDR + len(visible_basic)
        code_addr = hidden_addr + len(hidden_basic)
        next_call_addr = code_addr + DIRECT_ENTRY_LEN
        if next_call_addr == call_addr:
            break
        call_addr = next_call_addr
    else:
        raise RuntimeError("CALL address did not stabilize")

    visible_basic = make_ehbasic_prg.tokenize(call_stub_source(call_addr))
    hidden_addr = BASIC_ADDR + len(visible_basic)
    code_addr = hidden_addr + len(hidden_basic)
    machine_code = encode_loader(code_addr, call_addr, hidden_addr, len(hidden_basic))
    actual_call_addr = code_addr + DIRECT_ENTRY_LEN
    if actual_call_addr != call_addr:
        raise RuntimeError("CALL address changed after final layout")
    boot_stub = bytes([0x4C, code_addr & 0xFF, code_addr >> 8])
    prg = bytes([LOAD_ADDR & 0xFF, LOAD_ADDR >> 8]) + boot_stub + visible_basic + hidden_basic + machine_code
    return prg, call_addr


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Sheet64 EhBASIC PRG")
    parser.add_argument("input_bas")
    parser.add_argument("output_prg")
    args = parser.parse_args()

    source = Path(args.input_bas).read_text(encoding="utf-8")
    prg, call_addr = build_prg(source)

    out = Path(args.output_prg)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(prg)

    print(
        f"Built {out} ({len(prg)} bytes, load ${LOAD_ADDR:04X}, "
        f"LIST 10 => CALL {call_addr})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
