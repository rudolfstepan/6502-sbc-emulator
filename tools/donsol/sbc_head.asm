; Donsol SBC ROM Header
; Adapted from original NES version for 6502 SBC Emulator

; --- Memory Map ---
; $0000-$00FF: Zero Page
; $0100-$01FF: Stack
; $0200-$7EFF: Game RAM
; $8000-$FFFF: ROM (32KB)

; --- SBC Hardware ---
; VIA6522 at $8800
VIA_BASE            = $8800
VIA_ORB             = $8800    ; VIA Port B (general I/O)
VIA_ORA             = $8801    ; VIA Port A (keyboard input)
VIA_DDRB            = $8802    ; VIA Data Direction Register B
VIA_DDRA            = $8803    ; VIA Data Direction Register A
VIA_T1CL            = $8804    ; Timer 1 Counter Low
VIA_T1CH            = $8805    ; Timer 1 Counter High
VIA_T1LL            = $8806    ; Timer 1 Latch Low
VIA_T1LH            = $8807    ; Timer 1 Latch High
VIA_T2CL            = $8808    ; Timer 2 Counter Low
VIA_T2CH            = $8809    ; Timer 2 Counter High
VIA_SR              = $880A    ; Shift Register
VIA_ACR             = $880B    ; Auxiliary Control Register
VIA_PCR             = $880C    ; Peripheral Control Register
VIA_IFR             = $880D    ; Interrupt Flag Register
VIA_IER             = $880E    ; Interrupt Enable Register
VIA_ORA2            = $880F    ; Port A (no handshake)

; VIC Registers (Text/Bitmap Mode)
VIC_SCREEN_BASE     = $8000    ; Text mode screen buffer (40x25)
VIC_CTRL1           = $9000    ; VIC Control Register 1
VIC_CTRL2           = $9001    ; VIC Control Register 2
VIC_COLOR_BASE      = $9400    ; Color RAM (if available)

; --- Game Button Constants ---
BUTTON_RIGHT        = $01
BUTTON_LEFT         = $02
BUTTON_DOWN         = $04
BUTTON_UP           = $08
BUTTON_START        = $10
BUTTON_SELECT       = $20
BUTTON_B            = $40
BUTTON_A            = $80

; --- Redraw Flags ---
REQ_HP              = %00000001
REQ_SP              = %00000010
REQ_XP              = %00000100
REQ_RUN             = %00001000
REQ_CARD1           = %00010000
REQ_CARD2           = %00100000
REQ_CARD3           = %01000000
REQ_CARD4           = %10000000

; --- Zero Page Variables (Game State) ---
.segment "ZEROPAGE"

; Player stats
hp_player:              .res 1     ; health points
sp_player:              .res 1     ; shield points
dp_player:              .res 1     ; durability points
xp_player:              .res 1     ; experience
difficulty_player:      .res 1     ; difficulty setting
sickness_player:        .res 1     ; status effect
has_run_player:         .res 1     ; run flag

; Deck & Input
length_deck:            .res 1     ; deck length
hand_deck:              .res 1     ; cards in hand
seed1_deck:             .res 1     ; RNG seed 1
seed2_deck:             .res 1     ; RNG seed 2
down_input:             .res 1     ; current key down
last_input:             .res 1     ; last key state
next_input:             .res 1     ; next input event

; Room (encounter)
card1_room:             .res 1     ; card slot 1
card2_room:             .res 1     ; card slot 2
card3_room:             .res 1     ; card slot 3
card4_room:             .res 1     ; card slot 4
timer_room:             .res 1     ; timer counter
auto_room:              .res 1     ; auto-resolve flag
enemy_hp_game:          .res 1     ; simple enemy health
turn_game:              .res 1     ; turn counter
room_game:              .res 1     ; room counter

; Game state
id_dialog:              .res 1     ; dialog ID
cursor_game:            .res 1     ; menu cursor
view_game:              .res 1     ; current view (0=splash, 1=game)
hpui_game:              .res 1     ; HP UI state
spui_game:              .res 1     ; SP UI state
redraws_game:           .res 1     ; redraw flags

; Splash screen
cursor_splash:          .res 1     ; splash menu cursor
highscore_splash:       .res 1     ; highscore
difficulty_splash:      .res 1     ; difficulty

; Utility
lb_temp:                .res 1     ; low byte temp
hb_temp:                .res 1     ; high byte temp
id_temp:                .res 1     ; ID temp
damages_player:         .res 1     ; damage counter

; Temp card state
card_last:              .res 1     ; last card ID
card_last_type:         .res 1     ; last card type
card_last_value:        .res 1     ; last card value

; SBC-specific keyboard state
kbd_key_pressed:        .res 1     ; current ASCII key code
kbd_last_key:           .res 1     ; last key processed (for debounce)
reqdraw_splash:         .res 1     ; splash redraw flag
reqdraw_cursor:         .res 1     ; cursor redraw flag
reqdraw_game:           .res 1     ; game redraw flag

.segment "CODE"
