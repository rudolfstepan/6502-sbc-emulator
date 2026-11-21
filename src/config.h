#pragma once
#include <stdint.h>
#include <stdbool.h>

#define CFG_STR_MAX  256
#define CFG_PATH_MAX 1024
#define CFG_MAX_DEVS 8
#define DEFAULT_CPU_SPEED_HZ 27000000u
#define CFG_MAX_WINDOW_SCALE 25
#define C64_KEY_COUNT 65     /* 64 matrix keys plus RESTORE. */
#define C64_JOYSTICK_ACTIONS 5

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
    uint32_t rom_file_offset;          /* ROM only; used for split FPGA images */
    bool     has_rom_file_offset;
    char     uart_mode[32];  /* "stdio" or "tcp" */
    int      uart_port;      /* TCP mode */
    char     disk_path[CFG_STR_MAX];  /* DISK root path */
} DevConfig;

typedef struct {
    DevConfig devs[CFG_MAX_DEVS];
    int       num_devs;
    uint32_t  cpu_speed_hz;  /* 0 = unlimited */
    bool      cpu_speed_set;
    bool      debug;
    char      rom_file[CFG_STR_MAX]; /* shorthand */
    char      cpu_model[16];  /* "6502" or "65c02" */
    bool      trace;
    char      trace_file[CFG_STR_MAX];
    bool      profile;
    int       window_scale;
    bool      c64;
    bool      nes;
    bool      nes_sbc_cpu;
    char      nes_core[CFG_PATH_MAX];
    char      nes_rom_dir[CFG_PATH_MAX];
    char      nes_rom[CFG_PATH_MAX];
    char      nes_system_dir[CFG_PATH_MAX];
    char      c64_basic[CFG_STR_MAX];
    char      c64_kernal[CFG_STR_MAX];
    char      c64_chargen[CFG_STR_MAX];
    char      c64_floppy_image[CFG_STR_MAX];
    unsigned int c64_floppy_device;
    uint16_t c64_keys[C64_KEY_COUNT];       /* SDL scancodes, 0 uses the default. */
    uint16_t joystick_keys[C64_JOYSTICK_ACTIONS];
    uint16_t joystick_controls[C64_JOYSTICK_ACTIONS];
    unsigned int joystick_port;           /* 0 disables the joystick. */
} Config;

/* Parse INI file. Returns 0 on success, -1 if absent, -2 if invalid. */
int config_load(Config *cfg, const char *filename);
/* Fill in defaults for any unspecified fields */
void config_defaults(Config *cfg);
void config_dump(const Config *cfg);
/* Replace C64 settings in the active INI while preserving unrelated entries. */
int config_save_c64(const Config *cfg, const char *filename);
