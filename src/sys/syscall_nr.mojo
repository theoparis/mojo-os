# Darwin / XNU system call numbers and Mach traps.
#
# References:
#   - XNU bsd/kern/syscalls.master
#   - XNU osfmk/mach/mach_traps.h
#   - XNU osfmk/kern/syscall_sw.c

# ------------------------------------------------------------------------
# Syscall class tags
# In Darwin 64-bit ABI (x86_64 and arm64):
#   - Positive/tagged syscalls with class 2 (0x2000000) are BSD syscalls.
#   - Negative trap numbers (or tagged with class 1 / 0x1000000) are Mach traps.
# ------------------------------------------------------------------------
comptime SYSCALL_CLASS_SHIFT: UInt64 = 24
comptime SYSCALL_CLASS_UNIX: UInt64 = 2
comptime SYSCALL_CLASS_MACH: UInt64 = 1

comptime SYS_BASE_UNIX: UInt64 = SYSCALL_CLASS_UNIX << SYSCALL_CLASS_SHIFT  # 0x2000000
comptime SYS_BASE_MACH: UInt64 = SYSCALL_CLASS_MACH << SYSCALL_CLASS_SHIFT  # 0x1000000

# ------------------------------------------------------------------------
# BSD System Calls (bare numbers, also available with SYS_BASE_UNIX mask)
# ------------------------------------------------------------------------
comptime BSD_SYS_EXIT: UInt64 = 1
comptime BSD_SYS_FORK: UInt64 = 2
comptime BSD_SYS_READ: UInt64 = 3
comptime BSD_SYS_WRITE: UInt64 = 4
comptime BSD_SYS_OPEN: UInt64 = 5
comptime BSD_SYS_CLOSE: UInt64 = 6
comptime BSD_SYS_CHDIR: UInt64 = 12
comptime BSD_SYS_GETPID: UInt64 = 20
comptime BSD_SYS_GETUID: UInt64 = 24
comptime BSD_SYS_GETEUID: UInt64 = 25
comptime BSD_SYS_SIGACTION: UInt64 = 46
comptime BSD_SYS_SIGPROCMASK: UInt64 = 48
comptime BSD_SYS_SIGALTSTACK: UInt64 = 53
comptime BSD_SYS_IOCTL: UInt64 = 54
comptime BSD_SYS_MUNMAP: UInt64 = 73
comptime BSD_SYS_MPROTECT: UInt64 = 74
comptime BSD_SYS_FCNTL: UInt64 = 92
comptime BSD_SYS_GETTIMEOFDAY: UInt64 = 116
comptime BSD_SYS_WRITEV: UInt64 = 121
comptime BSD_SYS_MMAP: UInt64 = 197
comptime BSD_SYS_LSEEK: UInt64 = 199
comptime BSD_SYS_SYSCTL: UInt64 = 202
comptime BSD_SYS_STAT64: UInt64 = 338
comptime BSD_SYS_FSTAT64: UInt64 = 339
comptime BSD_SYS_LSTAT64: UInt64 = 340
comptime BSD_SYS_GETDIRENTRIES64: UInt64 = 344
comptime BSD_SYS_OPEN_NOCANCEL: UInt64 = 398
comptime BSD_SYS_CLOSE_NOCANCEL: UInt64 = 399
comptime BSD_SYS_OPENAT: UInt64 = 463
comptime BSD_SYS_OPENAT_NOCANCEL: UInt64 = 464

# ------------------------------------------------------------------------
# Mach Traps (positive index as in mach_trap_table, or negative as in x16)
# e.g., mach_msg_trap = -31, task_self_trap = -28, host_self_trap = -29
# ------------------------------------------------------------------------
comptime MACH_TRAP_VM_ALLOCATE: UInt64 = 10
comptime MACH_TRAP_VM_DEALLOCATE: UInt64 = 12
comptime MACH_TRAP_VM_PROTECT: UInt64 = 14
comptime MACH_TRAP_VM_MAP: UInt64 = 15
comptime MACH_TRAP_PORT_ALLOCATE: UInt64 = 16
comptime MACH_TRAP_PORT_DEALLOCATE: UInt64 = 18
comptime MACH_TRAP_REPLY_PORT: UInt64 = 26
comptime MACH_TRAP_THREAD_SELF: UInt64 = 27
comptime MACH_TRAP_TASK_SELF: UInt64 = 28
comptime MACH_TRAP_HOST_SELF: UInt64 = 29
comptime MACH_TRAP_MSG: UInt64 = 31
comptime MACH_TRAP_MSG_OVERWRITE: UInt64 = 32
comptime MACH_TRAP_SEMAPHORE_SIGNAL: UInt64 = 33
comptime MACH_TRAP_SEMAPHORE_WAIT: UInt64 = 36
comptime MACH_TRAP_TIMEBASE_INFO: UInt64 = 89
comptime MACH_TRAP_WAIT_UNTIL: UInt64 = 90

# ARM64 fast time traps
comptime MACH_ARM_TRAP_ABSTIME: UInt64 = 0xFFFFFFFFFFFFFFFE  # -2
comptime MACH_ARM_TRAP_CONTTIME: UInt64 = 0xFFFFFFFFFFFFFFFD  # -3

# ------------------------------------------------------------------------
# Darwin / BSD Errno values (returned as positive integers, carry set)
# ------------------------------------------------------------------------
comptime DARWIN_EPERM: UInt64 = 1
comptime DARWIN_ENOENT: UInt64 = 2
comptime DARWIN_ESRCH: UInt64 = 3
comptime DARWIN_EINTR: UInt64 = 4
comptime DARWIN_EIO: UInt64 = 5
comptime DARWIN_EBADF: UInt64 = 9
comptime DARWIN_ENOMEM: UInt64 = 12
comptime DARWIN_EACCES: UInt64 = 13
comptime DARWIN_EFAULT: UInt64 = 14
comptime DARWIN_EINVAL: UInt64 = 22
comptime DARWIN_ENOTTY: UInt64 = 25
comptime DARWIN_EROFS: UInt64 = 30
comptime DARWIN_ENOSYS: UInt64 = 78

# Mach kern_return_t codes
comptime KERN_SUCCESS: UInt64 = 0
comptime KERN_INVALID_ADDRESS: UInt64 = 1
comptime KERN_PROTECTION_FAILURE: UInt64 = 2
comptime KERN_NO_SPACE: UInt64 = 3
comptime KERN_INVALID_ARGUMENT: UInt64 = 4
comptime KERN_FAILURE: UInt64 = 5
comptime KERN_RESOURCE_SHORTAGE: UInt64 = 6
comptime KERN_NOT_RECEIVER: UInt64 = 7
comptime KERN_NO_ACCESS: UInt64 = 8

# Special Mach Port Names
comptime MACH_PORT_NULL: UInt64 = 0
comptime MACH_PORT_DEAD: UInt64 = 0xFFFFFFFFFFFFFFFF
