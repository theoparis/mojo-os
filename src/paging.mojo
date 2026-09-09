# Userspace virtual memory (proper paging: user VA != PA).
#
# The kernel itself runs on an *identity* map (VA == PA) built in boot.S: a
# 4KB-granule, T0SZ=32 level-1 table where L1[0] is a flat 1GB Device block
# (peripherals below 1GB), L1[1] points at a level-2 table of 2MB Normal
# blocks for RAM (0x40000000-0x80000000, all EL1-only), and L1[2..3] are
# Device. The kernel keeps using that identity map for itself.
#
# Userspace gets a *real virtual address space* in the low 128MB
# (0x00000000-0x08000000), distinct from physical memory. Standard
# non-PIE ET_EXEC binaries link at 0x400000 (e.g. static busybox), and
# Linux-compatible brk/mmap regions live in that same low VA range. User
# VAs are translated to physical frames handed out by the physical
# allocator, so nothing userspace touches is forced to sit at its physical
# address.
#
# To give userspace VAs we hang a second level-2 table under L1[0] (call it
# "L2-A", one fresh 4KB frame):
#   - slots 0..63  (VAs 0x00000000-0x08000000): the user VA space. Left
#     unmapped at first; pages are mapped at 4KB granularity via
#     lazily-created level-3 tables as the loader/syscalls demand them.
#   - slots 64..511 (VAs 0x08000000-0x40000000): Device-nGnRnE identity
#     blocks, mirroring the flat map so the kernel's MMIO (UART/GIC...)
#     still works after L1[0] is repointed.
# init_user_vm() builds and installs L2-A; map_user() maps user pages.
#
# Executable pages are mapped EL0 read/write+execute (AP[2:1]=01, UXN
# clear) and data/stack pages EL0 read/write non-executable (UXN set).
# Read-only pages (mprotect-style) would need a two-phase map (see the AP
# note in the old code) -- deferred until there's a proper mm layer.
#
# All of the shifts/counts below are 4KB-granule-specific; the notes on
# what changes for a 16KB granule are in docs/16k-pages.md.
from std.ffi import external_call
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin

from mem import read_u64, write_u64
from phys import PhysAlloc

comptime PAGE_SIZE: Int = 4096
comptime PAGE_MASK: Int = 4095
comptime SLOT_SIZE: Int = 0x200000  # one 2MB level-2 slot (512 x 4KB pages)
comptime USER_VA_TOP: Int = 0x08000000  # user VAs live in [0, this)
comptime USER_SLOTS: Int = USER_VA_TOP // SLOT_SIZE  # = 64 L2 slots

# descriptor bits (4KB granule, stage 1)
comptime D_PAGE: UInt64 = 0x3  # page descriptor at level 3
comptime D_TABLE: UInt64 = 0x3  # table descriptor
comptime D_BLOCK: UInt64 = 0x1  # block descriptor
comptime D_DEV: UInt64 = 0x4  # MAIR attr idx 1 (Device-nGnRnE) at bits[4:2]
comptime D_AF: UInt64 = 0x400
comptime D_SH_INNER: UInt64 = 0x300
comptime D_AP_RW_EL0: UInt64 = 0x40  # AP[2:1]=01: EL1 RW, EL0 RW
comptime D_UXN: UInt64 = 0x0040000000000000  # bit 54: EL0 cannot execute
comptime D_PXN: UInt64 = 0x0020000000000000  # bit 53: EL1 cannot execute
comptime D_ADDR_MASK: UInt64 = 0x0000FFFFFFFFF000


def flush_tlb_all():
    """Invalidate all stage-1 TLB entries (see boot.S:flush_tlb_all)."""
    external_call["flush_tlb_all", NoneType]()


@always_inline
def _zero_page(pa: Int):
    """Zero a 4KB physical frame (fresh frames from the allocator are not
    guaranteed clean, and userspace must see zeroed anon/brk pages)."""
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=pa
    )
    for j in range(PAGE_SIZE // 8):
        p[unsafe_offset=j] = 0


def init_user_vm(mut alloc: PhysAlloc, l1: Int) -> Bool:
    """Split L1[0] (a flat 1GB Device block) into L2-A so the low 128MB
    become a real user VA space.

    Builds one fresh level-2 table: slots 0..63 are invalid (user VA space,
    populated lazily by map_user); slots 64..511 are 2MB Device-nGnRnE
    identity blocks mirroring the old flat mapping so the kernel's MMIO
    keeps working. Then repoints L1[0] at it and flushes the TLB.
    """
    var table = alloc.alloc_pages(1)
    if table == 0:
        return False
    var t = Int(table)

    # zero-fill first (unmapped slots 0..63 are the user VA space)
    for i in range(512):
        write_u64(t + i * 8, 0)

    # slots 64..511: Device identity blocks (VAs 0x08000000..0x40000000)
    for i in range(USER_SLOTS, 512):
        var va = i * SLOT_SIZE
        var d: UInt64 = UInt64(va) | D_DEV | D_AF | D_BLOCK | D_UXN | D_PXN
        write_u64(t + i * 8, d)

    # repoint L1[0] at L2-A (was a flat Device block descriptor)
    write_u64(l1, UInt64(table) | D_TABLE)
    flush_tlb_all()
    return True


def map_user(
    mut alloc: PhysAlloc, l1: Int, va: Int, size: Int, exec: Bool
) -> Bool:
    """Map [va, va+size) as fresh EL0 pages in the low user VA space.

    Allocates a physical frame per page, zeroes it, and writes a PTE with
    EL0 read/write (+execute when `exec`). A page that is already mapped is
    left alone (contents preserved), so brk can regrow across a
    partially-used page and adjacent PT_LOADs sharing a page are harmless.
    Returns False if any page can't be mapped (no frame, or the range
    escapes the user VA space).
    """
    if size <= 0:
        return True
    var start = va & ~PAGE_MASK
    var endp = (va + size + PAGE_MASK) & ~PAGE_MASK
    if start < 0 or endp > USER_VA_TOP:
        return False

    var l1e = read_u64(l1)
    if (l1e & UInt64(0x3)) != D_TABLE:
        return False  # init_user_vm hasn't split L1[0] yet
    var l2a = Int(l1e & D_ADDR_MASK)

    var addr = start
    while addr < endp:
        var slot = addr // SLOT_SIZE
        if slot >= USER_SLOTS:
            return False
        var ent = read_u64(l2a + slot * 8)
        var l3: Int
        if (ent & UInt64(0x3)) == D_TABLE:
            l3 = Int(ent & D_ADDR_MASK)
        else:
            var l3f = alloc.alloc_pages(1)
            if l3f == 0:
                return False
            l3 = Int(l3f)
            for j in range(512):
                write_u64(l3 + j * 8, 0)  # all PTEs invalid initially
            write_u64(l2a + slot * 8, UInt64(l3) | D_TABLE)

        var pge = (addr // PAGE_SIZE) % 512
        var off = l3 + pge * 8
        if (read_u64(off) & UInt64(0x3)) == D_PAGE:
            addr += PAGE_SIZE  # already mapped: keep page + its data
            continue

        var frame = alloc.alloc_pages(1)
        if frame == 0:
            return False
        _zero_page(Int(frame))
        var np: UInt64 = (
            UInt64(frame) | D_PAGE | D_AF | D_SH_INNER | D_AP_RW_EL0
        )
        if not exec:
            np = np | D_UXN
        write_u64(off, np)
        addr += PAGE_SIZE

    flush_tlb_all()
    return True
