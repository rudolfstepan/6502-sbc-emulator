; ============================================================================
;  Blitter datapath diagnostic (runs on the flashed bitstream, no re-synth).
;
;  Does three blitter ops separated by fixed vblank waits -- NO busy polling --
;  so it isolates the engine/datapath from the busy-readback CDC:
;    1. FILL the whole screen blue
;    2. FILL a red rectangle in the middle
;    3. draw a white diagonal line
;
;  What you should see (each stage ~1.5 s apart):
;    * blue screen        -> FILL + colour + engine + app-port write all work
;    * red rectangle      -> a second op works (rect FILL)
;    * white diagonal line-> LINE works
;  If all three appear, the datapath is fine and the cube's problem is the
;  busy-poll race (fixed in RTL). If the screen stays black, the datapath itself
;  needs looking at.
; ============================================================================
.import __LOADADDR__
.segment "EXEHDR"
    .word __LOADADDR__

VIC_MODE = $9000
VIC_ISR  = $9007
VIC_PAGE = $900F
.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs
    lda #$20
    sta VIC_MODE            ; 640x400 hi-res
    lda #$00
    sta VIC_PAGE            ; page 0

    ; 1) FILL whole screen blue ($03)
    jsr set_full
    lda #$03
    sta $8848               ; colour = blue
    lda #$00
    sta $8849               ; OP = FILL
    lda #$00
    sta $884A               ; page 0
    sta $884F               ; trigger
    jsr wait_frames

    ; 2) FILL red rectangle (200,120)-(440,280)
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
    sta $8848               ; colour = red
    lda #$00
    sta $8849               ; OP = FILL
    lda #$00
    sta $884A
    sta $884F
    jsr wait_frames

    ; 3) white diagonal line (0,0)-(639,399)
    lda #$00
    sta $8840
    sta $8841
    sta $8842
    sta $8843
    lda #<639
    sta $8844
    lda #>639
    sta $8845
    lda #<399
    sta $8846
    lda #>399
    sta $8847
    lda #$FF
    sta $8848               ; colour = white
    lda #$03
    sta $8849               ; OP = LINE
    lda #$00
    sta $884A
    sta $884F
    jsr wait_frames

hang:
    jmp hang

; set blit endpoints to the whole 640x400 screen
set_full:
    lda #$00
    sta $8840
    sta $8841
    sta $8842
    sta $8843
    lda #<639
    sta $8844
    lda #>639
    sta $8845
    lda #<399
    sta $8846
    lda #>399
    sta $8847
    rts

; wait ~90 vblank frames (~1.5 s) using the VIC frame flag (bit1 of $9007)
wait_frames:
    ldx #90
@f:
    lda #$02
    sta VIC_ISR             ; clear frame flag
@w:
    lda VIC_ISR
    and #$02
    beq @w                  ; wait for next frame
    dex
    bne @f
    rts
