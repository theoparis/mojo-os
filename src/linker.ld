ENTRY(_start)

SECTIONS
{
    /* QEMU's `virt` machine loads an ELF kernel at its p_paddr, but a raw
     * (Linux-protocol) kernel image at RAM base + 0x80000 (0x40000000 +
     * 0x80000). Linking here makes both boot paths agree, so our absolute
     * addresses (vector table via VBAR_EL1, page tables, stacks) line up
     * with where the image is actually resident under either boot method. */
    . = 0x40080000;
    __kernel_start = .;

    .text : {
        KEEP(*(.text.boot))
        /* VBAR_EL1 requires the vector table to be 2KB-aligned. */
        . = ALIGN(0x800);
        KEEP(*(.text.vectors))
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    . = ALIGN(8);
    __bss_start = .;
    .bss : {
        *(.bss .bss.*)
    }
    __bss_end = .;

    /* A single 4KB, 512-entry level-1 translation table (4KB granule,
     * T0SZ=32 => 4GB VA space => level-1 block descriptors cover 1GB each).
     * Zeroed by hand in boot.S (all-zero entries are simply invalid, which
     * is what we want for the unused slots). */
    . = ALIGN(4096);
    __page_table = .;
    . += 4096;

    /* Level-2 table (512 x 2MB entries) covering the 1GB RAM range, so a
     * small "user" sub-region can be granted EL0 access without changing
     * permissions on the 1GB block the kernel itself executes from. */
    . = ALIGN(4096);
    __page_table_l2 = .;
    . += 4096;

    /* Reserve a stack region for EL1 (grows downward from __stack_top).
     * QEMU's -M virt places RAM at 0x40000000 (default 128 MiB), so this
     * sits just past the kernel's static image and is cleared with BSS.
     *
     * Note: the EL0 (userspace) stack is NOT reserved here -- it lives
     * inside the dedicated EL0-accessible region (USER_REGION_BASE in
     * boot.S, currently 0x41000000-0x413fffff), which is a fixed
     * hardware-permission carve-out in the page tables, not something
     * that should float with the kernel image's size. See boot.S. */
    . = ALIGN(16);
    __stack_bottom = .;
    . += 0x10000;
    __stack_top = .;

    /* End of the kernel's own static image (text..stack). Everything from
     * __kernel_start to here is reserved out of the physical allocator. */
    __kernel_end = __stack_top;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
    }
}
