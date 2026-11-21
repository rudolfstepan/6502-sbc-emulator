#include "cpu6502.h"
#include "disasm.h"

#include <assert.h>
#include <stdio.h>

typedef struct {
    uint16_t address;
    uint8_t value;
    bool write;
} Access;

typedef struct {
    uint8_t memory[65536];
    Access accesses[16];
    size_t count;
    size_t indexed_read_ticks;
} Fixture;

static uint8_t read_byte(void *context, uint16_t address)
{
    Fixture *fixture = context;
    assert(fixture->count < sizeof(fixture->accesses) / sizeof(fixture->accesses[0]));
    uint8_t value = fixture->memory[address];
    fixture->accesses[fixture->count++] = (Access){address, value, false};
    return value;
}

static void write_byte(void *context, uint16_t address, uint8_t value)
{
    Fixture *fixture = context;
    assert(fixture->count < sizeof(fixture->accesses) / sizeof(fixture->accesses[0]));
    fixture->accesses[fixture->count++] = (Access){address, value, true};
    fixture->memory[address] = value;
}

static void init(CPU6502 *cpu, Fixture *fixture, CPUModel model)
{
    cpu6502_init(cpu, read_byte, write_byte, fixture);
    cpu->mode = model;
    cpu->PC = 0x8000;
}

static void clock_indexed_read(void *context)
{
    Fixture *fixture = context;
    assert(fixture->count == 4 && fixture->accesses[3].address == 0x2002);
    fixture->indexed_read_ticks++;
}

static void expect_access(const Fixture *fixture, size_t index, uint16_t address,
                          uint8_t value, bool write)
{
    assert(index < fixture->count);
    const Access *access = &fixture->accesses[index];
    assert(access->address == address && access->value == value && access->write == write);
}

static void check_decimal_flag(CPUModel model, uint8_t sum, uint8_t difference)
{
    Fixture fixture = {.memory = {[0x8000] = 0xF8, 0x69, 0x01, 0xE9, 0x01}};
    CPU6502 cpu;
    init(&cpu, &fixture, model);
    cpu.A = 0x09;

    assert(cpu6502_step(&cpu) == 2); /* SED */
    assert(cpu6502_step(&cpu) == 2); /* ADC #$01 */
    assert(cpu.A == sum && (cpu.P & FLAG_D));

    cpu.A = 0x10;
    cpu.P |= FLAG_C;
    assert(cpu6502_step(&cpu) == 2); /* SBC #$01 */
    assert(cpu.A == difference && (cpu.P & FLAG_D));
}

static void check_indexed_read(void)
{
    Fixture fixture = {.memory = {[0x8000] = 0xBD, 0xFF, 0x20,
                                  [0x2002] = 0x80, [0x2102] = 0x12}};
    CPU6502 cpu;
    init(&cpu, &fixture, CPU_MODEL_2A03);
    cpu.X = 3;
    cpu.clock_indexed_read = clock_indexed_read;

    assert(cpu6502_step(&cpu) == 5);
    assert(cpu.A == 0x12 && fixture.count == 5 && fixture.indexed_read_ticks == 1);
    expect_access(&fixture, 3, 0x2002, 0x80, false);
    expect_access(&fixture, 4, 0x2102, 0x12, false);

    fixture.count = 0;
    init(&cpu, &fixture, CPU_MODEL_6502);
    cpu.X = 3;
    assert(cpu6502_step(&cpu) == 5);
    assert(cpu.A == 0x12 && fixture.count == 4);
    expect_access(&fixture, 3, 0x2102, 0x12, false);
}

static void check_indirect_indexed_store(void)
{
    Fixture fixture = {.memory = {[0x8000] = 0x91, 0xFF,
                                  [0x00FF] = 0x10, [0x0000] = 0x20}};
    CPU6502 cpu;
    init(&cpu, &fixture, CPU_MODEL_2A03);
    cpu.Y = 3;
    cpu.A = 0x34;

    assert(cpu6502_step(&cpu) == 6 && fixture.count == 6);
    expect_access(&fixture, 2, 0x00FF, 0x10, false);
    expect_access(&fixture, 3, 0x0000, 0x20, false);
    expect_access(&fixture, 4, 0x2013, 0x00, false);
    expect_access(&fixture, 5, 0x2013, 0x34, true);
}

static void check_indexed_rmw(void)
{
    Fixture fixture = {.memory = {[0x8000] = 0xFE, 0xFF, 0x20, [0x2102] = 0x12}};
    CPU6502 cpu;
    init(&cpu, &fixture, CPU_MODEL_2A03);
    cpu.X = 3;

    assert(cpu6502_step(&cpu) == 7 && fixture.count == 7);
    expect_access(&fixture, 3, 0x2002, 0x00, false);
    expect_access(&fixture, 4, 0x2102, 0x12, false);
    expect_access(&fixture, 5, 0x2102, 0x12, true);
    expect_access(&fixture, 6, 0x2102, 0x13, true);
}

static void check_jsr_bus_order(void)
{
    Fixture fixture = {.memory = {[0x8000] = 0x20, 0x12, 0x34}};
    CPU6502 cpu;
    init(&cpu, &fixture, CPU_MODEL_2A03);
    cpu.SP = 0xFD;

    assert(cpu6502_step(&cpu) == 6 && fixture.count == 6);
    assert(cpu.PC == 0x3412 && cpu.SP == 0xFB);
    expect_access(&fixture, 1, 0x8001, 0x12, false);
    expect_access(&fixture, 2, 0x01FD, 0x00, false);
    expect_access(&fixture, 3, 0x01FD, 0x80, true);
    expect_access(&fixture, 4, 0x01FC, 0x02, true);
    expect_access(&fixture, 5, 0x8002, 0x34, false);
}

int main(void)
{
    check_decimal_flag(CPU_MODEL_2A03, 0x0A, 0x0F);
    check_decimal_flag(CPU_MODEL_6502, 0x10, 0x09);
    check_indexed_read();
    check_indirect_indexed_store();
    check_indexed_rmw();
    check_jsr_bus_order();
    assert(disasm_is_official_6502_opcode(0xBD)); /* LDA abs,X */
    assert(!disasm_is_official_6502_opcode(0xA7)); /* LAX zp */
    puts("test_2a03: decimal flag and CPU bus access order passed");
    return 0;
}
