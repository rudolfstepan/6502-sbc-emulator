CC      = gcc
CFLAGS  = -std=c99 -Wall -Wextra -O2 -g $(shell pkg-config --cflags sdl2)
LDFLAGS = $(shell pkg-config --libs sdl2) -lm
TARGET  = sbc6502
SRCDIR  = src
OBJDIR  = build
KLAUS_BIN = $(OBJDIR)/klaus/6502_functional_test.bin
KLAUS_URL = https://raw.githubusercontent.com/Klaus2m5/6502_65C02_functional_tests/master/bin_files/6502_functional_test.bin

SRCS = $(wildcard $(SRCDIR)/*.c)
OBJS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))

.PHONY: all clean run check roms chess-rom test-chess-rom test-diskdir test-peek-poke test-klaus-6502

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

check: all test-diskdir test-chess-rom test-peek-poke test-klaus-6502

$(KLAUS_BIN):
	mkdir -p $(dir $@)
	curl -fsSL $(KLAUS_URL) -o $@

test-diskdir: $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) tests/test_diskdev_dir.c src/bus.c src/sram.c src/diskdev.c src/soundchip.c -o $(OBJDIR)/test_diskdev_dir $(LDFLAGS)
	./$(OBJDIR)/test_diskdev_dir

test-chess-rom: $(OBJDIR)
	bash tools/make_chess_rom.sh
	$(CC) $(CFLAGS) -I$(SRCDIR) tests/test_chess_rom.c src/bus.c src/cpu6502.c src/sram.c src/rom.c src/vic.c src/via6522.c src/soundchip.c -o $(OBJDIR)/test_chess_rom $(LDFLAGS)
	./$(OBJDIR)/test_chess_rom

test-peek-poke: $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) tests/test_peek_poke_addrs.c src/bus.c src/sram.c src/vic.c src/via6522.c src/diskdev.c src/soundchip.c -o $(OBJDIR)/test_peek_poke_addrs $(LDFLAGS)
	./$(OBJDIR)/test_peek_poke_addrs

test-klaus-6502: $(OBJDIR) $(KLAUS_BIN)
	$(CC) $(CFLAGS) -I$(SRCDIR) tests/test_klaus_6502.c src/cpu6502.c -o $(OBJDIR)/test_klaus_6502 $(LDFLAGS)
	./$(OBJDIR)/test_klaus_6502

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
