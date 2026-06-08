-- Character ROM: ASCII-compatible PETSCII-style 8x8 pixel patterns
-- Addressing: addr = char_code(6:0) & pixel_row(2:0)
-- Output: bit 7 = leftmost pixel. The VGA path uses char_code(7) as reverse video.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity char_rom is
  port (
    addr : in  std_logic_vector(9 downto 0);
    dout : out data_t
  );
end entity;

architecture rtl of char_rom is
  type rom_t is array (0 to 1023) of data_t;

  constant rom : rom_t := (
    -- PETSCII @ / screen-code 0
    x"3C", x"66", x"6E", x"6A", x"6E", x"60", x"3E", x"00",
    -- PETSCII A-Z screen-code block
    x"3C", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x02
    x"7C", x"66", x"66", x"7C", x"66", x"66", x"7C", x"00",
    -- Character 0x03
    x"3C", x"66", x"60", x"60", x"60", x"66", x"3C", x"00",
    -- Character 0x04
    x"78", x"6C", x"66", x"66", x"66", x"6C", x"78", x"00",
    -- Character 0x05
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"7E", x"00",
    -- Character 0x06
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x07
    x"3C", x"66", x"60", x"6E", x"66", x"66", x"3C", x"00",
    -- Character 0x08
    x"66", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x09
    x"7E", x"18", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x0A
    x"3E", x"0C", x"0C", x"0C", x"0C", x"6C", x"38", x"00",
    -- Character 0x0B
    x"66", x"6C", x"78", x"70", x"78", x"6C", x"66", x"00",
    -- Character 0x0C
    x"60", x"60", x"60", x"60", x"60", x"60", x"7E", x"00",
    -- Character 0x0D
    x"63", x"77", x"7F", x"6B", x"63", x"63", x"63", x"00",
    -- Character 0x0E
    x"66", x"76", x"7E", x"7E", x"6E", x"66", x"66", x"00",
    -- Character 0x0F
    x"3C", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x10
    x"7C", x"66", x"66", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x11
    x"3C", x"66", x"66", x"66", x"6E", x"3C", x"06", x"00",
    -- Character 0x12
    x"7C", x"66", x"66", x"7C", x"78", x"6C", x"66", x"00",
    -- Character 0x13
    x"3E", x"60", x"60", x"3C", x"06", x"06", x"7C", x"00",
    -- Character 0x14
    x"7E", x"18", x"18", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x15
    x"66", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x16
    x"66", x"66", x"66", x"66", x"66", x"3C", x"18", x"00",
    -- Character 0x17
    x"63", x"63", x"6B", x"7F", x"77", x"63", x"63", x"00",
    -- Character 0x18
    x"66", x"66", x"3C", x"18", x"3C", x"66", x"66", x"00",
    -- Character 0x19
    x"66", x"66", x"66", x"3C", x"18", x"18", x"18", x"00",
    -- Character 0x1A
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"7E", x"00",
    -- Character 0x1B
    x"3C", x"30", x"30", x"30", x"30", x"30", x"3C", x"00",
    -- Character 0x1C
    x"1C", x"36", x"30", x"7C", x"30", x"30", x"7E", x"00",
    -- Character 0x1D
    x"3C", x"0C", x"0C", x"0C", x"0C", x"0C", x"3C", x"00",
    -- Character 0x1E
    x"18", x"3C", x"7E", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x1F
    x"00", x"10", x"30", x"7F", x"7F", x"30", x"10", x"00",
    -- ASCII/PETSCII punctuation, digits, uppercase letters
    x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x21
    x"18", x"18", x"18", x"18", x"00", x"18", x"00", x"00",
    -- Character 0x22
    x"66", x"66", x"00", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x23
    x"36", x"36", x"7F", x"36", x"7F", x"36", x"36", x"00",
    -- Character 0x24
    x"18", x"3E", x"60", x"3C", x"06", x"7C", x"18", x"00",
    -- Character 0x25
    x"60", x"66", x"0C", x"18", x"30", x"66", x"06", x"00",
    -- Character 0x26
    x"38", x"6C", x"38", x"76", x"DC", x"CC", x"76", x"00",
    -- Character 0x27
    x"18", x"18", x"30", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x28
    x"0C", x"18", x"30", x"30", x"30", x"18", x"0C", x"00",
    -- Character 0x29
    x"30", x"18", x"0C", x"0C", x"0C", x"18", x"30", x"00",
    -- Character 0x2A
    x"00", x"66", x"3C", x"FF", x"3C", x"66", x"00", x"00",
    -- Character 0x2B
    x"00", x"18", x"18", x"7E", x"18", x"18", x"00", x"00",
    -- Character 0x2C
    x"00", x"00", x"00", x"00", x"00", x"18", x"18", x"30",
    -- Character 0x2D
    x"00", x"00", x"00", x"7E", x"00", x"00", x"00", x"00",
    -- Character 0x2E
    x"00", x"00", x"00", x"00", x"00", x"18", x"18", x"00",
    -- Character 0x2F
    x"06", x"0C", x"18", x"30", x"60", x"C0", x"80", x"00",
    -- Character 0x30
    x"3C", x"66", x"6E", x"76", x"66", x"66", x"3C", x"00",
    -- Character 0x31
    x"18", x"38", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x32
    x"3C", x"66", x"06", x"0C", x"18", x"30", x"7E", x"00",
    -- Character 0x33
    x"3C", x"66", x"06", x"1C", x"06", x"66", x"3C", x"00",
    -- Character 0x34
    x"0C", x"1C", x"3C", x"6C", x"7E", x"0C", x"0C", x"00",
    -- Character 0x35
    x"7E", x"60", x"7C", x"06", x"06", x"66", x"3C", x"00",
    -- Character 0x36
    x"3C", x"66", x"60", x"7C", x"66", x"66", x"3C", x"00",
    -- Character 0x37
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"60", x"00",
    -- Character 0x38
    x"3C", x"66", x"66", x"3C", x"66", x"66", x"3C", x"00",
    -- Character 0x39
    x"3C", x"66", x"66", x"3E", x"06", x"66", x"3C", x"00",
    -- Character 0x3A
    x"00", x"18", x"18", x"00", x"18", x"18", x"00", x"00",
    -- Character 0x3B
    x"00", x"18", x"18", x"00", x"18", x"18", x"30", x"00",
    -- Character 0x3C
    x"0C", x"18", x"30", x"60", x"30", x"18", x"0C", x"00",
    -- Character 0x3D
    x"00", x"00", x"7E", x"00", x"7E", x"00", x"00", x"00",
    -- Character 0x3E
    x"30", x"18", x"0C", x"06", x"0C", x"18", x"30", x"00",
    -- Character 0x3F
    x"3C", x"66", x"06", x"0C", x"18", x"00", x"18", x"00",
    -- Character 0x40
    x"3C", x"66", x"6E", x"6A", x"6E", x"60", x"3E", x"00",
    -- Character 0x41
    x"3C", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x42
    x"7C", x"66", x"66", x"7C", x"66", x"66", x"7C", x"00",
    -- Character 0x43
    x"3C", x"66", x"60", x"60", x"60", x"66", x"3C", x"00",
    -- Character 0x44
    x"78", x"6C", x"66", x"66", x"66", x"6C", x"78", x"00",
    -- Character 0x45
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"7E", x"00",
    -- Character 0x46
    x"7E", x"60", x"60", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x47
    x"3C", x"66", x"60", x"6E", x"66", x"66", x"3C", x"00",
    -- Character 0x48
    x"66", x"66", x"66", x"7E", x"66", x"66", x"66", x"00",
    -- Character 0x49
    x"7E", x"18", x"18", x"18", x"18", x"18", x"7E", x"00",
    -- Character 0x4A
    x"3E", x"0C", x"0C", x"0C", x"0C", x"6C", x"38", x"00",
    -- Character 0x4B
    x"66", x"6C", x"78", x"70", x"78", x"6C", x"66", x"00",
    -- Character 0x4C
    x"60", x"60", x"60", x"60", x"60", x"60", x"7E", x"00",
    -- Character 0x4D
    x"63", x"77", x"7F", x"6B", x"63", x"63", x"63", x"00",
    -- Character 0x4E
    x"66", x"76", x"7E", x"7E", x"6E", x"66", x"66", x"00",
    -- Character 0x4F
    x"3C", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x50
    x"7C", x"66", x"66", x"7C", x"60", x"60", x"60", x"00",
    -- Character 0x51
    x"3C", x"66", x"66", x"66", x"6E", x"3C", x"06", x"00",
    -- Character 0x52
    x"7C", x"66", x"66", x"7C", x"78", x"6C", x"66", x"00",
    -- Character 0x53
    x"3E", x"60", x"60", x"3C", x"06", x"06", x"7C", x"00",
    -- Character 0x54
    x"7E", x"18", x"18", x"18", x"18", x"18", x"18", x"00",
    -- Character 0x55
    x"66", x"66", x"66", x"66", x"66", x"66", x"3C", x"00",
    -- Character 0x56
    x"66", x"66", x"66", x"66", x"66", x"3C", x"18", x"00",
    -- Character 0x57
    x"63", x"63", x"6B", x"7F", x"77", x"63", x"63", x"00",
    -- Character 0x58
    x"66", x"66", x"3C", x"18", x"3C", x"66", x"66", x"00",
    -- Character 0x59
    x"66", x"66", x"66", x"3C", x"18", x"18", x"18", x"00",
    -- Character 0x5A
    x"7E", x"06", x"0C", x"18", x"30", x"60", x"7E", x"00",
    -- Character 0x5B
    x"3C", x"30", x"30", x"30", x"30", x"30", x"3C", x"00",
    -- Character 0x5C
    x"80", x"C0", x"60", x"30", x"18", x"0C", x"06", x"00",
    -- Character 0x5D
    x"3C", x"0C", x"0C", x"0C", x"0C", x"0C", x"3C", x"00",
    -- Character 0x5E
    x"18", x"3C", x"66", x"00", x"00", x"00", x"00", x"00",
    -- Character 0x5F
    x"00", x"00", x"00", x"00", x"00", x"00", x"FF", x"00",
    -- PETSCII-style block and line graphics
    x"00", x"00", x"00", x"FF", x"FF", x"00", x"00", x"00",
    -- Character 0x61
    x"18", x"18", x"18", x"18", x"18", x"18", x"18", x"18",
    -- Character 0x62
    x"18", x"18", x"18", x"FF", x"FF", x"18", x"18", x"18",
    -- Character 0x63
    x"00", x"00", x"00", x"1F", x"1F", x"18", x"18", x"18",
    -- Character 0x64
    x"00", x"00", x"00", x"F8", x"F8", x"18", x"18", x"18",
    -- Character 0x65
    x"18", x"18", x"18", x"1F", x"1F", x"00", x"00", x"00",
    -- Character 0x66
    x"18", x"18", x"18", x"F8", x"F8", x"00", x"00", x"00",
    -- Character 0x67
    x"00", x"00", x"00", x"FF", x"FF", x"18", x"18", x"18",
    -- Character 0x68
    x"18", x"18", x"18", x"FF", x"FF", x"00", x"00", x"00",
    -- Character 0x69
    x"18", x"18", x"18", x"1F", x"1F", x"18", x"18", x"18",
    -- Character 0x6A
    x"18", x"18", x"18", x"F8", x"F8", x"18", x"18", x"18",
    -- Character 0x6B
    x"80", x"C0", x"E0", x"F0", x"78", x"3C", x"1E", x"0F",
    -- Character 0x6C
    x"01", x"03", x"07", x"0F", x"1E", x"3C", x"78", x"F0",
    -- Character 0x6D
    x"AA", x"55", x"AA", x"55", x"AA", x"55", x"AA", x"55",
    -- Character 0x6E
    x"CC", x"CC", x"33", x"33", x"CC", x"CC", x"33", x"33",
    -- Character 0x6F
    x"F0", x"F0", x"F0", x"F0", x"0F", x"0F", x"0F", x"0F",
    -- Character 0x70
    x"F0", x"F0", x"F0", x"F0", x"F0", x"F0", x"F0", x"F0",
    -- Character 0x71
    x"0F", x"0F", x"0F", x"0F", x"0F", x"0F", x"0F", x"0F",
    -- Character 0x72
    x"FF", x"FF", x"FF", x"FF", x"00", x"00", x"00", x"00",
    -- Character 0x73
    x"00", x"00", x"00", x"00", x"FF", x"FF", x"FF", x"FF",
    -- Character 0x74
    x"F0", x"F0", x"F0", x"F0", x"00", x"00", x"00", x"00",
    -- Character 0x75
    x"0F", x"0F", x"0F", x"0F", x"00", x"00", x"00", x"00",
    -- Character 0x76
    x"00", x"00", x"00", x"00", x"F0", x"F0", x"F0", x"F0",
    -- Character 0x77
    x"00", x"00", x"00", x"00", x"0F", x"0F", x"0F", x"0F",
    -- Character 0x78
    x"81", x"42", x"24", x"18", x"18", x"24", x"42", x"81",
    -- Character 0x79
    x"18", x"3C", x"7E", x"FF", x"FF", x"7E", x"3C", x"18",
    -- Character 0x7A
    x"18", x"3C", x"7E", x"DB", x"FF", x"24", x"5A", x"A5",
    -- Character 0x7B
    x"00", x"3C", x"7E", x"7E", x"7E", x"7E", x"3C", x"00",
    -- Character 0x7C
    x"18", x"3C", x"7E", x"18", x"18", x"7E", x"3C", x"18",
    -- Character 0x7D
    x"18", x"18", x"18", x"FF", x"FF", x"18", x"18", x"18",
    -- Character 0x7E
    x"76", x"DC", x"00", x"76", x"DC", x"00", x"00", x"00",
    -- Character 0x7F
    x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF"
  );

begin
  dout <= rom(to_integer(unsigned(addr)));
end architecture;
