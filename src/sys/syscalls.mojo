# Implementations of the individual syscalls that manipulate user memory
# (brk, mmap, getrandom, clock_gettime, uname).
#
# ksyscall in sys/dispatch.mojo dispatches to these; keeping them separate
# from the dispatcher keeps the (long) syscall-number switch readable.
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin

from arch.console import print_str
from arch.mem import copy_lit, write_u8
from core.kstate import brk_cur, mmap_next, set_brk, set_mmap_next, user_map
from mm.paging import USER_HEAP_TOP, USER_VA_TOP
from mm.phys import PAGE_SIZE
from sys.syscall_nr import E_INVAL, E_MEM, E_NOSYS


def sys_brk(addr: Int) -> UInt64:
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


def sys_mmap(addr: Int, length: Int, prot: Int, flags: Int, fd: Int) -> UInt64:
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


def sys_getrandom(buf: Int, count: Int) -> UInt64:
    for i in range(count):
        write_u8(buf + i, 0)
    return UInt64(count)


def sys_clock_gettime(buf: Int):
    # { time_t tv_sec; long tv_nsec; } both zero. Avoids crashing callers.
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=buf
    )
    p[] = 0
    p[unsafe_offset=1] = 0


def sys_uname(buf: Int):
    """uname: fill a Linux struct utsname (6 x char[65], 390 bytes)."""
    copy_lit(buf + 0, "mojo-os")  # sysname
    copy_lit(buf + 65, "mojo-os")  # nodename
    copy_lit(buf + 130, "1.0.0")  # release
    copy_lit(buf + 195, "mojo-os 1.0.0")  # version
    copy_lit(buf + 260, "aarch64")  # machine
    copy_lit(buf + 325, "(none)")  # domainname
