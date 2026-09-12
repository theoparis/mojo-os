# Darwin / XNU system call and Mach VM handlers.
#
# Memory allocators and system information queries compatible with Darwin.
from arch.mem import read_u64, write_u32, write_u64, write_u8
from core.kstate import (
    OFF_BRK,
    OFF_FREE_HEAD,
    OFF_L1,
    OFF_MMAP,
    OFF_RAM_BASE,
    OFF_RAM_END,
    get64,
    set64,
    set_brk,
    set_mmap_next,
)
from mm.paging import map_user
from mm.phys import PAGE_MASK, PAGE_SHIFT, PAGE_SIZE, PhysAlloc
from sys.syscall_nr import (
    DARWIN_EFAULT,
    DARWIN_EINVAL,
    DARWIN_ENOMEM,
    KERN_INVALID_ADDRESS,
    KERN_INVALID_ARGUMENT,
    KERN_NO_SPACE,
    KERN_SUCCESS,
)


def sys_darwin_mmap(
    addr: Int,
    length: Int,
    prot: Int,
    flags: Int,
    fd: Int,
    offset: Int,
    mut is_err: Bool,
) -> UInt64:
    """Implement Darwin mmap. Returns mapped address or errno."""
    if length <= 0:
        is_err = True
        return DARWIN_EINVAL

    var alloc = PhysAlloc()
    alloc.free_head = get64(OFF_FREE_HEAD)
    alloc.ram_base = get64(OFF_RAM_BASE)
    alloc.ram_end = get64(OFF_RAM_END)

    var l1 = Int(get64(OFF_L1))
    var cur = Int(get64(OFF_MMAP))
    var aligned_len = (length + PAGE_MASK) & ~PAGE_MASK
    var target = cur - aligned_len

    var brk_val = Int(get64(OFF_BRK))
    if target <= brk_val:
        is_err = True
        return DARWIN_ENOMEM

    # Darwin PROT_EXEC is 0x4
    var exec = (prot & 0x4) != 0
    if not map_user(alloc, l1, target, aligned_len, exec):
        is_err = True
        return DARWIN_ENOMEM

    set_mmap_next(target)
    set64(OFF_FREE_HEAD, alloc.free_head)
    is_err = False
    return UInt64(target)


def mach_vm_allocate(
    target_task: UInt64,
    addr_ptr: Int,
    size: UInt64,
    flags: UInt64,
) -> UInt64:
    """Mach trap: allocate zero-filled virtual memory for a task."""
    if size == 0:
        return KERN_INVALID_ARGUMENT

    var alloc = PhysAlloc()
    alloc.free_head = get64(OFF_FREE_HEAD)
    alloc.ram_base = get64(OFF_RAM_BASE)
    alloc.ram_end = get64(OFF_RAM_END)

    var l1 = Int(get64(OFF_L1))
    var cur = Int(get64(OFF_MMAP))
    var aligned_len = (Int(size) + PAGE_MASK) & ~PAGE_MASK
    var target = cur - aligned_len

    var brk_val = Int(get64(OFF_BRK))
    if target <= brk_val:
        return KERN_NO_SPACE

    if not map_user(alloc, l1, target, aligned_len, False):
        return KERN_NO_SPACE

    set_mmap_next(target)
    set64(OFF_FREE_HEAD, alloc.free_head)

    # Write back allocated address to user pointer
    if addr_ptr != 0:
        write_u64(addr_ptr, UInt64(target))

    return KERN_SUCCESS


def mach_vm_deallocate(
    target_task: UInt64,
    address: UInt64,
    size: UInt64,
) -> UInt64:
    """Mach trap: deallocate virtual memory range (stub accepted)."""
    return KERN_SUCCESS


def mach_timebase_info(info_ptr: Int) -> UInt64:
    """mach_timebase_info_trap: returns numer/denom ratio for ticks to nanoseconds.
    """
    if info_ptr == 0:
        return KERN_INVALID_ARGUMENT
    # 1/1 ratio (nanoseconds direct)
    write_u32(info_ptr + 0, 1)  # numer
    write_u32(info_ptr + 4, 1)  # denom
    return KERN_SUCCESS


def sys_darwin_gettimeofday(tp: Int, tzp: Int) -> UInt64:
    """BSD gettimeofday(struct timeval *tp, struct timezone *tzp)."""
    if tp != 0:
        write_u64(tp + 0, 1700000000)  # tv_sec
        write_u32(tp + 8, 0)  # tv_usec
        write_u32(tp + 12, 0)
    if tzp != 0:
        write_u32(tzp + 0, 0)
        write_u32(tzp + 4, 0)
    return 0
