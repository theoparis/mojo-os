.section ".text.boot"
.global _start
.extern kmain

.global virtio_mb
virtio_mb:
    mfence
    retq

.global virtio_wait
virtio_wait:
    pause
    retq

.global virtio_sync
virtio_sync:
    addq    %rdi, %rsi
    andq    $-64, %rdi
.Lvirtio_sync_line:
    clflush (%rdi)
    addq    $64, %rdi
    cmpq    %rsi, %rdi
    jb      .Lvirtio_sync_line
    mfence
    retq

.global x86_in8
x86_in8:
    movw    %di, %dx
    xorl    %eax, %eax
    inb     %dx, %al
    retq

.global x86_in16
x86_in16:
    movw    %di, %dx
    xorl    %eax, %eax
    inw     %dx, %ax
    retq

.global x86_in32
x86_in32:
    movw    %di, %dx
    inl     %dx, %eax
    retq

.global x86_out8
x86_out8:
    movw    %di, %dx
    movl    %esi, %eax
    outb    %al, %dx
    retq

.global x86_out16
x86_out16:
    movw    %di, %dx
    movl    %esi, %eax
    outw    %ax, %dx
    retq

.global x86_out32
x86_out32:
    movw    %di, %dx
    movl    %esi, %eax
    outl    %eax, %dx
    retq

_start:
    # Entry point for the x86_64 ELF kernel.
    # When launched by the UEFI bootloader:
    #   RCX (Win64 ABI) or RDI (SysV ABI) carries the EFI_SYSTEM_TABLE pointer.
    # The UEFI loader calls the loaded kernel through the platform C ABI:
    # RCX/RDX/R8 are boot_args and the loaded image bounds. Preserve them
    # before using RCX for the BSS clear below. The SysV fallback keeps
    # direct/manual x86 launches usable.
    movq    %rcx, %r12
    movq    %rdx, %r13
    movq    %r8,  %r14
    testq   %r12, %r12
    jnz     .Lhas_boot_args
    movq    %rdi, %r12
    leaq    __kernel_start(%rip), %r13
    leaq    __kernel_end(%rip), %r14
.Lhas_boot_args:
    # Firmware identity mappings may mark its formerly-owned RAM read-only.
    # The kernel owns these pages after ExitBootServices and must be able to
    # initialize allocated frames and page tables.
    movq    %cr0, %rax
    andq    $~(1 << 16), %rax       # clear CR0.WP for supervisor accesses
    movq    %rax, %cr0

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
    #   rdi = XNU boot_args (preserved in %r12)
    #   rsi/rdx = loaded kernel bounds
    #   rcx = active PML4 physical address for the x86 paging backend
    movq    %r12, %rdi
    movq    %r13, %rsi
    movq    %r14, %rdx
    movq    %cr3, %rcx

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
    # Install a small flat GDT with ring-3 code/data descriptors.
    movq    %rdi, %r12             # user RIP
    movq    %rsi, %r13             # user RSP
    leaq    .Lgdt(%rip), %rax
    movq    %rax, .Lgdt_ptr+2(%rip)
    lgdt    .Lgdt_ptr(%rip)
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss

    # Enable SYSCALL and point LSTAR at our Darwin x86-64 entry stub.
    movl    $0xc0000080, %ecx       # IA32_EFER
    rdmsr
    orl     $1, %eax               # SCE
    wrmsr
    movl    $0xc0000081, %ecx       # IA32_STAR
    movl    $0x00080000, %eax       # kernel CS = 0x08
    movl    $0x00130000, %edx       # SYSRET base = 0x13
    wrmsr
    leaq    .Lsyscall_entry(%rip), %rax
    movq    %rax, %rdx
    shrq    $32, %rdx
    movl    %eax, %eax
    movl    $0xc0000082, %ecx       # IA32_LSTAR
    wrmsr
    movl    $0xc0000084, %ecx       # IA32_FMASK
    movl    $0x00000600, %eax       # mask IF and DF in kernel
    xorl    %edx, %edx
    wrmsr

    # Darwin's x86_64 process entry passes argc/argv in RDI/RSI as well as
    # providing the canonical argc/argv/env/apple layout on the user stack.
    movq    (%r13), %rdi
    leaq    8(%r13), %rsi

    # IRETQ performs the initial CPL0 -> CPL3 transition.
    pushq   $0x1b                  # user SS
    pushq   %r13
    pushq   $0x002                 # interrupts stay masked until kernel IDT exists
    pushq   $0x23                  # user CS
    pushq   %r12
    iretq

.Lsyscall_entry:
    # SYSCALL leaves the user RIP in RCX and flags in R11, but does not
    # switch stacks. Preserve user state before entering Mojo on a known
    # kernel stack. Interrupts remain masked by FMASK.
    movq    %rsp, .Luser_rsp(%rip)
    movq    %rcx, .Luser_rip(%rip)
    movq    %r11, .Luser_flags(%rip)
    movq    %r9, .Luser_a5(%rip)
    leaq    .Lsyscall_stack_top(%rip), %rsp

    # ksyscall(n, a0, a1, a2, a3, a4, a5, &error)
    movq    %r8, %r9
    movq    %r10, %r8
    movq    %rdx, %rcx
    movq    %rsi, %rdx
    movq    %rdi, %rsi
    movq    %rax, %rdi
    leaq    .Lsyscall_error(%rip), %rax
    pushq   %rax
    pushq   .Luser_a5(%rip)
    call    ksyscall
    addq    $16, %rsp

    movq    .Luser_rip(%rip), %rcx
    movq    .Luser_flags(%rip), %r11
    cmpq    $0, .Lsyscall_error(%rip)
    je      .Lsyscall_ok
    orq     $1, %r11               # Darwin errors set carry
    jmp     .Lsyscall_return
.Lsyscall_ok:
    andq    $-2, %r11
.Lsyscall_return:
    movq    .Luser_rsp(%rip), %rsp
    sysretq

.align 8
.Lgdt:
    .quad 0x0000000000000000
    .quad 0x00af9a000000ffff       # 0x08 kernel code
    .quad 0x00cf92000000ffff       # 0x10 kernel data
    .quad 0x00cff2000000ffff       # 0x18 user data
    .quad 0x00affa000000ffff       # 0x20 user code
.Lgdt_end:
.Lgdt_ptr:
    .word .Lgdt_end - .Lgdt - 1
    .quad .Lgdt

.section .bss
.align 16
.Luser_rsp:       .quad 0
.Luser_rip:       .quad 0
.Luser_flags:     .quad 0
.Luser_a5:        .quad 0
.Lsyscall_error:  .quad 0
.align 16
.Lsyscall_stack:
    .skip 16384
.Lsyscall_stack_top:
