# Makefile for Adventure SBC ROM

CA65 := ca65
LD65 := ld65
RM := rm -f

BUILD_DIR := build
MAIN_ASM := adventure.asm
CONFIG := adventure.cfg
OUTPUT := $(BUILD_DIR)/adventure.rom

all: $(OUTPUT)

$(OUTPUT): $(MAIN_ASM) $(CONFIG) | $(BUILD_DIR)
	$(CA65) $(MAIN_ASM) -o $(BUILD_DIR)/adventure.o
	$(LD65) -C $(CONFIG) -o $(OUTPUT) $(BUILD_DIR)/adventure.o

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	$(RM) $(BUILD_DIR)/*.o $(OUTPUT)

distclean: clean
	$(RM) -r $(BUILD_DIR)

.PHONY: all clean distclean
