#pragma once
#include <stdint.h>
#include <stddef.h>

#define BUS_MAX_DEVICES 16

typedef uint8_t (*bus_read_fn)(void *dev, uint16_t offset);
typedef void    (*bus_write_fn)(void *dev, uint16_t offset, uint8_t val);
typedef void    (*bus_tick_fn)(void *dev, uint32_t cycles);

typedef struct {
    void        *device;
    const char  *name;
    uint16_t     base;
    uint16_t     size;
    bus_read_fn  read;
    bus_write_fn write;
    bus_tick_fn  tick;   /* optional, may be NULL */
} BusDevice;

typedef struct {
    BusDevice devices[BUS_MAX_DEVICES];
    int       num_devices;
} Bus;

void    bus_init(Bus *bus);
void    bus_register(Bus *bus, const char *name, void *device,
                     uint16_t base, uint16_t size,
                     bus_read_fn read, bus_write_fn write,
                     bus_tick_fn tick);
uint8_t bus_read(Bus *bus, uint16_t addr);
void    bus_write(Bus *bus, uint16_t addr, uint8_t val);
void    bus_tick(Bus *bus, uint32_t cycles);
void    bus_dump(const Bus *bus);
void    bus_shutdown(void);
