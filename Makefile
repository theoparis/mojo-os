CLANG        ?= clang
LLD          ?= ld.lld
MOJO         ?= mojo
QEMU         ?= qemu-system-aarch64

TARGET       ?= aarch64-unknown-none-elf
TARGET_CPU   := cortex-a57
ASFLAGS      := --target=$(TARGET) -march=armv8-a -c
MOJOFLAGS    := --emit object --target-triple=$(TARGET_TRIPLE) --mcpu=$(TARGET_CPU)

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
