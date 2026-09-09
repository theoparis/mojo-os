/* Linker script for freestanding userspace binaries loaded by the kernel's
 * ELF loader (src/elf.mojo). Loaded into the real user VA space set up by
 * src/paging.mojo (low 128MB, 0x00000000-0x08000000), at the same standard
 * low text base a Linux/musl static binary uses (0x400000). Non-PIE,
 * ET_EXEC, no relocations. */
ENTRY(_start)

SECTIONS
{
    . = 0x400000;

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
