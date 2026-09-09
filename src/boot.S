.section ".text.boot"
.global _start

_start:
    // Core check: only let core 0 proceed; park others
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbz     x0, .Lcpu_zero
.Lpark_cpu:
    wfe
    b       .Lpark_cpu

.Lcpu_zero:
    // Set up a tiny stack pointer right below the kernel code start
    ldr     x0, =_start
    mov     sp, x0

    // Clear the BSS section (not strictly needed for this tiny demo but critical for real OS development)
    ldr     x1, =__bss_start
    ldr     x2, =__bss_end
.Lclear_bss:
    cmp     x1, x2
    b.ge    .Ljump_kernel
    str     xzr, [x1], #8
    b       .Lclear_bss

.Ljump_kernel:
    // Jump straight to the Mojo entry symbol
    bl      kmain

// Fail-safe catch loop
.Ldeadloop:
    wfi
    b       .Ldeadloop
