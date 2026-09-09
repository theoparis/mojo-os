/* A tiny freestanding /init for the Mojo OS: no libc, just raw Linux
 * arm64 syscalls via inline asm (svc #0, x8 = syscall number). Compiled
 * with clang targeting aarch64-none-elf and linked as a static, non-PIE
 * ET_EXEC binary by src/user/user.ld -- see the Makefile's `init` rule.
 *
 * This is the whole point of the exercise: the kernel's ELF loader
 * (src/elf.mojo) loads this exact binary out of the cpio initrd and runs
 * it at EL0, and its syscalls are serviced by the kernel's ksyscall
 * (src/kernel.mojo) via the EL0 trap handler in boot.S.
 */

static long sys_write(long fd, const void *buf, long count) {
    register long x0 asm("x0") = fd;
    register long x1 asm("x1") = (long)buf;
    register long x2 asm("x2") = count;
    register long x8 asm("x8") = 64; /* __NR_write */
    asm volatile("svc #0"
                 : "+r"(x0)
                 : "r"(x1), "r"(x2), "r"(x8)
                 : "memory");
    return x0;
}

static void sys_exit(long code) {
    register long x0 asm("x0") = code;
    register long x8 asm("x8") = 93; /* __NR_exit */
    asm volatile("svc #0" : : "r"(x0), "r"(x8) : "memory");
    __builtin_unreachable();
}

void _start(void) {
    const char msg[] = "Hello from a clang-compiled userspace ELF!\n";
    sys_write(1, msg, sizeof(msg) - 1);
    sys_exit(0);
}
