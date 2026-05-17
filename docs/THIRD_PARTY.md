# Third-Party Components

This project can generate and run ROM images from external upstream sources.

## Microsoft BASIC (mist64/msbasic)

- Upstream: https://github.com/mist64/msbasic
- License signal from upstream README: 2-clause BSD
- Local usage: build helper script and target-specific port files in this repository produce `roms/msbasic.rom`.

Recommended publication practice:
- Keep attribution to upstream project and authors.
- Include a note that the ROM was generated from `mist64/msbasic`.
- Include or link upstream license text/reference from the upstream README.

## 6502 Chess (maksimKorzh/6502-chess)

- Upstream: https://github.com/maksimKorzh/6502-chess
- License signal from upstream repository: MIT
- Local usage: adapted standalone ROM source in `tools/chess/chess.s` produces `roms/chess.rom`.

Recommended publication practice:
- Keep attribution to upstream project and author.
- Preserve the MIT license notice/reference for the adapted chess ROM source.

## Practical Summary

- Publishing MS BASIC integration is generally feasible with attribution.
- WozMon artifacts are intentionally not distributed in this repository.
