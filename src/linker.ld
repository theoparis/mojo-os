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

        /* Kernel state shared between kmain and the syscall dispatcher
         * (brk/mmap cursors, allocator free-list head, page-table base...).
         * Lives inside .bss so boot.S zeroes it like the rest of BSS.
         * Fields are accessed by offset from __kstate (see src/kstate.mojo). */
        . = ALIGN(8);
        __kstate = .;
        . += 256;
    }
    __bss_end = .;

    /* A single 4KB, 512-entry level-1 translation table (4KB granule,
     * T0SZ=32 => 4GB VA space => level-1 block descriptors cover 1GB each).
     * Zeroed by hand in boot.S (all-zero entries are simply invalid, which
     * is what we want for the unused slots). */
    . = ALIGN(4096);
    __page_table = .;
    . += 4096;

    /* Level-2 table (512 x 2MB entries) covering the 1GB RAM range
     * (0x40000000-0x80000000). This is the kernel's identity RAM map --
     * L1[1] points here and all entries are Normal, EL1-only 2MB blocks.
     * Userspace pages do NOT live here: they get their own low-VA table
     * (L2-A) hung under L1[0] by src/paging.mojo. */
    . = ALIGN(4096);
    __page_table_l2 = .;
    . += 4096;

    /* Reserve a stack region for EL1 (grows downward from __stack_top).
     * QEMU's -M virt places RAM at 0x40000000 (default 128 MiB), so this
     * sits just past the kernel's static image and is cleared with BSS.
     *
     * The EL0 (userspace) stack is NOT reserved here: userspace runs in the
     * low 128MB *virtual* address space carved out by src/paging.mojo, with
     * its stack at the top of that space (0x08000000 down) and pages mapped
     * onto frames from the physical allocator. See src/paging.mojo. */
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
