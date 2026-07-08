; ============================================================================
;  Blitter write-path probe (runs on the flashed bitstream, no re-synth).
;
;  Answers ONE question: does the hardware blitter actually write the DDR3
;  framebuffer at all?  It is independent of the display and of the busy poll.
;
;    1. CPU-write pixel (0,0) = $11 through the $6000 window (this path is known
;       to work -- the old software cube used it).
;    2. Trigger a blitter FILL of pixel (0,0) with $E0, wait a few frames.
;    3. CPU-read pixel (0,0) back.
;    4. Switch to text mode and fill the screen with:
;         green 'Y'  -> read back $E0  => the blitter DID write DDR3
;         red   'N'  -> read back != $E0 => the blitter did NOT write
;
;  Result 'Y' -> datapath writes DDR3; the black screen is a display/read issue.
;  Result 'N' -> the register/trigger/engine/app-write chain is broken.
; ============================================================================
.import __LOADADDR__
.segment "EXEHDR"
    .word __LOADADDR__
.segment "CODE"

start:
    sei
    cld
    ldx #$ff
    txs

    lda #$20
    sta $9000              ; hi-res 640x400
    lda #$00
    sta $900F              ; page 0
    sta $9006              ; framebuffer bank 0

    ; 1) CPU-write pixel (0,0) = $11 via the $6000 window (bank 0, offset 0)
    lda #$11
    sta $6000

    ; 2) blitter FILL pixel (0,0)-(0,0) with $E0
    lda #$00
    sta $8840              ; x0 lo
    sta $8841              ; x0 hi
    sta $8842              ; y0 lo
    sta $8843              ; y0 hi
    sta $8844              ; x1 lo
    sta $8845              ; x1 hi
    sta $8846              ; y1 lo
    sta $8847              ; y1 hi
    lda #$E0
    sta $8848              ; colour
    lda #$00
    sta $8849              ; OP = FILL
    lda #$00
    sta $884A              ; page 0
    sta $884F              ; trigger

    ; wait ~30 vblank frames (no busy poll) for the blit to complete
    ldx #30
@f:
    lda #$02
    sta $9007
@w:
    lda $9007
    and #$02
    beq @w
    dex
    bne @f

    ; 3) read pixel (0,0) back from DDR3
    lda $6000
    cmp #$E0
    beq @yes

    ; 'N' in red -> blitter did not write
    lda #$02
    sta $9003              ; fg = red
    lda #$4E               ; 'N'
    jmp @show
@yes:
    lda #$05
    sta $9003              ; fg = green
    lda #$59               ; 'Y'
@show:
    sta $70                ; save the character
    lda #$00
    sta $9005              ; global colour (not per-cell)
    sta $9004              ; bg = black
    sta $9000              ; text mode

    ; fill the visible text screen ($8000-$83FF) with the character
    ldx #$00
@fill:
    lda $70
    sta $8000,x
    sta $8100,x
    sta $8200,x
    sta $8300,x
    inx
    bne @fill

hang:
    jmp hang
