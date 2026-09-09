.section ".text.boot"
.global _start

.equ UART_BASE, 0x09000000
.equ UART_DR,   0x000
.equ UART_FR,   0x018
.equ UART_TXFF, 0x20

_start:
    // QEMU's `virt` machine passes boot parameters to the kernel entry in
    // x0-x3 (Linux boot protocol style): x0 = physical address of the DTB
    // (or 0 if none), x1-x3 = 0. Preserve them in callee-saved registers
    // before anything clobbers them, then hand them to kmain later.
    mov     x28, x0     // dtb pointer
    mov     x27, x1
    mov     x26, x2
    mov     x25, x3

    // Core check: only let core 0 proceed; park others
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbz     x0, .Lcpu_zero
.Lpark_cpu:
    wfe
    b       .Lpark_cpu

.Lcpu_zero:
    // Run the kernel in EL1h mode (its own SP_EL1 stack), so that EL0 user
    // code can freely use SP_EL0 without ever colliding with the kernel's
    // stack. (Exceptions from EL0 then arrive on SP_EL1 automatically.)
    msr     spsel, #1
    // Set up the EL1 stack pointer at the top of the reserved stack region.
    ldr     x0, =__stack_top
    mov     sp, x0

    // Clear the BSS section (not strictly needed for this tiny demo but critical for real OS development)
    ldr     x1, =__bss_start
    ldr     x2, =__bss_end
.Lclear_bss:
    cmp     x1, x2
    b.ge    .Lset_vbar
    str     xzr, [x1], #8
    b       .Lclear_bss

.Lset_vbar:
    // Install the exception vector table so hardware faults (alignment,
    // data/instruction aborts, etc.) print a diagnostic instead of hanging
    // silently forever.
    ldr     x0, =vectors
    msr     vbar_el1, x0
    isb

    // Enable FP/SIMD register access (CPACR_EL1.FPEN = 0b11 => don't trap
    // FP/SIMD instructions at EL1/EL0). The stdlib's formatting/bounds-
    // check machinery uses NEON registers even for plain integer work.
    mrs     x0, cpacr_el1
    orr     x0, x0, #(0x3 << 20)
    msr     cpacr_el1, x0
    isb

    bl      setup_mmu

.Ljump_kernel:
    // Jump to the Mojo entry symbol, handing over the boot parameters
    // preserved at _start (x0 = DTB physical address).
    mov     x0, x28
    mov     x1, x27
    mov     x2, x26
    mov     x3, x25
    bl      kmain

// Fail-safe catch loop
.Ldeadloop:
    wfi
    b       .Ldeadloop

// ---------------------------------------------------------------------
// Minimal identity-mapped MMU setup.
//
// With the MMU disabled (the reset default), *all* memory is implicitly
// treated as Device-nGnRnE, which architecturally forbids unaligned
// accesses no matter what SCTLR_EL1.A is set to. The stdlib's memcpy-style
// code deliberately issues unaligned (alignment=1) 32/64-bit loads/stores,
// so we need real Normal memory, which means a working MMU.
//
// Builds a single 4KB, 512-entry level-1 translation table (4KB granule,
// T0SZ=32 => 32-bit VA space => the level-1 table directly holds 1GB
// block descriptors, one per GB of address space). QEMU's `virt` machine
// puts peripherals (UART, GIC, ...) below 1GB and RAM at/above
// 0x40000000, so:
//   - block 0 (0x00000000-0x3FFFFFFF): Device-nGnRnE, non-executable
//   - block 1 (0x40000000-0x7FFFFFFF): Normal, cacheable (RAM/kernel)
//   - blocks 2-3: Device-nGnRnE as a safe default (unused by us)
// ---------------------------------------------------------------------
.equ MAIR_NORMAL_IDX,  0
.equ MAIR_DEVICE_IDX,  1
.equ MAIR_VALUE,       0x00000000000000FF  // idx0=Normal WB RW-alloc, idx1=Device-nGnRnE(0)

.equ TCR_VALUE,        0x0000000000803520  // T0SZ=32, IRGN0/ORGN0=WB, SH0=Inner, EPD1=1

.equ DESC_AF,          (1 << 10)
.equ DESC_SH_INNER,    (3 << 8)
.equ DESC_BLOCK,       0x1
.equ DESC_TABLE,       0x3
.equ DESC_UXN,         (1 << 54)
.equ DESC_PXN,         (1 << 53)
.equ DESC_AP_EL0,      (1 << 6)   // AP[2:1] = 01: EL1 RW + EL0 RW

// The level-2 table's 2MB entries [USER_L2_FIRST, USER_L2_LAST] (inclusive)
// are granted EL0 access -- this is where the first userspace process's
// code and stack will live (0x40000000 + USER_L2_FIRST*2MB, 4MB span).
.equ USER_L2_FIRST,    8
.equ USER_L2_LAST,     9

setup_mmu:
    stp     x30, x21, [sp, #-16]!

    // Zero the page table (all-zero entries are invalid, our safe default).
    ldr     x0, =__page_table
    mov     x1, #4096
    add     x1, x0, x1
.Lpt_zero:
    cmp     x0, x1
    b.ge    .Lpt_zero_done
    str     xzr, [x0], #8
    b       .Lpt_zero
.Lpt_zero_done:

    ldr     x21, =__page_table

    // Entry 0: 0x00000000, Device-nGnRnE, non-executable.
    mov     x0, #0
    orr     x0, x0, #(MAIR_DEVICE_IDX << 2)
    orr     x0, x0, #DESC_AF
    orr     x0, x0, #DESC_BLOCK
    orr     x0, x0, #DESC_UXN
    orr     x0, x0, #DESC_PXN
    str     x0, [x21, #0]

    // Entry 1: 0x40000000, Normal memory, cacheable, executable (RAM) --
    // but instead of one flat 1GB block (which would force the *entire*
    // kernel+RAM range to carry the same EL0 permission bit), point this
    // entry at a level-2 table of 2MB blocks, so only a small designated
    // sub-region can be granted EL0 access. Most of RAM (including the
    // kernel itself) stays EL1-only, matching the original behavior.
    ldr     x22, =__page_table_l2
    mov     x0, x22
    mov     x1, #4096
    add     x1, x0, x1
.Lpt2_zero:
    cmp     x0, x1
    b.ge    .Lpt2_zero_done
    str     xzr, [x0], #8
    b       .Lpt2_zero
.Lpt2_zero_done:

    mov     x23, #0             // loop index i (0..511)
    mov     x24, #0x40000000    // base address of entry i
.Ll2_loop:
    cmp     x23, #512
    b.ge    .Ll2_done
    mov     x0, x24
    orr     x0, x0, #DESC_AF
    orr     x0, x0, #DESC_SH_INNER
    orr     x0, x0, #DESC_BLOCK
    cmp     x23, #USER_L2_FIRST
    b.lt    .Ll2_store
    cmp     x23, #USER_L2_LAST
    b.gt    .Ll2_store
    orr     x0, x0, #DESC_AP_EL0
.Ll2_store:
    str     x0, [x22, x23, lsl #3]
    add     x24, x24, #0x200000
    add     x23, x23, #1
    b       .Ll2_loop
.Ll2_done:

    orr     x0, x22, #DESC_TABLE
    str     x0, [x21, #8]

    // Entries 2-3: Device-nGnRnE, non-executable (unused, safe default).
    mov     x2, #0x80000000
    mov     x1, #0x40000000
    mov     x0, x2
    orr     x0, x0, #(MAIR_DEVICE_IDX << 2)
    orr     x0, x0, #DESC_AF
    orr     x0, x0, #DESC_BLOCK
    orr     x0, x0, #DESC_UXN
    orr     x0, x0, #DESC_PXN
    str     x0, [x21, #16]
    add     x2, x2, x1
    mov     x0, x2
    orr     x0, x0, #(MAIR_DEVICE_IDX << 2)
    orr     x0, x0, #DESC_AF
    orr     x0, x0, #DESC_BLOCK
    orr     x0, x0, #DESC_UXN
    orr     x0, x0, #DESC_PXN
    str     x0, [x21, #24]

    ldr     x0, =MAIR_VALUE
    msr     mair_el1, x0
    ldr     x0, =TCR_VALUE
    msr     tcr_el1, x0
    msr     ttbr0_el1, x21
    isb

    mrs     x0, sctlr_el1
    bic     x0, x0, #(1 << 1)   // clear A (Alignment check enable)
    orr     x0, x0, #(1 << 0)   // set  M (MMU enable)
    orr     x0, x0, #(1 << 2)   // set  C (data cache enable)
    orr     x0, x0, #(1 << 12)  // set  I (instruction cache enable)
    msr     sctlr_el1, x0
    isb

    ldp     x30, x21, [sp], #16
    ret

// ---------------------------------------------------------------------
// Minimal AArch64 EL1 exception vector table.
//
// The table has 4 groups of 4 entries (Sync/IRQ/FIQ/SError), one group
// per exception source (Current EL w/ SP0, Current EL w/ SPx, Lower EL
// AArch64, Lower EL AArch32). Since we run at EL1h (SP_EL1 already
// loaded before this table is installed), only the second group's
// "Synchronous" entry is expected to ever fire in practice, but all 16
// are wired to the same diagnostic handler as a safety net. Each entry
// must be exactly 0x80 (128) bytes apart, and the table itself must be
// 2KB-aligned (enforced in linker.ld).
// ---------------------------------------------------------------------
.section ".text.vectors"
.align 11
.global vectors
vectors:
    // Synchronous, Current EL, SP0
    .align 7
    b       exc_handler
    // IRQ, Current EL, SP0
    .align 7
    b       exc_handler
    // FIQ, Current EL, SP0
    .align 7
    b       exc_handler
    // SError, Current EL, SP0
    .align 7
    b       exc_handler
    // Synchronous, Current EL, SPx  <-- the one we actually expect to hit
    .align 7
    b       exc_handler
    // IRQ, Current EL, SPx
    .align 7
    b       exc_handler
    // FIQ, Current EL, SPx
    .align 7
    b       exc_handler
    // SError, Current EL, SPx
    .align 7
    b       exc_handler
    // Synchronous, Lower EL, AArch64  <-- EL0 svc syscalls land here
    .align 7
    b       el0_sync
    // IRQ, Lower EL, AArch64
    .align 7
    b       exc_handler
    // FIQ, Lower EL, AArch64
    .align 7
    b       exc_handler
    // SError, Lower EL, AArch64
    .align 7
    b       exc_handler
    // Synchronous, Lower EL, AArch32
    .align 7
    b       exc_handler
    // IRQ, Lower EL, AArch32
    .align 7
    b       exc_handler
    // FIQ, Lower EL, AArch32
    .align 7
    b       exc_handler
    // SError, Lower EL, AArch32
    .align 7
    b       exc_handler

// ---------------------------------------------------------------------
// Shared exception handler: dump ESR_EL1 / ELR_EL1 / FAR_EL1 over the
// PL011 UART and halt. Written entirely in hand-rolled assembly (no
// Mojo runtime dependency) so it still works even if the fault was
// caused by stack corruption or some other broken runtime state.
// ---------------------------------------------------------------------
.section ".text"
exc_handler:
    mrs     x10, esr_el1
    mrs     x11, elr_el1
    mrs     x12, far_el1

    adr     x0, msg_exc
    bl      uart_puts
    mov     x0, x10
    bl      uart_puthex
    adr     x0, msg_elr
    bl      uart_puts
    mov     x0, x11
    bl      uart_puthex
    adr     x0, msg_far
    bl      uart_puts
    mov     x0, x12
    bl      uart_puthex
    adr     x0, msg_nl
    bl      uart_puts

.Lexc_halt:
    wfi
    b       .Lexc_halt

// ---------------------------------------------------------------------
// EL0 -> EL1 synchronous exception entry (svc syscalls, or a user fault).
//
// When EL0 traps we are already switched onto SP_EL1 (EL1h), so this saves
// the full EL0 context in a fixed frame on the kernel stack, dispatches
// syscalls, and restores + erets back to EL0. Only EC==0x15 (SVC from
// AArch64) is treated as a syscall; anything else is a user fault we report
// and halt on.
//
// Frame (relative to sp): x0..x30 at #0..#240, sp_el0@#248, elr@#256,
// spsr@#264, esr@#272. 320 bytes total (16-byte aligned).
// ---------------------------------------------------------------------
.equ EL0_FRAME,   320
.equ EL0_SVC,     0x15
.equ EL0_MSGLEN,  26

el0_sync:
    sub     sp, sp, #EL0_FRAME
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    mrs     x0, sp_el0
    str     x0, [sp, #248]
    mrs     x0, elr_el1
    str     x0, [sp, #256]
    mrs     x0, spsr_el1
    str     x0, [sp, #264]
    mrs     x0, esr_el1
    str     x0, [sp, #272]

    // EC = esr_el1 bits [31:26]; treat only 0x15 (SVC) as a syscall.
    lsr     x0, x0, #26
    cmp     x0, #EL0_SVC
    b.ne    .Lel0_fault

    // Load the syscall arguments and call the Mojo syscall dispatcher.
    // Kernel calling convention: x0 = nr, x1..x6 = args (user x8, x0..x5).
    ldr     x0, [sp, #64]   // syscall number (user x8)
    ldr     x1, [sp, #0]    // a0
    ldr     x2, [sp, #8]    // a1
    ldr     x3, [sp, #16]   // a2
    ldr     x4, [sp, #24]
    ldr     x5, [sp, #32]
    ldr     x6, [sp, #40]
    bl      ksyscall
    str     x0, [sp, #0]    // return value lands in user x0
    b       .Lel0_return

.Lel0_fault:
    adr     x0, msg_el0_fault
    bl      uart_puts
    b       .Lexc_halt

.Lel0_return:
    // Restore ELR/SPSR/SP_EL0, then the GPRs (base is sp), and eret.
    ldr     x0, [sp, #264]
    msr     spsr_el1, x0
    ldr     x0, [sp, #256]
    msr     elr_el1, x0
    ldr     x0, [sp, #248]
    msr     sp_el0, x0
    ldp     x1, x2, [sp, #8]
    ldp     x3, x4, [sp, #24]
    ldp     x5, x6, [sp, #40]
    ldp     x7, x8, [sp, #56]
    ldp     x9, x10, [sp, #72]
    ldp     x11, x12, [sp, #88]
    ldp     x13, x14, [sp, #104]
    ldp     x15, x16, [sp, #120]
    ldp     x17, x18, [sp, #136]
    ldp     x19, x20, [sp, #152]
    ldp     x21, x22, [sp, #168]
    ldp     x23, x24, [sp, #184]
    ldp     x25, x26, [sp, #200]
    ldp     x27, x28, [sp, #216]
    ldp     x29, x30, [sp, #232]
    ldr     x0, [sp, #0]
    add     sp, sp, #EL0_FRAME
    eret

// launch_el0: drop the CPU to EL0. x0 = entry point, x1 = EL0 stack top.
launch_el0:
    msr     sp_el0, x1
    msr     elr_el1, x0
    mov     x2, #0x3C0         // SPSR: DAIF masked, EL0t
    msr     spsr_el1, x2
    isb
    eret

// ---------------------------------------------------------------------
// EL0 self-test stub (proves the EL0 + syscall machinery before we build
// an ELF loader): writes a message via the write syscall, then exits.
// ---------------------------------------------------------------------
.equ USER_CODE_BASE, 0x41000000   // start of the EL0-accessible 4MB region

.global __el0_selftest
__el0_selftest:
    // write(1, el0_msg, EL0_MSGLEN). el0_msg itself stays in kernel .rodata
    // (only ksyscall/EL1 ever dereferences it, so it doesn't need to move),
    // but this *code* does, since it needs EL0 execute permission.
    ldr     x1, =el0_msg
    mov     x0, #1
    mov     x2, #EL0_MSGLEN
    mov     x8, #64            // __NR_write (arm64)
    svc     #0
    // exit(0)
    mov     x0, #0
    mov     x8, #93            // __NR_exit (arm64)
    svc     #0
.Lself_dead:
    b       .Lself_dead
.ltorg
__el0_selftest_end:

.global __run_el0_selftest
__run_el0_selftest:
    // Copy the self-test code (and its literal pool) into the EL0-
    // accessible user region -- it's linked as part of the kernel image,
    // which is EL1-only, so it can't be executed in place from EL0.
    ldr     x0, =__el0_selftest
    ldr     x1, =__el0_selftest_end
    ldr     x2, =USER_CODE_BASE
.Lselftest_copy:
    cmp     x0, x1
    b.ge    .Lselftest_copy_done
    ldrb    w3, [x0], #1
    strb    w3, [x2], #1
    b       .Lselftest_copy
.Lselftest_copy_done:
    ldr     x0, =USER_CODE_BASE
    ldr     x1, =__el0_stack_top
    b       launch_el0

// uart_putc: character (zero-extended) in w0. Clobbers x1-x2.
uart_putc:
    ldr     x1, =UART_BASE
.Lputc_wait:
    ldr     w2, [x1, #UART_FR]
    tst     w2, #UART_TXFF
    b.ne    .Lputc_wait
    str     w0, [x1, #UART_DR]
    ret

// uart_puts: NUL-terminated string pointer in x0.
uart_puts:
    stp     x19, x30, [sp, #-16]!
    mov     x19, x0
.Lputs_loop:
    ldrb    w0, [x19], #1
    cbz     w0, .Lputs_done
    bl      uart_putc
    b       .Lputs_loop
.Lputs_done:
    ldp     x19, x30, [sp], #16
    ret

// uart_puthex: 64-bit value in x0; prints "0x" followed by 16 hex digits.
uart_puthex:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    mov     x19, x0
    mov     w0, #'0'
    bl      uart_putc
    mov     w0, #'x'
    bl      uart_putc
    mov     x20, #60            // start at the top nibble (bits 63:60)
.Lhex_loop:
    lsr     x21, x19, x20
    and     x21, x21, #0xF
    cmp     x21, #10
    b.lt    .Lhex_digit
    add     w0, w21, #('a' - 10)
    b       .Lhex_emit
.Lhex_digit:
    add     w0, w21, #'0'
.Lhex_emit:
    bl      uart_putc
    subs    x20, x20, #4
    b.ge    .Lhex_loop
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

.section ".rodata"
msg_exc: .asciz "\n[EXCEPTION] esr_el1="
msg_elr: .asciz " elr_el1="
msg_far: .asciz " far_el1="
msg_nl:  .asciz "\n"
msg_el0_fault: .asciz "\n[EL0] unexpected exception (non-svc)\n"
el0_msg: .asciz "Hello from EL0 userspace!\n"
