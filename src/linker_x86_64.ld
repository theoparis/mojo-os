ENTRY(_start)

SECTIONS
{
    /* Load at 16MB physical address (well within conventional memory under UEFI). */
    . = 0x1000000;
    __kernel_start = .;

    .text : {
        KEEP(*(.text.boot))
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

        /* Kernel state shared between kmain and syscall dispatcher */
        . = ALIGN(8);
        __kstate = .;
        . += 256;

        /* Kernel stack (64KB) */
        . = ALIGN(16);
        __stack_bottom = .;
        . += 0x10000;
        __stack_top = .;
    }
    __bss_end = .;
    __kernel_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame)
    }
}
