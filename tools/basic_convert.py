#!/usr/bin/env python3
"""
MS BASIC V2 Converter
Converts between tokenized .prg files and plain text .txt files
"""

import sys
import struct

# MS BASIC tokens for this 6502 SBC (mist64/msbasic variant)
# Token values extracted from actual ROM via testing
TOKENS = {
    0x80: "END", 0x81: "FOR", 0x82: "NEXT", 0x83: "DATA", 0x84: "INPUT",
    0x85: "DIM", 0x86: "READ", 0x87: "LET", 0x88: "GOTO", 0x89: "RUN",
    0x8A: "IF", 0x8B: "RESTORE", 0x8C: "GOSUB", 0x8D: "RETURN", 0x8E: "REM",
    0x8F: "STOP", 0x90: "ON", 0x91: "WAIT", 0x92: "LOAD", 0x93: "SAVE",
    0x94: "DEF", 0x95: "POKE", 0x96: "PRINT", 0x97: "CONT", 0x98: "LIST",
    0x99: "CLEAR", 0x9A: "GET", 0x9B: "NEW", 0x9C: "TAB(", 0x9D: "TO",
    0x9E: "FN", 0x9F: "SPC(", 0xA0: "THEN", 0xA1: "NOT", 0xA2: "STEP",
    0xA3: "+", 0xA4: "-", 0xA5: "*", 0xA6: "/", 0xA7: "^",
    0xA8: "AND", 0xA9: "OR", 0xAA: ">", 0xAB: "=", 0xAC: "<",
    0xAD: "SGN", 0xAE: "INT", 0xAF: "ABS", 0xB0: "USR", 0xB1: "FRE",
    0xB2: "POS", 0xB3: "SQR", 0xB4: "RND", 0xB5: "LOG", 0xB6: "EXP",
    0xB7: "COS", 0xB8: "SIN", 0xB9: "TAN", 0xBA: "ATN", 0xBB: "PEEK",
    0xBC: "LEN", 0xBD: "STR$", 0xBE: "VAL", 0xBF: "ASC", 0xC0: "CHR$",
    0xC1: "LEFT$", 0xC2: "RIGHT$", 0xC3: "MID$",
}

# Reverse mapping for tokenization
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
                # Add space after token unless it's followed by special char
                if offset + 1 < len(data) and data[offset + 1] not in [0, ord('('), ord(','), ord(';'), ord(':')]:
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
        
        while i < len(line_text):
            # Track string literals (don't tokenize inside strings)
            if line_text[i] == '"':
                in_string = not in_string
                tokenized.append(ord(line_text[i]))
                i += 1
                continue
            
            # Don't tokenize inside strings
            if in_string:
                tokenized.append(ord(line_text[i]))
                i += 1
                continue
            
            # Check for tokens (longest match first)
            matched = False
            for token_len in range(10, 0, -1):  # Max token length ~10
                if i + token_len <= len(line_text):
                    substr = line_text[i:i+token_len].upper()
                    if substr in TOKEN_MAP:
                        # Check word boundaries
                        # Token must be preceded by non-alphanumeric or start of line
                        if i > 0 and line_text[i-1].isalnum():
                            continue
                        # Token must be followed by non-alphanumeric or end of line
                        next_pos = i + token_len
                        if next_pos < len(line_text) and line_text[next_pos].isalnum():
                            continue
                        
                        tokenized.append(TOKEN_MAP[substr])
                        i += token_len
                        matched = True
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
    if len(sys.argv) < 3:
        print("Usage:")
        print("  Detokenize: basic_convert.py file.prg file.txt")
        print("  Tokenize:   basic_convert.py file.txt file.prg")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    if input_file.endswith('.prg') and output_file.endswith('.txt'):
        detokenize_prg(input_file, output_file)
    elif input_file.endswith('.txt') and output_file.endswith('.prg'):
        tokenize_txt(input_file, output_file)
    else:
        print("Error: File extensions must be .prg or .txt")
        print("Examples:")
        print("  basic_convert.py program.prg program.txt  # detokenize")
        print("  basic_convert.py program.txt program.prg  # tokenize")
        sys.exit(1)

if __name__ == '__main__':
    main()
