#include "bus.h"
#include <stdio.h>
#include <string.h>

void bus_init(Bus *bus)
{
    memset(bus, 0, sizeof(*bus));
}

void bus_register(Bus *bus, const char *name, void *device,
                  uint16_t base, uint16_t size,
                  bus_read_fn read, bus_write_fn write,
                  bus_tick_fn tick)
{
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
}

uint8_t bus_read(Bus *bus, uint16_t addr)
{
    for (int i = 0; i < bus->num_devices; i++) {
        BusDevice *d = &bus->devices[i];
        if (addr >= d->base && addr < (uint32_t)(d->base + d->size)) {
            if (d->read)
                return d->read(d->device, (uint16_t)(addr - d->base));
            return 0xFF;
        }
    }
    /* open bus: return 0xFF */
    return 0xFF;
}

void bus_write(Bus *bus, uint16_t addr, uint8_t val)
{
    for (int i = 0; i < bus->num_devices; i++) {
        BusDevice *d = &bus->devices[i];
        if (addr >= d->base && addr < (uint32_t)(d->base + d->size)) {
            if (d->write)
                d->write(d->device, (uint16_t)(addr - d->base), val);
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
