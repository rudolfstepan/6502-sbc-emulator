#!/usr/bin/env python3
"""
Extract MS BASIC token values from mist64/msbasic token.s
"""

# Token list from msbasic/token.s in order (starting at 0x80)
# Note: TEX and REM share the same token value (TOKEN_REM)
# The list represents the order as they appear in the keyword table

tokens_in_order = [
    "END", "FOR", "NEXT", "DATA", "INPUT#", "INPUT", "DIM", "READ",
    "PLT", "LET", "GOTO", "RUN", "IF", "RESTORE", "GOSUB", "RETURN",
    "REM",  # TEX and REM share this token (TEX listed first in source, but both map to TOKEN_REM)
    "STOP", "ON", "NULL", "PLOD", "PSAV", "VLOD", "VSAV",
    "WAIT", "LOAD", "SAVE", "VERIFY", "DEF", "SLOD", "POKE",
    "PRINT#", "PRINT", "CONT", "LIST", "CLR", "CMD", "SYS",
    "OPEN", "CLOSE", "GET", "NEW",
    "TAB(", "TO", "FN", "SPC(", "THEN", "NOT", "STEP",
    "+", "-", "*", "/", "^", "AND", "OR",
    ">", "=", "<",
    "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR", "RND",
    "LOG", "EXP", "COS", "SIN", "TAN", "ATN", "PEEK",
    "LEN", "STR$", "VAL", "ASC", "CHR$", "LEFT$", "RIGHT$", "MID$",
]

print("MS BASIC Token Map (mist64/msbasic):")
print("=" * 50)
for i, token in enumerate(tokens_in_order):
    value = 0x80 + i
    print(f"0x{value:02X}: {token}")
