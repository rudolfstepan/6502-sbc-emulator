# Third-Party Components

This repository includes integrations/adaptations based on external upstream projects.

## Microsoft BASIC (mist64/msbasic)

- Upstream: https://github.com/mist64/msbasic
- License signal from upstream README: 2-clause BSD
- Local usage: build helpers and SBC6502-specific port files produce `roms/msbasic.rom`.

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

## NES profile

- The optional [FCEUmm core](https://github.com/libretro/libretro-fceumm) is
  installed separately. Its upstream repository provides the source and license.
- `third_party/libretro/libretro.h` is the upstream MIT-licensed Libretro API
  header from [libretro-common](https://github.com/libretro/libretro-common).
- `third_party/miniz/` contains the amalgamated Miniz 3.1.2 source for ZIP
  loading and its license from the [upstream release](https://github.com/richgel999/miniz/releases/tag/3.1.2).

## Practical Summary

- Publishing generated ROM artifacts is generally feasible when upstream attribution and license obligations are kept.
- Verify third-party license terms before redistribution in binary form.
