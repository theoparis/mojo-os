# The Linux syscall dispatcher (arm64 numbers), called from the EL0 trap.
#
# x8 holds the number; args in x0..x5. Unknown syscalls are logged once and
# return -ENOSYS so we can discover what a real program needs. The
# memory-manipulating handlers live in sys/syscalls.mojo; file syscalls are
# served by the VFS in fs/vfs.mojo.
from arch.console import print_str, print_uint, putc
from arch.mem import read_u8, read_u64, write_u8
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
    E_BADF,
    E_INVAL,
    E_MEM,
    E_NOENT,
    E_NOSYS,
    E_NOTTY,
    E_ROFS,
    SYS_BRK,
    SYS_CHDIR,
    SYS_CLOCK_GETTIME,
    SYS_CLOSE,
    SYS_EXIT,
    SYS_EXIT_GROUP,
    SYS_FACCESSAT,
    SYS_FCNTL,
    SYS_FSTAT,
    SYS_GETCWD,
    SYS_GETDENTS64,
    SYS_GETEGID,
    SYS_GETEUID,
    SYS_GETGID,
    SYS_GETPID,
    SYS_GETPPID,
    SYS_GETRANDOM,
    SYS_GETUID,
    SYS_IOCTL,
    SYS_LSEEK,
    SYS_MMAP,
    SYS_MPROTECT,
    SYS_MUNMAP,
    SYS_NEWFSTATAT,
    SYS_OPENAT,
    SYS_READ,
    SYS_SET_TID_ADDRESS,
    SYS_SIGACTION,
    SYS_SIGALTSTACK,
    SYS_SIGPROCMASK,
    SYS_UMASK,
    SYS_UNAME,
    SYS_WRITE,
    SYS_WRITEV,
)
from sys.syscalls import (
    sys_brk,
    sys_clock_gettime,
    sys_getrandom,
    sys_mmap,
    sys_uname,
)


def dispatch(
    n: UInt64,
    a0: UInt64,
    a1: UInt64,
    a2: UInt64,
    a3: UInt64,
    a4: UInt64,
    a5: UInt64,
) -> UInt64:
    """Handle one Linux syscall and return its result (or -errno)."""
    var vb = vfs()  # persistent VFS base (0 if the initrd wasn't mounted)

    # write(fd, buf, count): fd 0/1/2 go to the UART console.
    if n == SYS_WRITE:
        var fdw = Int(a0)
        if fdw == 0 or fdw == 1 or fdw == 2:
            var buf = Int(a1)
            var cnt = Int(a2)
            for i in range(cnt):
                putc(read_u8(buf + i))
            return UInt64(cnt)
        return E_ROFS  # the ramfs is read-only
    # read(fd, buf, count): stdin is empty (EOF); files come from the VFS.
    if n == SYS_READ:
        var fdr = Int(a0)
        if fdr < 3:
            return 0  # EOF on stdin
        if vb == 0:
            return E_BADF
        return vfs_read(vb, fdr, Int(a1), Int(a2))
    # close(fd): never close stdio.
    if n == SYS_CLOSE:
        var fdc = Int(a0)
        if fdc < 3:
            return 0
        if vb == 0:
            return E_BADF
        return vfs_close(vb, fdc)
    # exit / exit_group: never return
    if n == SYS_EXIT or n == SYS_EXIT_GROUP:
        while True:
            _ = 0
    if n == SYS_BRK:
        return sys_brk(Int(a0))
    if n == SYS_MMAP:
        return sys_mmap(Int(a0), Int(a1), Int(a2), Int(a3), Int(a4))
    # munmap / mprotect: accepted no-ops (no reclaim of pages yet)
    if n == SYS_MUNMAP or n == SYS_MPROTECT:
        return 0
    if n == SYS_OPENAT:
        if vb == 0:
            return E_NOENT
        return vfs_open(vb, Int(a1), Int(a2))
    if n == SYS_LSEEK:
        if vb == 0:
            return E_BADF
        return vfs_lseek(vb, Int(a0), Int(a1), Int(a2))
    if n == SYS_GETDENTS64:
        if vb == 0:
            return E_BADF
        return vfs_getdents(vb, Int(a0), Int(a1), Int(a2))
    if n == SYS_FSTAT:
        if Int(a0) < 3:
            vfs_stat_stdio(Int(a1))
            return 0
        if vb == 0:
            return E_BADF
        return vfs_fstat(vb, Int(a0), Int(a1))
    if n == SYS_NEWFSTATAT:
        if vb == 0:
            return E_NOENT
        return vfs_stat(vb, Int(a1), Int(a2))
    if n == SYS_GETCWD:
        if Int(a1) < 2:
            return E_INVAL
        write_u8(Int(a0), 0x2F)  # '/'
        write_u8(Int(a0) + 1, 0)
        return 2
    if n == SYS_CHDIR:
        return 0  # root-only cwd for now
    # fcntl(fd, cmd, arg): satisfy the flag query/clear cmds busybox uses.
    if n == SYS_FCNTL:
        var fcmd = Int(a1)
        if fcmd == 1 or fcmd == 2 or fcmd == 4:  # F_GETFD/F_SETFD/F_SETFL
            return 0
        if fcmd == 3:  # F_GETFL -> O_RDONLY
            return 0
        return E_INVAL
    # writev(fd, iov, count): gather the iovecs; stdout/stderr -> UART.
    if n == SYS_WRITEV:
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
    if n == SYS_FACCESSAT:
        if vb == 0:
            return E_NOENT
        var o = vfs_open(vb, Int(a1), 0)
        if o < 3:
            return o  # propagate -errno
        return vfs_close(vb, Int(o))
    # identity: we run everything as root (uid/gid 0)
    if (
        n == SYS_GETUID
        or n == SYS_GETEUID
        or n == SYS_GETGID
        or n == SYS_GETEGID
    ):
        return 0
    if n == SYS_UNAME:
        sys_uname(Int(a0))
        return 0
    if n == SYS_IOCTL:
        return E_NOTTY  # not a tty; isatty() comes back false
    if n == SYS_GETPID:
        return 1  # we are PID 1
    if n == SYS_GETPPID:
        return 0
    if n == SYS_UMASK:
        return 0
    # signal APIs: accept and ignore for now
    if n == SYS_SIGACTION or n == SYS_SIGPROCMASK or n == SYS_SIGALTSTACK:
        return 0
    if n == SYS_SET_TID_ADDRESS:
        return 1
    if n == SYS_GETRANDOM:
        return sys_getrandom(Int(a1), Int(a2))
    if n == SYS_CLOCK_GETTIME:
        sys_clock_gettime(Int(a1))
        return 0
    var nr = Int(n)
    if not syscall_seen(nr):
        syscall_mark(nr)
        print_str("[sys] unimplemented nr=")
        print_uint(UInt64(nr), 10)
        print_str(" a0=0x")
        print_uint(a0, 16)
        print_str(" a1=0x")
        print_uint(a1, 16)
        putc(0x0A)
    return E_NOSYS
