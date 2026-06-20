# SID → sound_chip4 converter

Converts a C64 PSID tune into a 6502 player ROM that plays an excerpt on the
FPGA's 4-voice sound chip (`sound_chip4`).

## Why it's an approximation

A SID file is 6502 player code that drives the MOS 6581 SID chip. The SID and
our chip differ fundamentally:

| | SID (6581) | our `sound_chip4` |
|---|---|---|
| Voices | 3 | 4 |
| Note model | gate (held) | trigger + duration |
| Pitch | live, per frame | live (after the `sound_voice_full` update) |
| Extras | pulse width, filter, ring-mod, sync | none |

So the converter reproduces **pitch contour (vibrato/slides), waveform, ADSR and
note length**, but drops filter / pulse-width / ring-mod. Drums become noise
hits. Only a short excerpt is converted (a full 50 Hz register stream for a
multi-minute tune would be ~150–200 KB — far larger than the 16 KB ROM).

## Pipeline

```sh
# 1. build the SID register extractor (uses the project's 6502 core)
gcc -O2 -I src tools/sid_convert/siddump.c src/cpu6502.c src/disasm.c \
    -o tools/sid_convert/siddump.exe

# 2. dump ~58 s of SID register frames (50 Hz) to a raw blob
#    (~58 s is about the most that fits in the 16 KB ROM after compression)
tools/sid_convert/siddump.exe sid_demo/World_Record_2.sid 58 \
    --raw tools/sid_convert/wr2.raw

# 3. convert the frames into a player ROM source (live-freq stream + note events)
python tools/sid_convert/convert_sid.py tools/sid_convert/wr2.raw \
    fpga/sw/soundsid.s 200          # last arg = frame-delay tuning (tempo)

# 4. assemble the 16 KB ROM
make -C fpga/sw soundsid

# 5. upload + run via the UART monitor (board in monitor mode: press KEY0)
make -C fpga/sw upload-soundsid
#   or: python fpga/tools/upload_monitor_hex.py fpga/sw/soundsid.rom \
#            --port COM15 --baud 230400 --address 0xC000 --run --verbose
```

The player triggers a note on each SID gate-on (note length = the gate-high
span) and applies **frequency changes** as they happen so vibrato/slides/
arpeggios track. The frequency stream is compressed — only stored when the SID
frequency actually changes — so held notes cost nothing and ~55-60 s of music
fits in the 16 KB shadow ROM. It loops the excerpt forever.

> Note: a true >16 KB ("32 KB") player would have to run from main RAM at
> `$0200`, but the monitor's `G 0200` reset/vector path lands in EhBASIC on this
> board, so the reliable path is the 16 KB ROM at `$C000` (`G C000`). The
> frequency-change compression is what makes ~58 s fit there.

## Tuning

- **Tempo**: the player paces frames with a calibrated delay loop. Adjust the
  last `convert_sid.py` argument (default 200) — larger = slower.
- **Length**: change the seconds in step 2.
- Requires the **4-voice bitstream** (with the live-frequency `sound_voice_full`)
  running on the board.

## Files

| File | Role |
|---|---|
| `siddump.c` | runs the PSID player on the C 6502 core, dumps SID regs/frame |
| `convert_sid.py` | frames → `soundsid.s` (player + data) |
| `fpga/sw/soundsid.s` / `.rom` | generated player + 16 KB ROM image |
