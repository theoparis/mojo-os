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

    /* The single top-level translation table for the 16KB granule: 2048 x
     * 8B descriptors = 16KB. With T0SZ=32 (4GB VA) the 16KB-granule walk
     * uses two levels, and this top table is indexed by VA[31:25]; each
     * entry is either a 32MB block descriptor (devices/RAM, identity) or a
     * pointer to a lazily-created 2048-entry leaf table for userspace pages
     * (see src/paging.mojo). Zeroed + filled by boot.S. Must be 16KB
     * aligned for TTBR0. */
    . = ALIGN(0x4000);
    __page_table = .;
    . += 0x4000;

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
