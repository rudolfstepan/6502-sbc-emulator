# Cave Adventure

A simple text adventure game for the 6502 SBC emulator.

## How to Play

### Build
```bash
cd tools/adventure
make
```

### Run
```bash
cd /home/rudolf/repos/6502
./bin/sbc6502 -c adventure.ini
```

## Gameplay

### Goal
Find the treasure and unlock the chest!

### Controls
- **N/S/E/W** - Move North/South/East/West
- **L** - Look (redraw current room)
- **I** - Show inventory
- **T** - Take item in current room
- **U** - Use item (only works with key at treasure)
- **Q** - Quit game

### Walkthrough
1. Start in Forest Clearing
2. Go **N** to Dark Forest
3. **T** to take the Torch
4. Go **E** to Cave Entrance
5. **T** to take the Key
6. Go **E** to Treasure Chamber (needs torch!)
7. **U** to use the Key and unlock the chest
8. **YOU WIN!**

## Map
```
    Forest Clearing
          |
    Dark Forest
          |
    Cave Entrance -(dark)-> Treasure Chamber
                                (locked chest)
```

## Items
- **Torch** - Found in Dark Forest. Needed to enter Treasure Chamber.
- **Key** - Found in Cave. Needed to open the treasure chest.
- **Gold** - In the treasure chest (win condition).

## Technical Details
- ROM Size: 16KB at $C000-$FFFF
- Zero Page Variables: 15 bytes
- Max Inventory: 4 items
- Rooms: 4 locations
- VIC Text Mode: 40x25 characters
