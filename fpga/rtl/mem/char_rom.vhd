-- Character ROM: 8x8 pixel patterns for ASCII characters (0x00-0x7F)
-- Each character is 8 rows of 8 pixels
-- Addressing: addr = char_code(6:0) & pixel_row(2:0)
-- Output: 8-bit pixel data (one horizontal line: bit 7=leftmost pixel)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity char_rom is
  port (
    -- Address: bits[9:3] = character code (0-127), bits[2:0] = pixel row (0-7)
    addr : in  std_logic_vector(9 downto 0);
    dout : out data_t  -- 8-bit output: one row of character pixels
  );
end entity;

architecture rtl of char_rom is
  -- ROM array: 128 characters × 8 rows = 1024 entries
  type rom_t is array (0 to 1023) of data_t;

  constant rom : rom_t := (
    -- Character 0x00 (NULL): blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x01: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x02: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x03: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x04: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x05: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x06: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x07: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x08: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x09: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x0A: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x0B: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x0C: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x0D: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x0E: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x0F: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x10: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x11: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x12: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x13: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x14: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x15: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x16: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x17: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x18: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x19: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x1A: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x1B: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x1C: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x1D: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x1E: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x1F: blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x20 (SPACE): blank
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x21 (!): vertical bar
    x"18", x"18", x"18", x"18", x"00", x"18", x"00", x"00",
    -- Character 0x22 ("): two dots
    x"66", x"66", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x23 (#): hash
    x"36", x"36", x"7F", x"36", x"7F", x"36", x"36", x"00",
    -- Character 0x24 ($): dollar
    x"18", x"3E", x"60", x"3C", x"06", x"7C", x"18", x"00",
    -- Character 0x25 (%): percent
    x"60", x"66", x"0C", x"18", x"30", x"66", x"06", x"00",
    -- Character 0x26 (&): ampersand
    x"38", x"6C", x"38", x"76", x"DC", x"CC", x"76", x"00",
    -- Character 0x27 ('): single quote
    x"18", x"18", x"30", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x28 ((): left paren
    x"0C", x"18", x"30", x"30", x"30", x"18", x"0C", x"00",
    -- Character 0x29 ()): right paren
    x"30", x"18", x"0C", x"0C", x"0C", x"18", x"30", x"00",
    -- Character 0x2A (*): asterisk
    x"00", x"66", x"3C", x"FF", x"3C", x"66", x"00", x"00",
    -- Character 0x2B (+): plus
    x"00", x"18", x"18", x"7E", x"18", x"18", x"00", x"00",
    -- Character 0x2C (,): comma
    x"00", x"00", x"00", x"00", x"00", x"18", x"18", x"30",
    -- Character 0x2D (-): minus
    x"00", x"00", x"00", x"7E", x"00", x"00", x"00", x"00",
    -- Character 0x2E (.): period
    x"00", x"00", x"00", x"00", x"00", x"18", x"18", x"00",
    -- Character 0x2F (/): slash
    x"06", x"0C", x"18", x"30", x"60", x"C0", x"80", x"00",
    -- Character 0x30 (0): zero
    x"3C", x"66", x"6E", x"76", x"66", x"66", x"3C", x"00",
    -- Character 0x31 (1): one
    x"18", x"38", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x32 (2): two
    x"3C", x"66", x"06", x"0C", x"18", x"30", x"7E", x"00",
    -- Character 0x33 (3): three
    x"3C", x"66", x"06", x"1C", x"06", x"66", x"3C", x"00",
    -- Character 0x34 (4): four
    x"0C", x"1C", x"3C", x"6C", x"7E", x"0C", x"0C", x"00",
    -- Character 0x35 (5): five
    x"7E", x"60", x"7C", x"06", x"06", x"66", x"3C", x"00",
    -- Character 0x36 (6): six
    x"3C", x"66", x"60", x"7C", x"66", x"66", x"3C", x"00",
    -- Character 0x37 (7): seven
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"60", x"00",
    -- Character 0x38 (8): eight
    x"3C", x"66", x"66", x"3C", x"66", x"66", x"3C", x"00",
    -- Character 0x39 (9): nine
    x"3C", x"66", x"66", x"3E", x"06", x"66", x"3C", x"00",
    -- Character 0x3A (:): colon
    x"00", x"18", x"18", x"00", x"18", x"18", x"00", x"00",
    -- Character 0x3B (;): semicolon
    x"00", x"18", x"18", x"00", x"18", x"18", x"30", x"00",
    -- Character 0x3C (<): less than
    x"0C", x"18", x"30", x"60", x"30", x"18", x"0C", x"00",
    -- Character 0x3D (=): equals
    x"00", x"00", x"7E", x"00", x"7E", x"00", x"00", x"00",
    -- Character 0x3E (>): greater than
    x"30", x"18", x"0C", x"06", x"0C", x"18", x"30", x"00",
    -- Character 0x3F (?): question mark
    x"3C", x"66", x"06", x"0C", x"18", x"00", x"18", x"00",
    -- Character 0x40 (@): at sign
    x"3C", x"66", x"6E", x"6A", x"6E", x"60", x"3E", x"00",
    -- Character 0x41 (A): uppercase A
    x"3C", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x42 (B): uppercase B
    x"7C", x"66", x"66", x"7C", x"66", x"66", x"7C", x"00",
    -- Character 0x43 (C): uppercase C
    x"3C", x"66", x"60", x"60", x"60", x"66", x"3C", x"00",
    -- Character 0x44 (D): uppercase D
    x"78", x"6C", x"66", x"66", x"66", x"6C", x"78", x"00",
    -- Character 0x45 (E): uppercase E
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"7E", x"00",
    -- Character 0x46 (F): uppercase F
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x47 (G): uppercase G
    x"3C", x"66", x"60", x"6E", x"66", x"66", x"3C", x"00",
    -- Character 0x48 (H): uppercase H
    x"66", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x49 (I): uppercase I
    x"7E", x"18", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x4A (J): uppercase J
    x"3E", x"0C", x"0C", x"0C", x"0C", x"6C", x"38", x"00",
    -- Character 0x4B (K): uppercase K
    x"66", x"6C", x"78", x"70", x"78", x"6C", x"66", x"00",
    -- Character 0x4C (L): uppercase L
    x"60", x"60", x"60", x"60", x"60", x"60", x"7E", x"00",
    -- Character 0x4D (M): uppercase M
    x"63", x"77", x"7F", x"6B", x"63", x"63", x"63", x"00",
    -- Character 0x4E (N): uppercase N
    x"66", x"76", x"7E", x"7E", x"6E", x"66", x"66", x"00",
    -- Character 0x4F (O): uppercase O
    x"3C", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x50 (P): uppercase P
    x"7C", x"66", x"66", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x51 (Q): uppercase Q
    x"3C", x"66", x"66", x"66", x"6E", x"3C", x"06", x"00",
    -- Character 0x52 (R): uppercase R
    x"7C", x"66", x"66", x"7C", x"78", x"6C", x"66", x"00",
    -- Character 0x53 (S): uppercase S
    x"3E", x"60", x"60", x"3C", x"06", x"06", x"7C", x"00",
    -- Character 0x54 (T): uppercase T
    x"7E", x"18", x"18", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x55 (U): uppercase U
    x"66", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x56 (V): uppercase V
    x"66", x"66", x"66", x"66", x"66", x"3C", x"18", x"00",
    -- Character 0x57 (W): uppercase W
    x"63", x"63", x"6B", x"7F", x"77", x"63", x"63", x"00",
    -- Character 0x58 (X): uppercase X
    x"66", x"66", x"3C", x"18", x"3C", x"66", x"66", x"00",
    -- Character 0x59 (Y): uppercase Y
    x"66", x"66", x"66", x"3C", x"18", x"18", x"18", x"00",
    -- Character 0x5A (Z): uppercase Z
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"7E", x"00",
    -- Character 0x5B ([): left bracket
    x"3C", x"30", x"30", x"30", x"30", x"30", x"3C", x"00",
    -- Character 0x5C (\): backslash
    x"80", x"C0", x"60", x"30", x"18", x"0C", x"06", x"00",
    -- Character 0x5D (]): right bracket
    x"3C", x"0C", x"0C", x"0C", x"0C", x"0C", x"3C", x"00",
    -- Character 0x5E (^): caret
    x"18", x"3C", x"66", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x5F (_): underscore
    x"00", x"00", x"00", x"00", x"00", x"00", x"FF", x"00",
    -- Character 0x60 (`): backtick
    x"30", x"18", x"0C", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x61 (a): lowercase a
    x"00", x"00", x"3C", x"06", x"3E", x"66", x"3E", x"00",
    -- Character 0x62 (b): lowercase b
    x"60", x"60", x"7C", x"66", x"66", x"66", x"7C", x"00",
    -- Character 0x63 (c): lowercase c
    x"00", x"00", x"3C", x"60", x"60", x"60", x"3C", x"00",
    -- Character 0x64 (d): lowercase d
    x"06", x"06", x"3E", x"66", x"66", x"66", x"3E", x"00",
    -- Character 0x65 (e): lowercase e
    x"00", x"00", x"3C", x"66", x"7E", x"60", x"3C", x"00",
    -- Character 0x66 (f): lowercase f
    x"1C", x"30", x"30", x"7C", x"30", x"30", x"30", x"00",
    -- Character 0x67 (g): lowercase g
    x"00", x"00", x"3E", x"66", x"66", x"3E", x"06", x"7C",
    -- Character 0x68 (h): lowercase h
    x"60", x"60", x"7C", x"66", x"66", x"66", x"66", x"00",
    -- Character 0x69 (i): lowercase i
    x"18", x"00", x"38", x"18", x"18", x"18", x"3C", x"00",
    -- Character 0x6A (j): lowercase j
    x"0C", x"00", x"1C", x"0C", x"0C", x"0C", x"6C", x"38",
    -- Character 0x6B (k): lowercase k
    x"60", x"60", x"66", x"6C", x"78", x"6C", x"66", x"00",
    -- Character 0x6C (l): lowercase l
    x"38", x"18", x"18", x"18", x"18", x"18", x"3C", x"00",
    -- Character 0x6D (m): lowercase m
    x"00", x"00", x"6C", x"FE", x"FE", x"D6", x"C6", x"00",
    -- Character 0x6E (n): lowercase n
    x"00", x"00", x"7C", x"66", x"66", x"66", x"66", x"00",
    -- Character 0x6F (o): lowercase o
    x"00", x"00", x"3C", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x70 (p): lowercase p
    x"00", x"00", x"7C", x"66", x"66", x"7C", x"60", x"60",
    -- Character 0x71 (q): lowercase q
    x"00", x"00", x"3E", x"66", x"66", x"3E", x"06", x"06",
    -- Character 0x72 (r): lowercase r
    x"00", x"00", x"7C", x"66", x"60", x"60", x"60", x"00",
    -- Character 0x73 (s): lowercase s
    x"00", x"00", x"3E", x"60", x"3C", x"06", x"7C", x"00",
    -- Character 0x74 (t): lowercase t
    x"18", x"18", x"7E", x"18", x"18", x"18", x"0E", x"00",
    -- Character 0x75 (u): lowercase u
    x"00", x"00", x"66", x"66", x"66", x"66", x"3E", x"00",
    -- Character 0x76 (v): lowercase v
    x"00", x"00", x"66", x"66", x"66", x"3C", x"18", x"00",
    -- Character 0x77 (w): lowercase w
    x"00", x"00", x"C6", x"D6", x"FE", x"6C", x"44", x"00",
    -- Character 0x78 (x): lowercase x
    x"00", x"00", x"66", x"3C", x"18", x"3C", x"66", x"00",
    -- Character 0x79 (y): lowercase y
    x"00", x"00", x"66", x"66", x"66", x"3E", x"06", x"7C",
    -- Character 0x7A (z): lowercase z
    x"00", x"00", x"7E", x"0C", x"18", x"30", x"7E", x"00",
    -- Character 0x7B ({): left brace
    x"0E", x"18", x"18", x"70", x"18", x"18", x"0E", x"00",
    -- Character 0x7C (|): pipe
    x"18", x"18", x"18", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x7D (}): right brace
    x"70", x"18", x"18", x"0E", x"18", x"18", x"70", x"00",
    -- Character 0x7E (~): tilde
    x"76", x"DC", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x7F (DEL): filled block
    x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"00"
  );

begin
  dout <= rom(to_integer(unsigned(addr)));
end architecture;
