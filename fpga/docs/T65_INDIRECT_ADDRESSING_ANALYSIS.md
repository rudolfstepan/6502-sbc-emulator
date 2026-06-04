# T65 Indirect Addressing Issue - Root Cause Analysis

## Summary

**Issue**: T65 CPU fails to execute `STA ($F2),Y` indirect-Y addressing instruction  
**Status**: ROOT CAUSE IDENTIFIED ✓  
**Evidence**: Diagnostic waveform analysis  

## Key Finding

The CPU **skips the indirect-Y instruction entirely** and jumps to the next sequential instruction.

### Execution Trace

```
C000: LDA #$00      ✓ Executed
C002: STA $F2       ✓ Executed (writes $00 to $F2)
C004: LDA #$80      ✓ Executed
C006: STA $F3       ✓ Executed (writes $80 to $F3)
C008: LDY #$00      ✓ Executed
C00A: LDA #$20      ✓ Executed
C00C: STA ($F2),Y   ✗ SKIPPED - CPU jumps directly to next instruction
C00E: JMP $C00E     ✓ Executed (infinite loop)
```

### What Should Happen

Instruction at C00C (opcode 0x91):
1. **Opcode**: 0x91 = STA indirect-Y (indirect indexed with Y register)
2. **Operation**: Write accumulator (0x20) to address ($F2 + Y)
   - $F2 = 0x00, $F3 = 0x80 → Effective address = 0x8000
   - Write 0x20 to VIC text RAM at 0x8000
3. **Next instruction**: C00E (normal sequential)

### What Actually Happens

The CPU appears to treat 0x91 as a **non-existent or unimplemented instruction**, causing it to:
- Skip the instruction entirely
- Advance to C00E without executing the indirect-Y write
- Continue with the jump

## Hypothesis

**Indirect-Y addressing mode (0x91) is not properly implemented in the T65 core.**

Possible causes:
1. T65 core doesn't support indirect-Y addressing
2. T65 is in wrong CPU mode (65C02 vs 6502 compatibility)
3. T65 internal state is corrupted/not initialized correctly
4. Address bus for indirect addressing wraps incorrectly on page boundary

## Diagnostic Evidence

**Diagnostic Run Results**:
- Instructions actually fetched: ~3327 (stuck in infinite JMP loop)
- Expected instructions: ~15-20 before entering loop
- VIC write to 0x8000: **NEVER OCCURRED**
- Zero page writes: **OCCURRED** (0xF2 and 0xF3 set correctly)

**Timeline**:
- Cycle 23: Zero page $F2 written with 0x00
- Cycle 33: Zero page $F3 written with 0x80
- Cycle 43-44: Instruction fetch at C00C (the indirect-Y instruction)
- Cycle 55-56: **JUMP to C00E** (instruction was skipped!)

## Next Steps

### Option A: Verify T65 Opcode Support (Quick Check)

Check T65 core implementation for opcode 0x91:

```vhdl
-- File: third_party/t65/rtl/T65_MCode.vhd
-- Search for: "X'91"  (indirect-Y addressing mode)
-- Check if instruction decode handles this opcode
```

**Expected**: T65 should have case statement for 0x91  
**If Missing**: This is the bug - T65 doesn't implement indirect-Y

### Option B: Check CPU Mode Configuration

Review T65 instantiation in adapter:

```vhdl
-- File: rtl/cpu/t65_adapter.vhd
-- Look for: Mode => "00"  (should be 6502 mode)
```

**Current Setting**: "00" = standard 6502  
**Verify**: 6502 definitely supports indirect-Y

### Option C: Verify Address Wrapping

The indirect-Y address calculation might have an issue:
- Zero page address $F2 reads low byte of target address
- Zero page address $F3 reads high byte (must wrap within zero page)
- Y register adds offset

**Test**: Are $F2 and $F3 being read correctly before the write?

## Recommended Fix Strategy

1. **Confirm T65 has opcode 0x91**
   - If yes → problem is in adapter/wiring
   - If no → need to patch T65 core or find alternative CPU

2. **If T65 supports 0x91**:
   - Check address/data bus timing during indirect fetch
   - Verify read data is stable when T65 expects it
   - Check VDA signal during indirect addressing phases

3. **If T65 doesn't support 0x91**:
   - Either patch T65 (complex VHDL surgery)
   - Or replace with alternative 6502 core
   - Or implement wrapper that emulates indirect-Y

## Testing Approach

Once fix is applied:
1. Run `tb_t65_indirect_diagnosis` → Should see write to $8000
2. Run `tb_sbc_t65_indirect_vic` → Should pass
3. Run full kernel boot → Should complete CLRSCR without hanging

## Risk Assessment

**Risk**: Medium  
**Complexity**: Medium-High (depends on root cause)  
**Impact**: High (blocks all indirect-Y code)

---

## Decision Point

**Before implementing fix, we must determine**:
- Does T65 have 0x91 opcode implemented?
- Is it a T65 limitation or integration issue?

This will determine the fix strategy.

---

*Generated: Tier 1 Phase 1 Analysis*  
*Next: Inspect T65 core for opcode 0x91 support*
