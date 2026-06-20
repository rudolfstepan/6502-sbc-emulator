# FPGA Sound Chip

There are **two independent VHDL sound-chip versions**, both register-compatible
with the C emulator's sound chip (`src/soundchip.c`), so the same 6502 code runs
on either:

1. **Large 4-voice chip** (`sound_chip4.vhd` + `sound_voice_full.vhd`) — the full
   model: 4 voices, 5 waveforms, ADSR envelopes, note duration, and a mixer.
   **This is now wired into the Tang Primer 20K board** and drives the dock's
   **PT8211 (TM8211)** DAC. See [The Large 4-Voice Version](#the-large-4-voice-version).
2. **Bring-up single voice** (`sound_voice.vhd`) — one voice, square + noise, no
   envelope; the original minimal version, kept as a simpler alternative. The
   register-map / usage sections below apply to a single voice and are common to
   both (the 4-voice chip just has four such voices plus envelopes).

Files:

- RTL (bring-up): [`rtl/core/peripherals/sound_voice.vhd`](../rtl/core/peripherals/sound_voice.vhd) — oscillator + register file
- RTL (DAC): [`rtl/core/peripherals/pt8211_dac.vhd`](../rtl/core/peripherals/pt8211_dac.vhd) — I2S serializer for the PT8211
- RTL (large): [`rtl/core/peripherals/sound_voice_full.vhd`](../rtl/core/peripherals/sound_voice_full.vhd), [`rtl/core/peripherals/sound_chip4.vhd`](../rtl/core/peripherals/sound_chip4.vhd)
- BASIC examples: [`examples/soundtone.bas`](../../examples/soundtone.bas) (single tone), [`examples/soundtest.bas`](../../examples/soundtest.bas) (menu demo)

## Overview

| Property | Value |
| --- | --- |
| Voices | 1 (channel 0); channels 1–3 reserved in the address map, not yet in hardware |
| Waveforms | square, noise (LFSR) |
| Frequency | direct in Hz, 16-bit |
| Volume | 8-bit (0–255) |
| Output | signed 16-bit, two's complement, to PT8211 DAC |
| Sample rate | ≈47 kHz (BCK ≈1.5 MHz, 32 BCK/frame) |
| ADSR / duration | registers accepted but **not yet acted on** |

The oscillator is a 24-bit phase accumulator clocked at 27 MHz. The phase
increment is `inc = freq_hz * 2^24 / 27 MHz`, approximated in hardware as
`(freq * 159) >> 8` (error < 0.05 %). A note plays for as long as the CONTROL
gate bit is set — there is no automatic note-off yet, so software must clear the
gate to stop the tone.

## Register Map

Channel 0 occupies **`$8830`–`$8839`** (decimal `34864`–`34873`). Offsets match
`src/soundchip.h`:

| Address | Dec | Offset | Register | Function |
| --- | --- | --- | --- | --- |
| `$8830` | 34864 | +0 | FREQ_LO | Frequency low byte (Hz) |
| `$8831` | 34865 | +1 | FREQ_HI | Frequency high byte |
| `$8832` | 34866 | +2 | DUR_LO | Duration low — *accepted, unused* |
| `$8833` | 34867 | +3 | DUR_HI | Duration high — *accepted, unused* |
| `$8834` | 34868 | +4 | VOLUME | Peak amplitude 0–255 |
| `$8835` | 34869 | +5 | CONTROL | Waveform + gate (see below) |
| `$8836` | 34870 | +6 | ATTACK | *accepted, unused* |
| `$8837` | 34871 | +7 | DECAY | *accepted, unused* |
| `$8838` | 34872 | +8 | SUSTAIN | *accepted, unused* |
| `$8839` | 34873 | +9 | RELEASE | *accepted, unused* |
| `$883A` | 34874 | +10 | TIME_MS | free-running millisecond counter, low 8 bits |

`TIME_MS` is independent of CPU speed and wraps every 256 ms. Software should
subtract a saved start value from the current value; unsigned subtraction then
handles wraparound naturally for delays shorter than 256 ms.

### CONTROL register (`$8835`)

| Bits | Meaning |
| --- | --- |
| 6–4 | Waveform: `001` = square, `100` = noise (any other value → square) |
| 0 | Gate: `1` = note on, `0` = silence |

Common values: `$11` = square + gate on, `$41` = noise + gate on, `$00` = off.

The frequency is given **directly in Hz** (not as a divider). For example, 440 Hz
is `$01B8`: write `$B8` to FREQ_LO and `$01` to FREQ_HI.

## Usage

### 6502 assembly

```asm
SND     = $8830
FREQ_LO = SND+0
FREQ_HI = SND+1
VOLUME  = SND+4
CONTROL = SND+5

    LDA #$B8          ; 440 Hz = $01B8
    STA FREQ_LO
    LDA #$01
    STA FREQ_HI
    LDA #200          ; volume 0..255
    STA VOLUME
    LDA #$11          ; square + gate on
    STA CONTROL
    ; ... software delay for note length ...
    LDA #$00          ; gate off -> silence
    STA CONTROL
```

### BASIC

```basic
10 POKE 34864,184 : REM FREQ_LO (440 Hz = $01B8)
20 POKE 34865,1   : REM FREQ_HI
30 POKE 34868,255 : REM VOLUME
40 POKE 34869,17  : REM CONTROL = $11 = square + gate
50 FOR I=1 TO 500 : NEXT
60 POKE 34869,0   : REM gate off
```

See [`examples/soundtone.bas`](../../examples/soundtone.bas) for a minimal single
tone and [`examples/soundtest.bas`](../../examples/soundtest.bas) for a menu with
a scale, siren, noise burst, and a short melody. Because duration is not yet
honoured in hardware, note length is controlled by software delay loops that set
and then clear the gate bit.

## Hardware (Tang Primer 20K dock)

The synth's signed 16-bit sample is serialized to the dock's PT8211 audio DAC.
The serializer in `pt8211_dac.vhd` is a 1:1 VHDL port of Sipeed's proven Verilog
driver (`TangPrimer-20K-example/PT8211/src/pt8211_drive.v`): BCK is a
free-running ~1.5 MHz clock, a fresh sample is loaded at the start of each 16-bit
half-frame and shifted out MSB-first, and WS toggles a few BCK after the data
word (the PT8211's right-justified format).

### Pin assignment

| Signal | FPGA pin | I/O standard | Notes |
| --- | --- | --- | --- |
| `dac_bck` (BCK) | N15 | LVCMOS33 | bit clock |
| `dac_ws` (WS/LRCK) | P16 | LVCMOS33 | word/channel select |
| `dac_din` (DIN) | P15 | LVCMOS33 | serial data, MSB first |
| `pa_en` (PA_EN) | R16 | LVCMOS33 | **audio power-amp enable, held high** |

`PA_EN` (R16) **must be driven high** or the dock's headphone amplifier stays
off/floating and you hear only hiss. It is tied high in `tang20k_sbc_top.vhd`.

These pins are in Bank 1, whose VCCIO is locked to 3.3 V by other ports, so they
are constrained as `LVCMOS33`. (The standalone Sipeed demo omits `IO_TYPE` and
lets the bank default to 1.8 V — that is not possible here because the bank is
shared.)

> **Build note:** the sound sources must be listed in
> [`boards/tang_primer_20k/project/build.tcl`](../boards/tang_primer_20k/project/build.tcl).
> The PowerShell build (`make_tang20k.ps1`) drives `gw_sh build.tcl`, **not** the
> `.gprj` project file — if `sound_voice.vhd`/`pt8211_dac.vhd` are missing from
> `build.tcl`, GowinEDA synthesizes them as empty black boxes and the DAC pins
> float (noise / silence).

## Current Limitations

- Only channel 0 is implemented; `$8890`+ (channels 1–3) are reserved in the
  address map but have no hardware yet.
- Only square and noise waveforms (no sine / triangle / sawtooth).
- ADSR envelope and duration registers are captured but ignored — software must
  clear the gate bit to end a note.
- Mono only (the same sample feeds both DAC channels).

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Constant hiss, even when idle | `PA_EN` (R16) not driven high, or wrong DAC pins |
| No sound at all after a rebuild | Sound sources missing from `build.tcl`; black-box synthesis |
| `CT1136` bank VCCIO error at build | Audio pins need `IO_TYPE=LVCMOS33` (Bank 1 is 3.3 V) |
| Wrong pitch | Frequency is in Hz (16-bit); check FREQ_LO/FREQ_HI split |
| Note never stops | Clear CONTROL bit 0 (gate) in software; duration is not yet honoured |

## The Large 4-Voice Version

`sound_chip4.vhd` + `sound_voice_full.vhd` implement the **full** C-emulator
model in hardware — an independent second version alongside the bring-up voice
above. Both use the same per-voice register layout, so 6502 code is portable.

### What it adds over the bring-up voice

| Feature | Bring-up `sound_voice` | Large `sound_chip4` |
| --- | --- | --- |
| Voices | 1 | 4, mixed |
| Waveforms | square, noise | sine, square, sawtooth, triangle, noise |
| Envelope | none (gate only) | full ADSR (attack/decay/sustain/release) |
| Duration | ignored | honoured (note auto-stops) |
| Noise | 16-bit Galois LFSR | xorshift32 (same sequence as the C code) |

The CONTROL waveform field (bits 6–4) selects: `0`=sine, `1`=square,
`2`=sawtooth, `3`=triangle, `4`=noise — matching `src/soundchip.c`. Writing
CONTROL with bit 0 set captures all registers and (re)triggers the note, again
matching the emulator. ATTACK/DECAY/RELEASE are in units of 8 ms; SUSTAIN is a
0–255 level; duration is in ms; frequency in Hz (0 → 440 default, clamped
20–12000).

### Implementation notes

- **Sine** uses a hard-coded 256-entry signed LUT (`SINE`), indexed by the top 8
  phase bits — no `math_real` needed at synthesis except for the phase-increment
  constant `PHASE_MUL = 2^PHASE_BITS·256 / CLK_HZ` (159 at 27 MHz).
- **Envelope** is time-based (mirrors `envelope_at()` in the C code): a 1 ms time
  base drives a small ATK/DEC/SUS/REL state machine, and each ramp uses a
  division-free Bresenham accumulator (≤1 envelope step per clock).
- **Mixer** sums the four signed voices; each voice is pre-scaled by `>>10`
  (volume/255 · env/255 · 0.25 headroom), so four max-volume voices sum without
  clipping. A hard clip guards corner cases.
- **Interface**: `cs(3:0)` (one chip-select per voice), shared `we`/`addr(3:0)`/
  `din`, muxed `dout`, signed 16-bit `sample_out`, and `active`.

### Status

Verified in simulation by [`sim/tb/tb_sound_chip4.vhd`](../sim/tb/tb_sound_chip4.vhd)
(envelope attack, waveform swing, multi-voice mix, duration auto-stop) and **wired
into the Tang Primer 20K board** in `sbc_t65_boot_monitor_top.vhd`, replacing the
bring-up `sound_voice`. The four voices are selected by `DEV_SOUND0..3`
(`$8830`, `$8890`, `$889A`, `$88A4`); because those bases are not all 16-aligned,
the top computes each voice's register offset as `cpu_addr - base`. The mixed
`sample_out` feeds `pt8211_dac`. Build sources are listed in
`boards/tang_primer_20k/project/build.tcl` and `tang_sbc.gprj`.

### Demo ROM (`soundtest.rom`)

[`fpga/sw/soundtest.s`](../sw/soundtest.s) is a standalone 6502 demo ROM that
exercises all four voices — each waveform on voice 0, an ADSR swell, and a
4-voice chord — and writes a "SOUND TEST" title to the HDMI text screen. It
builds to a 16 KB image (`$C000-$FFFF`) and uploads through the UART monitor
exactly like the EhBASIC ROM:

```sh
make -C fpga/sw soundtest          # -> fpga/sw/soundtest.rom (16 KB)

# board in monitor mode (press KEY0), then:
python fpga/tools/upload_monitor_hex.py fpga/sw/soundtest.rom \
       --port COM15 --baud 230400 --address 0xC000 --run --verbose
# or, build + upload in one step:
make -C fpga/sw upload-soundtest
```

The ROM's reset vector points at `$C000`, so it also runs from a cold boot if
written to the SD card (wrap it with `fpga/tools/make_sd_boot_image.py`).

## See Also

- [Architecture](./01_ARCHITECTURE.md) — memory map
- [Modules Reference](./02_MODULES.md) — `sound_voice.vhd`, `pt8211_dac.vhd`
- [Tang Primer 20K Guide](../boards/tang_primer_20k/README.md) — board wiring
- `src/soundchip.c` / `src/soundchip.h` — reference C implementation
</content>
