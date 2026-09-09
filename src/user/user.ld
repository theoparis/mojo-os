/* Linker script for freestanding userspace binaries loaded by the kernel's
 * ELF loader (src/elf.mojo). Must match the EL0-accessible region set up in
 * boot.S's level-2 page table (USER_L2_FIRST..USER_L2_LAST, currently
 * 0x41000000-0x413fffff -- 4MB). Non-PIE, ET_EXEC, no relocations. */
ENTRY(_start)

SECTIONS
{
    . = 0x41000000;

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    . = ALIGN(16);
    .bss : {
        *(.bss .bss.*)
    }

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
        *(.note.*)
    }
}
