"""Create a 40-column VIC title screen for a standalone SID ROM."""

import textwrap
import unicodedata


SCREEN_WIDTH = 40
SCREEN_HEIGHT = 25
INNER_WIDTH = 36
DEFAULT_CREDIT = "Rudolf Stepan"

# Three columns by five rows. A dot marks an empty cell.
GLYPHS = {
    "A": ".#. #.# ### #.# #.#",
    "B": "##. #.# ##. #.# ##.",
    "C": ".## #.. #.. #.. .##",
    "D": "##. #.# #.# #.# ##.",
    "E": "### #.. ##. #.. ###",
    "F": "### #.. ##. #.. #..",
    "G": ".## #.. #.# #.# .##",
    "H": "#.# #.# ### #.# #.#",
    "I": "### .#. .#. .#. ###",
    "J": "..# ..# ..# #.# .#.",
    "K": "#.# #.# ##. #.# #.#",
    "L": "#.. #.. #.. #.. ###",
    "M": "#.# ### ### #.# #.#",
    "N": "#.# ### ### ### #.#",
    "O": ".#. #.# #.# #.# .#.",
    "P": "##. #.# ##. #.. #..",
    "Q": ".#. #.# #.# .#. ..#",
    "R": "##. #.# ##. #.# #.#",
    "S": ".## #.. .#. ..# ##.",
    "T": "### .#. .#. .#. .#.",
    "U": "#.# #.# #.# #.# ###",
    "V": "#.# #.# #.# #.# .#.",
    "W": "#.# #.# ### ### #.#",
    "X": "#.# #.# .#. #.# #.#",
    "Y": "#.# #.# .#. .#. .#.",
    "Z": "### ..# .#. #.. ###",
    "0": "### #.# #.# #.# ###",
    "1": ".#. ##. .#. .#. ###",
    "2": "##. ..# .#. #.. ###",
    "3": "##. ..# .## ..# ##.",
    "4": "#.# #.# ### ..# ..#",
    "5": "### #.. ##. ..# ##.",
    "6": ".## #.. ### #.# ###",
    "7": "### ..# .#. .#. .#.",
    "8": "### #.# ### #.# ###",
    "9": "### #.# ### ..# ##.",
    "-": "... ... ### ... ...",
    " ": "... ... ... ... ...",
}


def vic_text(value: str) -> str:
    """Fold text into printable ASCII understood by the VIC character ROM."""
    plain = unicodedata.normalize("NFKD", value.upper())
    ascii_text = "".join(
        character if " " <= character <= "~" else "?"
        for character in plain
        if not unicodedata.combining(character)
    )
    return " ".join(ascii_text.split())


def title_art(title: str) -> list[str]:
    words = textwrap.wrap(title, width=(INNER_WIDTH + 1) // 4, break_long_words=False)
    if len(words) > 2 or any(len(word) > (INNER_WIDTH + 1) // 4 for word in words):
        return []
    if any(char not in GLYPHS for char in title):
        return []
    rows = []
    for line in words:
        if rows:
            rows.append("")
        glyphs = [GLYPHS[character].split() for character in line]
        rows.extend(" ".join(row).replace(".", " ") for row in zip(*glyphs))
    return rows


def title_screen(title: str, credit: str, composer: str = "") -> bytes:
    """Return the exact 1,000 text cells written by the ROM's reset routine."""
    title = vic_text(title)[:64].rstrip()
    rows = ["SID SOUNDTRACK", ""]
    art = title_art(title)
    if art:
        rows.extend(art)
        rows.append("")
    rows.extend(textwrap.wrap(title, width=INNER_WIDTH))
    rows.append("")
    if composer:
        rows.extend(textwrap.wrap(f"MUSIC: {vic_text(composer)[:40]}", width=INNER_WIDTH))
    rows.append("")
    rows.extend(textwrap.wrap(f"ROM: {vic_text(credit)[:60]}", width=INNER_WIDTH))
    rows.append("CONVERTED WITH SID ROM CONVERTER")

    border = "+" + "-" * INNER_WIDTH + "+"
    frame = [border, *(f"|{row.center(INNER_WIDTH)}|" for row in rows), border]
    top = (SCREEN_HEIGHT - len(frame)) // 2
    screen = [""] * top + frame
    screen.extend([""] * (SCREEN_HEIGHT - len(screen)))
    return "".join(line.center(SCREEN_WIDTH) for line in screen).encode("ascii")


def bytes_directive(label: str, data: bytes | bytearray) -> str:
    lines = [f"{label}:"]
    for index in range(0, len(data), 16):
        lines.append("    .byte " + ", ".join(str(value) for value in data[index:index + 16]))
    return "\n".join(lines) + "\n"


SCREEN_CODE = """
; Write the 40x25 title directly to text and colour RAM.
draw_title:
    lda #0
    sta $9000
    sta $9004
    lda #1
    sta $9005
    lda #$FF
    sta $9001
    sta $9002
    ldx #0
@pages:
    .repeat 3, page
        lda screen_text + page * 256, x
        sta $8000 + page * 256, x
        lda #$0D
        sta $8400 + page * 256, x
    .endrepeat
    inx
    bne @pages
@last:
    lda screen_text + 768, x
    sta $8300, x
    lda #$0D
    sta $8700, x
    inx
    cpx #232
    bne @last
    rts
"""
