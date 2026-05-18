 ;;

show_game: ; 
  LDA #$01
  STA reqdraw_game
  STA reqdraw_cursor
  STA view_game ; set view
  JSR restart_game ; restart
  RTS ;;

restart_game: ; 
  JSR init_deck ; deck
  JSR shuffle_deck
  JSR reset_player ; player
  JSR enter_room
  LDA #$0D
  CLC
  ADC difficulty_player ; reflect difficulty
  JSR show_dialog ; dialog:difficulty
  RTS ;;

interpolateStats_game: ; 
  LDA spui_game ; 
  CMP sp_player ; sprite x
  BEQ @skip
  BCC @incShield
  DEC spui_game ; when less
  JMP @redrawShield
@incShield: ; 
  INC spui_game
@redrawShield: ; 
  LDA redraws_game ; request redraw
  ORA REQ_SP
  STA redraws_game
  RTS
@skip: ; 
  LDA hpui_game ; interpolate health
  CMP hp_player ; sprite x
  BEQ @done
  BCC @incHealth
  DEC hpui_game
  JMP @redrawHealth
@incHealth: ; 
  INC hpui_game
@redrawHealth: ; 
  LDA redraws_game ; request redraw
  ORA REQ_HP
  STA redraws_game
@done: ; 
  RTS ;;

redrawScreen_game: ; ; remove flag
  LDA #$00
  STA reqdraw_game ;
  JSR stop_renderer
  JSR load_game
  JSR loadInterface_game
  JSR loadAttributes_game
  JSR start_renderer
  RTI ;;

load_game: ; 
  BIT PPUSTATUS ; reset latch
  LDA #$20
  STA PPUADDR
  LDA #$00
  STA PPUADDR
  LDX #$00
  LDY #$00
@loop: ; 
  LDA #$00 ; sprite id
  STA PPUDATA
  INY
  CPY #$00
  BNE @loop
  INX
  CPX #$04
  BNE @loop
  RTS ;;

loadInterface_game: ; 
  BIT PPUSTATUS ; read PPU status to reset the high/low latch
  LDA #$21 ; HP H
  STA PPUADDR ; write the high byte
  LDA #$03
  STA PPUADDR ; write the low byte
  LDA #$12
  STA PPUDATA
  LDA #$1A ; HP P
  STA PPUDATA
  LDA #$21 ; SP S
  STA PPUADDR ; write the high byte
  LDA #$0A
  STA PPUADDR ; write the low byte
  LDA #$1D
  STA PPUDATA
  LDA #$1A ; SP P
  STA PPUDATA
  LDA #$21 ; XP X
  STA PPUADDR ; write the high byte
  LDA #$11
  STA PPUADDR ; write the low byte
  LDA #$22
  STA PPUDATA
  LDA #$1A ; XP P
  STA PPUDATA
  RTS ;;

loadAttributes_game: ; 
  BIT PPUSTATUS
  LDA #$23
  STA PPUADDR
  LDA #$C0
  STA PPUADDR
  LDX #$00
@loop: ; 
  LDA attributes_game, x
  STA PPUDATA
  INX
  CPX #$40
  BNE @loop
  RTS ;;

redrawCursor_game: ; ; remove flag
  LDA #$00
  STA reqdraw_cursor ; setup
  LDA #$B0
  STA $0200 ; (part1)set tile.y pos
  LDA #$13
  STA $0201 ; (part1)set tile.id
  LDA #$00
  STA $0202 ; (part1)set tile.attribute[off] ;
  LDX cursor_game
  LDA selections_game, x
  STA $0203 ; set tile.x pos
  JSR sprites_renderer
@done: ; 
  RTI ;; redraw

redrawHealth_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_HP
  STA redraws_game ;
  LDY hpui_game
  BIT PPUSTATUS ; read PPU status to reset the high/low latch ; pos
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$07
  STA PPUADDR ; write the low byte ; digits
  LDA number_high, y
  STA PPUDATA
  LDA number_low, y
  STA PPUDATA ; progress bar
  LDA healthbarpos, y ; regA has sprite offset
  TAY ; regY has sprite offset
  LDX #$00
@loop: ; 
  LDA #$20
  STA PPUADDR ; write the high byte
  LDA healthbaroffset, x
  STA PPUADDR ; write the low byte
  LDA progressbar, y ; regA has sprite id
  STA PPUDATA
  INY
  INX
  CPX #$06
  BNE @loop ; sickness
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$05
  STA PPUADDR ; write the low byte
  LDA sickness_player
  CMP #$01
  BNE @false ; sickness icon
  LDA #$3F
  STA PPUDATA
  JMP @done
@false: ; 
  LDA #$00
  STA PPUDATA
@done: ; 
  JSR fix_renderer
  RTI ;; shield value

redrawShield_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_SP
  STA redraws_game ; 
  LDY spui_game
  BIT PPUSTATUS ; read PPU status to reset the high/low latch ; pos
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$0E
  STA PPUADDR ; write the low byte ; digit 1
  LDA number_high, y
  STA PPUDATA
  LDA number_low, y
  STA PPUDATA ; 
  LDA shieldbarpos, y ; regA has sprite offset
  TAY ; regY has sprite offset
  LDX #$00
@loop: ; 
  LDA #$20
  STA PPUADDR ; write the high byte
  LDA shieldbaroffset, x
  STA PPUADDR ; write the low byte
  LDA progressbar, y ; regA has sprite id
  STA PPUDATA
  INY
  INX
  CPX #$06
  BNE @loop ; durability
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$0C
  STA PPUADDR ; write the low byte
  LDX dp_player
  LDA card_glyphs, x
  STA PPUDATA
  JSR fix_renderer
  RTI ;; experience value

redrawExperience_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_XP
  STA redraws_game ;
  LDY xp_player
  BIT PPUSTATUS ; read PPU status to reset the high/low latch ; pos
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$15
  STA PPUADDR ; write the low byte ; load xp in y
  LDA number_high, y ; digit 1
  STA PPUDATA
  LDA number_low, y ; digit 2
  STA PPUDATA ; progress bar
  LDA experiencebarpos, y ; regA has sprite offset
  TAY ; regY has sprite offset
  LDX #$00
@loop: ; 
  LDA #$20
  STA PPUADDR ; write the high byte
  LDA experiencebaroffset, x
  STA PPUADDR ; write the low byte
  LDA progressbar, y ; regA has sprite id
  STA PPUDATA
  INY
  INX
  CPX #$06
  BNE @loop
  JSR fix_renderer
  RTI ;;

redrawRun_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_RUN
  STA redraws_game ;
  JSR stop_renderer
  LDA length_deck ; don't display the run butto on first hand
  CMP #$31 ; deck is $36 - 4(first hand)
  BEQ @hide
  JSR loadRun_player ; load canRun in regA
  CMP #$01
  BNE @hide
  LDA length_deck ; Can't run the last room
  CMP #$00
  BEQ @hide
@show: ; RUN: $1c,$1f,$18
  BIT PPUSTATUS ; read PPU status to reset the high/low latch
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$18
  STA PPUADDR ; write the low byte
  LDA #$6D ; Button(B)
  STA PPUDATA
  LDA #$00 ; Blank
  STA PPUDATA
  LDA #$1C ; R
  STA PPUDATA
  LDA #$1F ; U
  STA PPUDATA
  LDA #$18 ; N
  STA PPUDATA
  JSR start_renderer
  RTI
@hide: ; 
  BIT PPUSTATUS ; read PPU status to reset the high/low latch
  LDA #$21
  STA PPUADDR ; write the high byte
  LDA #$18
  STA PPUADDR ; write the low byte
  LDA #$00 ; R
  STA PPUDATA
  STA PPUDATA
  STA PPUDATA
  STA PPUDATA
  STA PPUDATA
  JSR start_renderer
  RTI ;;

redrawName_game: ; ;remove trigger
  LDA #$00
  STA reqdraw_name ;
  BIT PPUSTATUS
  LDA #$21
  STA PPUADDR
  LDA #$43
  STA PPUADDR
  LDX #$00
@loop: ; 
  LDY #$01 ; load card id ; load card name
  LDY cursor_game
  LDA card1_room, y
  TAY
  LDA card_names_offset_lb,y
  STA lb_temp
  LDA card_names_offset_hb,y
  STA hb_temp
  TYA
  STX id_temp
  CLC
  ADC id_temp
  TAY
  LDA (lb@temp), y ; load value at 16-bit address from (lb@temp + hb@temp) + y ; draw sprite
  STA PPUDATA
  INX
  CPX #$10
  BNE @loop
  JSR fix_renderer
  RTI ;; to merge into a single routine

redrawCard1_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_CARD1
  STA redraws_game ;
  JSR stop_renderer
  LDX #$00
@loop: ; 
  LDA card1pos_high, x
  STA PPUADDR ; write the high byte
  LDA card1pos_low, x
  STA PPUADDR ; write the low byte
  LDA card1_buffers, x
  STA PPUDATA ; set tile.x pos
  INX
  CPX #$36
  BNE @loop
  JSR start_renderer
  RTI ;;

redrawCard2_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_CARD2
  STA redraws_game ;
  JSR stop_renderer
  LDX #$00
@loop: ; 
  LDA card1pos_high, x
  STA PPUADDR ; write the high byte
  LDA card2pos_low, x
  STA PPUADDR ; write the low byte
  LDA card2_buffers, x
  STA PPUDATA
  INX
  CPX #$36
  BNE @loop
  JSR start_renderer
  RTI ;;

redrawCard3_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_CARD3
  STA redraws_game ;
  LDX #$00
  JSR stop_renderer
@loop: ; 
  LDA card3pos_high, x
  STA PPUADDR ; write the high byte
  LDA card3pos_low, x
  STA PPUADDR ; write the low byte
  LDA card3_buffers, x
  STA PPUDATA
  INX
  CPX #$36
  BNE @loop
  JSR start_renderer
  RTI ;;

redrawCard4_game: ; ; remove flag
  LDA redraws_game
  EOR REQ_CARD4
  STA redraws_game ;
  JSR stop_renderer
  LDX #$00
@loop: ; 
  LDA card3pos_high, x
  STA PPUADDR ; write the high byte
  LDA card4pos_low, x
  STA PPUADDR ; write the low byte
  LDA card4_buffers, x
  STA PPUDATA
  INX
  CPX #$36
  BNE @loop
  JSR start_renderer
  RTI ;;

animateTimer_game: ; when timer reaches 0, set auto@room flag to 1
  LDA timer_room
  CMP #$00
  BEQ @skip ; check timer is done
  CMP #$01
  BEQ @run
  DEC timer_room
  RTS
@run: ; 
  LDA #$01
  STA auto_room
@skip: ; 
  RTS