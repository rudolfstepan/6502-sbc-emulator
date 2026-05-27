with open('roms/ehbasic.rom', 'rb') as f:
    data = f.read()

def find_keywords(data):
    # Try searching for all possible combinations of 'DATA'
    # D A T (A|0x80)
    target = bytes([ord('D'), ord('A'), ord('T'), ord('A') | 0x80])
    offset = data.find(target)
    if offset != -1:
        print(f"Found keyword sequence at {hex(offset)}")
        # Try to extract the whole table
        j = offset - 10 # Go back to start of table (END)
        # Search backwards for a 0 or start of keywords
        pass
    else:
        print("Sequence not found")

find_keywords(data)
