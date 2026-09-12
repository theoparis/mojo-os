# The Darwin / XNU syscall & Mach trap dispatcher.
#
# Syscall ABI Conventions:
# - User state (passed in trap frame):
#     x16 (or eax): System call / Mach trap number.
#     args: x0..x5 (or rdi, rsi, rdx, r10, r8, r9).
# - Numbering:
#     POSIX/BSD syscalls: either tagged with class 2 (nr & 0xFF000000 == 0x2000000)
#       or bare positive numbers (1 = exit, 3 = read, 4 = write, etc.).
#     Mach traps: negative numbers (e.g. -28 = task_self, -31 = mach_msg,
#       -10 = mach_vm_allocate), or positive 1..127.
# - Return values:
#     On success: return result in ret0 (x0 / rax); is_error = False.
#     On error: return positive errno in ret0 (x0 / rax); is_error = True (triggers PSR64_CF).
from arch.console import print_str, print_uint, putc
from arch.mem import read_u64, read_u8, write_u8
from core.kstate import syscall_mark, syscall_seen, vfs
from fs.vfs import (
    close as vfs_close,
    fstat as vfs_fstat,
    getdents as vfs_getdents,
    lseek as vfs_lseek,
    open as vfs_open,
    read_fd as vfs_read,
    stat_path as vfs_stat,
    stat_stdio as vfs_stat_stdio,
)
from sys.syscall_nr import (
    BSD_SYS_CHDIR,
    BSD_SYS_CLOSE,
    BSD_SYS_CLOSE_NOCANCEL,
    BSD_SYS_EXIT,
    BSD_SYS_FCNTL,
    BSD_SYS_FORK,
    BSD_SYS_FSTAT64,
    BSD_SYS_GETDIRENTRIES64,
    BSD_SYS_GETEUID,
    BSD_SYS_GETPID,
    BSD_SYS_GETTIMEOFDAY,
    BSD_SYS_GETUID,
    BSD_SYS_IOCTL,
    BSD_SYS_LSEEK,
    BSD_SYS_LSTAT64,
    BSD_SYS_MMAP,
    BSD_SYS_MPROTECT,
    BSD_SYS_MUNMAP,
    BSD_SYS_OPEN,
    BSD_SYS_OPEN_NOCANCEL,
    BSD_SYS_OPENAT,
    BSD_SYS_OPENAT_NOCANCEL,
    BSD_SYS_READ,
    BSD_SYS_SIGACTION,
    BSD_SYS_SIGALTSTACK,
    BSD_SYS_SIGPROCMASK,
    BSD_SYS_STAT64,
    BSD_SYS_SYSCTL,
    BSD_SYS_WRITE,
    BSD_SYS_WRITEV,
    DARWIN_EBADF,
    DARWIN_EINVAL,
    DARWIN_ENOENT,
    DARWIN_ENOSYS,
    DARWIN_ENOTTY,
    DARWIN_EROFS,
    KERN_SUCCESS,
    MACH_ARM_TRAP_ABSTIME,
    MACH_ARM_TRAP_CONTTIME,
    MACH_PORT_DEAD,
    MACH_PORT_NULL,
    MACH_TRAP_HOST_SELF,
    MACH_TRAP_MSG,
    MACH_TRAP_MSG_OVERWRITE,
    MACH_TRAP_PORT_ALLOCATE,
    MACH_TRAP_PORT_DEALLOCATE,
    MACH_TRAP_REPLY_PORT,
    MACH_TRAP_SEMAPHORE_SIGNAL,
    MACH_TRAP_SEMAPHORE_WAIT,
    MACH_TRAP_TASK_SELF,
    MACH_TRAP_THREAD_SELF,
    MACH_TRAP_TIMEBASE_INFO,
    MACH_TRAP_VM_ALLOCATE,
    MACH_TRAP_VM_DEALLOCATE,
    MACH_TRAP_VM_MAP,
    MACH_TRAP_VM_PROTECT,
    MACH_TRAP_WAIT_UNTIL,
    SYS_BASE_MACH,
    SYS_BASE_UNIX,
)
from sys.syscalls import (
    mach_timebase_info,
    mach_vm_allocate,
    mach_vm_deallocate,
    sys_darwin_gettimeofday,
    sys_darwin_mmap,
)


def dispatch(
    n: UInt64,
    a0: UInt64,
    a1: UInt64,
    a2: UInt64,
    a3: UInt64,
    a4: UInt64,
    a5: UInt64,
    mut is_error: Bool,
) -> UInt64:
    """Handle Darwin syscall or Mach trap and return result.

    Sets `is_error = True` if an error occurred (so PSR64 carry flag will be set).
    """
    is_error = False
    var vb = vfs()

    # Detect Mach trap vs Unix syscall:
    # 1) Negative numbers: e.g. -28 (0xFFFFFFFFFFFFFFE4) or fast time traps (-2, -3)
    # 2) Tagged with SYS_BASE_MACH (0x1000000)
    var is_mach: Bool
    var call_num: UInt64

    if (n & 0x8000000000000000) != 0:
        # Negative trap number: Mach trap
        is_mach = True
        call_num = ~n + 1  # negate to positive trap number
    elif (n & 0xFF000000) == SYS_BASE_MACH:
        is_mach = True
        call_num = n & 0x00FFFFFF
    elif (n & 0xFF000000) == SYS_BASE_UNIX:
        is_mach = False
        call_num = n & 0x00FFFFFF
    else:
        # Bare number: if small positive (1..500) treat as Unix syscall
        is_mach = False
        call_num = n

    # --------------------------------------------------------------------
    # Fast ARM64 time traps
    # --------------------------------------------------------------------
    if n == MACH_ARM_TRAP_ABSTIME or n == MACH_ARM_TRAP_CONTTIME:
        # Return a simulated monotonically increasing timestamp (in ticks/ns)
        return 1700000000000000

    # --------------------------------------------------------------------
    # Mach Traps
    # --------------------------------------------------------------------
    if is_mach:
        if call_num == MACH_TRAP_TASK_SELF:
            return 0x103  # Simulated task port send right
        if call_num == MACH_TRAP_THREAD_SELF:
            return 0x203  # Simulated thread port send right
        if call_num == MACH_TRAP_HOST_SELF:
            return 0x303  # Simulated host port send right
        if call_num == MACH_TRAP_REPLY_PORT:
            return 0x403  # Simulated reply port
        if call_num == MACH_TRAP_VM_ALLOCATE or call_num == MACH_TRAP_VM_MAP:
            var ret = mach_vm_allocate(a0, Int(a1), a2, a3)
            if ret != KERN_SUCCESS:
                is_error = True
            return ret
        if call_num == MACH_TRAP_VM_DEALLOCATE:
            return mach_vm_deallocate(a0, a1, a2)
        if call_num == MACH_TRAP_VM_PROTECT:
            return KERN_SUCCESS
        if call_num == MACH_TRAP_PORT_ALLOCATE:
            return KERN_SUCCESS
        if call_num == MACH_TRAP_PORT_DEALLOCATE:
            return KERN_SUCCESS
        if call_num == MACH_TRAP_TIMEBASE_INFO:
            return mach_timebase_info(Int(a0))
        if call_num == MACH_TRAP_WAIT_UNTIL:
            return KERN_SUCCESS
        if call_num == MACH_TRAP_SEMAPHORE_SIGNAL:
            return KERN_SUCCESS
        if call_num == MACH_TRAP_SEMAPHORE_WAIT:
            return KERN_SUCCESS
        if call_num == MACH_TRAP_MSG or call_num == MACH_TRAP_MSG_OVERWRITE:
            # Handle mach_msg_trap stub (e.g. IPC bootstrap or ping)
            return KERN_SUCCESS

        # Unimplemented Mach trap
        var tnum = Int(call_num)
        if not syscall_seen(tnum):
            syscall_mark(tnum)
            print_str("[mach] unimplemented trap nr=")
            print_uint(call_num, 10)
            putc(0x0A)
        return KERN_SUCCESS

    # --------------------------------------------------------------------
    # BSD System Calls
    # --------------------------------------------------------------------
    if call_num == BSD_SYS_WRITE:
        var fdw = Int(a0)
        if fdw == 0 or fdw == 1 or fdw == 2:
            var buf = Int(a1)
            var cnt = Int(a2)
            for i in range(cnt):
                putc(read_u8(buf + i))
            return UInt64(cnt)
        is_error = True
        return DARWIN_EROFS

    if call_num == BSD_SYS_READ:
        var fdr = Int(a0)
        if fdr < 3:
            return 0  # stdin EOF
        if vb == 0:
            is_error = True
            return DARWIN_EBADF
        return vfs_read(vb, fdr, Int(a1), Int(a2))

    if call_num == BSD_SYS_CLOSE or call_num == BSD_SYS_CLOSE_NOCANCEL:
        var fdc = Int(a0)
        if fdc < 3:
            return 0
        if vb == 0:
            is_error = True
            return DARWIN_EBADF
        return vfs_close(vb, fdc)

    if call_num == BSD_SYS_EXIT:
        print_str("[user] exit(")
        print_uint(a0, 10)
        print_str(") - halting cleanly\n")
        while True:
            _ = 0

    if call_num == BSD_SYS_MMAP:
        var err: Bool = False
        var res = sys_darwin_mmap(
            Int(a0), Int(a1), Int(a2), Int(a3), Int(a4), Int(a5), err
        )
        is_error = err
        return res

    if call_num == BSD_SYS_MUNMAP or call_num == BSD_SYS_MPROTECT:
        return 0

    if (
        call_num == BSD_SYS_OPEN
        or call_num == BSD_SYS_OPEN_NOCANCEL
        or call_num == BSD_SYS_OPENAT
        or call_num == BSD_SYS_OPENAT_NOCANCEL
    ):
        if vb == 0:
            is_error = True
            return DARWIN_ENOENT
        var path_addr = Int(a0)
        var flags = Int(a1)
        if call_num == BSD_SYS_OPENAT or call_num == BSD_SYS_OPENAT_NOCANCEL:
            path_addr = Int(a1)
            flags = Int(a2)
        var fd = vfs_open(vb, path_addr, flags)
        if fd >= 0x8000000000000000:  # error
            is_error = True
            return DARWIN_ENOENT
        return fd

    if call_num == BSD_SYS_LSEEK:
        if vb == 0:
            is_error = True
            return DARWIN_EBADF
        var pos = vfs_lseek(vb, Int(a0), Int(a1), Int(a2))
        if pos >= 0x8000000000000000:
            is_error = True
            return DARWIN_EINVAL
        return pos

    if call_num == BSD_SYS_GETDIRENTRIES64:
        if vb == 0:
            is_error = True
            return DARWIN_EBADF
        return vfs_getdents(vb, Int(a0), Int(a1), Int(a2))

    if call_num == BSD_SYS_FSTAT64:
        if Int(a0) < 3:
            vfs_stat_stdio(Int(a1))
            return 0
        if vb == 0:
            is_error = True
            return DARWIN_EBADF
        var st = vfs_fstat(vb, Int(a0), Int(a1))
        if st != 0:
            is_error = True
            return DARWIN_EBADF
        return 0

    if call_num == BSD_SYS_STAT64 or call_num == BSD_SYS_LSTAT64:
        if vb == 0:
            is_error = True
            return DARWIN_ENOENT
        var st = vfs_stat(vb, Int(a0), Int(a1))
        if st != 0:
            is_error = True
            return DARWIN_ENOENT
        return 0

    if call_num == BSD_SYS_CHDIR:
        return 0

    if call_num == BSD_SYS_WRITEV:
        var wfd = Int(a0)
        var iov = Int(a1)
        var cnt = Int(a2)
        var total: Int = 0
        var toconsole = wfd == 0 or wfd == 1 or wfd == 2
        for k in range(cnt):
            var base = Int(read_u64(iov + k * 16))
            var len = Int(read_u64(iov + k * 16 + 8))
            total += len
            if toconsole:
                for i in range(len):
                    putc(read_u8(base + i))
        return UInt64(total)

    if call_num == BSD_SYS_GETPID:
        return 1

    if call_num == BSD_SYS_GETUID or call_num == BSD_SYS_GETEUID:
        return 0

    if call_num == BSD_SYS_IOCTL:
        is_error = True
        return DARWIN_ENOTTY

    if (
        call_num == BSD_SYS_SIGACTION
        or call_num == BSD_SYS_SIGPROCMASK
        or call_num == BSD_SYS_SIGALTSTACK
    ):
        return 0

    if call_num == BSD_SYS_FCNTL:
        return 0

    if call_num == BSD_SYS_GETTIMEOFDAY:
        return sys_darwin_gettimeofday(Int(a0), Int(a1))

    if call_num == BSD_SYS_SYSCTL:
        return 0

    var nr = Int(call_num)
    if not syscall_seen(nr):
        syscall_mark(nr)
        print_str("[darwin] unimplemented bsd syscall nr=")
        print_uint(UInt64(nr), 10)
        print_str(" a0=0x")
        print_uint(a0, 16)
        print_str(" a1=0x")
        print_uint(a1, 16)
        putc(0x0A)
    is_error = True
    return DARWIN_ENOSYS
