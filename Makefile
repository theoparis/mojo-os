CLANG        ?= clang
LLD          ?= ld.lld
LLD_LINK     ?= lld-link
# Custom-built mojo (work/modular) that auto-selects the "baremetal" stdlib
# plugin for `-none-` target triples, so `debug_assert`/`abort` work without
# libc. The stock nix-packaged mojo does not have this patch.
WORK         := /home/theo/src/modular
PATCHED_MOJO := $(WORK)/bazel-bin/Mojo/tools/mojo/mojo
PATCHED_RT   := $(WORK)/bazel-bin/Mojo/libKGENCompilerRTShared.so

# Prefer the patched Mojo build (auto-selects the baremetal stdlib plugin for
# `-none-` targets, so debug_assert/abort work without libc). When it isn't
# built yet, fall back to a system/pixi Mojo and compensate with
# -DASSERT=none (the baremetal plugin is what makes asserts usable).
MOJO         := $(PATCHED_MOJO)
MOJO_STDLIB  := $(WORK)/Mojo/stdlib
MOJO_ASSERT  ?= -DASSERT=none
COMPILER_RT  := $(PATCHED_RT)

# Only pass -mojo-search-paths when an explicit stdlib tree is configured;
# an empty value makes the driver treat the next argument as an input file.
MOJO_SEARCH  := $(if $(MOJO_STDLIB),-mojo-search-paths $(MOJO_STDLIB),)
MOJO_RT_ENV  := $(if $(COMPILER_RT),MODULAR_MOJO_MAX_COMPILERRT_PATH=$(COMPILER_RT),)
QEMU         ?= qemu-system-aarch64
OBJCOPY      ?= llvm-objcopy

# Which CPU QEMU should model. 4KB (PAGE_SHIFT=12) runs on cortex-a57;
# 16KB (PAGE_SHIFT=14) needs cortex-a76 or max (boot.S checks TGran16 and
# prints a clear error if the emulated CPU lacks the 16KB granule).
QEMU_CPU     ?= $(if $(filter 14,$(PAGE_SHIFT)),cortex-a76,cortex-a57)

# Translation granule the kernel is built for: 12 = 4KB (default; runs on
# any ARMv8 incl. cortex-a57), 14 = 16KB (needs a CPU with the 16KB
# granule, e.g. QEMU cortex-a76/max). Drives boot.S (TCR TG0 + table
# geometry) via ASFLAGS and Mojo (PAGE_SHIFT in phys.mojo/paging.mojo) via
# MOJOFLAGS. See docs/16k-pages.md.
PAGE_SHIFT   ?= 12

OPTIMIZATION_LEVEL ?= 1
TARGET       ?= aarch64-unknown-none-elf
TARGET_CPU   := cortex-a57
ASFLAGS      := --target=$(TARGET) -march=armv8-a -DPAGE_SHIFT=$(PAGE_SHIFT) -c
MOJOFLAGS    := --optimization-level $(OPTIMIZATION_LEVEL) -D PAGE_SHIFT=$(PAGE_SHIFT) $(MOJO_ASSERT) $(MOJO_SEARCH) -I src -I . --emit object --target-triple=$(TARGET) --mcpu=$(TARGET_CPU)

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

# ------------------------------------------------------------------------
# x86_64 UEFI bootloader application & kernel
# ------------------------------------------------------------------------
# UEFI starts us in long mode and requires a PE/COFF EFI application (BOOTX64.EFI)
# which parses and loads the freestanding x86_64 ELF kernel image.
UEFI_TARGET      := x86_64-unknown-uefi
UEFI_CPU         := x86-64
UEFI_DIR         := $(BUILD_DIR)/uefi
UEFI_APP         := $(UEFI_DIR)/BOOTX64.EFI
UEFI_ESP         := $(UEFI_DIR)/esp
UEFI_BOOT_APP    := $(UEFI_ESP)/EFI/BOOT/BOOTX64.EFI
UEFI_KERNEL_ELF  := $(UEFI_ESP)/kernel.elf
UEFI_MOJOFLAGS   := $(MOJO_ASSERT) $(MOJO_SEARCH) --optimization-level $(OPTIMIZATION_LEVEL) -I src -I . --emit object --target-triple=$(UEFI_TARGET) --mcpu=$(UEFI_CPU)

# Mojo emits ARM64 COFF through its Windows target; the native aarch64 UEFI
# backend does not yet support COFF emission.
UEFI_AA64_DIR       := $(BUILD_DIR)/uefi-aa64
UEFI_AA64_ESP       := $(UEFI_AA64_DIR)/esp
UEFI_AA64_BOOT_APP  := $(UEFI_AA64_ESP)/EFI/BOOT/BOOTAA64.EFI
UEFI_AA64_KERNEL    := $(UEFI_AA64_ESP)/kernel.elf
UEFI_AA64_INITRD    := $(UEFI_AA64_ESP)/initrd.cpio
UEFI_AA64_MOJOFLAGS := -D ARCH=aarch64 $(MOJO_ASSERT) $(MOJO_SEARCH) --optimization-level $(OPTIMIZATION_LEVEL) -I src -I . --emit object --target-triple=aarch64-unknown-windows --mcpu=cortex-a57
QEMU_AA64_EFI       ?= /usr/share/edk2/aarch64/QEMU_EFI.fd

X86_TARGET       := x86_64-unknown-none-elf
X86_CPU          := x86-64
X86_KERNEL_ELF   := $(BUILD_DIR)/kernel_x86_64.elf
X86_OBJS         := $(BUILD_DIR)/boot_x86_64.o $(BUILD_DIR)/kernel_x86_64.o
X86_LINKER_SCRIPT:= src/linker_x86_64.ld
X86_ASFLAGS      := --target=$(X86_TARGET) -c
X86_MOJOFLAGS    := -D ARCH=x86_64 -D PAGE_SHIFT=$(PAGE_SHIFT) $(MOJO_ASSERT) $(MOJO_SEARCH) --optimization-level $(OPTIMIZATION_LEVEL) -I src -I . --emit object --target-triple=$(X86_TARGET) --mcpu=$(X86_CPU)

QEMU_X86         ?= qemu-system-x86_64
# `-bios` needs a monolithic firmware image. Override this for distributions
# that package an equivalent image at a different path.
OVMF_CODE        ?= $(firstword $(wildcard /usr/share/edk2/x64/OVMF.4m.fd /usr/share/OVMF/OVMF.fd))

INITRD       := $(BUILD_DIR)/initrd.cpio
MKCPIO       := $(MOJO_RT_ENV) $(MOJO) run $(MOJO_SEARCH) -I src tools/mkcpio.mojo

# User-space binaries to bundle into the initrd, as archive-name=path pairs.
INIT_MACHO    := $(BUILD_DIR)/init_macho
INIT_DYLIB    := $(BUILD_DIR)/libSystem.B.dylib
X86_INIT_MACHO := $(BUILD_DIR)/init_macho_x86_64
X86_INIT_DYLIB := $(BUILD_DIR)/libSystem.B_x86_64.dylib
X86_INITRD     := $(BUILD_DIR)/initrd_x86_64.cpio

INITRD_ENTRIES := init=$(INIT_MACHO) usr/lib/libSystem.B.dylib=$(INIT_DYLIB) usr/lib/libSystem.dylib=$(INIT_DYLIB)

.PHONY: all clean run run-linux userspace uefi kernel-x86 run-uefi uefi-aa64 run-uefi-aa64

all: $(KERNEL_ELF)

kernel-x86: $(X86_KERNEL_ELF)

uefi: $(UEFI_BOOT_APP) $(UEFI_KERNEL_ELF) $(UEFI_ESP)/initrd.cpio

uefi-aa64: $(UEFI_AA64_BOOT_APP) $(UEFI_AA64_KERNEL) $(UEFI_AA64_INITRD)

$(UEFI_DIR):
	mkdir -p $@

$(UEFI_DIR)/main.o: uefi/main.mojo | $(UEFI_DIR)
	$(MOJO) build $(UEFI_MOJOFLAGS) $< -o $@

$(UEFI_DIR)/uefi_loader.o: uefi/uefi_loader.mojo | $(UEFI_DIR)
	$(MOJO) build $(UEFI_MOJOFLAGS) $< -o $@

$(UEFI_APP): $(UEFI_DIR)/main.o $(UEFI_DIR)/uefi_loader.o
	$(LLD_LINK) /subsystem:efi_application /entry:efi_main /nodefaultlib /machine:x64 /out:$@ $^

$(BUILD_DIR)/boot_x86_64.o: src/boot_x86_64.S | $(BUILD_DIR)
	$(CLANG) $(X86_ASFLAGS) $< -o $@

$(BUILD_DIR)/kernel_x86_64.o: src/kernel.mojo $(KERNEL_SRCS) | $(BUILD_DIR)
	$(MOJO) build $(X86_MOJOFLAGS) $< -o $@

$(X86_KERNEL_ELF): $(X86_LINKER_SCRIPT) $(X86_OBJS)
	$(LLD) -T $(X86_LINKER_SCRIPT) $(X86_OBJS) -o $@

$(UEFI_BOOT_APP): $(UEFI_APP)
	mkdir -p $(dir $@)
	cp $< $@

$(UEFI_KERNEL_ELF): $(X86_KERNEL_ELF)
	mkdir -p $(dir $@)
	cp $< $@

$(UEFI_ESP)/initrd.cpio: $(X86_INITRD)
	mkdir -p $(dir $@)
	cp $< $@

$(UEFI_AA64_DIR):
	mkdir -p $@

$(UEFI_AA64_DIR)/main.o: uefi/main.mojo | $(UEFI_AA64_DIR)
	$(MOJO) build $(UEFI_AA64_MOJOFLAGS) $< -o $@

$(UEFI_AA64_DIR)/uefi_loader.o: uefi/uefi_loader.mojo | $(UEFI_AA64_DIR)
	$(MOJO) build $(UEFI_AA64_MOJOFLAGS) $< -o $@

$(UEFI_AA64_DIR)/BOOTAA64.EFI: $(UEFI_AA64_DIR)/main.o $(UEFI_AA64_DIR)/uefi_loader.o
	$(LLD_LINK) /subsystem:efi_application /entry:efi_main /nodefaultlib /machine:arm64 /out:$@ $^

$(UEFI_AA64_BOOT_APP): $(UEFI_AA64_DIR)/BOOTAA64.EFI
	mkdir -p $(dir $@)
	cp $< $@

$(UEFI_AA64_KERNEL): $(KERNEL_ELF)
	mkdir -p $(dir $@)
	cp $< $@

$(UEFI_AA64_INITRD): $(INITRD)
	mkdir -p $(dir $@)
	cp $< $@

# OVMF_CODE can be overridden for distributions that store OVMF elsewhere.
run-uefi: uefi
	@test -n "$(OVMF_CODE)" || { echo "Set OVMF_CODE to a monolithic OVMF firmware image"; exit 1; }
	$(QEMU_X86) -machine q35 -m 128M -nographic -bios $(OVMF_CODE) \
		-drive format=raw,file=fat:rw:$(UEFI_ESP)

run-uefi-aa64: uefi-aa64
	@test -f "$(QEMU_AA64_EFI)" || { echo "Set QEMU_AA64_EFI to an AArch64 UEFI firmware image"; exit 1; }
	$(QEMU) -M virt -cpu $(QEMU_CPU) -m 256M -nographic \
		-drive if=pflash,format=raw,readonly=on,file=$(QEMU_AA64_EFI) \
		-drive format=raw,file=fat:rw:$(UEFI_AA64_ESP)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/boot.o: src/boot.S | $(BUILD_DIR)
	$(CLANG) $(ASFLAGS) $< -o $@

KERNEL_SRCS  := $(shell find src -name '*.mojo')

$(BUILD_DIR)/kernel.o: src/kernel.mojo $(KERNEL_SRCS) | $(BUILD_DIR)
	$(MOJO) build $(MOJOFLAGS) $< -o $@

$(KERNEL_ELF): $(LINKER_SCRIPT) $(OBJS)
	$(LLD) -T $(LINKER_SCRIPT) $(OBJS) -o $@

$(KERNEL_BIN): $(KERNEL_ELF)
	$(OBJCOPY) -O binary $< $@

# ------------------------------------------------------------------------
# Userspace + initrd (Linux-style boot target)
# ------------------------------------------------------------------------

# Build the dynamic macOS arm64 libSystem.dylib written in Mojo
$(INIT_DYLIB): src/user/libsystem.mojo | $(BUILD_DIR)
	$(MOJO) build -DASSERT=none $(MOJO_SEARCH) -I src --target-triple=arm64-apple-darwin --emit object $< -o $(BUILD_DIR)/libsystem.o
	ld64.lld -arch arm64 -platform_version macos 27.0 27.0 -dylib -install_name /usr/lib/libSystem.B.dylib $(BUILD_DIR)/libsystem.o -o $@
	ln -sf libSystem.B.dylib $(BUILD_DIR)/libSystem.dylib

$(INIT_MACHO): src/user/init.c $(INIT_DYLIB) | $(BUILD_DIR)
	clang --target=aarch64-apple-darwin -fuse-ld=lld \
		-fno-stack-protector \
		-Wl,-platform_version,macos,27.0,27.0 \
		-Wl,-pagezero_size,0x10000 \
		-Wl,-fixup_chains \
		-L$(BUILD_DIR) -lSystem \
		src/user/init.c -o $@

$(X86_INIT_DYLIB): src/user/libsystem.mojo | $(BUILD_DIR)
	$(MOJO) build -DASSERT=none $(MOJO_SEARCH) -I src --target-triple=x86_64-apple-darwin --emit object $< -o $(BUILD_DIR)/libsystem_x86_64.o
	ld64.lld -arch x86_64 -platform_version macos 27.0 27.0 -dylib -install_name /usr/lib/libSystem.B.dylib $(BUILD_DIR)/libsystem_x86_64.o -o $@

$(X86_INIT_MACHO): src/user/init.c $(X86_INIT_DYLIB) | $(BUILD_DIR)
	clang --target=x86_64-apple-darwin -fuse-ld=lld -fno-stack-protector -nostdlib \
		-Wl,-e,_main -Wl,-platform_version,macos,27.0,27.0 -Wl,-pagezero_size,0x10000 \
		-Wl,-fixup_chains -L$(BUILD_DIR) -lSystem.B_x86_64 $< -o $@

$(X86_INITRD): tools/mkcpio.mojo src/fs/cpio.mojo $(X86_INIT_MACHO) $(X86_INIT_DYLIB)
	$(MKCPIO) $@ init=$(X86_INIT_MACHO) usr/lib/libSystem.B.dylib=$(X86_INIT_DYLIB) usr/lib/libSystem.dylib=$(X86_INIT_DYLIB)

# The cpio initrd that QEMU loads and the kernel unpacks at boot.
$(INITRD): tools/mkcpio.mojo src/fs/cpio.mojo $(INIT_MACHO) $(INIT_DYLIB)
	$(MKCPIO) $@ $(INITRD_ENTRIES)

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
