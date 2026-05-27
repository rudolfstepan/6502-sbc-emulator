#!/usr/bin/env python3
"""
EhBASIC V2.22 tokenizer: converts ASCII .bas source to binary .prg format.

Usage:
    python make_ehbasic_prg.py input.bas output.prg

The .prg binary format (EhBASIC tokenized program in memory):
  Each line: [LINK_LO][LINK_HI][LINENUM_LO][LINENUM_HI][tokens...][0x00]
  End of program: [0x00][0x00]

LINK is the absolute address of the next line in SRAM.
The program is loaded starting at $0301 (Ram_base=$0300, Smeml=$0301 after init).

Token values are from EhBASIC V2.22 source (basic.asm).
Single-char operators (*, +, -, /, ^, <, =, >) are also tokenized.
Strings in quotes and REM text are copied verbatim.
"""

import sys
import re

# EhBASIC program starts at this absolute address in SRAM.
# Ram_base = $0300; after LAB_COLD, Smeml = $0301 (incremented once).
PROG_START = 0x0301

# Token table: (keyword, token_byte)
# MUST be ordered longest-first for keywords sharing a common prefix,
# so "GOSUB" is tried before "GOTO", "RESTORE" before "RETURN", etc.
TOKENS = [
    # Multi-word / long keywords first
    ("RETIRQ",  0x8E), ("RETNMI",  0x8F), ("RESTORE", 0x8C), ("RETURN",  0x90),
    ("BITTST(", 0xDD), ("BITSET",  0xA7), ("BITCLR",  0xA8),
    ("LCASE$(", 0xD9), ("UCASE$(", 0xD8),
    ("VARPTR(", 0xE2), ("RIGHT$(", 0xE4), ("LEFT$(",  0xE3), ("MID$(",   0xE5),
    ("HEX$(",   0xDB), ("BIN$(",   0xDC), ("STR$(",   0xD5), ("CHR$(",   0xDA),
    ("SADD(",   0xD3), ("TWOPI",   0xE1),
    ("GOSUB",   0x8D), ("PRINT",   0x9F), ("INPUT",   0x84), ("CLEAR",   0xA2),
    ("WIDTH",   0xA4), ("WHILE",   0xB4), ("UNTIL",   0xB3), ("SWAP",    0xA6),
    ("STEP",    0xB2), ("STOP",    0x92), ("SAVE",    0x98), ("LOAD",    0x97),
    ("LIST",    0xA1), ("LOOP",    0x9E), ("POKE",    0x9A), ("DOKE",    0x9B),
    ("CALL",    0x9C), ("CONT",    0xA0), ("DATA",    0x83), ("NEXT",    0x82),
    ("NULL",    0x94), ("WAIT",    0x96), ("ELSE",    0xAC), ("THEN",    0xB0),
    ("PEEK(",   0xD1), ("DEEK(",   0xD2), ("FRE(",    0xC7), ("SQR(",    0xC9),
    ("SIN(",    0xCE), ("TAN(",    0xCF), ("ATN(",    0xD0), ("ABS(",    0xC5),
    ("ASC(",    0xD7), ("COS(",    0xCD), ("EXP(",    0xCC), ("INT(",    0xC4),
    ("LOG(",    0xCB), ("LEN(",    0xD4), ("MAX(",    0xDE), ("MIN(",    0xDF),
    ("POS(",    0xC8), ("RND(",    0xCA), ("SGN(",    0xC3), ("USR(",    0xC6),
    ("VAL(",    0xD6), ("SPC(",    0xAF), ("READ",    0x86),
    ("GOTO",    0x89), ("FOR",     0x81), ("LET",     0x87), ("DEC",     0x88),
    ("DEF",     0x99), ("DIM",     0x85), ("END",     0x80), ("EOR",     0xBC),
    ("AND",     0xBB), ("OFF",     0xB5), ("NOT",     0xB1), ("NEW",     0xA3),
    ("NMI",     0xAA), ("IRQ",     0xA9), ("INC",     0x95), ("GET",     0xA5),
    ("REM",     0x91), ("RUN",     0x8A), ("ON",      0x93), ("OR",      0xBD),
    ("DO",      0x9D), ("IF",      0x8B), ("PI",      0xE0), ("FN",      0xAE),
    ("TO",      0xAD),
]

# Build sorted keyword list: longer keywords first to ensure greedy match
TOKENS_SORTED = sorted(TOKENS, key=lambda x: -len(x[0]))

# Keyword names for word-boundary checking (those NOT ending in '(')
KEYWORDS_NO_PAREN = {kw for kw, _ in TOKENS if not kw.endswith('(')}

# Single/double character operators that EhBASIC tokenizes.
# Order: longer sequences first (>> before >, << before <).
OPERATORS = [
    ("<<", 0xBF), (">>", 0xBE),
    ("*",  0xB8), ("+",  0xB6), ("-",  0xB7), ("/",  0xB9),
    ("^",  0xBA), ("<",  0xC2), ("=",  0xC1), (">",  0xC0),
    ("?",  0x9F),  # ? is shorthand for PRINT
]


def _is_ident_char(ch: str) -> bool:
    """Return True if ch can be part of a BASIC identifier (letter, digit, $)."""
    return ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"


def tokenize_line_body(text: str) -> bytes:
    """
    Tokenize the statement part of a BASIC line (no line number).
    Handles:
      - Quoted strings verbatim
      - REM: rest of line verbatim
      - Keyword and operator substitution
      - DATA: items after DATA token are verbatim until ':' or end
    """
    result = bytearray()
    i = 0
    n = len(text)
    in_rem = False
    in_data = False  # after DATA token, don't tokenize values

    while i < n:
        ch = text[i].upper()

        # --- After REM: copy everything as-is until end ---
        if in_rem:
            result.append(ord(text[i]))
            i += 1
            continue

        # --- Quoted string: copy verbatim ---
        if text[i] == '"':
            result.append(ord('"'))
            i += 1
            while i < n and text[i] != '"':
                result.append(ord(text[i]))
                i += 1
            if i < n:
                result.append(ord('"'))
                i += 1
            continue

        # --- Statement separator: reset in_data flag ---
        if text[i] == ':':
            result.append(ord(':'))
            i += 1
            in_data = False
            continue

        # --- In DATA section: copy verbatim ---
        if in_data:
            result.append(ord(text[i]))
            i += 1
            continue

        # --- Try two/single-char operators ---
        op_matched = False
        for op_str, op_tok in OPERATORS:
            seg = text[i:i+len(op_str)].upper()
            if seg == op_str:
                result.append(op_tok)
                i += len(op_str)
                op_matched = True
                break
        if op_matched:
            continue

        # --- Try keyword match (uppercase letters only) ---
        if ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
            kw_matched = False
            for kw, tok in TOKENS_SORTED:
                seg = text[i:i+len(kw)].upper()
                if seg != kw:
                    continue
                # Word-boundary check for keywords that don't end in '('
                if kw not in ("PI",) and not kw.endswith('('):
                    next_pos = i + len(kw)
                    if next_pos < n and _is_ident_char(text[next_pos].upper()):
                        continue  # Prefix of a longer identifier
                result.append(tok)
                i += len(kw)
                kw_matched = True
                if kw == "REM":
                    in_rem = True
                elif kw == "DATA":
                    in_data = True
                break
            if kw_matched:
                continue

        # --- Default: copy character verbatim ---
        result.append(ord(text[i]))
        i += 1

    return bytes(result)


def tokenize(source: str) -> bytes:
    """
    Convert an ASCII EhBASIC source string to a tokenized .prg binary.

    Each non-empty, non-comment source line must start with a line number.
    Lines starting with '#' or ';' are treated as source-level comments and ignored.
    """
    lines = []

    for raw in source.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith('#') or stripped.startswith(';'):
            continue

        # Split off line number
        m = re.match(r'^(\d+)\s*(.*)', stripped)
        if not m:
            raise ValueError(f"Line without line number: {stripped!r}")

        linenum = int(m.group(1))
        body_src = m.group(2)

        token_body = tokenize_line_body(body_src)
        lines.append((linenum, token_body))

    # Sort by line number (source may be out of order)
    lines.sort(key=lambda x: x[0])

    # Build binary: calculate LINK addresses
    # Each BASIC line in memory: [LINK_LO][LINK_HI][LINENUM_LO][LINENUM_HI][body...][0x00]
    # Followed by end-of-program marker: [0x00][0x00]
    addr = PROG_START
    output = bytearray()

    for linenum, body in lines:
        line_size = 4 + len(body) + 1   # header(4) + body + null
        next_addr = addr + line_size
        output.append(next_addr & 0xFF)         # LINK low
        output.append((next_addr >> 8) & 0xFF)  # LINK high
        output.append(linenum & 0xFF)           # LINENUM low
        output.append((linenum >> 8) & 0xFF)    # LINENUM high
        output.extend(body)                     # tokenized body
        output.append(0x00)                     # null terminator
        addr = next_addr

    output.append(0x00)   # end-of-program marker
    output.append(0x00)

    return bytes(output)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} input.bas output.prg", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, 'r', encoding='utf-8') as f:
        source = f.read()

    binary = tokenize(source)

    with open(out_path, 'wb') as f:
        f.write(binary)

    print(f"Tokenized {in_path} -> {out_path} ({len(binary)} bytes, "
          f"{source.count(chr(10))+1} source lines)")


if __name__ == '__main__':
    main()
