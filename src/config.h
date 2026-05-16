#pragma once
#include <stdint.h>
#include <stdbool.h>

#define CFG_STR_MAX  256
#define CFG_MAX_DEVS 8

typedef enum {
    DEV_SRAM,
    DEV_ROM,
    DEV_VIA,
    DEV_UART,
    DEV_DISK,
} DevType;

typedef struct {
    DevType  type;
    uint16_t base;
    uint32_t size;           /* SRAM/ROM only */
    char     rom_file[CFG_STR_MAX];   /* ROM only */
    char     uart_mode[32];  /* "stdio" or "tcp" */
    int      uart_port;      /* TCP mode */
    char     disk_path[CFG_STR_MAX];  /* DISK root path */
} DevConfig;

typedef struct {
    DevConfig devs[CFG_MAX_DEVS];
    int       num_devs;
    uint32_t  cpu_speed_hz;  /* 0 = unlimited */
    bool      debug;
    char      rom_file[CFG_STR_MAX]; /* shorthand */
} Config;

/* Parse INI file. Returns 0 on success, -1 on error. */
int config_load(Config *cfg, const char *filename);
/* Fill in defaults for any unspecified fields */
void config_defaults(Config *cfg);
void config_dump(const Config *cfg);
