# Mojo OS kernel entry point.
#
# This module owns kmain (boot orchestration) plus the two runtime glue
# exports the compiler/stdlib expect a freestanding program to provide:
#   * memcpy                    - the LLVM backend can lower some copies to a
#                                 libcall rather than inline them
#   * __mojo_baremetal_debug_write - debug_assert failure sink (see the
#                                 BareMetalPlugin in the patched stdlib)
# These exports must live in the top-level module passed to `mojo build`,
# because an @export in an imported-but-unreferenced module is not emitted.
from std.memory.pointer import Pointer
from std.ffi import external_call
from std.origin import MutUntrackedOrigin, UntrackedOrigin
from std.sys.defines import MOJO_VERSION
from std.sys.info import CompilationTarget

from console import print_int, print_str, print_uint, println, putc
from dtb import BootParams, MemRegions, parse_dtb
from elf import elf_image_end, elf_phdrs, load_elf
from kstate import (
    OFF_FREE_HEAD,
    OFF_L1,
    OFF_RAM_BASE,
    OFF_RAM_END,
    OFF_USER_BASE,
    OFF_USER_HI,
    brk_cur,
    get64,
    mmap_next,
    set64,
    set_brk,
    set_mmap_next,
    user_map,
    vfs,
    set_vfs,
)
from mem import read_u16, read_u64, read_u8, write_u64, write_u8
from paging import USER_VA_TOP, init_user_vm, map_user
from phys import PAGE_SIZE, PhysAlloc
from ramfs import unpack_cpio
from vfs import (
    add_file as vfs_add,
    close as vfs_close,
    fstat as vfs_fstat,
    getdents as vfs_getdents,
    lseek as vfs_lseek,
    mount as vfs_mount,
    open as vfs_open,
    read as vfs_read,
    resolve as vfs_resolve,
    stat_path as vfs_stat,
    stat_stdio as vfs_stat_stdio,
)

# aarch64 Linux syscall numbers we implement or recognize
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

# Userspace lives in the low 128MB VA space carved out of L1[0] by
# paging.mojo (user VA != PA). The EL0 stack sits at its very top
# (0x08000000 down) and anonymous mmaps descend from just below it. brk
# grows up from the end of the image and is capped at USER_HEAP_TOP, below
# which mmap never descends.
comptime USER_STACK_SIZE: Int = 0x10000  # 64KB initial user stack
comptime USER_HEAP_TOP: Int = 0x04000000  # brk cap == mmap floor (64MB)

# Linux errno returns, pre-encoded as UInt64 (they come back negative).
comptime E_NOSYS: UInt64 = 0xFFFFFFFFFFFFFFDA  # -38
comptime E_INVAL: UInt64 = 0xFFFFFFFFFFFFFFEA  # -22
comptime E_NOTTY: UInt64 = 0xFFFFFFFFFFFFFFE7  # -25
comptime E_MEM: UInt64 = 0xFFFFFFFFFFFFFFF4  # -12
comptime E_NOENT: UInt64 = 0xFFFFFFFFFFFFFFFE  # -2
comptime E_BADF: UInt64 = 0xFFFFFFFFFFFFFFF7  # -9
comptime E_ROFS: UInt64 = 0xFFFFFFFFFFFFFFE2  # -30


@export("memcpy")
def _memcpy(dest: Int, src: Int, n: Int) abi("C") -> Int:
    var d = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=dest
    )
    var s = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=src
    )
    for i in range(n):
        d[unsafe_offset=i] = s[unsafe_offset=i]
    return dest


@export("memset")
def _memset(dest: Int, val: Int, n: Int) abi("C") -> Int:
    var d = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=dest
    )
    var v = UInt8(val)
    for i in range(n):
        d[unsafe_offset=i] = v
    return dest


@export("__mojo_baremetal_debug_write")
def _mojo_baremetal_debug_write(message_addr: Int, length: Int) abi("C"):
    var ptr = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=message_addr
    )
    var msg_len = length
    if msg_len > 0 and ptr[unsafe_offset=msg_len - 1] == 0:
        msg_len -= 1
    print_str("[ASSERT] ")
    for i in range(msg_len):
        putc(ptr[unsafe_offset=i])
    putc(0x0A)


def _report_memory(mem: MemRegions):
    """Print the RAM regions read from the DTB /memory node."""
    print_str("[mem] ")
    print_uint(UInt64(mem.n()), 10)
    print_str(" region(s):\n")
    for i in range(mem.n()):
        print_str("      [0x")
        print_uint(mem.base(i), 16)
        print_str(", 0x")
        print_uint(mem.end(i), 16)
        print_str(")  size=0x")
        print_uint(mem.size(i), 16)
        putc(0x0A)


def _setup_allocator(
    mut alloc: PhysAlloc,
    mem: MemRegions,
    bp: BootParams,
    klo: UInt64,
    khi: UInt64,
) -> Bool:
    """Configure `alloc` over the first DTB RAM region, reserving all the
    ranges the kernel already occupies so it won't hand them out."""
    if mem.n() < 1:
        return False
    alloc.reserve(klo, khi)
    # Only the kernel image, initrd and DTB are carved out up front. User
    # pages no longer live in a reserved identity window -- map_user hands
    # out ordinary physical frames from this same allocator on demand.
    if bp.has_initrd:
        alloc.reserve(bp.initrd_start, bp.initrd_end)
    if bp.dtb_end > bp.dtb_start:
        alloc.reserve(bp.dtb_start, bp.dtb_end)
    alloc.init(mem.base(0), mem.end(0))
    return True


def _sys_brk(addr: Int) -> UInt64:
    """brk(addr): set/query the program break. Pages between the old and new
    break are mapped EL0 read/write on demand (no reclaim on shrink), capped
    below the top of the user heap region."""
    var cur = brk_cur()
    if addr == 0:
        return UInt64(cur)
    if addr <= cur:
        set_brk(addr)
        return UInt64(addr)
    # Grow: cap at the top of the low heap region, well below the stack.
    if addr > USER_HEAP_TOP:
        return E_MEM
    if not user_map(cur, addr - cur, False):
        return E_MEM
    set_brk(addr)
    return UInt64(addr)


def _sys_mmap(addr: Int, length: Int, prot: Int, flags: Int, fd: Int) -> UInt64:
    """mmap(addr, length, prot, flags, fd, offset): anonymous mappings only.

    Maps *virtual* addresses in the low user VA space onto fresh physical
    frames (read/write, executable if PROT_EXEC). A NULL addr carves a
    region from the TOP of the user VA space downward (mmap_next, just
    below the EL0 stack) so it never collides with brk, which grows up from
    the image end and is capped at USER_HEAP_TOP. MAP_FIXED maps at the
    requested address instead."""
    if length <= 0:
        return E_INVAL
    var anon = (flags & 0x20) != 0
    if not anon or fd != -1:
        print_str("[mmap] only MAP_ANONYMOUS (fd=-1) is supported\n")
        return E_NOSYS
    var page = PAGE_SIZE
    var nbytes = (length + page - 1) & ~(page - 1)
    var fixed = (flags & 0x10) != 0  # MAP_FIXED
    var base: Int
    if fixed:
        base = (addr + page - 1) & ~(page - 1)
    else:
        base = mmap_next() - nbytes
    if base < 0x10000 or base + nbytes > USER_VA_TOP:
        return E_MEM
    if not fixed and base < USER_HEAP_TOP:
        return E_MEM  # don't descend into the brk region
    var exec = (prot & 1) != 0
    if not user_map(base, nbytes, exec):
        return E_MEM
    if not fixed:
        set_mmap_next(base)
    return UInt64(base)


def _sys_getrandom(buf: Int, count: Int) -> UInt64:
    for i in range(count):
        write_u8(buf + i, 0)
    return UInt64(count)


def _sys_clock_gettime(buf: Int):
    # { time_t tv_sec; long tv_nsec; } both zero. Avoids crashing callers.
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=buf
    )
    p[] = 0
    p[unsafe_offset=1] = 0


def _syscall_seen(nr: Int) -> Bool:
    var word = nr // 64
    var bit = nr % 64
    var w = get64(64 + word * 8)
    return (w & (UInt64(1) << UInt64(bit))) != 0


def _syscall_mark(nr: Int):
    var word = nr // 64
    var bit = nr % 64
    var off = 64 + word * 8
    var w = get64(off)
    set64(off, w | (UInt64(1) << UInt64(bit)))


@export("ksyscall")
def ksyscall(
    n: UInt64,
    a0: UInt64,
    a1: UInt64,
    a2: UInt64,
    a3: UInt64,
    a4: UInt64,
    a5: UInt64,
) abi("C") -> UInt64:
    """Linux syscall dispatcher (arm64 numbers); called from the EL0 trap.

    x8 holds the number; args in x0..x5. Implementations are in this file
    (and src/kstate.mojo for shared state). Unknown syscalls are logged
    once and return -ENOSYS so we can discover what a real program needs.
    """
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
        return _sys_brk(Int(a0))
    if n == SYS_MMAP:
        return _sys_mmap(Int(a0), Int(a1), Int(a2), Int(a3), Int(a4))
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
        var toconsole = (wfd == 0 or wfd == 1 or wfd == 2)
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
        _sys_uname(Int(a0))
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
        return _sys_getrandom(Int(a1), Int(a2))
    if n == SYS_CLOCK_GETTIME:
        _sys_clock_gettime(Int(a1))
        return 0
    var nr = Int(n)
    if not _syscall_seen(nr):
        _syscall_mark(nr)
        print_str("[sys] unimplemented nr=")
        print_uint(UInt64(nr), 10)
        print_str(" a0=0x")
        print_uint(a0, 16)
        print_str(" a1=0x")
        print_uint(a1, 16)
        putc(0x0A)
    return E_NOSYS


def _copy_lit(addr: Int, lit: StringLiteral):
    """Copy a string literal (incl. NUL) to user memory at `addr`."""
    var p = lit.ptr()
    var i: Int = 0
    while True:
        var c = p[unsafe_offset=i]
        write_u8(addr + i, c)
        if c == 0:
            return
        i += 1


def _sys_uname(buf: Int):
    """uname: fill a Linux struct utsname (6 x char[65], 390 bytes)."""
    _copy_lit(buf + 0, "mojo-os")  # sysname
    _copy_lit(buf + 65, "mojo-os")  # nodename
    _copy_lit(buf + 130, "1.0.0")  # release
    _copy_lit(buf + 195, "mojo-os 1.0.0")  # version
    _copy_lit(buf + 260, "aarch64")  # machine
    _copy_lit(buf + 325, "(none)")  # domainname


def write_u64_word(addr: Int, v: Int):
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = UInt64(v)


comptime MAX_ARGV = 16


def _nul_len(addr: Int) -> Int:
    """Bytes of a NUL-terminated string at `addr`, including the NUL."""
    var i: Int = 0
    while read_u8(addr + i) != 0:
        i += 1
    return i + 1


def _cmp_word(w: Int, wlen: Int, lit: StringLiteral, want_exact: Bool) -> Bool:
    """Compare a cmdline word to a literal (prefix or exact match)."""
    var p = lit.ptr()
    var i: Int = 0
    while p[unsafe_offset=i] != 0:
        if i >= wlen:
            return False
        if read_u8(w + i) != p[unsafe_offset=i]:
            return False
        i += 1
    if want_exact:
        return i == wlen
    return True  # word starts with the literal


def _is_boot_word(w: Int, wlen: Int) -> Bool:
    """True if `w` is a kernel boot parameter (consumed, not passed on)."""
    if _cmp_word(w, wlen, "quiet", True) or _cmp_word(w, wlen, "rw", True):
        return True
    if _cmp_word(w, wlen, "ro", True) or _cmp_word(w, wlen, "nosmp", True):
        return True
    if _cmp_word(w, wlen, "console=", False):
        return True
    if _cmp_word(w, wlen, "rdinit=", False):
        return True
    if _cmp_word(w, wlen, "init=", False):
        return True
    if _cmp_word(w, wlen, "root=", False):
        return True
    if _cmp_word(w, wlen, "earlycon=", False):
        return True
    if _cmp_word(w, wlen, "loglevel=", False):
        return True
    return False


def _collect_argv(scr: Int, cmd: Int, cmdlen: Int) -> Int:
    """Build the argv list into the kernel scratch region `scr` and return
    argc. Region layout:
      scr+0          u64 argc
      scr+8          u64 argv[N] (kernel addrs of NUL strings)
      scr+8+8*MAX    string bytes
    argv[0] is always "busybox"; argv[1..] come from non-boot tokens on the
    DTB cmdline, or default to busybox "echo ..." when there are none."""
    var strp = scr + 8 + MAX_ARGV * 8
    # argv[0] = "busybox"
    _copy_lit(strp, "busybox")
    write_u64(scr + 8, UInt64(strp))
    strp += _nul_len(strp)
    var argc = 1

    if cmd != 0 and cmdlen > 0:
        var i: Int = 0
        while i < cmdlen:
            while i < cmdlen:
                var b = read_u8(cmd + i)
                if b != 0x20 and b != 0x09:  # not space / tab
                    break
                i += 1
            var ws = i
            while i < cmdlen:
                var b = read_u8(cmd + i)
                if b == 0x20 or b == 0x09:
                    break
                i += 1
            var wlen = i - ws
            if wlen > 0 and not _is_boot_word(cmd + ws, wlen):
                if argc >= MAX_ARGV:
                    break
                for j in range(wlen):
                    write_u8(strp + j, read_u8(cmd + ws + j))
                write_u8(strp + wlen, 0)
                write_u64(scr + 8 + argc * 8, UInt64(strp))
                strp += wlen + 1
                argc += 1

    if argc == 1:  # no app args on the cmdline: default busybox echo
        _copy_lit(strp, "echo")
        write_u64(scr + 8 + argc * 8, UInt64(strp))
        strp += _nul_len(strp)
        argc += 1
        _copy_lit(strp, "hello from busybox on mojo-os!")
        write_u64(scr + 8 + argc * 8, UInt64(strp))
        strp += _nul_len(strp)
        argc += 1
    write_u64(scr, UInt64(argc))
    return argc


def _build_user_stack(
    top: Int, entry: Int, phdr: Int, phnum: Int, argc: Int, argaddrs: Int
) -> Int:
    """Lay out an initial Linux process stack (argc/argv/envp/auxv) in the
    mapped stack region just below `top` and return the initial sp.

    `argc` argv strings (each NUL-terminated) are copied out of the kernel
    argv list at `argaddrs` (an array of `argc` u64 kernel addresses, as
    built by _collect_argv) into the user stack region.
    """
    var s = (top - 0x300) & ~15
    # 1) copy each argv string (kernel -> user), remembering the user addrs
    var strp = top - 0x200
    var uaddrs = Array[Int, MAX_ARGV](uninitialized=True)
    for i in range(argc):
        var src = Int(read_u64(argaddrs + i * 8))
        var d = strp
        while True:
            var b = read_u8(src)
            write_u8(d, b)
            d += 1
            src += 1
            if b == 0:
                break
        uaddrs[i] = strp
        strp = d
    # AT_RANDOM: 16 zero bytes right after the strings
    for i in range(16):
        write_u8(strp + i, 0)
    var rnd = strp
    strp += 16

    # 2) arrays from s: argc, argv[], NULL, envp NULL, auxv pairs, AT_NULL
    var p = s
    write_u64_word(p, argc)
    p += 8
    for i in range(argc):
        write_u64_word(p, uaddrs[i])
        p += 8
    write_u64_word(p, 0)  # argv terminator
    p += 8
    write_u64_word(p, 0)  # envp terminator (no environment yet)
    p += 8
    write_u64_word(p, 6)  # AT_PAGESZ
    p += 8
    write_u64_word(p, PAGE_SIZE)
    p += 8
    write_u64_word(p, 25)  # AT_RANDOM
    p += 8
    write_u64_word(p, rnd)
    p += 8
    if phdr > 0:
        write_u64_word(p, 3)  # AT_PHDR
        p += 8
        write_u64_word(p, phdr)
        p += 8
        write_u64_word(p, 4)  # AT_PHENT
        p += 8
        write_u64_word(p, 56)
        p += 8
        write_u64_word(p, 5)  # AT_PHNUM
        p += 8
        write_u64_word(p, phnum)
        p += 8
    write_u64_word(p, 0)  # AT_NULL
    p += 8
    write_u64_word(p, 0)
    return s


def _run_user(entry: Int, sp: Int):
    """Drop to EL0 at `entry` with the EL0 stack pointer at `sp`.

    Pages the image needs must already be mapped with EL0 access (see
    paging.mojo / elf.mojo); boot.S:run_user just erets.
    """
    external_call["run_user", NoneType](entry, sp)


@export("kmain")
def kmain(x0: Int, x1: Int, x2: Int, x3: Int) abi("C"):
    var arch = StringLiteral[CompilationTarget[].__triple_arch()]()
    println(
        t"Hello from bare-metal {arch}, built with Mojo"
        t" {MOJO_VERSION.major}.{MOJO_VERSION.minor}.{MOJO_VERSION.patch},"
        t" running on QEMU!\n"
    )

    # x0 = DTB physical address (Linux boot protocol); x1/x2 = kernel image
    # static extent [start, end); x3 = level-1 page-table address, as set up
    # by boot.S from linker symbols.
    var kernel_lo = UInt64(x1)
    var kernel_hi = UInt64(x2)
    var l1base = x3
    var mem = MemRegions()
    var bp = parse_dtb(x0, mem)
    if not bp.has_dtb:
        print_str("[dtb] none passed in x0\n")
    else:
        print_str("[dtb] @0x")
        print_uint(UInt64(x0), 16)
        if bp.has_initrd:
            print_str("  initrd [0x")
            print_uint(bp.initrd_start, 16)
            print_str(", 0x")
            print_uint(bp.initrd_end, 16)
            print_str(")")
        else:
            print_str("  no initrd in /chosen")
        putc(0x0A)
        if bp.cmdline_len > 0:
            print_str('[cmdline] "')
            var n = bp.cmdline_len
            if read_u8(bp.cmdline_addr + n - 1) == 0:
                n -= 1
            for i in range(n):
                putc(read_u8(bp.cmdline_addr + i))
            print_str('"\n')
        else:
            print_str("[cmdline] (none)\n")

    _report_memory(mem)
    var alloc = PhysAlloc()
    if _setup_allocator(alloc, mem, bp, kernel_lo, kernel_hi):
        print_str("[alloc] total free: 0x")
        print_uint(alloc.free_total(), 16)
        putc(0x0A)
        # Prepare the low user VA space before any user mapping. On 16KB
        # this is a no-op; on 4KB it splits L1[0] into a level-2 table.
        if not init_user_vm(alloc, l1base):
            print_str("[paging] init_user_vm failed\n")
    else:
        print_str("[alloc] no RAM region from /memory\n")

    if bp.has_initrd:
        var fs = unpack_cpio(Int(bp.initrd_start), Int(bp.initrd_end))
        print_str("[ramfs] unpacked ")
        print_uint(UInt64(fs.total()), 10)
        print_str(" file(s)\n")
        fs.list()

        # Mount the initrd as the persistent VFS for the file syscalls. The
        # region is allocated (never freed) and its address saved to kernel
        # state before we snapshot the allocator free-list head below.
        var vbase = alloc.alloc_pages(1)
        if vbase != 0:
            vfs_mount(Int(vbase))
            var mounted = 0
            for i in range(fs.total()):
                if vfs_add(
                    Int(vbase),
                    fs.name_addr(i),
                    fs.data_addr(i),
                    fs.entry_size(i),
                    UInt64(fs.entry_mode(i)),
                ):
                    mounted += 1
            set_vfs(Int(vbase))
            print_str("[vfs] mounted ")
            print_uint(UInt64(mounted), 10)
            print_str(" file(s) @0x")
            print_uint(vbase, 16)
            putc(0x0A)
        else:
            print_str("[vfs] alloc failed, files disabled\n")

        # A stable kernel scratch buffer for building the user argv list
        # (from the DTB cmdline). Allocated before the allocator snapshot so
        # syscall-time free-list re-attach doesn't reuse it.
        var argscr = alloc.alloc_pages(1)
        if argscr == 0:
            print_str("[argv] scratch alloc failed\n")

        var idx = fs.lookup("/init")
        if idx >= 0:
            print_str('[ramfs] lookup "/init" -> entry ')
            print_int(idx)
            print_str(" (size=")
            print_uint(UInt64(fs.entry_size(idx)), 10)
            print_str(")\n")

            var fdata = fs.data_addr(idx)
            var imgend = elf_image_end(fdata)
            var phdr = elf_phdrs(fdata)
            var phnum = Int(read_u16(fdata + 56))
            var entry = load_elf(alloc, l1base, fdata)

            if entry != 0 and mem.n() >= 1:
                # EL0 stack at the top of the user VA space, growing down.
                var stack_top = USER_VA_TOP
                var stack_base = stack_top - USER_STACK_SIZE
                if map_user(alloc, l1base, stack_base, USER_STACK_SIZE, False):
                    print_str("[user] stack [0x")
                    print_uint(UInt64(stack_base), 16)
                    print_str(", 0x")
                    print_uint(UInt64(stack_top), 16)
                    print_str(")\n")
                else:
                    print_str("[user] stack mapping failed\n")

                # Snapshot kernel state for the syscall layer once all the
                # static mappings (image + stack) are in place: allocator
                # free-list head, RAM bounds, L1 table, user VA space,
                # brk/mmap cursors.
                var heap_base = (imgend + 0xFFFF) & ~0xFFFF
                set64(OFF_FREE_HEAD, alloc.free_head)
                set64(OFF_RAM_BASE, mem.base(0))
                set64(OFF_RAM_END, mem.end(0))
                set64(OFF_L1, UInt64(l1base))
                set64(OFF_USER_BASE, 0)
                set64(OFF_USER_HI, UInt64(USER_VA_TOP))
                set_brk(heap_base)
                # Anonymous mmaps descend top-down from just below the stack,
                # so they can never collide with brk's upward growth.
                set_mmap_next(stack_base)

                print_str("[user] brk base=0x")
                print_uint(UInt64(heap_base), 16)
                print_str(" phdr=0x")
                print_uint(UInt64(phdr), 16)
                print_str("\n")
                var argc = _collect_argv(
                    Int(argscr), bp.cmdline_addr, bp.cmdline_len
                )
                var sp = _build_user_stack(
                    stack_top, entry, phdr, phnum, argc, Int(argscr) + 8
                )
                print_str("[user] entry=0x")
                print_uint(UInt64(entry), 16)
                print_str("\n[user] dropping to EL0...\n")
                _run_user(entry, sp)
            else:
                print_str("[elf] failed to load /init\n")
        else:
            print_str("[ramfs] /init not found\n")

    while True:
        _ = 0
