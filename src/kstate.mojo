# Kernel state shared between kmain (boot) and the syscall dispatcher.
#
# Lives at linker symbol __kstate (256 bytes inside BSS, zeroed at boot,
# see src/linker.ld). Both kmain and ksyscall access fields by fixed
# offsets through raw 64-bit loads/stores, because a Mojo object can't be
# shared across the two exported functions. Fields (u64 each):
#   0   free list head of the physical allocator
#   8   RAM base / 16 RAM end (DTB /memory)
#   24  level-1 page-table address (TTBR0 / __page_table)
#   32  brk cursor (user program break)
#   40  next anonymous mmap address
#   48  user window base / 56 high end
#   64..92  bitmap of syscall numbers already reported as unimplemented
#   96   base address of the persistent VFS region (src/vfs.mojo)
from std.ffi import external_call

from mem import read_u64, write_u64
from paging import map_user
from phys import PhysAlloc

comptime OFF_FREE_HEAD: Int = 0
comptime OFF_RAM_BASE: Int = 8
comptime OFF_RAM_END: Int = 16
comptime OFF_L1: Int = 24
comptime OFF_BRK: Int = 32
comptime OFF_MMAP: Int = 40
comptime OFF_USER_BASE: Int = 48
comptime OFF_USER_HI: Int = 56
comptime OFF_TRACE: Int = 64
comptime OFF_VFS: Int = 96


def base() -> Int:
    """Physical address of the kernel-state area (boot.S:kstate_ptr)."""
    return external_call["kstate_ptr", Int]()


def get64(off: Int) -> UInt64:
    return read_u64(base() + off)


def set64(off: Int, v: UInt64):
    write_u64(base() + off, v)


def free_head() -> UInt64:
    return get64(OFF_FREE_HEAD)


def set_free_head(v: UInt64):
    set64(OFF_FREE_HEAD, v)


def ram_base() -> UInt64:
    return get64(OFF_RAM_BASE)


def ram_end() -> UInt64:
    return get64(OFF_RAM_END)


def l1() -> Int:
    return Int(get64(OFF_L1))


def brk_cur() -> Int:
    return Int(get64(OFF_BRK))


def set_brk(v: Int):
    set64(OFF_BRK, UInt64(v))


def mmap_next() -> Int:
    return Int(get64(OFF_MMAP))


def set_mmap_next(v: Int):
    set64(OFF_MMAP, UInt64(v))


def user_hi() -> Int:
    return Int(get64(OFF_USER_HI))


def vfs() -> Int:
    """Base address of the persistent VFS region, or 0 if not mounted."""
    return Int(get64(OFF_VFS))


def set_vfs(v: Int):
    set64(OFF_VFS, UInt64(v))


def user_map(va: Int, size: Int, exec: Bool) -> Bool:
    """Map user pages, attaching the allocator to the saved free list so the
    free-list head stays in kernel state across syscalls. VA is a user
    virtual address (in the low VA space); frames come from the allocator."""
    var a = PhysAlloc()
    a.attach(free_head(), ram_base(), ram_end())
    var ok = map_user(a, l1(), va, size, exec)
    set_free_head(a.free_head)
    return ok


def syscall_seen(nr: Int) -> Bool:
    """True if syscall `nr` (0..255) has already been logged as unknown."""
    var word = nr // 64
    var bit = nr % 64
    var w = get64(OFF_TRACE + word * 8)
    return (w & (UInt64(1) << UInt64(bit))) != 0


def syscall_mark(nr: Int):
    var word = nr // 64
    var bit = nr % 64
    var w = get64(OFF_TRACE + word * 8)
    set64(OFF_TRACE + word * 8, w | (UInt64(1) << UInt64(bit)))
