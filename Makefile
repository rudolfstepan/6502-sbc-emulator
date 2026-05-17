CC      = gcc
CFLAGS  = -std=c99 -Wall -Wextra -O2 -g $(shell pkg-config --cflags sdl2)
LDFLAGS = $(shell pkg-config --libs sdl2) -lm
TARGET  = sbc6502
SRCDIR  = src
OBJDIR  = build

SRCS = $(wildcard $(SRCDIR)/*.c)
OBJS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))

.PHONY: all clean run check roms chess-rom test-chess-rom test-diskdir

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

check: all test-diskdir test-chess-rom

test-diskdir: $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) tests/test_diskdev_dir.c src/bus.c src/sram.c src/diskdev.c src/soundchip.c -o $(OBJDIR)/test_diskdev_dir $(LDFLAGS)
	./$(OBJDIR)/test_diskdev_dir

test-chess-rom: $(OBJDIR)
	bash tools/make_chess_rom.sh
	$(CC) $(CFLAGS) -I$(SRCDIR) tests/test_chess_rom.c src/bus.c src/cpu6502.c src/sram.c src/rom.c src/vic.c src/via6522.c src/soundchip.c -o $(OBJDIR)/test_chess_rom $(LDFLAGS)
	./$(OBJDIR)/test_chess_rom

roms:
	bash tools/make_kernel_rom.sh
	bash tools/make_msbasic_rom.sh
	bash tools/make_chess_rom.sh

chess-rom:
	bash tools/make_chess_rom.sh

run: all
	./$(TARGET) sbc.ini

# Run with a ROM file directly
rom: all
	./$(TARGET) -r $(ROM) $(if $(SPEED),-s $(SPEED))
