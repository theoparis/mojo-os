# aarch64 Linux syscall numbers and the errno values we return.
#
# Kept separate from the dispatch/implementation modules so any part of the
# kernel (syscalls, tracing) can name them without pulling in the handlers.


# core syscalls we implement or recognize
comptime SYS_WRITE: UInt64 = 64
comptime SYS_READ: UInt64 = 63
comptime SYS_EXIT: UInt64 = 93
comptime SYS_EXIT_GROUP: UInt64 = 94
comptime SYS_BRK: UInt64 = 214
comptime SYS_MMAP: UInt64 = 222
comptime SYS_MUNMAP: UInt64 = 215
comptime SYS_MPROTECT: UInt64 = 226
comptime SYS_CLOSE: UInt64 = 57
comptime SYS_IOCTL: UInt64 = 29
comptime SYS_GETPID: UInt64 = 172
comptime SYS_GETPPID: UInt64 = 173
comptime SYS_UMASK: UInt64 = 166
comptime SYS_SIGACTION: UInt64 = 134
comptime SYS_SIGPROCMASK: UInt64 = 135
comptime SYS_SIGALTSTACK: UInt64 = 132
comptime SYS_GETRANDOM: UInt64 = 278
comptime SYS_CLOCK_GETTIME: UInt64 = 113
comptime SYS_SET_TID_ADDRESS: UInt64 = 96

# file / fs / identity syscalls served by the VFS (aarch64 numbers)
comptime SYS_FCNTL: UInt64 = 25
comptime SYS_WRITEV: UInt64 = 66
comptime SYS_GETCWD: UInt64 = 17
comptime SYS_FACCESSAT: UInt64 = 48
comptime SYS_CHDIR: UInt64 = 49
comptime SYS_OPENAT: UInt64 = 56
comptime SYS_GETDENTS64: UInt64 = 61
comptime SYS_LSEEK: UInt64 = 62
comptime SYS_NEWFSTATAT: UInt64 = 79
comptime SYS_FSTAT: UInt64 = 80
comptime SYS_GETUID: UInt64 = 174
comptime SYS_GETEUID: UInt64 = 175
comptime SYS_GETGID: UInt64 = 176
comptime SYS_GETEGID: UInt64 = 177
comptime SYS_UNAME: UInt64 = 160

# Linux errno returns, pre-encoded as UInt64 (they come back negative).
comptime E_NOSYS: UInt64 = 0xFFFFFFFFFFFFFFDA  # -38
comptime E_INVAL: UInt64 = 0xFFFFFFFFFFFFFFEA  # -22
comptime E_NOTTY: UInt64 = 0xFFFFFFFFFFFFFFE7  # -25
comptime E_MEM: UInt64 = 0xFFFFFFFFFFFFFFF4  # -12
comptime E_NOENT: UInt64 = 0xFFFFFFFFFFFFFFFE  # -2
comptime E_BADF: UInt64 = 0xFFFFFFFFFFFFFFF7  # -9
comptime E_ROFS: UInt64 = 0xFFFFFFFFFFFFFFE2  # -30
