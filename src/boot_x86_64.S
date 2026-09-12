.section ".text.boot"
.global _start
.extern kmain

_start:
    # Entry point for the x86_64 ELF kernel.
    # When launched by the UEFI bootloader:
    #   RCX (Win64 ABI) or RDI (SysV ABI) carries the EFI_SYSTEM_TABLE pointer.
    movq    %rcx, %r12             # In Win64 ABI (UEFI), st is in %rcx
    testq   %r12, %r12
    jnz     .Lhas_st
    movq    %rdi, %r12             # In SysV ABI, st is in %rdi
.Lhas_st:

    # Initialize COM1 serial port (0x3F8)
    movw    $0x3f9, %dx            # IER: disable all interrupts
    xorl    %eax, %eax
    outb    %al, %dx

    movw    $0x3fb, %dx            # LCR: enable DLAB (set baud rate divisor)
    movb    $0x80, %al
    outb    %al, %dx

    movw    $0x3f8, %dx            # Divisor low byte (115200 baud -> divisor 1)
    movb    $0x01, %al
    outb    %al, %dx

    movw    $0x3f9, %dx            # Divisor high byte = 0
    xorl    %eax, %eax
    outb    %al, %dx

    movw    $0x3fb, %dx            # LCR: 8 bits, no parity, 1 stop bit (8N1)
    movb    $0x03, %al
    outb    %al, %dx

    movw    $0x3fa, %dx            # FCR: enable & clear FIFO, 14-byte threshold
    movb    $0xc7, %al
    outb    %al, %dx

    movw    $0x3fc, %dx            # MCR: RTS/DSR set
    movb    $0x0b, %al
    outb    %al, %dx

    # Set up kernel stack
    leaq    __stack_top(%rip), %rsp

    # Clear BSS
    leaq    __bss_start(%rip), %rdi
    leaq    __bss_end(%rip), %rcx
    subq    %rdi, %rcx
    shrq    $3, %rcx
    xorl    %eax, %eax
    rep stosq

    # Prepare arguments for kmain(x0, x1, x2, x3) (System V ABI):
    #   rdi = sys_table (preserved in %r12)
    #   rsi = __kernel_start
    #   rdx = __kernel_end
    #   rcx = 0
    movq    %r12, %rdi
    leaq    __kernel_start(%rip), %rsi
    leaq    __kernel_end(%rip), %rdx
    xorq    %rcx, %rcx

    # In System V ABI, %rsp must be 16-byte aligned prior to call
    call    kmain

.Lhalt_loop:
    hlt
    jmp     .Lhalt_loop

# ------------------------------------------------------------------------
# COM1 Serial Port (0x3F8) I/O
# ------------------------------------------------------------------------
.globl x86_putc
x86_putc:
    # rdi = char
    cmpb    $10, %dil              # '\n'?
    jne     .Lputc_send
    # Prepend '\r' for serial terminal CRLF newline
    movw    $0x3fd, %dx
.Lwait_cr:
    inb     %dx, %al
    testb   $0x20, %al             # LSR THRE (bit 5)
    jz      .Lwait_cr
    movw    $0x3f8, %dx
    movb    $13, %al               # '\r'
    outb    %al, %dx

.Lputc_send:
    movw    $0x3fd, %dx
.Lwait_tx:
    inb     %dx, %al
    testb   $0x20, %al             # LSR THRE (bit 5)
    jz      .Lwait_tx
    movw    $0x3f8, %dx
    movb    %dil, %al
    outb    %al, %dx
    retq

.globl x86_getc
x86_getc:
    movw    $0x3fd, %dx
.Lwait_rx:
    inb     %dx, %al
    testb   $0x01, %al             # LSR Data Ready (bit 0)
    jz      .Lwait_rx
    movw    $0x3f8, %dx
    inb     %dx, %al
    movzbq  %al, %rax
    retq

# ------------------------------------------------------------------------
# Architecture Helpers
# ------------------------------------------------------------------------
.globl kstate_ptr
kstate_ptr:
    leaq    __kstate(%rip), %rax
    retq

.globl flush_tlb_all
flush_tlb_all:
    movq    %cr3, %rax
    movq    %rax, %cr3
    retq

.globl run_user
run_user:
    movq    %rsi, %rsp
    jmpq    *%rdi
