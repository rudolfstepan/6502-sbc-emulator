# Third-Party Components

This repository includes integrations/adaptations based on external upstream projects.

## ROMs and distribution

- **Original game and system ROMs.** Users provide these locally. This includes
  NES and Famicom cartridges, the Famicom Disk System BIOS, and the C64 BASIC,
  KERNAL and character ROMs. A local build can stage user-supplied C64 ROMs in
  `bin/roms/c64/`. Assemble public packages from a clean staging directory and
  exclude the local ROM collection.
- **Self-developed ROMs.** Publish them only when you hold all required
  redistribution rights. Account for embedded music, artwork, data and code.
  A port or a generated ROM also requires the applicable permission and
  notices for its upstream material.
- **External dependencies.** Record the version and license of each library,
  runtime DLL, imported file and bundled asset. Include the applicable license
  texts, copyright notices and any corresponding source required by those terms
  with the published artifact.

## Microsoft BASIC (mist64/msbasic)

- Upstream: https://github.com/mist64/msbasic
- License signal from upstream README: 2-clause BSD
- Local usage: build helpers and SBC6502-specific port files produce `roms/msbasic.rom`.

Recommended publication practice:
- Keep attribution to upstream project and authors.
- Include a note that the ROM was generated from `mist64/msbasic`.
- Include or link upstream license text/reference from the upstream README.

## 6502 Chess (maksimKorzh/6502-chess)

- The adaptation in `tools/chess/chess.s` records MIT as its license signal
  for the upstream code. Confirm the terms and required notices for the exact
  upstream revision used before redistributing the adapted ROM.
  [6502 Chess upstream](https://github.com/maksimKorzh/6502-chess)

## EhBASIC

- The build script assembles `roms/ehbasic.rom` from the EhBASIC 2.22 source
  and project-specific patches. Verify redistribution rights and preserve
  the notices for the exact upstream source used.
  [EhBASIC source used by the builder](https://github.com/Klaus2m5/6502_EhBASIC_V2.22)

## NES profile

- FCEUmm is distributed under the GNU GPL, version 2 as documented upstream.
  The unmodified reference core and
  the adapted core are installed locally under distinct names. `tools/fceumm_sbc/`
  builds the adapted library from a pinned FCEUmm snapshot and the project's
  2A03 instruction executor. [FCEUmm GPL text](https://github.com/libretro/libretro-fceumm/blob/master/Copying)
- When publishing the adapted library, distribute the derived work under the
  applicable GPL terms. Preserve copyright and license notices and record
  which upstream files were changed and when. Provide the complete corresponding
  source alongside the binary at the same download location for an online
  release. Include the exact FCEUmm revision, all integration changes, the adapter,
  the compiled SBC CPU, bus and disassembler sources, and the build and
  installation scripts. [FCEUmm GPL, sections 1–3](https://github.com/libretro/libretro-fceumm/blob/master/Copying)
- `third_party/libretro/libretro.h` is the upstream MIT-licensed Libretro API
  header from [libretro-common](https://github.com/libretro/libretro-common).
- `third_party/miniz/` contains the amalgamated Miniz 3.1.2 source for ZIP
  loading. Include its [copyright and permission notice](../third_party/miniz/LICENSE)
  when publishing builds that incorporate it.

## SDL2 and compiler runtime libraries

- The runtime uses SDL2. Preserve its applicable notices, including the license
  for the SDL2 version supplied with Windows bundles. [SDL2 license](https://github.com/libsdl-org/SDL/blob/SDL2/LICENSE.txt)
- Windows bundles may also contain `libwinpthread-1.dll` and `libgcc_s_seh-1.dll`.
  Use the notices and redistribution terms of the exact toolchain packages
  that provided those binaries.
