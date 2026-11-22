#pragma once

#include <stdbool.h>
#include <stdint.h>

#define APPLE2_DISK_ROM_SIZE 256

typedef struct {
    uint8_t rom[APPLE2_DISK_ROM_SIZE];
    uint8_t *tracks;
    unsigned half_track;
    unsigned position;
    unsigned rotation_cycles;
    unsigned coast_cycles;
    uint8_t phases;
    uint8_t latch;
    bool motor;
    bool drive_two;
    bool q6;
    bool q7;
} Apple2Disk;

bool apple2_disk_mount(Apple2Disk *disk, const char *path);
void apple2_disk_eject(Apple2Disk *disk);
void apple2_disk_reset(Apple2Disk *disk);
void apple2_disk_tick(Apple2Disk *disk, unsigned cycles);
uint8_t apple2_disk_switch(Apple2Disk *disk, unsigned address);
