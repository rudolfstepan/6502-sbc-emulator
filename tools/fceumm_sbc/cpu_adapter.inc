/* Included by FCEUmm's x6502.c. Its scheduler remains responsible for frame
 * timing, interrupt delivery, DMA and refresh of the mapper and APU. */
#include "bus.h"
#include "cpu6502.h"
#include "disasm.h"

static struct {
    CPU6502 cpu;
    Bus bus;
    uint8_t fetched_opcode;
    bool opcode_pending;
    int indexed_read_cycles;
} sbc_adapter;

static uint8_t sbc_read(void *context, uint16_t address)
{
    (void)context;
    /* The scheduler already fetched the instruction and updated open bus. */
    if (sbc_adapter.opcode_pending) {
        sbc_adapter.opcode_pending = false;
        return sbc_adapter.fetched_opcode;
    }
    return RdMemNorm(address);
}

static void sbc_write(void *context, uint16_t address, uint8_t value)
{
    (void)context;
    WrMemNorm(address, value);
}

static uint8_t sbc_bus_read(void *context, uint16_t address)
{
    return bus_read(context, address);
}

static void sbc_bus_write(void *context, uint16_t address, uint8_t value)
{
    bus_write(context, address, value);
}

static void sbc_clock_indexed_read(void *context)
{
    (void)context;
    ADDCYC(1);
    sbc_adapter.indexed_read_cycles++;
}

static void sbc_cpu_power(void)
{
    bus_init(&sbc_adapter.bus);
    /* FCEUmm's dynamically installed handlers own the actual NES address map. */
    bus_register(&sbc_adapter.bus, "NES address space", NULL, 0, 0x10000u,
                 sbc_read, sbc_write, NULL);
    cpu6502_init(&sbc_adapter.cpu, sbc_bus_read, sbc_bus_write, &sbc_adapter.bus);
    sbc_adapter.cpu.mode = CPU_MODEL_2A03;
    sbc_adapter.cpu.clock_indexed_read = sbc_clock_indexed_read;
}

static int sbc_cpu_step(uint16_t pc, uint8_t opcode)
{
    CPU6502 *cpu = &sbc_adapter.cpu;

    /* The surrounding core owns the serialized register state and also changes
     * it for interrupts and undocumented instructions between these steps. */
    cpu->PC = pc;
    cpu->A = X.A;
    cpu->X = X.X;
    cpu->Y = X.Y;
    cpu->SP = X.S;
    cpu->P = X.P;
    sbc_adapter.fetched_opcode = opcode;
    sbc_adapter.opcode_pending = true;
    sbc_adapter.indexed_read_cycles = 0;

    int cycles = cpu6502_step(cpu);

    X.A = cpu->A;
    X.X = cpu->X;
    X.Y = cpu->Y;
    X.S = cpu->SP;
    X.P = cpu->P;
    /* FCEUmm polls IRQs with the saved I flag. BRK and RTI update that
     * latch directly, while ordinary instructions keep its delayed value. */
    if (opcode == 0x00) X.mooPI |= I_FLAG;
    if (opcode == 0x40) X.mooPI = X.P;

    /* The extra indexed read cycle has already advanced the host timestamp. */
    return cycles - sbc_adapter.indexed_read_cycles;
}
