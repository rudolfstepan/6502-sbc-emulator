 ;; player

reset_player: ; 
  LDA #$15
  STA hp_player
  STA hpui_game
  LDA #$00
  STA sp_player
  STA spui_game
  STA dp_player
  STA sickness_player
  STA has_run_player
  RTS ;;

addSickness_player: ; 
  LDA #$01
  STA sickness_player
  RTS ;;

removeSickness_player: ; 
  LDA #$00
  STA sickness_player
  RTS ;; ;; running

loadRun_player: ; () -> a:canRun ; check if player is alive
  LDA hp_player
  CMP #$00
  BEQ @disableRun ; 
  LDA difficulty_player
  CMP #$00
  BEQ @easy
  CMP #$01
  BEQ @normal
  CMP #$02
  BEQ @hard
  CMP #$03
  BEQ @special
@easy: ; RULE | can escape if when no monsters present or when has not escaped before
  JSR loadEnemiesLeft_room
  CPX #$00
  BEQ @enableRun ; when monsters left
  LDA has_run_player
  CMP #$01
  BEQ @disableRun ; when has not escaped
  JSR @enableRun
  RTS
@normal: ; RULE | can escape when has not escaped before
  LDA has_run_player
  CMP #$01
  BEQ @disableRun ; when has not escaped
  JSR @enableRun
  RTS
@hard: ; RULE | can escape if there are no monsters present
  JSR loadEnemiesLeft_room
  CPX #$00
  BNE @disableRun ; when no monsters present
  JSR @enableRun
  RTS
@special: ; RULE | can escape if not injured
  LDA hp_player
  CMP #$15
  BNE @disableRun ; when hp is not full
  JSR @enableRun
  RTS
@enableRun: ; 
  LDA #$01
  RTS
@disableRun
  LDA #$00
  RTS ;;

updateExperience_player: ; () -> a:xp
  JSR loadCardsLeft_room ; load cards left, stores counts in x
  STX id_temp
  LDA #$36 ; cards max
  SEC
  SBC length_deck ; minus length
  SBC id_temp ; minus cards left
  STA xp_player ; load xp AND update high score
  RTS ;;

tryRun_player: ; 
  LDA hp_player ; check if player is alive
  CMP #$00
  BEQ @onDead ; 
  LDA xp_player ; when alive, check for victory
  CMP #$36
  BEQ @onVictory
  JSR loadRun_player ; load canRun in regA when alive, check for escape
  CMP #$01
  BEQ @onEscape
  LDA #$04 ; dialog: cannot_run when unable, display dialog
  JSR show_dialog
  RTS
@onEscape: ; 
  JSR returnCards_room ; draw cards for next room
  JSR enter_room
  LDA #$01 ; record running
  STA has_run_player
  LDA #$0C ; dialog:run
  JSR show_dialog
  RTS
@onVictory: ; 
  LDA #$00 ; dialog:clear
  JSR show_dialog
  JSR show_splash
  RTS
@onDead: ; 
  JSR restart_game
  RTS ; ;;

clampHealth_player: ; 
  LDA hp_player
  CMP #$15
  BCC @done
  LDA #$15
  STA hp_player
@done: ; 
  RTS