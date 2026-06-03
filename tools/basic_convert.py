#!/usr/bin/env python3
"""
BASIC Tokenizer/Detokenizer for 6502 SBC Emulator
Supports two BASIC variants with different token tables:

  --type msbasic  (default)  MS BASIC V2 (mist64/msbasic ROM, sbc.ini)
  --type ehbasic             EhBASIC V2.22 (ehbasic.ini)

Usage:
  txt → prg:  python3 basic_convert.py prog.txt prog.prg [--type msbasic|ehbasic]
  prg → txt:  python3 basic_convert.py prog.prg prog.txt [--type msbasic|ehbasic]

Token tables were verified by raw-byte analysis of compiled .prg files:
  - MS BASIC:  PRINT=0x96, POKE=0x95, INPUT=0x84 confirmed by runtime testing.
               Operator tokens 0xAA..0xAC verified by listing output.
  - EhBASIC:   Full table verified by detokenizing adventure.prg (round-trip clean).
"""

import sys
import struct

# MS BASIC tokens (mist64/msbasic ROM — used with sbc.ini / msbasic.rom)
# Verified working: PRINT(0x96), POKE(0x95), INPUT(0x84), AND(0xA8), INT(0xAE)
# Note: 0xAA = "=" and 0xAB = ">" — the ROM uses this ordering (confirmed by
# listing: writing 0xAB for = displays as ">", so = must be 0xAA).
MS_TOKENS = {
    0x80: "END", 0x81: "FOR", 0x82: "NEXT", 0x83: "DATA", 0x84: "INPUT",
    0x85: "DIM", 0x86: "READ", 0x87: "LET", 0x88: "GOTO", 0x89: "RUN",
    0x8A: "IF", 0x8B: "RESTORE", 0x8C: "GOSUB", 0x8D: "RETURN", 0x8E: "REM",
    0x8F: "STOP", 0x90: "ON", 0x91: "WAIT", 0x92: "LOAD", 0x93: "SAVE",
    0x94: "DEF", 0x95: "POKE", 0x96: "PRINT", 0x97: "CONT", 0x98: "LIST",
    0x99: "CLEAR", 0x9A: "GET", 0x9B: "NEW", 0x9C: "TAB(", 0x9D: "TO",
    0x9E: "FN", 0x9F: "SPC(", 0xA0: "THEN", 0xA1: "NOT", 0xA2: "STEP",
    0xA3: "+", 0xA4: "-", 0xA5: "*", 0xA6: "/", 0xA7: "^",
    0xA8: "AND", 0xA9: "OR", 0xAA: "=", 0xAB: ">", 0xAC: "<",
    0xAD: "SGN", 0xAE: "INT", 0xAF: "ABS", 0xB0: "USR", 0xB1: "FRE",
    0xB2: "POS", 0xB3: "SQR", 0xB4: "RND", 0xB5: "LOG", 0xB6: "EXP",
    0xB7: "COS", 0xB8: "SIN", 0xB9: "TAN", 0xBA: "ATN", 0xBB: "PEEK",
    0xBC: "LEN", 0xBD: "STR$", 0xBE: "VAL", 0xBF: "ASC", 0xC0: "CHR$",
    0xC1: "LEFT$", 0xC2: "RIGHT$", 0xC3: "MID$",
}

# EhBASIC V2.22 tokens (used with ehbasic.ini / ehbasic.rom)
# Verified by round-trip detokenization of adventure.prg (all keywords correct).
EH_TOKENS = {
    0x80: "END", 0x81: "FOR", 0x82: "NEXT", 0x83: "DATA", 0x84: "INPUT",
    0x85: "DIM", 0x86: "READ", 0x87: "LET", 0x88: "DEC", 0x89: "GOTO",
    0x8A: "RUN", 0x8B: "IF", 0x8C: "RESTORE", 0x8D: "GOSUB", 0x8E: "RETIRQ",
    0x8F: "RETNMI", 0x90: "RETURN", 0x91: "REM", 0x92: "STOP", 0x93: "ON",
    0x94: "NULL", 0x95: "INC", 0x96: "WAIT", 0x97: "LOAD", 0x98: "SAVE",
    0x99: "DEF", 0x9A: "POKE", 0x9B: "DOKE", 0x9C: "CALL", 0x9D: "DO",
    0x9E: "LOOP", 0x9F: "PRINT", 0xA0: "CONT", 0xA1: "LIST", 0xA2: "CLEAR",
    0xA3: "NEW", 0xA4: "WIDTH", 0xA5: "GET", 0xA6: "SWAP", 0xA7: "BITSET",
    0xA8: "BITCLR", 0xA9: "IRQ", 0xAA: "NMI", 0xAB: "TAB(", 0xAC: "ELSE", 0xAD: "TO",
    0xAE: "FN", 0xAF: "SPC(", 0xB0: "THEN", 0xB1: "NOT", 0xB2: "STEP",
    0xB3: "UNTIL", 0xB4: "WHILE", 0xB5: "OFF", 0xB6: "+", 0xB7: "-",
    0xB8: "*", 0xB9: "/", 0xBA: "^", 0xBB: "AND", 0xBC: "EOR", 0xBD: "OR",
    0xBE: ">>", 0xBF: "<<", 0xC0: ">", 0xC1: "=", 0xC2: "<", 0xC3: "SGN(",
    0xC4: "INT(", 0xC5: "ABS(", 0xC6: "USR(", 0xC7: "FRE(", 0xC8: "POS(",
    0xC9: "SQR(", 0xCA: "RND(", 0xCB: "LOG(", 0xCC: "EXP(", 0xCD: "COS(",
    0xCE: "SIN(", 0xCF: "TAN(", 0xD0: "ATN(", 0xD1: "PEEK(", 0xD2: "DEEK(",
    0xD3: "SADD(", 0xD4: "LEN(", 0xD5: "STR$(", 0xD6: "VAL(", 0xD7: "ASC(",
    0xD8: "UCASE$(", 0xD9: "LCASE$(", 0xDA: "CHR$(", 0xDB: "HEX$(", 0xDC: "BIN$(",
    0xDD: "BITTST(", 0xDE: "MAX(", 0xDF: "MIN(", 0xE0: "PI", 0xE1: "TWOPI",
    0xE2: "VARPTR(", 0xE3: "LEFT$(", 0xE4: "RIGHT$(", 0xE5: "MID$(",
}

# Add ? as shorthand for PRINT in EhBASIC
EH_TOKEN_MAP_EXTRA = {"?": 0x9F}

# Global maps will be selected at runtime
TOKENS = MS_TOKENS
TOKEN_MAP = {v: k for k, v in TOKENS.items()}

def set_basic_type(basic_type):
    global TOKENS, TOKEN_MAP
    if basic_type == 'ehbasic':
        TOKENS = EH_TOKENS
        TOKEN_MAP = {v: k for k, v in TOKENS.items()}
        TOKEN_MAP.update(EH_TOKEN_MAP_EXTRA)
    else:
        TOKENS = MS_TOKENS
        TOKEN_MAP = {v: k for k, v in TOKENS.items()}

def detokenize_prg(prg_file, txt_file):
    """Convert tokenized .prg to readable .txt"""
    with open(prg_file, 'rb') as f:
        data = f.read()

    lines = []
    offset = 0

    while offset < len(data):
        # Check for end of program (00 00)
        if offset + 1 < len(data) and data[offset] == 0 and data[offset + 1] == 0:
            break

        # Read link address (2 bytes, little-endian) - we ignore this
        if offset + 2 > len(data):
            break
        link = struct.unpack('<H', data[offset:offset+2])[0]
        if link == 0:
            break
        offset += 2

        # Read line number (2 bytes, little-endian)
        if offset + 2 > len(data):
            break
        line_num = struct.unpack('<H', data[offset:offset+2])[0]
        offset += 2

        # Read line text until 0x00
        line_text = ""
        while offset < len(data) and data[offset] != 0:
            byte = data[offset]
            if byte >= 0x80:  # Token
                token = TOKENS.get(byte, f"?{byte:02X}?")
                line_text += token

                # Add space after keyword token unless it's followed by space or special char
                # No space after operator tokens or tokens ending with '('
                is_operator = token in ["*", "+", "-", "/", "^", "<", "=", ">", "<<", ">>", "?", "AND", "OR", "EOR", "NOT"]
                if not is_operator and not token.endswith('('):
                    if offset + 1 < len(data) and data[offset + 1] not in [0, ord(' '), ord('('), ord(','), ord(';'), ord(':')]:
                        line_text += " "
            else:  # Regular ASCII
                line_text += chr(byte)
            offset += 1

        # Skip the 0x00 terminator
        offset += 1

        lines.append(f"{line_num} {line_text.strip()}\n")

    with open(txt_file, 'w') as f:
        f.writelines(lines)

    print(f"Detokenized {len(lines)} lines: {prg_file} -> {txt_file}")

def tokenize_txt(txt_file, prg_file, start_addr=0x0300):
    """Convert plain text .txt to tokenized .prg"""
    with open(txt_file, 'r') as f:
        lines = f.readlines()

    output = bytearray()
    current_addr = start_addr

    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):  # Skip empty lines and comments
            continue

        # Parse line number
        parts = line.split(None, 1)
        if not parts:
            continue

        try:
            line_num = int(parts[0])
        except ValueError:
            print(f"Warning: Skipping line without number: {line}")
            continue

        line_text = parts[1] if len(parts) > 1 else ""

        # Tokenize the line
        tokenized = bytearray()
        i = 0
        in_string = False
        in_rem = False
        in_data = False

        rem_token = TOKEN_MAP.get("REM")
        data_token = TOKEN_MAP.get("DATA")

        while i < len(line_text):
            # Track strings
            if line_text[i] == '"':
                in_string = not in_string
                tokenized.append(ord(line_text[i]))
                i += 1
                continue

            if in_string:
                tokenized.append(ord(line_text[i]))
                i += 1
                continue

            # Track REM
            if in_rem:
                tokenized.append(ord(line_text[i]))
                i += 1
                continue

            # Track DATA
            if in_data:
                if line_text[i] == ':':
                    in_data = False
                else:
                    tokenized.append(ord(line_text[i]))
                    i += 1
                    continue

            # Check for tokens (longest match first)
            matched = False
            for token_len in range(10, 0, -1):  # Max token length ~10
                if i + token_len <= len(line_text):
                    substr = line_text[i:i+token_len].upper()
                    if substr in TOKEN_MAP:
                        # Check word boundaries for alphabetic tokens
                        if substr[0].isalpha():
                            # Token must be preceded by non-alphanumeric or start of line
                            if i > 0 and line_text[i-1].isalnum():
                                continue
                            # Token must be followed by non-alphanumeric or end of line
                            next_pos = i + token_len
                            if next_pos < len(line_text) and line_text[next_pos].isalnum():
                                # Exception: if token ends in '(', it's fine
                                if not substr.endswith('('):
                                    continue

                        val = TOKEN_MAP[substr]
                        tokenized.append(val)
                        i += token_len
                        matched = True

                        if val == rem_token:
                            in_rem = True
                        elif val == data_token:
                            in_data = True
                        break

            if not matched:
                # Regular character
                tokenized.append(ord(line_text[i]))
                i += 1

        # Calculate next line address
        line_len = 2 + 2 + len(tokenized) + 1  # link + line_num + text + null
        next_addr = current_addr + line_len

        # Write line: [link][line_num][tokenized_text][0x00]
        output.extend(struct.pack('<H', next_addr))
        output.extend(struct.pack('<H', line_num))
        output.extend(tokenized)
        output.append(0x00)

        current_addr = next_addr

    # End marker (00 00)
    output.extend(struct.pack('<H', 0))

    with open(prg_file, 'wb') as f:
        f.write(output)

    print(f"Tokenized {len(lines)} lines: {txt_file} -> {prg_file} ({len(output)} bytes)")

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Convert between BASIC .prg and .txt files")
    parser.add_argument("input", help="Input file (.prg or .txt)")
    parser.add_argument("output", help="Output file (.txt or .prg)")
    parser.add_argument("--type", choices=['msbasic', 'ehbasic'], default='msbasic',
                        help="BASIC variant (default: msbasic)")
    parser.add_argument("--addr", type=lambda x: int(x, 16),
                        help="Start address in hex (default: 0300 for msbasic, 0301 for ehbasic)")

    args = parser.parse_args()

    set_basic_type(args.type)

    start_addr = args.addr
    if start_addr is None:
        start_addr = 0x0301 if args.type == 'ehbasic' else 0x0300

    if args.input.endswith('.prg') and (args.output.endswith('.txt') or args.output.endswith('.bas')):
        detokenize_prg(args.input, args.output)
    elif (args.input.endswith('.txt') or args.input.endswith('.bas')) and args.output.endswith('.prg'):
        tokenize_txt(args.input, args.output, start_addr=start_addr)
    else:
        print("Error: File extensions must be .prg for binary, and .txt or .bas for text")
        sys.exit(1)

if __name__ == '__main__':
    main()
