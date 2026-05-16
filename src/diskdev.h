#pragma once
#include <stdint.h>
#include "bus.h"

#define DISK_REG_CMD      0x00
#define DISK_REG_STATUS   0x01
#define DISK_REG_ADDR_LO  0x02
#define DISK_REG_ADDR_HI  0x03
#define DISK_REG_LEN_LO   0x04
#define DISK_REG_LEN_HI   0x05
#define DISK_REG_ACT_LO   0x06
#define DISK_REG_ACT_HI   0x07
#define DISK_REG_ERR      0x08

#define DISK_CMD_NONE     0x00
#define DISK_CMD_SAVE     0x01
#define DISK_CMD_LOAD     0x02

#define DISK_ST_BUSY      0x01
#define DISK_ST_OK        0x02
#define DISK_ST_ERR       0x04
#define DISK_ST_EOF       0x08

typedef struct {
    Bus      *bus;
    char      root_path[256];
    uint16_t  addr;
    uint16_t  len;
    uint16_t  actual;
    uint8_t   status;
    uint8_t   err;
} DiskDev;

int     diskdev_init(DiskDev *d, Bus *bus, const char *root_path);
uint8_t diskdev_read(void *dev, uint16_t offset);
void    diskdev_write(void *dev, uint16_t offset, uint8_t val);
