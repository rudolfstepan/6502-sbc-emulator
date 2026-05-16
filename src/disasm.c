#include "disasm.h"
#include <stdio.h>
#include <string.h>

typedef enum {
    AM_IMP, AM_ACC, AM_IMM, AM_ZP,  AM_ZPX, AM_ZPY,
    AM_ABS, AM_ABX, AM_ABY, AM_IND, AM_IZX, AM_IZY, AM_REL
} AddrMode;

typedef struct { const char *mnem; AddrMode mode; } OpInfo;

static const OpInfo ops[256] = {
/*00*/ {"BRK",AM_IMP},{"ORA",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*04*/ {"???",AM_IMP},{"ORA",AM_ZP}, {"ASL",AM_ZP}, {"???",AM_IMP},
/*08*/ {"PHP",AM_IMP},{"ORA",AM_IMM},{"ASL",AM_ACC},{"???",AM_IMP},
/*0C*/ {"???",AM_IMP},{"ORA",AM_ABS},{"ASL",AM_ABS},{"???",AM_IMP},
/*10*/ {"BPL",AM_REL},{"ORA",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*14*/ {"???",AM_IMP},{"ORA",AM_ZPX},{"ASL",AM_ZPX},{"???",AM_IMP},
/*18*/ {"CLC",AM_IMP},{"ORA",AM_ABY},{"???",AM_IMP},{"???",AM_IMP},
/*1C*/ {"???",AM_IMP},{"ORA",AM_ABX},{"ASL",AM_ABX},{"???",AM_IMP},
/*20*/ {"JSR",AM_ABS},{"AND",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*24*/ {"BIT",AM_ZP}, {"AND",AM_ZP}, {"ROL",AM_ZP}, {"???",AM_IMP},
/*28*/ {"PLP",AM_IMP},{"AND",AM_IMM},{"ROL",AM_ACC},{"???",AM_IMP},
/*2C*/ {"BIT",AM_ABS},{"AND",AM_ABS},{"ROL",AM_ABS},{"???",AM_IMP},
/*30*/ {"BMI",AM_REL},{"AND",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*34*/ {"???",AM_IMP},{"AND",AM_ZPX},{"ROL",AM_ZPX},{"???",AM_IMP},
/*38*/ {"SEC",AM_IMP},{"AND",AM_ABY},{"???",AM_IMP},{"???",AM_IMP},
/*3C*/ {"???",AM_IMP},{"AND",AM_ABX},{"ROL",AM_ABX},{"???",AM_IMP},
/*40*/ {"RTI",AM_IMP},{"EOR",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*44*/ {"???",AM_IMP},{"EOR",AM_ZP}, {"LSR",AM_ZP}, {"???",AM_IMP},
/*48*/ {"PHA",AM_IMP},{"EOR",AM_IMM},{"LSR",AM_ACC},{"???",AM_IMP},
/*4C*/ {"JMP",AM_ABS},{"EOR",AM_ABS},{"LSR",AM_ABS},{"???",AM_IMP},
/*50*/ {"BVC",AM_REL},{"EOR",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*54*/ {"???",AM_IMP},{"EOR",AM_ZPX},{"LSR",AM_ZPX},{"???",AM_IMP},
/*58*/ {"CLI",AM_IMP},{"EOR",AM_ABY},{"???",AM_IMP},{"???",AM_IMP},
/*5C*/ {"???",AM_IMP},{"EOR",AM_ABX},{"LSR",AM_ABX},{"???",AM_IMP},
/*60*/ {"RTS",AM_IMP},{"ADC",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*64*/ {"???",AM_IMP},{"ADC",AM_ZP}, {"ROR",AM_ZP}, {"???",AM_IMP},
/*68*/ {"PLA",AM_IMP},{"ADC",AM_IMM},{"ROR",AM_ACC},{"???",AM_IMP},
/*6C*/ {"JMP",AM_IND},{"ADC",AM_ABS},{"ROR",AM_ABS},{"???",AM_IMP},
/*70*/ {"BVS",AM_REL},{"ADC",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*74*/ {"???",AM_IMP},{"ADC",AM_ZPX},{"ROR",AM_ZPX},{"???",AM_IMP},
/*78*/ {"SEI",AM_IMP},{"ADC",AM_ABY},{"???",AM_IMP},{"???",AM_IMP},
/*7C*/ {"???",AM_IMP},{"ADC",AM_ABX},{"ROR",AM_ABX},{"???",AM_IMP},
/*80*/ {"???",AM_IMP},{"STA",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*84*/ {"STY",AM_ZP}, {"STA",AM_ZP}, {"STX",AM_ZP}, {"???",AM_IMP},
/*88*/ {"DEY",AM_IMP},{"???",AM_IMP},{"TXA",AM_IMP},{"???",AM_IMP},
/*8C*/ {"STY",AM_ABS},{"STA",AM_ABS},{"STX",AM_ABS},{"???",AM_IMP},
/*90*/ {"BCC",AM_REL},{"STA",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*94*/ {"STY",AM_ZPX},{"STA",AM_ZPX},{"STX",AM_ZPY},{"???",AM_IMP},
/*98*/ {"TYA",AM_IMP},{"STA",AM_ABY},{"TXS",AM_IMP},{"???",AM_IMP},
/*9C*/ {"???",AM_IMP},{"STA",AM_ABX},{"???",AM_IMP},{"???",AM_IMP},
/*A0*/ {"LDY",AM_IMM},{"LDA",AM_IZX},{"LDX",AM_IMM},{"???",AM_IMP},
/*A4*/ {"LDY",AM_ZP}, {"LDA",AM_ZP}, {"LDX",AM_ZP}, {"???",AM_IMP},
/*A8*/ {"TAY",AM_IMP},{"LDA",AM_IMM},{"TAX",AM_IMP},{"???",AM_IMP},
/*AC*/ {"LDY",AM_ABS},{"LDA",AM_ABS},{"LDX",AM_ABS},{"???",AM_IMP},
/*B0*/ {"BCS",AM_REL},{"LDA",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*B4*/ {"LDY",AM_ZPX},{"LDA",AM_ZPX},{"LDX",AM_ZPY},{"???",AM_IMP},
/*B8*/ {"CLV",AM_IMP},{"LDA",AM_ABY},{"TSX",AM_IMP},{"???",AM_IMP},
/*BC*/ {"LDY",AM_ABX},{"LDA",AM_ABX},{"LDX",AM_ABY},{"???",AM_IMP},
/*C0*/ {"CPY",AM_IMM},{"CMP",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*C4*/ {"CPY",AM_ZP}, {"CMP",AM_ZP}, {"DEC",AM_ZP}, {"???",AM_IMP},
/*C8*/ {"INY",AM_IMP},{"CMP",AM_IMM},{"DEX",AM_IMP},{"???",AM_IMP},
/*CC*/ {"CPY",AM_ABS},{"CMP",AM_ABS},{"DEC",AM_ABS},{"???",AM_IMP},
/*D0*/ {"BNE",AM_REL},{"CMP",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*D4*/ {"???",AM_IMP},{"CMP",AM_ZPX},{"DEC",AM_ZPX},{"???",AM_IMP},
/*D8*/ {"CLD",AM_IMP},{"CMP",AM_ABY},{"???",AM_IMP},{"???",AM_IMP},
/*DC*/ {"???",AM_IMP},{"CMP",AM_ABX},{"DEC",AM_ABX},{"???",AM_IMP},
/*E0*/ {"CPX",AM_IMM},{"SBC",AM_IZX},{"???",AM_IMP},{"???",AM_IMP},
/*E4*/ {"CPX",AM_ZP}, {"SBC",AM_ZP}, {"INC",AM_ZP}, {"???",AM_IMP},
/*E8*/ {"INX",AM_IMP},{"SBC",AM_IMM},{"NOP",AM_IMP},{"???",AM_IMP},
/*EC*/ {"CPX",AM_ABS},{"SBC",AM_ABS},{"INC",AM_ABS},{"???",AM_IMP},
/*F0*/ {"BEQ",AM_REL},{"SBC",AM_IZY},{"???",AM_IMP},{"???",AM_IMP},
/*F4*/ {"???",AM_IMP},{"SBC",AM_ZPX},{"INC",AM_ZPX},{"???",AM_IMP},
/*F8*/ {"SED",AM_IMP},{"SBC",AM_ABY},{"???",AM_IMP},{"???",AM_IMP},
/*FC*/ {"???",AM_IMP},{"SBC",AM_ABX},{"INC",AM_ABX},{"???",AM_IMP},
};

int disasm(uint16_t addr,
           uint8_t (*read_fn)(void *ctx, uint16_t addr),
           void    *ctx,
           char    *buf, int buf_size)
{
    uint8_t op  = read_fn(ctx, addr);
    uint8_t b1  = read_fn(ctx, (uint16_t)(addr + 1));
    uint8_t b2  = read_fn(ctx, (uint16_t)(addr + 2));

    const OpInfo *info = &ops[op];
    int len = 1;
    char operand[32] = "";

    switch (info->mode) {
    case AM_IMP: len=1; break;
    case AM_ACC: len=1; snprintf(operand,sizeof(operand),"A");              break;
    case AM_IMM: len=2; snprintf(operand,sizeof(operand),"#$%02X",b1);     break;
    case AM_ZP:  len=2; snprintf(operand,sizeof(operand),"$%02X",b1);      break;
    case AM_ZPX: len=2; snprintf(operand,sizeof(operand),"$%02X,X",b1);    break;
    case AM_ZPY: len=2; snprintf(operand,sizeof(operand),"$%02X,Y",b1);    break;
    case AM_ABS: len=3; snprintf(operand,sizeof(operand),"$%04X",
                                 (uint16_t)(b1|(b2<<8)));                   break;
    case AM_ABX: len=3; snprintf(operand,sizeof(operand),"$%04X,X",
                                 (uint16_t)(b1|(b2<<8)));                   break;
    case AM_ABY: len=3; snprintf(operand,sizeof(operand),"$%04X,Y",
                                 (uint16_t)(b1|(b2<<8)));                   break;
    case AM_IND: len=3; snprintf(operand,sizeof(operand),"($%04X)",
                                 (uint16_t)(b1|(b2<<8)));                   break;
    case AM_IZX: len=2; snprintf(operand,sizeof(operand),"($%02X,X)",b1);  break;
    case AM_IZY: len=2; snprintf(operand,sizeof(operand),"($%02X),Y",b1);  break;
    case AM_REL: {
        len=2;
        int16_t off = (int8_t)b1;
        uint16_t target = (uint16_t)(addr + 2 + off);
        snprintf(operand,sizeof(operand),"$%04X",target);
        break;
    }
    }

    /* Raw bytes */
    char raw[12] = "";
    switch (len) {
    case 1: snprintf(raw,sizeof(raw),"%02X      ",op);         break;
    case 2: snprintf(raw,sizeof(raw),"%02X %02X   ",op,b1);   break;
    case 3: snprintf(raw,sizeof(raw),"%02X %02X %02X",op,b1,b2); break;
    }

    snprintf(buf, (size_t)buf_size, "%04X  %s  %-3s %s",
             addr, raw, info->mnem, operand);
    return len;
}
