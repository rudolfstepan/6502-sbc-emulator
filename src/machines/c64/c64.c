#include "c64.h"
#include "c64_vic.h"

#include <stdio.h>
#include <string.h>

#define CPU_PORT_LORAM  0x01u
#define CPU_PORT_HIRAM  0x02u
#define CPU_PORT_CHAREN 0x04u
#define CPU_PORT_PULLUPS 0x17u

static bool load_rom(const char *path, const char *name, uint8_t *bytes, size_t size)
{
    if (!path[0]) {
        fprintf(stderr, "C64: set [machine] %s to the %zu-byte ROM file\n", name, size);
        return false;
    }

    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "C64: cannot open %s ROM '%s'\n", name, path);
        return false;
    }

    size_t count = fread(bytes, 1, size, file);
    bool valid = count == size && fgetc(file) == EOF && !ferror(file);
    fclose(file);
    if (!valid) {
        fprintf(stderr, "C64: expected exactly %zu bytes in %s ROM '%s'\n", size, name, path);
        return false;
    }
    printf("C64: loaded %s ROM '%s' (%zu bytes)\n", name, path, size);
    return true;
}

bool c64_init(C64 *c64, const char *basic, const char *kernal, const char *chargen)
{
    memset(c64, 0, sizeof(*c64));
    if (!load_rom(basic, "basic", c64->basic, sizeof(c64->basic)) ||
        !load_rom(kernal, "kernal", c64->kernal, sizeof(c64->kernal)) ||
        !load_rom(chargen, "chargen", c64->chargen, sizeof(c64->chargen))) {
        return false;
    }

    cia_init_native(&c64->cia1);
    cia_init_native(&c64->cia2);
    sid_init(&c64->sid);
    return true;
}

static uint8_t cpu_port_pins(const C64 *c64)
{
    return (c64->cpu_port_data & c64->cpu_port_direction) |
           (CPU_PORT_PULLUPS & ~c64->cpu_port_direction);
}

static bool io_visible(uint8_t pins)
{
    return (pins & (CPU_PORT_LORAM | CPU_PORT_HIRAM)) && (pins & CPU_PORT_CHAREN);
}

static uint8_t cia_port(const CIA6526 *cia, unsigned int port, uint8_t inputs)
{
    uint8_t direction = cia->regs[port + 2];
    return (cia->regs[port] & direction) | (inputs & ~direction);
}

static uint8_t keyboard_port(const C64 *c64, unsigned int port)
{
    uint8_t selected = (uint8_t)~cia_port(&c64->cia1, port ^ 1u, 0xFF);
    selected |= c64->joystick[port];
    uint8_t inputs = 0xFF;
    for (unsigned int col = 0; col < 8; col++) {
        if (port == 0 && (c64->keyboard[col] & selected)) {
            inputs &= (uint8_t)~(1u << col);
        } else if (port == 1 && (selected & (1u << col))) {
            inputs &= (uint8_t)~c64->keyboard[col];
        }
    }
    return cia_port(&c64->cia1, port, inputs) & (uint8_t)~c64->joystick[port ^ 1u];
}

static uint8_t io_read(C64 *c64, uint16_t addr)
{
    if (addr < 0xD400) {
        return c64_vic_read(c64, addr & 0x3F);
    }
    if (addr < 0xD800) {
        unsigned int reg = addr & 0x1F;
        return sid_read(&c64->sid, reg);
    }
    if (addr < 0xDC00) {
        return 0xF0 | c64->color_ram[addr & 0x3FF];
    }
    unsigned int reg = addr & 0x0F;
    if (addr < 0xDD00) {
        return reg < 2 ? keyboard_port(c64, reg) : cia_read(&c64->cia1, reg);
    }
    if (addr < 0xDE00) {
        return reg < 2 ? cia_port(&c64->cia2, reg, 0xFF) : cia_read(&c64->cia2, reg);
    }
    return 0xFF;
}

static void io_write(C64 *c64, uint16_t addr, uint8_t value)
{
    if (addr < 0xD400) {
        c64_vic_write(c64, addr & 0x3F, value);
    } else if (addr < 0xD800) {
        unsigned int reg = addr & 0x1F;
        sid_write(&c64->sid, reg, value);
    } else if (addr < 0xDC00) {
        c64->color_ram[addr & 0x3FF] = value & 0x0F;
    } else if (addr < 0xDD00) {
        cia_write(&c64->cia1, addr, value);
    } else if (addr < 0xDE00) {
        cia_write(&c64->cia2, addr, value);
    }
}

uint8_t c64_read(void *machine, uint16_t addr)
{
    C64 *c64 = machine;
    uint8_t pins = cpu_port_pins(c64);
    uint8_t rom_pins = pins & (CPU_PORT_LORAM | CPU_PORT_HIRAM);

    if (addr == 0) {
        return c64->cpu_port_direction;
    }
    if (addr == 1) {
        return pins;
    }
    if (addr >= 0xE000 && (pins & CPU_PORT_HIRAM)) {
        return c64->kernal[addr - 0xE000];
    }
    if (addr >= 0xD000 && addr < 0xE000 && rom_pins) {
        return io_visible(pins) ? io_read(c64, addr) : c64->chargen[addr - 0xD000];
    }
    if (addr >= 0xA000 && addr < 0xC000 && rom_pins == (CPU_PORT_LORAM | CPU_PORT_HIRAM)) {
        return c64->basic[addr - 0xA000];
    }
    return c64->ram[addr];
}

void c64_write(void *machine, uint16_t addr, uint8_t value)
{
    C64 *c64 = machine;
    if (addr == 0) {
        c64->cpu_port_direction = value;
    } else if (addr == 1) {
        c64->cpu_port_data = value;
    } else if (addr >= 0xD000 && addr < 0xE000 && io_visible(cpu_port_pins(c64))) {
        io_write(c64, addr, value);
    } else {
        c64->ram[addr] = value;
    }
}

void c64_tick(void *machine, uint32_t cycles)
{
    C64 *c64 = machine;
    cia_tick(&c64->cia1, cycles);
    cia_tick(&c64->cia2, cycles);
    sid_tick(&c64->sid, cycles);

    c64_vic_tick(c64, cycles);
}

bool c64_irq(const C64 *c64)
{
    return cia_irq(&c64->cia1) || c64_vic_irq(c64);
}

bool c64_nmi(const C64 *c64)
{
    return c64->restore_pressed || cia_irq(&c64->cia2);
}

void c64_set_key(C64 *c64, unsigned int index)
{
    if (index < 64) {
        c64->keyboard[index / 8] |= 1u << (index % 8);
    }
}

void c64_clear_keys(C64 *c64)
{
    memset(c64->keyboard, 0, sizeof(c64->keyboard));
}

uint16_t c64_video_bank(const C64 *c64)
{
    return (uint16_t)((~cia_port(&c64->cia2, 0, 0xFF) & 0x03) << 14);
}

uint8_t c64_video_read(const C64 *c64, uint16_t addr)
{
    if ((addr & 0x7000) == 0x1000) {
        return c64->chargen[addr & 0x0FFF];
    }
    return c64->ram[addr];
}
