CC      ?= gcc

ifeq ($(OS),Windows_NT)
SHELL       := cmd
.SHELLFLAGS := /C
EXEEXT      = .exe
PATH        := C:/tools/cc65/bin;C:/msys64/mingw64/bin;C:/msys64/usr/bin;$(PATH)
export PATH
SDL2_DLL        ?= C:/msys64/mingw64/bin/SDL2.dll
WINPTHREAD_DLL  ?= C:/msys64/mingw64/bin/libwinpthread-1.dll
LIBGCC_DLL      ?= C:/msys64/mingw64/bin/libgcc_s_seh-1.dll
COPY_IF_EXISTS   = if exist "$(subst /,\,$1)" copy /Y "$(subst /,\,$1)" "$(subst /,\,$2)" >NUL
ifneq ($(wildcard C:/msys64/mingw64/bin/gcc.exe),)
CC := C:/msys64/mingw64/bin/gcc.exe
endif
SDL2_CFLAGS ?= $(shell where pkg-config >NUL 2>NUL && pkg-config --cflags sdl2)
SDL2_LIBS   ?= $(shell where pkg-config >NUL 2>NUL && pkg-config --libs sdl2)
ifeq ($(strip $(SDL2_CFLAGS)),)
SDL2_CFLAGS := $(shell where sdl2-config >NUL 2>NUL && sdl2-config --cflags)
endif
ifeq ($(strip $(SDL2_LIBS)),)
SDL2_LIBS := $(shell where sdl2-config >NUL 2>NUL && sdl2-config --libs)
endif
ifeq ($(strip $(SDL2_CFLAGS)),)
SDL2_CFLAGS := $(shell if exist C:\msys64\mingw64\bin\pkg-config.exe C:\msys64\mingw64\bin\pkg-config.exe --cflags sdl2)
endif
ifeq ($(strip $(SDL2_LIBS)),)
SDL2_LIBS := $(shell if exist C:\msys64\mingw64\bin\pkg-config.exe C:\msys64\mingw64\bin\pkg-config.exe --libs sdl2)
endif
ifeq ($(strip $(SDL2_LIBS)),)
SDL2_LIBS := -lmingw32 -lSDL2main -lSDL2
endif
MKDIR_P     = if not exist "$(subst /,\\,$1)" mkdir "$(subst /,\\,$1)"
RM_RF       = powershell -NoProfile -Command "$(foreach p,$1,if (Test-Path '$(subst /,\\,$p)') { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue '$(subst /,\\,$p)' };)"
LS_FILESIZE = powershell -NoProfile -Command "Get-Item '$(subst /,\\,$1)' | Select-Object Name,Length | Format-Table -AutoSize"
else
EXEEXT      =
SDL2_CFLAGS ?= $(shell pkg-config --cflags sdl2)
SDL2_LIBS   ?= $(shell pkg-config --libs sdl2)
MKDIR_P     = mkdir -p $1
RM_RF       = rm -rf $1
LS_FILESIZE = ls -lh $1
endif

RUN_BIN = $(if $(filter Windows_NT,$(OS)),$(subst /,\\,$1),./$1)

# SIMD / auto-vectorisation flags, chosen per target architecture.
# On Windows we always target x86-64 MinGW; elsewhere we query uname -m.
ifeq ($(OS),Windows_NT)
    SIMD_CFLAGS := -msse2 -ftree-vectorize
else
    _ARCH := $(shell uname -m)
    ifeq ($(_ARCH),aarch64)
        SIMD_CFLAGS := -ftree-vectorize
    else ifeq ($(_ARCH),armv7l)
        SIMD_CFLAGS := -mfpu=neon -ftree-vectorize
    else
        SIMD_CFLAGS := -msse2 -ftree-vectorize
    endif
endif

CFLAGS  = -std=c99 -Wall -Wextra -O2 -g $(SIMD_CFLAGS) $(SDL2_CFLAGS)
LDFLAGS = $(SDL2_LIBS) -lm
TEST_SDL2_CFLAGS = $(filter-out -Dmain=SDL_main,$(SDL2_CFLAGS))
TEST_SDL2_LIBS = $(filter-out -mwindows -lSDL2main -lmingw32,$(SDL2_LIBS))
TEST_CFLAGS = -std=c99 -Wall -Wextra -O2 -g $(TEST_SDL2_CFLAGS)
TEST_LDFLAGS = $(TEST_SDL2_LIBS) -lm
BINDIR  = bin
TARGET_NAME = sbc6502$(EXEEXT)
TARGET  = $(BINDIR)/$(TARGET_NAME)
SRCDIR  = src
OBJDIR  = build
BASH    ?= bash
ifeq ($(OS),Windows_NT)
ifneq ($(wildcard C:/msys64/usr/bin/bash.exe),)
BASH := C:\msys64\usr\bin\bash.exe
else
BASH := bash -c
endif
endif
KLAUS_BIN = $(OBJDIR)/klaus/6502_functional_test.bin
KLAUS_URL = https://raw.githubusercontent.com/Klaus2m5/6502_65C02_functional_tests/master/bin_files/6502_functional_test.bin

SRCS = $(wildcard $(SRCDIR)/*.c)
OBJS = $(patsubst $(SRCDIR)/%.c,$(OBJDIR)/%.o,$(SRCS))

BENCH_CFLAGS = -std=c99 -Wall -Wextra -O3 -DNDEBUG $(SIMD_CFLAGS)

.PHONY: all clean run check roms kernel-rom chess-rom ehbasic-rom soundtest-rom avdemo-rom adventure test-chess-rom test-diskdir test-peek-poke test-klaus-6502 release bench-mandelbrot demo demo-rom avdemo ehbasic

all: $(TARGET)

release: CFLAGS = -std=c99 -Wall -Wextra -O3 -DNDEBUG $(SIMD_CFLAGS) $(SDL2_CFLAGS)
release: clean $(TARGET)
	strip $(TARGET)
	@echo "Release build complete: $(TARGET) (optimized, stripped)"
	@$(call LS_FILESIZE,$(TARGET))

$(OBJDIR):
	@$(call MKDIR_P,$(OBJDIR))

$(BINDIR):
	@$(call MKDIR_P,$(BINDIR))

$(OBJDIR)/%.o: $(SRCDIR)/%.c | $(OBJDIR)
	$(CC) $(CFLAGS) -I$(SRCDIR) -c $< -o $@

$(TARGET): $(OBJS) | $(BINDIR)
	$(CC) $(CFLAGS) $^ -o $@ $(LDFLAGS)
	$(if $(filter Windows_NT,$(OS)),@$(call COPY_IF_EXISTS,$(SDL2_DLL),$(BINDIR)/SDL2.dll))
	$(if $(filter Windows_NT,$(OS)),@$(call COPY_IF_EXISTS,$(WINPTHREAD_DLL),$(BINDIR)/libwinpthread-1.dll))
	$(if $(filter Windows_NT,$(OS)),@$(call COPY_IF_EXISTS,$(LIBGCC_DLL),$(BINDIR)/libgcc_s_seh-1.dll))
	$(BASH) tools/stage_runtime.sh "$(BINDIR)"
	@echo "Built: $@"

clean:
	@$(call RM_RF,$(OBJDIR) $(BINDIR))

check: all test-diskdir test-chess-rom test-peek-poke test-klaus-6502 test-65c02

$(KLAUS_BIN):
	@$(call MKDIR_P,$(dir $@))
	curl -fsSL $(KLAUS_URL) -o $@

test-diskdir: $(OBJDIR)
	$(CC) $(TEST_CFLAGS) -I$(SRCDIR) tests/test_diskdev_dir.c src/bus.c src/sram.c src/diskdev.c src/soundchip.c -o $(OBJDIR)/test_diskdev_dir$(EXEEXT) $(TEST_LDFLAGS)
	$(call RUN_BIN,$(OBJDIR)/test_diskdev_dir$(EXEEXT))

test-chess-rom: $(OBJDIR)
	$(BASH) tools/make_chess_rom.sh
	$(CC) $(TEST_CFLAGS) -I$(SRCDIR) tests/test_chess_rom.c src/bus.c src/cpu6502.c src/disasm.c src/sram.c src/rom.c src/vic.c src/via6522.c src/soundchip.c -o $(OBJDIR)/test_chess_rom$(EXEEXT) $(TEST_LDFLAGS)
	$(call RUN_BIN,$(OBJDIR)/test_chess_rom$(EXEEXT))

test-peek-poke: $(OBJDIR)
	$(CC) $(TEST_CFLAGS) -I$(SRCDIR) tests/test_peek_poke_addrs.c src/bus.c src/sram.c src/vic.c src/via6522.c src/diskdev.c src/soundchip.c -o $(OBJDIR)/test_peek_poke_addrs$(EXEEXT) $(TEST_LDFLAGS)
	$(call RUN_BIN,$(OBJDIR)/test_peek_poke_addrs$(EXEEXT))

test-klaus-6502: $(OBJDIR) $(KLAUS_BIN)
	$(CC) $(TEST_CFLAGS) -I$(SRCDIR) tests/test_klaus_6502.c src/cpu6502.c src/disasm.c -o $(OBJDIR)/test_klaus_6502$(EXEEXT) $(TEST_LDFLAGS)
	$(call RUN_BIN,$(OBJDIR)/test_klaus_6502$(EXEEXT))

test-65c02: $(OBJDIR)
	$(CC) $(TEST_CFLAGS) -I$(SRCDIR) tests/test_65c02.c src/cpu6502.c src/disasm.c -o $(OBJDIR)/test_65c02$(EXEEXT) $(TEST_LDFLAGS)
	$(call RUN_BIN,$(OBJDIR)/test_65c02$(EXEEXT))

roms:
	$(BASH) tools/make_kernel_rom.sh
	$(BASH) tools/make_msbasic_rom.sh
	$(BASH) tools/make_ehbasic_rom.sh
	$(BASH) tools/make_chess_rom.sh
	$(BASH) tools/make_soundtest_rom.sh

kernel-rom:
	$(BASH) tools/make_kernel_rom.sh

ehbasic-rom: kernel-rom
	$(BASH) tools/make_ehbasic_rom.sh

chess-rom:
	$(BASH) tools/make_chess_rom.sh

soundtest-rom:
	$(BASH) tools/make_soundtest_rom.sh
	$(BASH) tools/stage_runtime.sh "$(BINDIR)"

adventure: data/disk/adventure.prg

data/disk/adventure.prg: examples/adventure.bas tools/make_ehbasic_prg.py
	python3 tools/make_ehbasic_prg.py examples/adventure.bas data/disk/adventure.prg

bench-mandelbrot: $(OBJDIR)
	$(CC) $(BENCH_CFLAGS) -I$(SRCDIR) tests/bench_mandelbrot.c \
	    -o $(OBJDIR)/bench_mandelbrot$(EXEEXT)
	$(call RUN_BIN,$(OBJDIR)/bench_mandelbrot$(EXEEXT)) $(OBJDIR)/mandelbrot.bmp

demo-rom:
	$(BASH) tools/make_demo.sh

demo: all demo-rom
	$(call RUN_BIN,$(TARGET)) demo.ini

avdemo-rom:
	$(BASH) tools/make_avdemo_rom.sh
	$(BASH) tools/stage_runtime.sh "$(BINDIR)"

avdemo: all avdemo-rom
	$(call RUN_BIN,$(TARGET)) $(BINDIR)/avdemo.ini

soundtest: all soundtest-rom
	$(call RUN_BIN,$(TARGET)) $(BINDIR)/soundtest.ini

run: all
	$(call RUN_BIN,$(TARGET)) $(BINDIR)/sbc.ini

ehbasic: all ehbasic-rom
	$(BASH) tools/stage_runtime.sh "$(BINDIR)"
	$(call RUN_BIN,$(TARGET)) $(BINDIR)/ehbasic.ini

# Run with a ROM file directly
rom: all
	$(call RUN_BIN,$(TARGET)) -r $(ROM) $(if $(SPEED),-s $(SPEED))
