#include "bus.h"
#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t *data;
    uint32_t size;
} BusLinearMem;

static int bus_addr_in_device(const BusDevice *d, uint16_t addr)
{
    uint32_t start = d->base;
    uint32_t end = start + d->size;
    return addr >= start && addr < end;
}

static void bus_configure_linear_fastpath(BusDevice *d)
{
    d->linear_data = NULL;
    d->linear_flags = 0;

    if (d->device == NULL) {
        return;
    }

    if (d->name && strcmp(d->name, "SRAM") == 0) {
        BusLinearMem *ram = (BusLinearMem *)d->device;
        d->linear_data = ram->data;
        d->linear_flags = BUS_LINEAR_WRITABLE;
        return;
    }

    if (d->name && strcmp(d->name, "ROM") == 0) {
        BusLinearMem *rom = (BusLinearMem *)d->device;
        d->linear_data = rom->data;
        return;
    }
}

void bus_init(Bus *bus)
{
    memset(bus, 0, sizeof(*bus));
}

void bus_register(Bus *bus, const char *name, void *device,
                  uint16_t base, uint16_t size,
                  bus_read_fn read, bus_write_fn write,
                  bus_tick_fn tick)
{
    if (size == 0) {
        fprintf(stderr, "bus: refusing zero-sized device '%s'\n", name ? name : "?");
        return;
    }

    if (bus->num_devices >= BUS_MAX_DEVICES) {
        fprintf(stderr, "bus: too many devices (max %d)\n", BUS_MAX_DEVICES);
        return;
    }

    BusDevice *d = &bus->devices[bus->num_devices++];
    d->device = device;
    d->name   = name;
    d->base   = base;
    d->size   = size;
    d->read   = read;
    d->write  = write;
    d->tick   = tick;

    bus_configure_linear_fastpath(d);

    {
        uint16_t end_addr = (uint16_t)(base + size - 1u);
        uint16_t start_page = (uint16_t)(base >> 8);
        uint16_t end_page = (uint16_t)(end_addr >> 8);

        for (uint16_t page = start_page; page <= end_page; page++) {
            BusDevice *mapped = bus->page_map[page];
            if (mapped == NULL) {
                bus->page_map[page] = d;
            } else if (mapped != d) {
                /* Overlap on this page: keep correctness via linear fallback. */
                bus->page_map[page] = NULL;
            }
        }
    }
}

uint8_t bus_read(Bus *bus, uint16_t addr)
{
    BusDevice *fast = bus->page_map[addr >> 8];
    if (fast && bus_addr_in_device(fast, addr)) {
        uint16_t offset = (uint16_t)(addr - fast->base);
        if (fast->linear_data) {
            return fast->linear_data[offset];
        }
        if (fast->read)
            return fast->read(fast->device, offset);
        return 0xFF;
    }

    for (int i = 0; i < bus->num_devices; i++) {
        BusDevice *d = &bus->devices[i];
        if (bus_addr_in_device(d, addr)) {
            uint16_t offset = (uint16_t)(addr - d->base);
            if (d->linear_data) {
                return d->linear_data[offset];
            }
            if (d->read)
                return d->read(d->device, offset);
            return 0xFF;
        }
    }
    /* open bus: return 0xFF */
    return 0xFF;
}

void bus_write(Bus *bus, uint16_t addr, uint8_t val)
{
    BusDevice *fast = bus->page_map[addr >> 8];
    if (fast && bus_addr_in_device(fast, addr)) {
        uint16_t offset = (uint16_t)(addr - fast->base);
        if (fast->linear_data) {
            if (fast->linear_flags & BUS_LINEAR_WRITABLE) {
                fast->linear_data[offset] = val;
            }
            return;
        }
        if (fast->write)
            fast->write(fast->device, offset, val);
        return;
    }

    for (int i = 0; i < bus->num_devices; i++) {
        BusDevice *d = &bus->devices[i];
        if (bus_addr_in_device(d, addr)) {
            uint16_t offset = (uint16_t)(addr - d->base);
            if (d->linear_data) {
                if (d->linear_flags & BUS_LINEAR_WRITABLE) {
                    d->linear_data[offset] = val;
                }
                return;
            }
            if (d->write)
                d->write(d->device, offset, val);
            return;
        }
    }
}

void bus_tick(Bus *bus, uint32_t cycles)
{
    for (int i = 0; i < bus->num_devices; i++) {
        if (bus->devices[i].tick)
            bus->devices[i].tick(bus->devices[i].device, cycles);
    }
}

void bus_dump(const Bus *bus)
{
    printf("Bus map (%d device(s)):\n", bus->num_devices);
    for (int i = 0; i < bus->num_devices; i++) {
        const BusDevice *d = &bus->devices[i];
        printf("  %-12s $%04X - $%04X  (%u bytes)\n",
               d->name ? d->name : "?",
               d->base, (unsigned)(d->base + d->size - 1), d->size);
    }
}

void bus_shutdown() {
}
