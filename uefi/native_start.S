.text
.globl native_entry
.extern native_kernel_main

native_entry:
    # Win64 ABI passes 1st argument in RCX; System V expects it in RDI.
    movq %rcx, %rdi
    jmp native_kernel_main

.globl native_hello
native_hello:
    # SystemTable pointer is in RDI.
    # ConsoleOut is at offset 64 (0x40), OutputString is at offset 8.
    movq 64(%rdi), %rcx
    movq 8(%rcx), %rax
    leaq native_message(%rip), %rdx
    subq $40, %rsp
    callq *%rax
    addq $40, %rsp
    retq

.section .rdata,"dr"
.align 2
native_message:
    .short 0x0048, 0x0065, 0x006c, 0x006c, 0x006f, 0x0020
    .short 0x0066, 0x0072, 0x006f, 0x006d, 0x0020, 0x006e
    .short 0x0061, 0x0074, 0x0069, 0x0076, 0x0065, 0x0020
    .short 0x004d, 0x006f, 0x006a, 0x006f, 0x0020, 0x006b
    .short 0x0065, 0x0072, 0x006e, 0x0065, 0x006c, 0x0021
    .short 0x000d, 0x000a, 0x0000
