#pragma once

#include <stdbool.h>
#include <stddef.h>

typedef struct {
    void *data;
    size_t size;
    char *name;
    char *archive_path;
} NesContent;

bool nes_content_load(NesContent *content, const char *path);
void nes_content_free(NesContent *content);
unsigned long nes_content_checksum(const NesContent *content);
bool nes_save_write(const char *path, const void *data, size_t size);
