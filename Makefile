CC      = gcc
CFLAGS  = -std=c99 -Wall -Wextra -O2 -g $(shell pkg-config --cflags sdl2)
LDFLAGS = $(shell pkg-config --libs sdl2)
TARGET  = sbc6502
SRCDIR  = src
OBJDIR  = build

SRCS = $(wildcard $(SRCDIR)/*.c)
OBJS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))

.PHONY: all clean run check roms test-diskdir

all: $(TARGET)

$(OBJDIR):
	mkdir -p $(OBJDIR)

$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) -c $< -o $@

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)
	@echo "Built: $@"

clean:
	rm -rf $(OBJDIR) $(TARGET)

check: all test-diskdir

test-diskdir: $(OBJDIR)
	$(CC) -std=c99 -Wall -Wextra -O2 -g -I$(SRCDIR) tests/test_diskdev_dir.c src/bus.c src/sram.c src/diskdev.c -o $(OBJDIR)/test_diskdev_dir
	./$(OBJDIR)/test_diskdev_dir

roms:
	bash tools/make_kernel_rom.sh
	bash tools/make_msbasic_rom.sh

run: all
	./$(TARGET) sbc.ini

# Run with a ROM file directly
rom: all
	./$(TARGET) -r $(ROM) $(if $(SPEED),-s $(SPEED))
