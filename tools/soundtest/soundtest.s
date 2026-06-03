; ============================================================
; soundtest.s  --  Standalone 4-Voice Sound-Chip Showcase ROM
; 16 KB at $C000-$FFFF (includes interrupt vectors)
;
; ~60-second looping song:
;   1) Intro laser sweep (voice 3)
;   2) Ambient section A — 28-chord Am/F/C/G progression  (~29s)
;      V0=triangle lead  V1=sine pad  V2=triangle harmony  V3=sawtooth bass
;   3) SID-style square-wave arpeggio  ×2  (~10s)
;   4) Ambient section B — 16-chord Dm/Bb/Am bridge  (~17s)
;   5) SID arpeggio ×1  (~5s), then loop back to 2
;
; Waveform encoding in CONTROL register: bits [6:4] = waveform
;   0=sine  1=square  2=sawtooth  3=triangle  4=noise
; No BASIC, no tokenizer, pure 6502 machine code.
; ============================================================

; ---- Hardware -----------------------------------------------
VIC_RAM      = $8000

; Voice 0 ($8830)
V0_FLO       = $8830
V0_FHI       = $8831
V0_DLO       = $8832
V0_DHI       = $8833
V0_VOL       = $8834
V0_CTL       = $8835
V0_ATK       = $8836
V0_DEC       = $8837
V0_SUS       = $8838
V0_REL       = $8839

; Voice 1 ($8890)
V1_FLO       = $8890
V1_FHI       = $8891
V1_DLO       = $8892
V1_DHI       = $8893
V1_VOL       = $8894
V1_CTL       = $8895
V1_ATK       = $8896
V1_DEC       = $8897
V1_SUS       = $8898
V1_REL       = $8899

; Voice 2 ($889A)
V2_FLO       = $889A
V2_FHI       = $889B
V2_DLO       = $889C
V2_DHI       = $889D
V2_VOL       = $889E
V2_CTL       = $889F
V2_ATK       = $88A0
V2_DEC       = $88A1
V2_SUS       = $88A2
V2_REL       = $88A3

; Voice 3 ($88A4)
V3_FLO       = $88A4
V3_FHI       = $88A5
V3_DLO       = $88A6
V3_DHI       = $88A7
V3_VOL       = $88A8
V3_CTL       = $88A9
V3_ATK       = $88AA
V3_DEC       = $88AB
V3_SUS       = $88AC
V3_REL       = $88AD

; ---- Zero page ----------------------------------------------
ptr_lo       = $00
ptr_hi       = $01
dly_cnt      = $02
sweep_lo     = $03
sweep_hi     = $04
sweep_cnt    = $05    ; loop counter for intro_sweep (X is clobbered by delay)

; ============================================================
.segment "CODE"

; ---- Reset entry point --------------------------------------
.proc reset
    SEI
    CLD
    LDX #$FF
    TXS

    LDX #0
print_loop:
    LDA title_str, X
    BEQ print_done
    STA VIC_RAM, X
    INX
    CPX #40
    BNE print_loop
print_done:

    JSR setup_patches
    JSR intro_sweep         ; laser sweep intro (once at startup)

forever:
    JSR play_poly_showcase  ; ambient A: 28 chords ~29s
    JSR play_hyper_arp      ; SID arp phrase 1    ~5s
    JSR play_hyper_arp      ; SID arp phrase 2    ~5s
    JSR play_ambient_bridge ; ambient B: 16 chords ~17s
    JSR play_hyper_arp      ; SID arp phrase 3    ~5s
    JMP forever             ; total loop ~61s
.endproc

; ============================================================
; setup_patches -- distinct timbre per voice
; ============================================================
.proc setup_patches
    ; Voice 0: lead
    LDA #220
    STA V0_VOL
    LDA #2
    STA V0_ATK
    LDA #3
    STA V0_DEC
    LDA #150
    STA V0_SUS
    LDA #6
    STA V0_REL

    ; Voice 1: wide pad
    LDA #185
    STA V1_VOL
    LDA #8
    STA V1_ATK
    LDA #10
    STA V1_DEC
    LDA #190
    STA V1_SUS
    LDA #14
    STA V1_REL

    ; Voice 2: bright pluck
    LDA #180
    STA V2_VOL
    LDA #0
    STA V2_ATK
    LDA #2
    STA V2_DEC
    LDA #90
    STA V2_SUS
    LDA #3
    STA V2_REL

    ; Voice 3: bass / FX
    LDA #255
    STA V3_VOL
    LDA #0
    STA V3_ATK
    LDA #2
    STA V3_DEC
    LDA #120
    STA V3_SUS
    LDA #6
    STA V3_REL
    RTS
.endproc

; ============================================================
; intro_sweep -- rising + falling laser sweep on voice 3
; ============================================================
.proc intro_sweep
    LDA #120
    STA sweep_lo
    LDA #0
    STA sweep_hi

    LDA #24
    STA sweep_cnt
sweep_up:
    LDA sweep_lo
    STA V3_FLO
    LDA sweep_hi
    STA V3_FHI
    LDA #60
    STA V3_DLO
    LDA #0
    STA V3_DHI
    LDA #1
    STA V3_CTL
    LDA #2
    JSR delay_25ms_units    ; clobbers X — use sweep_cnt instead

    CLC
    LDA sweep_lo
    ADC #18
    STA sweep_lo
    LDA sweep_hi
    ADC #0
    STA sweep_hi
    DEC sweep_cnt
    BNE sweep_up

    LDA #24
    STA sweep_cnt
sweep_down:
    LDA sweep_lo
    STA V3_FLO
    LDA sweep_hi
    STA V3_FHI
    LDA #60
    STA V3_DLO
    LDA #0
    STA V3_DHI
    LDA #1
    STA V3_CTL
    LDA #2
    JSR delay_25ms_units

    SEC
    LDA sweep_lo
    SBC #14
    STA sweep_lo
    LDA sweep_hi
    SBC #0
    STA sweep_hi
    DEC sweep_cnt
    BNE sweep_down
    RTS
.endproc
; ============================================================
; ambient_play_engine
; Shared 4-voice ambient playback loop.
; On entry: ptr_lo/ptr_hi must point to an 11-byte-per-entry
; table (V0FL,V0FH, V1FL,V1FH, V2FL,V2FH, V3FL,V3FH,
;          DLO,DHI, WAIT), terminated by a 0 first byte.
; Waveforms: V0/V2=triangle($31) V1=sine($01) V3=sawtooth($21)
; ============================================================
.proc ambient_play_engine
    LDY #0
amb_next:
    LDA (ptr_lo), Y
    BEQ amb_done
    STA V0_FLO
    INY
    LDA (ptr_lo), Y
    STA V0_FHI
    INY

    LDA (ptr_lo), Y
    STA V1_FLO
    INY
    LDA (ptr_lo), Y
    STA V1_FHI
    INY

    LDA (ptr_lo), Y
    STA V2_FLO
    INY
    LDA (ptr_lo), Y
    STA V2_FHI
    INY

    LDA (ptr_lo), Y
    STA V3_FLO
    INY
    LDA (ptr_lo), Y
    STA V3_FHI
    INY

    LDA (ptr_lo), Y
    STA V0_DLO
    STA V1_DLO
    STA V2_DLO
    STA V3_DLO
    INY

    LDA (ptr_lo), Y
    STA V0_DHI
    STA V1_DHI
    STA V2_DHI
    STA V3_DHI
    INY

    LDA (ptr_lo), Y
    PHA

    LDA #$31            ; triangle (3<<4) | trigger
    STA V0_CTL
    LDA #$01            ; sine     (0<<4) | trigger
    STA V1_CTL
    LDA #$31            ; triangle
    STA V2_CTL
    LDA #$21            ; sawtooth (2<<4) | trigger
    STA V3_CTL

    CLC
    LDA ptr_lo
    ADC #11
    STA ptr_lo
    BCC amb_ptr_ok
    INC ptr_hi
amb_ptr_ok:
    PLA
    JSR delay_25ms_units
    LDY #0
    JMP amb_next
amb_done:
    RTS
.endproc

; ============================================================
; play_poly_showcase
; Section A: sets ADSR for all four ambient voices, then plays
; ambient_data (28 chords, ~29s).
; ============================================================
.proc play_poly_showcase
    ; V0: triangle lead — medium attack
    LDA #200
    STA V0_VOL
    LDA #10
    STA V0_ATK
    LDA #5
    STA V0_DEC
    LDA #200
    STA V0_SUS
    LDA #25
    STA V0_REL
    ; V1: sine pad — slow attack for lush washes
    LDA #165
    STA V1_VOL
    LDA #20
    STA V1_ATK
    LDA #8
    STA V1_DEC
    LDA #220
    STA V1_SUS
    LDA #35
    STA V1_REL
    ; V2: triangle inner harmony
    LDA #175
    STA V2_VOL
    LDA #15
    STA V2_ATK
    LDA #6
    STA V2_DEC
    LDA #210
    STA V2_SUS
    LDA #28
    STA V2_REL
    ; V3: sawtooth bass — fast attack, warm mid-decay
    LDA #230
    STA V3_VOL
    LDA #3
    STA V3_ATK
    LDA #12
    STA V3_DEC
    LDA #160
    STA V3_SUS
    LDA #18
    STA V3_REL

    LDA #<ambient_data
    STA ptr_lo
    LDA #>ambient_data
    STA ptr_hi
    JMP ambient_play_engine
.endproc

; ============================================================
; play_ambient_bridge
; Section B: plays bridge_data (16 chords, ~17s).
; ADSR already set by play_poly_showcase.
; ============================================================
.proc play_ambient_bridge
    LDA #<bridge_data
    STA ptr_lo
    LDA #>bridge_data
    STA ptr_hi
    JMP ambient_play_engine
.endproc

; ============================================================
; play_hyper_arp
; Entry = ARP_FL,ARP_FH,BASS_FL,BASS_FH,DL,DH,WAIT
; ARP uses voice 2, BASS uses voice 3
; Table terminated by first byte = 0
; ============================================================
.proc play_hyper_arp
    ; sharper transient for arp + punchy bass
    LDA #0
    STA V2_ATK
    LDA #1
    STA V2_DEC
    LDA #70
    STA V2_SUS
    LDA #2
    STA V2_REL

    LDA #0
    STA V3_ATK
    LDA #4
    STA V3_DEC
    LDA #20
    STA V3_SUS
    LDA #8
    STA V3_REL

    LDA #<arp_data
    STA ptr_lo
    LDA #>arp_data
    STA ptr_hi

    LDY #0
arp_next:
    LDA (ptr_lo), Y
    BEQ arp_done
    STA V2_FLO
    INY
    LDA (ptr_lo), Y
    STA V2_FHI
    INY

    LDA (ptr_lo), Y
    STA V3_FLO
    INY
    LDA (ptr_lo), Y
    STA V3_FHI
    INY

    LDA (ptr_lo), Y
    STA V2_DLO
    STA V3_DLO
    INY
    LDA (ptr_lo), Y
    STA V2_DHI
    STA V3_DHI
    INY

    LDA (ptr_lo), Y
    PHA

    LDA #$11            ; square (1<<4) | trigger — SID-style bright pluck
    STA V2_CTL
    STA V3_CTL

    CLC
    LDA ptr_lo
    ADC #7
    STA ptr_lo
    BCC arp_ptr_ok
    INC ptr_hi
arp_ptr_ok:

    PLA
    JSR delay_25ms_units
    LDY #0
    JMP arp_next
arp_done:

    ; restore bass to the main section shape
    LDA #2
    STA V3_DEC
    LDA #120
    STA V3_SUS
    LDA #6
    STA V3_REL
    RTS
.endproc

; ============================================================
; delay_25ms_units -- wait A * ~25ms (at 1 MHz)
; ============================================================
.proc delay_25ms_units
    STA dly_cnt
delay_outer:
    LDX #25
delay_mid:
    LDY #200
delay_inner:
    DEY
    BNE delay_inner
    DEX
    BNE delay_mid
    DEC dly_cnt
    BNE delay_outer
    RTS
.endproc

; ============================================================
; Data
; ============================================================

title_str:
    .byte "AMBIENT X4 CHIP DEMO  60s SONG", 0

; ============================================================
; ambient_data — Section A, 28 chords, ~29s
; Format: V0FL,V0FH, V1FL,V1FH, V2FL,V2FH, V3FL,V3FH, DLO,DHI,WAIT
; All notes: dur=2000ms (DLO=208,DHI=7), WAIT=40 (1s) or 50/60
; ============================================================
ambient_data:
    ; — Part 1: Gentle intro, lower register (8 chords) ——
    ; Am:  A3       E3       C3      A2
    .byte 220,0,  165,0,  131,0,  110,0,  208,7, 40
    ; F:   C4       A3       F3      F2
    .byte   5,1,  220,0,  175,0,   87,0,  208,7, 40
    ; C:   E4       G3       E3      C2
    .byte  73,1,  196,0,  165,0,   65,0,  208,7, 40
    ; G:   D4       B3       G3      G2
    .byte  37,1,  247,0,  196,0,   98,0,  208,7, 40
    ; Am:  A3       E3       C3      A2
    .byte 220,0,  165,0,  131,0,  110,0,  208,7, 40
    ; F:   C4       A3       F3      F2
    .byte   5,1,  220,0,  175,0,   87,0,  208,7, 40
    ; C:   G4       E4       C4      C2   (higher voicing)
    .byte 136,1,   73,1,    5,1,   65,0,  208,7, 40
    ; G:   D4       G3       B3      G2
    .byte  37,1,  196,0,  247,0,   98,0,  208,7, 40
    ; — Part 2: Building, mid-high register (8 chords) ——
    ; Am7: G4       E4       C4      A2
    .byte 136,1,   73,1,    5,1,  110,0,  208,7, 40
    ; Fmaj7: A4     C4       A3      F2
    .byte 184,1,    5,1,  220,0,   87,0,  208,7, 40
    ; C:   E5       G4       C4      C3
    .byte 147,2,  136,1,    5,1,  131,0,  208,7, 40
    ; G:   D5       B4       G4      G2
    .byte  75,2,  238,1,  136,1,   98,0,  208,7, 40
    ; Am7: G4       E4       C4      A2
    .byte 136,1,   73,1,    5,1,  110,0,  208,7, 40
    ; Dm:  F4       D4       A3      D2
    .byte  93,1,   37,1,  220,0,   73,0,  208,7, 40
    ; E:   E5       B4       E4      E2   (dominant tension)
    .byte 147,2,  238,1,   73,1,   82,0,  208,7, 40
    ; Am:  A4       E4       C4      A2   (resolve, slight pause)
    .byte 184,1,   73,1,    5,1,  110,0,  208,7, 50
    ; — Part 3: Peak, high register (8 chords) ——
    ; Am:  E5       C5       A4      A2
    .byte 147,2,   11,2,  184,1,  110,0,  208,7, 40
    ; F:   C6       A4       F4      F2
    .byte  23,4,  184,1,   93,1,   87,0,  208,7, 40
    ; C:   E5       C5       G4      C2
    .byte 147,2,   11,2,  136,1,   65,0,  208,7, 40
    ; G:   D5       B4       G4      G2
    .byte  75,2,  238,1,  136,1,   98,0,  208,7, 40
    ; Dm:  F5       D5       A4      D2
    .byte 186,2,   75,2,  184,1,   73,0,  208,7, 40
    ; Am:  E5       C5       A4      A2
    .byte 147,2,   11,2,  184,1,  110,0,  208,7, 40
    ; G:   D5       B4       G4      G2
    .byte  75,2,  238,1,  136,1,   98,0,  208,7, 40
    ; Am (climax): C6      A5      E5      A2
    .byte  23,4,  112,3,  147,2,  110,0,  208,7, 50
    ; — Part 4: Outro, descend (4 chords) ——
    ; Am/C: E4      A3       E3      C3
    .byte  73,1,  220,0,  165,0,  131,0,  208,7, 40
    ; F:    F4      C4       A3      F2
    .byte  93,1,    5,1,  220,0,   87,0,  208,7, 40
    ; G:    D4      G3       B3      G2
    .byte  37,1,  196,0,  247,0,   98,0,  208,7, 40
    ; Am:   A3      E3       C3      A2   (long final wait)
    .byte 220,0,  165,0,  131,0,  110,0,  208,7, 60
    .byte 0

; ============================================================
; bridge_data — Section B, 16 chords Dm/Bb/Am, ~17s
; ============================================================
bridge_data:
    ; Dm:  D5       A4       F4      D2
    .byte  75,2,  184,1,   93,1,   73,0,  208,7, 40
    ; Bb:  F5       D5       Bb4     Bb1(58Hz)
    .byte 186,2,   75,2,  210,1,   58,0,  208,7, 40
    ; Am:  C6       A4       E4      A2
    .byte  23,4,  184,1,   73,1,  110,0,  208,7, 40
    ; E7:  E5       B4       G#4     E2
    .byte 147,2,  238,1,  159,1,   82,0,  208,7, 40
    ; Dm:  F5       D5       A4      D2
    .byte 186,2,   75,2,  184,1,   73,0,  208,7, 40
    ; Gm:  D5       Bb4      G4      G2
    .byte  75,2,  210,1,  136,1,   98,0,  208,7, 40
    ; C:   E5       G4       C4      C2
    .byte 147,2,  136,1,    5,1,   65,0,  208,7, 40
    ; F:   C6       A4       F4      F2
    .byte  23,4,  184,1,   93,1,   87,0,  208,7, 40
    ; Dm:  A5       F5       D5      D2
    .byte 112,3,  186,2,   75,2,   73,0,  208,7, 40
    ; C:   G5       E5       C5      C2
    .byte  16,3,  147,2,   11,2,   65,0,  208,7, 40
    ; Bb:  F5       D5       Bb4     Bb1
    .byte 186,2,   75,2,  210,1,   58,0,  208,7, 40
    ; Am:  E5       C5       A4      A2
    .byte 147,2,   11,2,  184,1,  110,0,  208,7, 40
    ; Dm:  D5       A4       F4      D2
    .byte  75,2,  184,1,   93,1,   73,0,  208,7, 40
    ; G:   D5       B4       G4      G2
    .byte  75,2,  238,1,  136,1,   98,0,  208,7, 40
    ; Am7: G5       E5       C5      A2
    .byte  16,3,  147,2,   11,2,  110,0,  208,7, 40
    ; Am:  A4       E4       C4      A2   (long final wait)
    .byte 184,1,   73,1,    5,1,  110,0,  208,7, 60
    .byte 0

; ============================================================
; arp_data — SID square-wave arpeggio, 7 bytes per entry
; V2FL,V2FH, V3FL,V3FH, DLO,DHI, WAIT
; 4 chords × 12 notes, WAIT=4 (100ms each) → ~4.9s per pass
; ============================================================
arp_data:
    ; — Am: A4-C5-E5 (×4) with A2 bass ——
    .byte 184,1,  110,0,  80,0, 4   ; A4+A2
    .byte  11,2,  110,0,  80,0, 4   ; C5+A2
    .byte 147,2,  110,0,  80,0, 4   ; E5+A2
    .byte 184,1,  110,0,  80,0, 4
    .byte  11,2,  110,0,  80,0, 4
    .byte 147,2,  110,0,  80,0, 4
    .byte 220,3,  110,0,  80,0, 4   ; A5+A2 (octave jump)
    .byte 147,2,  110,0,  80,0, 4
    .byte  11,2,  110,0,  80,0, 4
    .byte 220,3,  110,0,  80,0, 4
    .byte 147,2,  110,0,  80,0, 4
    .byte  11,2,  110,0,  80,0, 4
    ; — C: C5-E5-G5 (×4) with C2 bass ——
    .byte  11,2,   65,0,  80,0, 4   ; C5+C2
    .byte 147,2,   65,0,  80,0, 4   ; E5+C2
    .byte  16,3,   65,0,  80,0, 4   ; G5+C2
    .byte  11,2,   65,0,  80,0, 4
    .byte 147,2,   65,0,  80,0, 4
    .byte  16,3,   65,0,  80,0, 4
    .byte  23,4,   65,0,  80,0, 4   ; C6+C2 (high octave)
    .byte  16,3,   65,0,  80,0, 4
    .byte 147,2,   65,0,  80,0, 4
    .byte  23,4,   65,0,  80,0, 4
    .byte  16,3,   65,0,  80,0, 4
    .byte 147,2,   65,0,  80,0, 4
    ; — G: G5-B5-D5 (×4) with G1 bass ——
    .byte  16,3,   49,0,  80,0, 4   ; G5+G1
    .byte 220,3,   49,0,  80,0, 4   ; B5+G1
    .byte  75,2,   49,0,  80,0, 4   ; D5+G1
    .byte  16,3,   49,0,  80,0, 4
    .byte 220,3,   49,0,  80,0, 4
    .byte  75,2,   49,0,  80,0, 4
    .byte  16,3,   49,0,  80,0, 4
    .byte 220,3,   49,0,  80,0, 4
    .byte  75,2,   49,0,  80,0, 4
    .byte  16,3,   49,0,  80,0, 4
    .byte 220,3,   49,0,  80,0, 4
    .byte  75,2,   49,0,  80,0, 4
    ; — F: F5-A4-C5 (×4) with F1 bass ——
    .byte 186,2,   44,0,  80,0, 4   ; F5+F1
    .byte 184,1,   44,0,  80,0, 4   ; A4+F1
    .byte  11,2,   44,0,  80,0, 4   ; C5+F1
    .byte 186,2,   44,0,  80,0, 4
    .byte 184,1,   44,0,  80,0, 4
    .byte  11,2,   44,0,  80,0, 4
    .byte 186,2,   44,0,  80,0, 4
    .byte 184,1,   44,0,  80,0, 4
    .byte  11,2,   44,0,  80,0, 4
    .byte 186,2,   44,0,  80,0, 4
    .byte 184,1,   44,0,  80,0, 4
    .byte  11,2,   44,0, 160,0, 8   ; hold + long wait (phrase end)
    .byte 0

; ---- NMI / IRQ stubs ----------------------------------------
.proc nmi_handler
    RTI
.endproc

.proc irq_handler
    RTI
.endproc

; ---- Interrupt vectors at $FFFA-$FFFF -----------------------
.segment "VECTORS"
    .word nmi_handler
    .word reset
    .word irq_handler
