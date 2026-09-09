ENTRY(_start)

SECTIONS
{
    . = 0x40000000;

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

    /* Reserve a stack region for EL1 (grows downward from __stack_top).
     * QEMU's -M virt places RAM at 0x40000000 (default 128 MiB), so this
     * sits just past the kernel's static image and is cleared with BSS. */
    . = ALIGN(16);
    __stack_bottom = .;
    . += 0x10000;
    __stack_top = .;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
    }
}
