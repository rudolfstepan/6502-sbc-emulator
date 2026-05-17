CC      = gcc
CFLAGS  = -std=c99 -Wall -Wextra -O2 -g $(shell pkg-config --cflags sdl2)
LDFLAGS = $(shell pkg-config --libs sdl2)
TARGET  = sbc6502
SRCDIR  = src
OBJDIR  = build

SRCS = $(wildcard $(SRCDIR)/*.c)
OBJS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))

.PHONY: all clean run check roms

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

check: all

roms:
	bash tools/make_kernel_rom.sh
	bash tools/make_msbasic_rom.sh

run: all
	./$(TARGET) sbc.ini

# Run with a ROM file directly
rom: all
	./$(TARGET) -r $(ROM) $(if $(SPEED),-s $(SPEED))
