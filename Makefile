CLANG        ?= clang
LLD          ?= ld.lld
# Custom-built mojo (work/modular) that auto-selects the "baremetal" stdlib
# plugin for `-none-` target triples, so `debug_assert`/`abort` work without
# libc. The stock nix-packaged mojo does not have this patch.
MOJO         ?= work/modular/bazel-bin/Mojo/tools/mojo/mojo
MOJO_STDLIB  ?= work/modular/Mojo/stdlib
QEMU         ?= qemu-system-aarch64

TARGET       ?= aarch64-unknown-none-elf
TARGET_CPU   := cortex-a57
ASFLAGS      := --target=$(TARGET) -march=armv8-a -c
MOJOFLAGS    := -mojo-search-paths $(MOJO_STDLIB) --emit object --target-triple=$(TARGET) --mcpu=$(TARGET_CPU)

BUILD_DIR    := build
KERNEL_ELF   := $(BUILD_DIR)/kernel.elf
OBJS         := $(BUILD_DIR)/boot.o $(BUILD_DIR)/kernel.o
LINKER_SCRIPT:= src/linker.ld

.PHONY: all clean run

all: $(KERNEL_ELF)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/boot.o: src/boot.S | $(BUILD_DIR)
	$(CLANG) $(ASFLAGS) $< -o $@

$(BUILD_DIR)/kernel.o: src/kernel.mojo | $(BUILD_DIR)
	$(MOJO) build $(MOJOFLAGS) $< -o $@

$(KERNEL_ELF): $(LINKER_SCRIPT) $(OBJS)
	$(LLD) -T $(LINKER_SCRIPT) $(OBJS) -o $@

run: $(KERNEL_ELF)
	@echo "--- Starting QEMU (Press Ctrl+A then X to exit) ---"
	$(QEMU) -M virt -cpu cortex-a57 -nographic -kernel $(KERNEL_ELF)

clean:
	rm -rf $(BUILD_DIR)
