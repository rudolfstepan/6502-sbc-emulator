;============================================================
; PIX16 SDRAM Write Path Diagnostic  v1.1
;
; Stand-alone ROM — no kernel dependency.
; Tests whether CPU->SDRAM writes reliably round-trip on the
; PIX16 FPGA (Spartan-6, T65 NMOS Mode="00", 50 MHz no-PLL).
;
; OUTPUT: mirrored to BOTH the VGA text screen (VIC VRAM
;         $8000, 40x25) AND the UART ($8810).  Every char
;         goes through 'cout' which writes the VIC screen and
;         transmits on the UART.
;
; CONFIRMED bug (v1.0 run): CPU->SDRAM writes using ABSOLUTE-
; INDEXED addressing (STA abs,X) are dropped, while plain
; ABSOLUTE writes (STA abs) succeed.  Cause: STA abs,X does a
; dummy READ one CPU cycle before the WRITE.  That read leaves
; sdram_ctrl busy (ctrl_idle='0'); the write arrives ~2 clocks
; later, hits sdram_if's ctrl_idle='0' branch which does NOT
; latch it, and T65 (NMOS) ignores Rdy on writes so it never
; waits.  EhBASIC stores input with  STA Ibuffs,X  -> every
; keystroke is lost -> '?SYNTAX ERROR' on all commands.
;
; T6 (indexed burst) FAILs; T7 (absolute burst, same addresses
; and count) PASSes — the A/B control that proves it.
;
; See fpga/docs/EHBASIC_SYNTAX_ERROR_ANALYSIS.md
;
; Build:  python tools/build_diag_sdram.py
; Upload: python tools/build_diag_sdram.py --upload --port COM15
; UART baud is set in the FPGA top-level (not here); match your
; terminal to it (board currently 230400 8N1).
;============================================================

; ---- Peripherals -------------------------------------------
UART_DATA  = $8810
UART_SR    = $8811
UART_TDRE  = $10        ; bit 4 = TX data register empty

VIC_BASE   = $8000      ; VIC text VRAM (BRAM, single-cycle)
COLS       = 40
ROWS       = 25

; ---- ZP scratch — all ZP is BRAM ($0000-$01FF), reliable ----
T0   = $00              ; general-purpose temp
T1   = $01              ; general-purpose temp
SL   = $02              ; string pointer lo  (for pstr)
SH   = $03              ; string pointer hi  (for pstr)
CNT  = $04              ; iteration counter
FAIL = $05              ; failure count for current test

; VGA state (separate from test scratch + SDRAM test addresses)
CURX = $10              ; cursor column 0..39
CURY = $11              ; cursor row    0..24
VPL  = $12              ; VRAM pointer low
VPH  = $13              ; VRAM pointer high
VTMP = $14              ; char being emitted to VGA

; Key SDRAM address under test (EhBASIC input buffer base)
IBUFFS = $0221

.segment "CODE"

;============================================================
; DIAG_ENTRY — jumped to by monitor "G C000"
; Also the RESET/NMI/IRQ vector target for hardware reset.
;============================================================
DIAG_ENTRY:
    sei
    cld
    ldx #$FF
    txs

    ; Stabilisation delay (~6.5 ms): let SDRAM init + UART settle.
    ldy #$00
dly_out:
    ldx #$00
dly_in:
    dex
    bne dly_in
    dey
    bne dly_out

    jsr vcls            ; clear VGA screen, home cursor

    lda #<str_banner
    sta SL
    lda #>str_banner
    sta SH
    jsr pstr

;============================================================
; T1: ZP BRAM sanity — baseline for basic CPU operation.
;============================================================
    lda #<str_t1
    sta SL
    lda #>str_t1
    sta SH
    jsr pstr

    lda #$55
    sta T0
    lda T0
    cmp #$55
    bne t1_fail
    lda #$AA
    sta T0
    lda T0
    cmp #$AA
    bne t1_fail
    jsr sub_pass
    jmp test2
t1_fail:
    jsr sub_fail

;============================================================
; T2: Single ABSOLUTE SDRAM write+read at $0221.
; Two passes: WR=$55 then WR=$AA.  (STA abs — no dummy read.)
;============================================================
test2:
    lda #<str_t2a
    sta SL
    lda #>str_t2a
    sta SH
    jsr pstr
    lda #$55
    sta IBUFFS
    lda IBUFFS
    sta T0
    jsr show_rd
    lda T0
    jsr phex
    jsr space
    lda T0
    cmp #$55
    bne t2a_fail
    jsr sub_pass
    jmp t2b
t2a_fail:
    jsr sub_fail
t2b:
    lda #<str_t2b
    sta SL
    lda #>str_t2b
    sta SH
    jsr pstr
    lda #$AA
    sta IBUFFS
    lda IBUFFS
    sta T0
    jsr show_rd
    lda T0
    jsr phex
    jsr space
    lda T0
    cmp #$AA
    bne t2b_fail
    jsr sub_pass
    jmp test3
t2b_fail:
    jsr sub_fail

;============================================================
; T3: EhBASIC "LIST" sim — 5 ABSOLUTE writes $0221-$0225.
;============================================================
test3:
    lda #<str_t3
    sta SL
    lda #>str_t3
    sta SH
    jsr pstr

    lda #$4C
    sta $0221
    lda #$49
    sta $0222
    lda #$53
    sta $0223
    lda #$54
    sta $0224
    lda #$00
    sta $0225

    jsr show_rd
    lda $0221
    jsr phex
    jsr space
    lda $0222
    jsr phex
    jsr space
    lda $0223
    jsr phex
    jsr space
    lda $0224
    jsr phex
    jsr space
    lda $0225
    jsr phex
    jsr space

    lda #$00
    sta FAIL
    lda $0221
    cmp #$4C
    beq t3c2
    inc FAIL
t3c2:
    lda $0222
    cmp #$49
    beq t3c3
    inc FAIL
t3c3:
    lda $0223
    cmp #$53
    beq t3c4
    inc FAIL
t3c4:
    lda $0224
    cmp #$54
    beq t3c5
    inc FAIL
t3c5:
    lda $0225
    cmp #$00
    beq t3_done
    inc FAIL
t3_done:
    lda FAIL
    bne t3_fail
    jsr sub_pass
    jmp test4
t3_fail:
    jsr show_nfail
    jsr sub_fail

;============================================================
; T4: Refresh-window stress — 128 ABSOLUTE writes to $0221.
;============================================================
test4:
    lda #<str_t4
    sta SL
    lda #>str_t4
    sta SH
    jsr pstr

    lda #$00
    sta FAIL
    lda #$80
    sta CNT
    lda #$55
    sta T1
t4_loop:
    lda T1
    sta IBUFFS
    lda IBUFFS
    cmp T1
    beq t4_ok
    inc FAIL
t4_ok:
    lda T1
    eor #$FF
    sta T1
    dec CNT
    bne t4_loop

    jsr show_nfail
    lda FAIL
    bne t4_fail
    jsr sub_pass
    jmp test5
t4_fail:
    jsr sub_fail

;============================================================
; T5: Multi-row ABSOLUTE writes $0221 / $0480 / $2000.
;============================================================
test5:
    lda #<str_t5
    sta SL
    lda #>str_t5
    sta SH
    jsr pstr

    lda #$B1
    sta $0221
    lda #$B2
    sta $0480
    lda #$B3
    sta $2000

    jsr show_rd
    lda $0221
    jsr phex
    jsr space
    lda $0480
    jsr phex
    jsr space
    lda $2000
    jsr phex
    jsr space

    lda #$00
    sta FAIL
    lda $0221
    cmp #$B1
    beq t5c2
    inc FAIL
t5c2:
    lda $0480
    cmp #$B2
    beq t5c3
    inc FAIL
t5c3:
    lda $2000
    cmp #$B3
    beq t5_done
    inc FAIL
t5_done:
    lda FAIL
    bne t5_fail
    jsr sub_pass
    jmp test6
t5_fail:
    jsr show_nfail
    jsr sub_fail

;============================================================
; T6: Burst 32B with INDEXED store  STA $0221,X  (0..31).
; This is EhBASIC's exact 'STA Ibuffs,X' pattern.  The dummy
; READ in STA abs,X leaves sdram_ctrl busy -> the write is
; dropped.  EXPECT FAIL (this is the reproduction).
;============================================================
test6:
    lda #<str_t6
    sta SL
    lda #>str_t6
    sta SH
    jsr pstr

    ldx #$00
t6_wr:
    txa
    sta $0221,x         ; <-- absolute-INDEXED: dummy-read then write
    inx
    cpx #$20
    bne t6_wr

    lda #$00
    sta FAIL
    ldx #$00
t6_rd:
    lda $0221,x
    stx T0
    cmp T0
    beq t6_ok
    inc FAIL
t6_ok:
    inx
    cpx #$20
    bne t6_rd

    jsr show_nfail
    lda FAIL
    bne t6_fail
    jsr sub_pass
    jmp test7
t6_fail:
    jsr sub_fail
    jsr dump32          ; hex-dump all 32 bytes for inspection

;============================================================
; T7: Burst 32B with ABSOLUTE store  STA $0221+I  (I=0..31).
; Same addresses, same count as T6 — ONLY the addressing mode
; differs (no dummy read).  Writes $C0..$DF so leftover T6 data
; cannot mask a failure.  EXPECT PASS.
; T6 FAIL + T7 PASS == indexed-addressing dummy-read confirmed.
;============================================================
test7:
    lda #<str_t7
    sta SL
    lda #>str_t7
    sta SH
    jsr pstr

    .repeat 32, I
    lda #($C0+I)
    sta $0221+I         ; <-- ABSOLUTE: no dummy read
    .endrep

    lda #$00
    sta FAIL
    ldx #$00
t7_rd:
    txa
    clc
    adc #$C0            ; expected = X + $C0
    sta T0
    lda $0221,x         ; readback (reads honor Rdy, reliable)
    cmp T0
    beq t7_ok
    inc FAIL
t7_ok:
    inx
    cpx #$20
    bne t7_rd

    jsr show_nfail
    lda FAIL
    bne t7_fail
    jsr sub_pass
    jmp diag_done
t7_fail:
    jsr sub_fail

;============================================================
diag_done:
    jsr newline
    lda #<str_done
    sta SL
    lda #>str_done
    sta SH
    jsr pstr
diag_halt:
    jmp diag_halt

;============================================================
; dump32 — hex-dump 32 bytes at $0221 (used on T6 fail)
;============================================================
.proc dump32
    lda #<str_dump
    sta SL
    lda #>str_dump
    sta SH
    jsr pstr
    ldx #$00
loop:
    lda $0221,x
    jsr phex
    jsr space
    inx
    cpx #$20
    bne loop
    jmp newline
.endproc

;============================================================
; OUTPUT PRIMITIVES — everything routes through 'cout'
;============================================================

; cout: emit char A to BOTH UART and VGA.  Preserves X, Y.
cout:
    jsr utx             ; UART (preserves all regs)
    jmp vout            ; VGA  (preserves X, Y)

; utx: raw UART TX of A, polls TDRE.  Preserves A, X, Y.
utx:
    pha
utx_wait:
    lda UART_SR
    and #UART_TDRE
    beq utx_wait
    pla
    sta UART_DATA
    rts

; vout: write char A to the VIC text screen at the cursor.
;   $0D -> newline;  $0A -> ignored.  Scrolls at bottom.
;   Preserves X, Y (saved on stack).
vout:
    sta VTMP
    txa
    pha
    tya
    pha
    lda VTMP
    cmp #$0A
    beq vout_done       ; ignore LF
    cmp #$0D
    beq vout_cr
    ; printable char -> VRAM at cursor
    jsr vcalc           ; VPL/VPH = VIC_BASE + CURY*COLS + CURX
    ldy #0
    lda VTMP
    sta (VPL),y
    inc CURX
    lda CURX
    cmp #COLS
    bcc vout_done
    lda #0              ; column wrap -> next line
    sta CURX
    inc CURY
    jmp vout_scroll
vout_cr:
    lda #0
    sta CURX
    inc CURY
vout_scroll:
    lda CURY
    cmp #ROWS
    bcc vout_done
    jsr vscroll
    lda #(ROWS-1)
    sta CURY
vout_done:
    pla
    tay
    pla
    tax
    rts

; vcalc: VPL/VPH = VIC_BASE + CURY*COLS + CURX.  Clobbers A, Y.
vcalc:
    lda #<VIC_BASE
    sta VPL
    lda #>VIC_BASE
    sta VPH
    ldy CURY
    beq vcalc_addx
vcalc_mul:
    lda VPL
    clc
    adc #COLS
    sta VPL
    bcc vcalc_nc
    inc VPH
vcalc_nc:
    dey
    bne vcalc_mul
vcalc_addx:
    lda VPL
    clc
    adc CURX
    sta VPL
    bcc vcalc_done
    inc VPH
vcalc_done:
    rts

; vscroll: scroll VRAM up one row, clear bottom row.  BRAM only.
;   Clobbers A, X, Y.
vscroll:
    ldx #0
vs0:
    lda VIC_BASE+COLS,x
    sta VIC_BASE,x
    inx
    bne vs0
vs1:
    lda VIC_BASE+COLS+$100,x
    sta VIC_BASE+$100,x
    inx
    bne vs1
vs2:
    lda VIC_BASE+COLS+$200,x
    sta VIC_BASE+$200,x
    inx
    bne vs2
vs3:
    lda VIC_BASE+COLS+$300,x
    sta VIC_BASE+$300,x
    inx
    cpx #192            ; $C0 = remaining bytes of 960
    bne vs3
    lda #$20            ; clear last row
    ldx #0
vsc:
    sta VIC_BASE+(ROWS-1)*COLS,x
    inx
    cpx #COLS
    bne vsc
    rts

; vcls: clear whole VIC VRAM to spaces, home cursor.
vcls:
    lda #<VIC_BASE
    sta VPL
    lda #>VIC_BASE
    sta VPH
    lda #$20
    ldy #0
    ldx #8              ; 8*256 = 2048 covers 1000 used
vcls_lp:
    sta (VPL),y
    iny
    bne vcls_lp
    inc VPH
    dex
    bne vcls_lp
    lda #0
    sta CURX
    sta CURY
    rts

;============================================================
; HIGH-LEVEL HELPERS
;============================================================

; phex: print A as two uppercase hex digits (UART+VGA).
;   Clobbers A.  Preserves X, Y.
phex:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr phex_nib
    jsr cout
    pla
    and #$0F
    jsr phex_nib
    jmp cout
phex_nib:
    ora #$30
    cmp #$3A
    bcc phex_nib_done
    adc #$06            ; CMP set carry; +6+1 = +7 -> 'A'..'F'
phex_nib_done:
    rts

; pstr: print null-terminated string at (SH:SL).
;   Clobbers A, Y.  Preserves X.
pstr:
    ldy #$00
pstr_loop:
    lda (SL),y
    beq pstr_done
    jsr cout
    iny
    bne pstr_loop
pstr_done:
    rts

space:
    lda #$20
    jmp cout

newline:
    lda #$0D
    jmp cout

show_rd:
    lda #<str_rd
    sta SL
    lda #>str_rd
    sta SH
    jmp pstr

show_nfail:
    lda #<str_nfail
    sta SL
    lda #>str_nfail
    sta SH
    jsr pstr
    lda FAIL
    jsr phex
    jmp space

sub_pass:
    lda #<str_pass
    sta SL
    lda #>str_pass
    sta SH
    jmp pstr

sub_fail:
    lda #<str_fail
    sta SL
    lda #>str_fail
    sta SH
    jmp pstr

;============================================================
; STRINGS (kept <=40 cols so VGA lines do not wrap)
;============================================================
str_banner:
    .byte $0D,$0A
    .byte "==== PIX16 SDRAM DIAG v1.1 ====",$0D,$0A
    .byte "T65-NMOS 50MHz  Ibuffs=$0221",$0D,$0A
    .byte "ABS=absolute  IDX=STA abs,X",$0D,$0A
    .byte "===============================",$0D,$0A
    .byte $00

str_t1:  .byte "T1 ZP-BRAM $00:        ",$00
str_t2a: .byte "T2 $0221 ABS W=55: ",$00
str_t2b: .byte "T2 $0221 ABS W=AA: ",$00
str_t3:  .byte "T3 LIST-sim ABS: ",$00
str_t4:  .byte "T4 stress128 ABS: ",$00
str_t5:  .byte "T5 multirow ABS: ",$00
str_t6:  .byte "T6 burst32 IDX: ",$00
str_t7:  .byte "T7 burst32 ABS: ",$00

str_pass:  .byte "PASS",$0D,$0A,$00
str_fail:  .byte "FAIL",$0D,$0A,$00
str_rd:    .byte "RD=",$00
str_nfail: .byte "fails=",$00
str_dump:  .byte " dump:",$0D,$0A,$00

str_done:
    .byte "===============================",$0D,$0A
    .byte "DONE. T6 IDX FAIL + T7 ABS PASS",$0D,$0A
    .byte "= indexed STA abs,X drops write.",$0D,$0A
    .byte "EhBASIC uses STA Ibuffs,X -> bug.",$0D,$0A
    .byte "===============================",$0D,$0A
    .byte $00

;============================================================
; Hardware vectors — all point to DIAG_ENTRY.
;============================================================
.segment "VECTORS"
    .word DIAG_ENTRY    ; $FFFA NMI
    .word DIAG_ENTRY    ; $FFFC RESET
    .word DIAG_ENTRY    ; $FFFE IRQ
