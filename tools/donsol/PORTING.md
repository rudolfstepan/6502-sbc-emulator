# Donsol SBC Port - Status and Plan

## Overview
This is a port of the [Donsol](https://github.com/hundredrabbits/Donsol) roguelike card game from NES to the 6502 SBC Emulator. The original is written in 6502 assembly but designed for NES hardware.

## Current Status: **Foundation Layer (WIP)**

### Completed
- ✅ SBC memory map and hardware constants (`sbc_head.asm`)
- ✅ Basic keyboard input stubs (`sbc_input.asm`)
- ✅ Basic text-mode video output stubs (`sbc_video.asm`)
- ✅ Main loop structure (`donsol_sbc.asm`)
- ✅ Project scaffold (Makefile, linker config)
- ✅ Game state zero-page layout (adapted from NES version)

### In Progress
- 🔄 Keyboard matrix scanning (need SBC keyboard protocol details)
- 🔄 Text-mode rendering routines
- 🔄 Game logic module adaptation

### Not Started
- ❌ Integrating original Donsol game modules (deck, player, room, game, splash, dialog)
- ❌ Sound chip interface (SBC audio)
- ❌ Saving/loading game state
- ❌ Difficulty balancing for text-mode display

## Key Differences from NES Version

### Hardware Layer Replacements

| NES | SBC |
|-----|-----|
| PPU ($2000-$2007) | VIC text/bitmap mode |
| Sprite OAM ($4014) | Text characters |
| Joypad ($4016) | VIA keyboard matrix |
| NMI interrupt | Main loop polling |
| CHR-ROM tiles | ASCII/custom glyphs |

### Software Architecture

**NES Donsol:**
- Rendering driven by NMI (60 FPS vertical blank)
- Separate joypad read in NMI (`nmi.asm`)
- Main loop processes input flags set by NMI
- PPU nametable updates during play

**SBC Donsol:**
- Rendering driven by main loop
- Keyboard polling in main loop (`readJoy_sbc`)
- Same button input abstraction (BUTTON_A, BUTTON_B, etc.)
- Screen updates via text mode writes

## File Structure

```
tools/donsol/
├── donsol_sbc.asm         # Main loop and entry point
├── sbc_head.asm           # Hardware constants and memory map
├── sbc_input.asm          # Keyboard input handler
├── sbc_video.asm          # Text-mode rendering
├── sbc_donsol.cfg         # Linker configuration
├── Makefile               # Build script
└── src/                   # Downloaded Donsol original source
    ├── src/
    │   ├── deck.asm       # Deck shuffling logic (to integrate)
    │   ├── player.asm     # Player stats (to integrate)
    │   ├── room.asm       # Encounter logic (to integrate)
    │   ├── game.asm       # Main game state (to integrate)
    │   ├── splash.asm     # Title/menu (to adapt)
    │   ├── dialog.asm     # Dialog text (to adapt)
    │   └── ...
```

## Integration Checklist

### Phase 1: Core Game Logic
- [ ] Copy `deck.asm` (modify for text output)
- [ ] Copy `player.asm` (should be mostly portable)
- [ ] Copy `room.asm` (modify rendering calls)
- [ ] Copy `game.asm` (modify rendering calls)
- [ ] Copy `dialog.asm` (convert sprite positions to text positions)

### Phase 2: Rendering
- [ ] Implement text-mode card display
- [ ] Implement text-mode HP/SP/XP bars
- [ ] Implement text-mode menu cursor
- [ ] Test splash screen

### Phase 3: Input
- [ ] Implement full VIA keyboard matrix scanning
- [ ] Map keyboard keys to game buttons
- [ ] Test input responsiveness

### Phase 4: Polish
- [ ] Add visual feedback (colors, cursor movement)
- [ ] Optimize screen updates (only redraw changed parts)
- [ ] Add game balance for text mode (if needed)

## Next Steps

1. **Keyboard Implementation**: Determine exact VIA keyboard protocol for your SBC and implement proper matrix scanning in `sbc_input.asm`.

2. **Game Logic Integration**: Copy the core game modules from the original Donsol and modify only the rendering calls.

3. **Screen Layout**: Design a text-mode layout for Donsol's UI:
   ```
   DONSOL - STATUS
   ================
   HP: [3/3]  SP: [0/0]  XP: [0/100]
   
   [CARD1] [CARD2] [CARD3] [CARD4]
    [A]     [B]     [C]     [D]
   
   > START  DIFFICULTY  QUIT
   ```

4. **Testing**: Build and test incrementally with `make` command.

## Building

```bash
cd tools/donsol
make              # Build donsol.rom in build/
make clean        # Clean build artifacts
```

## Compatibility Notes

- **Memory**: Uses $8000-$FFFF for ROM (32KB available)
- **Zero Page**: $0000-$00FF for game state (same layout as NES version)
- **Video**: Text mode 40x25 characters
- **Input**: 8-direction keyboard + 3 action buttons
- **No audio** for now (can be added later via SBC sound chip)

## References

- Original Donsol: https://github.com/hundredrabbits/Donsol
- NES Donsol source analysis available in project history
- SBC Emulator capabilities: See parent directory docs
