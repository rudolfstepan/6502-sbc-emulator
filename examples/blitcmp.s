; ============================================================================
;  Blitter vs CPU visual comparison (runs on the flashed bitstream, no re-synth,
;  stays in hi-res the whole time).
;
;    * CONTROL: fill framebuffer bank 0 ($6000-$7FFF) white via CPU byte writes
;               -> a white band across the top ~12 rows. This is the path the old
;               software cube used, so it proves display + CPU + DDR3 work.
;    * TEST:    blitter FILL a red rectangle in the middle.
;
;  What you see tells us exactly where the problem is:
;    white band + red rectangle -> CPU works AND blitter works
;    white band, NO red rectangle -> display+CPU work, blitter is broken
;    nothing (black)             -> even the CPU/display path is broken now
; ============================================================================
.import __LOADADDR__
.segment "EXEHDR"
    .word __LOADADDR__

PTR = $00                      ; zero-page pointer for the CPU fill
.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs

    lda #$20
    sta $9000                  ; hi-res 640x400
    lda #$00
    sta $900F                  ; page 0
    sta $9006                  ; framebuffer bank 0

    ; --- CONTROL: fill bank 0 ($6000-$7FFF) white via CPU writes ---
    lda #$00
    sta PTR
    lda #$60
    sta PTR+1
    ldx #$20                   ; 32 pages = 8192 bytes = ~12 rows
    ldy #$00
@page:
    lda #$FF
@byte:
    sta (PTR),y
    iny
    bne @byte
    inc PTR+1
    dex
    bne @page

    ; --- TEST: blitter FILL red rectangle (200,120)-(440,280) ---
    lda #<200
    sta $8840
    lda #>200
    sta $8841
    lda #<120
    sta $8842
    lda #>120
    sta $8843
    lda #<440
    sta $8844
    lda #>440
    sta $8845
    lda #<280
    sta $8846
    lda #>280
    sta $8847
    lda #$E0
    sta $8848                  ; colour = red
    lda #$00
    sta $8849                  ; OP = FILL
    lda #$00
    sta $884A                  ; page 0
    sta $884F                  ; trigger (blit runs in hardware, async)

hang:
    jmp hang
