CLANG        ?= clang
LLD          ?= ld.lld
# Custom-built mojo (work/modular) that auto-selects the "baremetal" stdlib
# plugin for `-none-` target triples, so `debug_assert`/`abort` work without
# libc. The stock nix-packaged mojo does not have this patch.
WORK         := work/modular
MOJO         ?= $(WORK)/bazel-bin/Mojo/tools/mojo/mojo
MOJO_STDLIB  ?= $(WORK)/Mojo/stdlib
# The Mojo CompilerRT shared library, needed only when building/running
# *host* mojo programs (like the mkcpio tool); the bare-metal kernel build
# links against our own freestanding runtime instead.
COMPILER_RT  := $(WORK)/bazel-bin/Mojo/libKGENCompilerRTShared.so
QEMU         ?= qemu-system-aarch64
OBJCOPY      ?= llvm-objcopy

# Which CPU QEMU should model. cortex-a57 (default) has no 16KB granule;
# a 16KB page build needs cortex-a76 or max (see docs/16k-pages.md).
QEMU_CPU     ?= cortex-a57

TARGET       ?= aarch64-unknown-none-elf
TARGET_CPU   := cortex-a57
ASFLAGS      := --target=$(TARGET) -march=armv8-a -c
MOJOFLAGS    := -mojo-search-paths $(MOJO_STDLIB) -I src --emit object --target-triple=$(TARGET) --mcpu=$(TARGET_CPU)

# Freestanding userspace binaries are compiled with clang for a bare
# `-none-` triple (no OS, no libc) and linked as static non-PIE ET_EXEC by
# src/user/user.ld (load address inside the EL0-accessible region).
USER_CC      := clang
USER_TARGET  := aarch64-none-elf

BUILD_DIR    := build
KERNEL_ELF   := $(BUILD_DIR)/kernel.elf
KERNEL_BIN   := $(BUILD_DIR)/kernel.bin
OBJS         := $(BUILD_DIR)/boot.o $(BUILD_DIR)/kernel.o
LINKER_SCRIPT:= src/linker.ld

INIT_ELF     := $(BUILD_DIR)/init
INITRD       := $(BUILD_DIR)/initrd.cpio
MKCPIO       := $(BUILD_DIR)/mkcpio

# User-space binaries to bundle into the initrd, as archive-name=path pairs.
INITRD_ENTRIES := init=$(INIT_ELF)

.PHONY: all clean run run-linux userspace

all: $(KERNEL_ELF)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/boot.o: src/boot.S | $(BUILD_DIR)
	$(CLANG) $(ASFLAGS) $< -o $@

$(BUILD_DIR)/kernel.o: src/kernel.mojo $(wildcard src/*.mojo) | $(BUILD_DIR)
	$(MOJO) build $(MOJOFLAGS) $< -o $@

$(KERNEL_ELF): $(LINKER_SCRIPT) $(OBJS)
	$(LLD) -T $(LINKER_SCRIPT) $(OBJS) -o $@

$(KERNEL_BIN): $(KERNEL_ELF)
	$(OBJCOPY) -O binary $< $@

# ------------------------------------------------------------------------
# Userspace + initrd (Linux-style boot target)
# ------------------------------------------------------------------------

# Build the cpio writer as a native (host) mojo executable. Needs the host
# Mojo CompilerRT (set via env) -- the bare-metal kernel build does not.
$(MKCPIO): tools/mkcpio.mojo src/cpio.mojo | $(BUILD_DIR)
	MODULAR_MOJO_MAX_COMPILERRT_PATH=$(COMPILER_RT) \
		$(MOJO) build -mojo-search-paths $(MOJO_STDLIB) -I src \
		tools/mkcpio.mojo -o $@

# /init for the ramfs: a tiny freestanding ELF that does raw Linux syscalls.
$(INIT_ELF): src/user/init.c src/user/user.ld | $(BUILD_DIR)
	$(USER_CC) --target=$(USER_TARGET) -ffreestanding -fno-builtin \
		-nostdlib -static -fno-pie -O2 -Wall \
		-Wl,-T,src/user/user.ld -o $@ $<

# The cpio initrd that QEMU loads and the kernel unpacks at boot.
$(INITRD): $(MKCPIO) $(INIT_ELF)
	LD_LIBRARY_PATH=$(dir $(COMPILER_RT)) $(MKCPIO) $@ $(INITRD_ENTRIES)

userspace: $(INITRD)

# Run the kernel the way Linux boots: raw image + DTB + cpio initrd, so the
# kernel loads /init from the initrd and runs it at EL0. (Override INITRD or
# APPEND on the command line if you want a different initramfs.)
run-linux: $(KERNEL_BIN) $(INITRD)
	@echo "--- Starting QEMU (Linux-protocol boot, initrd present, -cpu $(QEMU_CPU)) ---"
	$(QEMU) -M virt -cpu $(QEMU_CPU) -nographic -kernel $(KERNEL_BIN) \
		-initrd $(INITRD) -append "$(APPEND)"

run: $(KERNEL_ELF)
	@echo "--- Starting QEMU (Press Ctrl+A then X to exit) ---"
	$(QEMU) -M virt -cpu $(QEMU_CPU) -nographic -kernel $(KERNEL_ELF)

clean:
	rm -rf $(BUILD_DIR)

APPEND ?= console=ttyAMA0 rdinit=/init
