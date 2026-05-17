#ifndef SOUNDCHIP_H
#define SOUNDCHIP_H

#include <stdint.h>

void soundchip_init();
void soundchip_beep(float frequency, int duration_ms);
void soundchip_shutdown();

uint8_t soundchip_bus_read(void *dev, uint16_t offset);
void soundchip_bus_write(void *dev, uint16_t offset, uint8_t val);

#endif // SOUNDCHIP_H