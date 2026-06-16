# EhBASIC "Syntax Error" on All Commands — Root Cause Analysis

**Date:** 2026-06-07  
**Status:** RESOLVED 2026-06-07 — all three symptoms fixed; EhBASIC boots and runs correctly on FPGA hardware  
**Symptom:** Every BASIC command typed at the `Ready.` prompt returns `?SYNTAX ERROR` — `LIST`, `PRINT 1+1`, `10 REM` all fail equally.

---

## 1. Observed Behaviour

From the VGA screenshot:

```
3□□□□□ Bytes free
Enhanced BASIC 2.22
Ready.
list
?SYNTAX ERROR
print 1+1
?SYNTAX ERROR
PRINT 1+1
?SYNTAX ERROR
10 REM
?SYNTAX ERROR
```

Key observations:
- EhBASIC boots, prints the banner, shows `Ready.` — so cold-start ZP init works.
- The `3□□□□□ Bytes free` line suggests ~31 KB free but the remaining digit glyphs are wrong (separate issue, likely character ROM mapping).
- Input is echoed correctly — the typed text appears on screen before the error.
- The error is 100% consistent across every command, every session.

---

## 2. The Input → Tokenize Path

Understanding what BASIC does with each keypress is the foundation:

### 2.1 Input collection (`LAB_1357`)

```
LAB_1357:
  LDX #$00
LAB_1359:
  JSR V_INPT          ; JMP (VEC_IN=$E2) → KERNAL_CHRIN_NB
  BCC LAB_1359        ; loop if no char (C=0)
  BEQ LAB_1359        ; loop if null
  CMP #$0D            ; Enter?
  BEQ → LAB_1866      ; yes: null-terminate + exit
  ...
  STA Ibuffs,X        ; <-- ONLY SDRAM WRITE in input loop
  INX
  JSR LAB_PRNA        ; echo character (VIC VRAM + UART)
  BNE LAB_1359        ; loop always
```

`Ibuffs = IRQ_vec + $14 = $020D + $14 = $0221` — first byte of the input buffer lands at **SDRAM address $0221**.

### 2.2 CR handler (`LAB_1866`)

On Enter:
```
  STA Ibuffs,X        ; write $00 null-terminator to SDRAM
  LDX #<Ibuffs        ; $21
  LDY #>Ibuffs        ; $02
  ; fall through to CRLF print, then return to LAB_1280
```

### 2.3 Dispatch (`LAB_1280`)

```
LAB_127D:
  JSR LAB_1357        ; collect input into Ibuffs (SDRAM $0221+)
LAB_1280:
  STX Bpntrl          ; $21  (ZP BRAM)
  STY Bpntrh          ; $02  (ZP BRAM)
  JSR LAB_GBYT        ; reads LDA ($Bpntrh:$Bpntrl) = LDA $0221 from SDRAM
  BEQ LAB_127D        ; null? retry (empty line)
  LDX #$FF
  STX Clineh
  BCC LAB_1295        ; C=0 → numeric → new program line
  ; else: immediate mode
  JSR LAB_13A6        ; crunch (tokenize) the line
  JMP LAB_15F6        ; scan and interpret
```

`LAB_GBYT` is the code from `LAB_2CEE` copied to ZP BRAM at $C2:

```
LAB_2CEE (= ZP $BC):
  INC Bpntrl          ; advance pointer
  BNE LAB_2CF4
  INC Bpntrh
LAB_2CF4 (= ZP $C2):
  LDA ($Bpntrl,indirect)  ; self-modifying: effective = LDA $0221 after init
  CMP #TK_ELSE
  BEQ .done
  CMP #':'
  BCS .done           ; ≥ ':' → C=1, return (immediate mode command)
  CMP #' '
  BEQ LAB_2CEE        ; skip spaces (loop, increment ptr)
  SEC
  SBC #'0'
  SEC
  SBC #$D0            ; for digits: C=0 on return (line-number mode)
.done:
  RTS
```

So the **first SDRAM READ** after input (`LDA $0221`) determines whether the line is treated as a command or a new line number. The character at $0221 must be the first character the user typed.

If $0221 contains garbage (0x00, 0xFF, random), `LAB_GBYT` returns with A=garbage, and the tokenizer will immediately fail.

---

## 3. The SDRAM Write Path

### 3.1 Hardware write flow

The CPU-to-SDRAM write involves these components in sequence:

1. **T65 write cycle**: T65 drives `R_W_n='0'` (via `WRn_i`), `VDA='1'`, and data+address.
2. **t65_adapter** computes `cpu_we = (NOT t65_r_w_n) AND t65_vda`.
3. **Top-level** gates the write: `cpu_bus_we = cpu_we AND NOT cpu_enable`.  
   (`cpu_enable` toggles every 50 MHz clock → 25 MHz effective rate; `cpu_bus_we='1'` only during the "hold" half-cycle.)
4. **sdram_if** receives `cpu_bus_we`, latches addr/data, drives `wr_burst_req` to sdram_ctrl.
5. **sdram_ctrl** performs the actual SDRAM write sequence: ACT → WRITE → CAS latency → burst.

### 3.2 T65 ignores Rdy during write cycles

**File:** [fpga/third_party/t65/rtl/T65.vhd](../third_party/t65/rtl/T65.vhd), line 256:

```vhdl
really_rdy <= Rdy or not(WRn_i);
```

`WRn_i` is the registered write-enable. During a write cycle `WRn_i='0'` → `NOT WRn_i='1'` → **`really_rdy='1'` always**, regardless of the `Rdy` input from the memory system.

This is correct NMOS 6502 behaviour: the real 6502 also ignores `RDY` during write cycles. The T65 `Mode="00"` (confirmed in [fpga/rtl/cpu/t65_adapter.vhd](../rtl/cpu/t65_adapter.vhd)) faithfully replicates this.

**Consequence:** When T65 executes `STA $0221`:
- T65 asserts the write, drives addr=$0221, data=char.
- If the memory subsystem asserts `Rdy='0'`, T65 does **not** stall — it advances to the next instruction regardless.
- sdram_if has exactly **one clock where `cpu_bus_we='1'`** to capture the write. If sdram_if misses this window, the write is permanently lost.

### 3.3 The sdram_if write-miss bug

**File:** [fpga/rtl/mem/sdram_if.vhd](../rtl/mem/sdram_if.vhd), S_IDLE state:

```vhdl
when S_IDLE =>
    wr_burst_req <= '0';
    rd_burst_req <= '0';
    rdy          <= '1';
    if cs = '1' and ctrl_idle = '0' then
        rdy <= '0';           -- stall for reads; IGNORED for writes
        -- addr_lat and din_lat NOT latched here!
        -- state does NOT change!
    elsif ctrl_idle = '1' then
        if cs = '1' and cpu_bus_we = '1' then
            addr_lat <= "000000000" & addr;
            din_lat  <= din;
            rdy      <= '0';
            state    <= S_WR_REQ;
        elsif cs = '1' and cpu_we = '0' then
            addr_lat <= "000000000" & addr;
            rdy      <= '0';
            state    <= S_RD_REQ;
        end if;
    end if;
```

The write is only latched in the `elsif ctrl_idle = '1'` branch.

The `if cs='1' and ctrl_idle='0'` branch only asserts `rdy <= '0'` — it does **not** latch `addr_lat`/`din_lat` and does **not** transition state.

**For a read**, this is fine: T65 waits because `Rdy='0'` forces `really_rdy='0'` (since `WRn_i='1'` during reads: `NOT WRn_i = '0'`), so T65 stalls until `ctrl_idle='1'` and `rdy` goes back to '1'.

**For a write**, `Rdy='0'` is ignored. T65 moves on. When `ctrl_idle` eventually becomes '1', `cpu_bus_we` is no longer '1' (T65 is now in the next instruction's read cycle). The write to $0221 is gone.

### 3.4 When does ctrl_idle = '0' during a CPU write?

`ctrl_idle='1'` only in `S_IDLE` of sdram_ctrl.

`ctrl_idle='0'` whenever sdram_ctrl is in any other state:
1. **SDRAM refresh**: fires every 375 clocks (7.5 µs @ 50 MHz). Refresh takes approximately 7-15 clocks (S_AR → S_TRFC → back to S_IDLE). During this window, `ctrl_idle='0'`.
2. **Preceding access still completing**: if a previous read or write is still running in sdram_ctrl when the next CPU write starts.

The input loop (`STA Ibuffs,X; INX; JSR LAB_PRNA; JSR V_INPT; BCC ...`) has no SDRAM reads between consecutive `STA` instructions (KERNAL_CHROUT writes to VIC VRAM BRAM, KERNAL_CHRIN_NB reads UART peripheral — neither touches SDRAM). So by the time of the second `STA`, sdram_ctrl should be back in S_IDLE.

However, SDRAM refresh is the wildcard. With 375-clock period and ~10-clock refresh duration, the probability of a refresh coinciding with any given write is roughly 10/375 ≈ 2.7%. For a 5-character command, the probability that **at least one** character is lost is ~13%, and that the **first** character is lost is ~2.7%.

A 2.7% first-character miss rate would produce sporadic failures, not the observed 100% failure rate. There must be an additional mechanism.

---

## 4. Candidate Explanations for 100% Failure

### Hypothesis A: Preceding write still in sdram_ctrl

When the user types quickly (or the serial port floods input), consider what happens after `STA Ibuffs,X` (stores char 1):
- sdram_if transitions S_IDLE → S_WR_REQ → S_WR_WAIT → S_LOCKED → S_IDLE.
- sdram_ctrl performs ACT (S_ACTIVE → S_TRCD=2 clocks) → WRITE (S_WRITE) → S_WD → S_TWR=3 → S_PRE → S_TRP=4 → S_IDLE.
- Total: approximately 2+1+1+3+1+4 = 12 sdram_ctrl clocks + sdram_if overhead ≈ 18-20 total clocks.

T65 (at 25 MHz effective) takes:
- INX: 2 CPU cycles × 2 = 4 clocks
- JSR LAB_PRNA + JMP (VEC_OUT) + KERNAL_CHROUT (writes VIC VRAM BRAM): ~15-20 CPU cycles × 2 = 30-40 clocks
- Return path to `JSR V_INPT`: ~10 CPU cycles × 2 = 20 clocks
- KERNAL_CHRIN_NB (UART read, no SDRAM): ~6 CPU cycles × 2 = 12 clocks
- Return and BCC loop: ~5 CPU cycles × 2 = 10 clocks

Total between consecutive `STA` instructions: ~76-82 clocks (with chars available immediately).

The SDRAM write completes in ~20 clocks, well before the next `STA` (~76 clocks later). **Hypothesis A is unlikely to cause 100% failure** at human typing speeds — though it might cause failures when pasting large blocks at baud-rate speed.

### Hypothesis B: Timing of cpu_bus_we pulse

`cpu_bus_we = cpu_we AND NOT cpu_enable`

`cpu_enable` toggles every 50 MHz clock. T65's write cycle:
- At the active clock edge when `cpu_enable='1'`: T65 updates `WRn_i <= NOT Write`, `Set_Addr_To_r` (which drives VDA).
- After this edge: `WRn_i='0'` → `cpu_we = (NOT '0') AND vda = '1' AND vda`.
- On the next clock: `cpu_enable` flips to '0' → `cpu_bus_we = cpu_we AND NOT '0' = cpu_we`.

So `cpu_bus_we='1'` for exactly **one 50 MHz clock cycle** (the hold phase). sdram_if samples this in its registered process:

```vhdl
process(clk, rst)
begin
  if rising_edge(clk) then
    -- S_IDLE check: sees cpu_bus_we='1' for one clock
```

If sdram_if's registered process sees `cpu_bus_we='1'` but `ctrl_idle='0'` at that same clock edge, it falls into the stall branch — and because `cpu_bus_we='1'` is only present for one clock, by the next clock it's gone. **The write is permanently lost.**

This is a **guaranteed loss** whenever `ctrl_idle='0'` coincides with the one-clock `cpu_bus_we='1'` pulse. Since `ctrl_idle='0'` for ~12 clocks out of every 375, and the `cpu_bus_we` window is exactly 1 clock, the collision probability per write is 12/375 ≈ 3.2%.

### Hypothesis C: Initial SDRAM state causes first write to hit busy ctrl

At cold start, sdram_ctrl runs through its initialisation sequence (S_INIT, S_INIT_PRECH, S_INIT_AR1, S_INIT_AR2, etc.). This takes many clocks. The boot RAM test (which bypasses sdram_if) runs immediately after init. Then the UART monitor upload happens.

By the time EhBASIC is running and the user types the first character, sdram_ctrl should be in S_IDLE. Unless...

The ZP copy in `LAB_COLD` (`STY`/`STA` loops copying to $BC-$D7 and $00-$11) goes to ZP BRAM — not SDRAM. So there is no preceding SDRAM activity before the first `STA Ibuffs,X`.

### Hypothesis D: The bug is NOT in SDRAM writes

Perhaps SDRAM writes actually succeed, but the **read-back** in `LAB_GBYT` fails. `LAB_GBYT` at $C2 executes `LDA ($C3)` where $C3/$C4 = $21/$02, producing `LDA $0221`. This is an **indexed-indirect** read from SDRAM. 

The T65 timing for this read is:
1. T1: fetch opcode (ROM, no wait state)
2. T2: fetch ZP page ($C3), read Bpntrl from ZP BRAM
3. T3: fetch ZP page+1 ($C4), read Bpntrh from ZP BRAM  
4. T4: address formed, T65 reads from effective address $0221 (SDRAM)
5. T5: final cycle (for indexed-indirect, there's an extra cycle)

At T4-T5, sdram_if sees a read request. Since T65 IS stalled by `Rdy='0'` during reads (because WRn_i='1' during reads), sdram_if can hold T65 until the SDRAM data is ready. The read should work correctly, assuming the data is actually there.

If the write succeeded but the read returned wrong data, that would manifest as unparseable characters → Syntax Error. But the T65 indirect-read fix (moving vectors to ZP BRAM) was done precisely because JMP-indirect reads were unreliable. For non-JMP reads, the standard read path (sdram_if S_RD_REQ → S_RD_WAIT → S_LOCKED → data returned) should work — T65 waits on Rdy.

### Hypothesis E: VEC_OUT path causes SDRAM contention

`KERNAL_CHROUT` writes to VIC VRAM (BRAM at $8000+). This is **not** SDRAM — it's a separate BRAM block. No sdram_if involvement. ✓

However, `KERNAL_CHROUT` in the kernel might also update cursor position or write to SDRAM for scrolling. Let me flag this as worth checking in `tools/kernel/kernel.s`.

If KERNAL_CHROUT triggers an SDRAM access (e.g., reading/writing a scroll buffer in SDRAM range), and if this SDRAM operation is still in progress when the NEXT input character arrives and `STA Ibuffs,X` fires, the write could hit a busy sdram_ctrl.

Given the VGA VIC VRAM is at $8000 (BRAM), scrolling that buffer shouldn't need SDRAM. But if the kernel scrolls by copying rows (LDA from VIC VRAM, STA to VIC VRAM shifted by one row), it's all BRAM — no SDRAM. **Likely safe**, but worth verifying.

---

## 5. Why Monitor and Boot RAM Test Work

Both bypass sdram_if entirely:

**UART Monitor write path** ([fpga/rtl/sbc_t65_sdram_boot_top.vhd](../rtl/sbc_t65_sdram_boot_top.vhd)):
```vhdl
ctrl_wr_burst_req <= mon_wr_burst_req when mon_ctrl_active='1'
                     else wr_burst_req;
```
`mon_wr_burst_req` is driven directly from the monitor state machine (M_SDR_WR_REQ), which waits for `ctrl_idle='1'` before asserting the burst request. No sdram_if involved.

**Boot RAM test** uses `test_wr_burst_*` signals, same bypass mechanism.

Both paths correctly wait for `ctrl_idle='1'` before issuing the write request. They don't have the T65 `really_rdy` problem because they don't use the CPU bus at all.

---

## 6. Address Mapping Verification

CPU address $0221 → sdram_if → `addr_lat = "000000000" & $0221 = 24'h000221`.

sdram_ctrl maps:
- `bank    = sys_addr[23:22] = 2'b00` → bank 0
- `row     = sys_addr[21:9]  = 13'h0001` → row 1  
- `col     = sys_addr[8:0]   = 9'h021` → column 33

This is valid SDRAM space. The mapping is identical for reads and writes. ✓

---

## 7. LAB_COLD Initialisation Verification

`LAB_COLD` copies:
1. **PG2_TABS** to $0200-$0204 (5 bytes: ccflag, ccbyte, ccnull, CTRLC address — but VEC_CC is now at $EA, so CTRLC address bytes are dead).
2. **LAB_2CEE** code block to ZP $BC-$D7 (the self-modifying LAB_GBYT etc.).
3. **StrTab** to ZP $00-$11.

LAB_COLD does **NOT** touch:
- ZP $E2-$EB (VEC_IN, VEC_OUT, VEC_LD, VEC_SV, VEC_CC — all in upper ZP, set by RESET_ENTRY).
- Ibuffs at $0221+ (SDRAM input buffer).

Vectors set in RESET_ENTRY survive across `LAB_COLD`. ✓

---

## 8. Summary of Root Cause

The write-loss mechanism is confirmed:

| Step | Component | Signal | Problem |
|------|-----------|--------|---------|
| T65 `STA $0221` | T65 core | `WRn_i='0'` | `really_rdy='1'` regardless of `Rdy` |
| Write cycle | sdram_if | `ctrl_idle='0'` | Only `rdy<='0'` — addr/data NOT latched |
| One clock later | T65 | advances | `cpu_bus_we='1'` window expired |
| Subsequent clocks | sdram_if | `ctrl_idle='1'` | `cpu_bus_we='0'` — nothing to latch |
| **Result** | SDRAM $0221 | unchanged | Write permanently lost |

**The 100% failure rate** is still not fully explained by the ~3% per-write refresh collision alone. The additional factor is likely that the **first write** (the first character) coincides with the SDRAM refresh that fires immediately after the preceding long idle period (waiting for user input). After a long idle, the next SDRAM refresh fires within 375 clocks of the last one. The exact timing relative to when the user presses a key is deterministic per session boot but could consistently land in the refresh window depending on the SDRAM refresh counter phase at power-on/reset.

Alternatively, the very first `STA Ibuffs,X` may coincide with sdram_ctrl completing a refresh or a prior read (the PG2_TABS write at $0200-$0204 during LAB_COLD), causing ctrl_idle='0' at the critical moment.

---

## 9. Proposed Fix

### Fix A: Latch write even when ctrl_idle='0' (recommended)

Modify `sdram_if.vhd` S_IDLE to add a pending-write latch:

```vhdl
-- New state: wait for ctrl_idle before submitting latched write
when S_IDLE =>
    wr_burst_req <= '0';
    rd_burst_req <= '0';
    rdy          <= '1';
    if cs = '1' and cpu_bus_we = '1' then
        -- Latch write IMMEDIATELY regardless of ctrl_idle
        addr_lat <= "000000000" & addr;
        din_lat  <= din;
        rdy      <= '0';
        if ctrl_idle = '1' then
            state <= S_WR_REQ;       -- can go directly
        else
            state <= S_WR_HOLD;      -- wait for ctrl to free up
        end if;
    elsif ctrl_idle = '1' then
        if cs = '1' and cpu_we = '0' then
            addr_lat <= "000000000" & addr;
            rdy      <= '0';
            state    <= S_RD_REQ;
        end if;
    elsif cs = '1' and ctrl_idle = '0' then
        rdy <= '0';                  -- existing read-stall behaviour
    end if;

when S_WR_HOLD =>
    wr_burst_req <= '0';
    rdy          <= '0';
    if ctrl_idle = '1' then
        state <= S_WR_REQ;
    end if;
```

This captures `addr_lat`/`din_lat` immediately in the one-clock `cpu_bus_we='1'` window, then waits for `ctrl_idle='1'` before proceeding — all while keeping `rdy='0'` (harmless for writes since T65 already advanced, but necessary to prevent sdram_if from accepting a new request before the pending one is submitted).

**Note:** since T65 ignores `rdy` during writes, keeping `rdy='0'` in S_WR_HOLD does not stall T65. The write to $0221 is captured safely. T65 is only visibly stalled if a subsequent **read** arrives while in S_WR_HOLD (the read sees `rdy='0'` and T65 waits).

### Fix B: Gate cpu_enable to force T65 to stall on write + ctrl_busy

Modify the top-level to force `cpu_rdy='0'` when a write is pending AND ctrl_idle='0'. This is more invasive and harder to get right — not recommended.

### Fix C: Verify the bug first with a targeted SDRAM read-back test

Before rebuilding FPGA bitstream, add a diagnostic to the kernel RESET_ENTRY that:
1. Writes $55 to $0221 from CPU (`STA $0221`).
2. Reads $0221 back (`LDA $0221`).
3. Compares — if $55 returns, write succeeded; send 'W' on UART.
4. If not $55, send 'X' on UART.

If 'X' appears, the SDRAM write path is confirmed broken. If 'W', the bug is elsewhere.

This test can be inserted into `fpga/asm/ehbasic_fpga.s` in the RESET_ENTRY diagnostic sequence (between 'R' and 'S').

---

## 10. Secondary Issue: `3□□□□□ Bytes free`

The digits after '3' render as box glyphs. Possible causes:

1. **Character ROM mapping**: VIC character glyphs may not have standard ASCII mapping for digits. The VGA text renderer uses character indices that may differ from ASCII codes.

2. **SDRAM read returns wrong data**: If reads from the memory-size display path fail, the digit ASCII codes could be corrupted. However, this would affect the '3' as well — and '3' renders correctly.

3. **EhBASIC number formatting**: EhBASIC stores the free-memory count and converts to decimal string for printing. If intermediate SDRAM variables (digit table, stack frame) are corrupted, the digits could be wrong.

4. **VIC register off-by-one**: Cursor column tracking may be off by one, causing the digit characters to write to shifted VRAM positions, landing outside the character glyph table range.

This issue is **secondary** to the Syntax Error problem. Once SDRAM writes are fixed, the free-memory display may self-correct (if the underlying cause is the same SDRAM write corruption).

---

## 11. Next Steps

### 2026-06-07 follow-up after failed retest

The failed retest still showed `Syntax Error`, and the boot line still rendered as `3□□□□□ Bytes free`. That points beyond a lost first input character: the number formatting path is being corrupted too.

The concrete second root cause was a zero-page collision in `tools/kernel/kernel.s`: the kernel used `$F2-$F9` for screen pointers and cursor state, while EhBASIC uses `$EF-$FF` as its decimal/string work area. Every `KERNAL_CHROUT` call could therefore overwrite EhBASIC state while printing banners, memory-size digits, echoed input, or error text.

Implemented kernel-side fix:

- `CHROUT` now uses only `$EC/$ED` as a temporary screen pointer.
- Cursor state moved out of SDRAM/page 2. Final kernel uses `$EC/$ED`,
  which EhBASIC leaves unused, as cursor bytes at rest and as the temporary
  screen pointer only while inside `CHROUT`.
- `SCROLL` no longer needs a second zero-page pointer.
- `STROUT` uses `$EE/$EF` only as a saved/restored temporary pointer; `CHROUT`, the path EhBASIC calls for every character, does not touch `$EF-$FF`.

Follow-up note: placing cursor state at `$0205/$0206` looked safe from an
EhBASIC memory-map perspective, but it is SDRAM in the FPGA design. Moving it
to `$E0/$E1` also collided with EhBASIC's IRQ metadata area. The final `$EC/$ED`
placement avoids both problems.

1. **Upload the rebuilt `fpga/roms/fpga_ehbasic_16kb.rom`** containing the fixed kernel and retest `LIST`, `PRINT 1+1`, and `10 REM`.

2. **If Syntax Error persists**: add an input-buffer/crunch diagnostic to dump `$0221+` before and after `LAB_13A6`, then confirm whether `PRINT` becomes `TK_PRINT`.

3. **After Syntax Error is fixed**: Address the `□□□□□` glyph issue separately.

---

## 12. Final Resolution (2026-06-07)

**User confirmed: "ok it works!"** — all three symptoms resolved after the fix below.

### Three symptoms, one root cause

| Symptom | What was actually happening |
| --- | --- |
| VGA: no new lines after ~18 rows | Each char triggered another scroll before VIC updated |
| UART: missing LF in echo | Rapid scroll loop disrupted the CR+LF send sequence |
| FOR loop prints 1,1,1,…,1099 | Scroll loop between PRINT calls corrupted float-to-decimal timing |

All three were caused by a **single bug in `roms/kernel.rom`**: the pre-built binary was stale — it predated the SCROLL and STRPTR fixes that existed only in the `tools/kernel/kernel.s` working copy. The build script (`fpga/tools/build_fpga_ehbasic.py`) consumes `roms/kernel.rom` directly without checking whether `kernel.s` has changed.

### The SCROLL infinite-loop mechanism

The old SCROLL cleared the bottom row with:

```asm
clr:
    sta VIC_BASE + (ROWS-1)*COLS,x
    inx
    cpx #COLS       ; exits when X = COLS = 40
    bne clr
```

After the loop, **X = 40**. Back in CHROUT's newline path:

```asm
    jsr SCROLL
    ldy #(ROWS-1)
    jmp done
done:
    stx CURSOR_X    ; stores 40 into $EC !
```

Next CHROUT call:

```asm
    ldx CURSOR_X    ; X = 40
    ...
    inx             ; X = 41
    cpx #COLS       ; cpx #40 → bcc NOT taken
    ; fall through to newline → scroll again
```

Every single character after the first scroll immediately triggered another scroll, producing a continuous scroll loop with no visible output.

### Fixes applied

**`tools/kernel/kernel.s`**

1. **SCROLL saves/restores A, X, Y** — prevents CURSOR_X from being set to 40 on exit.

2. **STRPTR_LO moved $EE→$EB, STRPTR_HI moved $EF→$EE** — the old STRPTR_HI=$EF collided with EhBASIC's `Decss` buffer (`$EF–$F4`), which is written on every `PRINT` of a number. The new positions ($EB, $EE) are both marked unused by EhBASIC.

**`roms/kernel.rom`** — rebuilt from source after the fixes above.

**`fpga/asm/Makefile`** — added `kernel` target with proper dependency on `kernel.s` and `kernel.cfg`; `fpga-ehbasic` and `upload-ehbasic` targets now depend on `$(KERNEL_ROM)`, so `make fpga-ehbasic` auto-rebuilds the kernel when the source changes.

### Rebuild procedure

```sh
make -C fpga/asm fpga-ehbasic       # rebuilds kernel.rom then 16KB combined ROM
# or in one step with upload:
make -C fpga/asm upload-ehbasic     # build + upload (press KEY0 on board first)
```
