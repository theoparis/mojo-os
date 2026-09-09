# Userspace virtual memory (proper paging: user VA != PA) on the 16KB
# translation granule.
#
# boot.S builds a single top-level translation table (16KB, 2048 entries;
# 16KB granule, T0SZ=32 => 4GB VA space, two-level walk). The top table is
# indexed by VA[31:25]; each of its entries is either a 32MB *block*
# descriptor or a pointer to a lazily-created 2048-entry *leaf* table
# (page index VA[24:14], 16KB pages, one leaf covers 32MB):
#   - slots 0..3   (VAs 0x00000000-0x08000000): userspace VA space. Left
#                   unmapped at boot; map_user() fills it leaf-by-leaf with
#                   16KB user pages backed by physical frames from the
#                   allocator (VA != PA).
#   - slots 4..31  (VAs 0x08000000-0x40000000): Device-nGnRnE identity
#                   blocks (UART 0x09000000, GIC 0x08000000, ...), EL1-only.
#   - slots 32..63 (VAs 0x40000000-0x80000000): Normal identity RAM blocks,
#                   EL1-only (kernel + RAM; the kernel runs on this map).
#   - slots 64..127: invalid.
# The kernel keeps running on this same identity map for itself.
#
# map_user() maps low-VA user pages onto fresh physical frames at 16KB
# granularity: exec pages are EL0 read/write+execute (AP[2:1]=01, UXN
# clear), data/stack pages EL0 read/write non-exec (UXN set). Read-only
# pages (mprotect-style) would need a two-phase map -- deferred until a
# proper mm layer exists.
#
# All the shifts/counts below are derived from PAGE_SHIFT (see phys.mojo),
# so this module works for any granule that keeps the two-level walk.
from std.ffi import external_call
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin

from mem import read_u64, write_u64
from phys import PAGE_MASK, PAGE_SHIFT, PAGE_SIZE, PhysAlloc

# index bits per table = granule_bits - 3 (9 for 4KB, 11 for 16KB)
comptime INDEX_BITS: Int = PAGE_SHIFT - 3
comptime TABLE_ENTRIES: Int = 1 << INDEX_BITS  # 2048 for 16KB
# top-table slot shift: each top entry covers one full leaf table (32MB)
comptime SLOT_SHIFT: Int = PAGE_SHIFT + INDEX_BITS  # 25 for 16KB
comptime USER_VA_TOP: Int = 0x08000000  # user VAs live in [0, this)
comptime USER_SLOTS: Int = USER_VA_TOP >> SLOT_SHIFT  # 4 top slots

# descriptor bits (16KB granule, stage 1) -- format identical across
# granules; only table sizes/coverage differ.
comptime D_PAGE: UInt64 = 0x3  # page descriptor (leaf)
comptime D_TABLE: UInt64 = 0x3  # table descriptor
comptime D_BLOCK: UInt64 = 0x1  # block descriptor
comptime D_DEV: UInt64 = 0x4  # MAIR attr idx 1 (Device-nGnRnE) at bits[4:2]
comptime D_AF: UInt64 = 0x400
comptime D_SH_INNER: UInt64 = 0x300
comptime D_AP_RW_EL0: UInt64 = 0x40  # AP[2:1]=01: EL1 RW, EL0 RW
comptime D_UXN: UInt64 = 0x0040000000000000  # bit 54: EL0 cannot execute
comptime D_ADDR_MASK: UInt64 = 0x0000FFFFFFFFF000


def flush_tlb_all():
    """Invalidate all stage-1 TLB entries (see boot.S:flush_tlb_all)."""
    external_call["flush_tlb_all", NoneType]()


@always_inline
def _zero_page(pa: Int):
    """Zero a PAGE_SIZE physical frame (fresh frames from the allocator are
    not guaranteed clean, and userspace must see zeroed anon/brk pages)."""
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=pa
    )
    for j in range(PAGE_SIZE // 8):
        p[unsafe_offset=j] = 0


def _leaf_for(mut alloc: PhysAlloc, l1: Int, slot: Int) -> Int:
    """Return the leaf-table address covering user-VA top-table `slot`,
    creating it (a fresh zeroed 16KB frame of invalid entries) if needed.
    Returns 0 on allocation failure."""
    var ent = read_u64(l1 + slot * 8)
    if (ent & UInt64(0x3)) == D_TABLE:
        return Int(ent & D_ADDR_MASK)
    var lf = alloc.alloc_pages(1)
    if lf == 0:
        return 0
    var leaf = Int(lf)
    for j in range(TABLE_ENTRIES):
        write_u64(leaf + j * 8, 0)  # all PTEs invalid initially
    write_u64(l1 + slot * 8, UInt64(leaf) | D_TABLE)
    return leaf


def map_user(
    mut alloc: PhysAlloc, l1: Int, va: Int, size: Int, exec: Bool
) -> Bool:
    """Map [va, va+size) as fresh EL0 user pages in the low user VA space.

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

    var addr = start
    while addr < endp:
        var slot = addr >> SLOT_SHIFT
        if slot >= USER_SLOTS:
            return False
        var leaf = _leaf_for(alloc, l1, slot)
        if leaf == 0:
            return False
        var pge = (addr >> PAGE_SHIFT) & (TABLE_ENTRIES - 1)
        var off = leaf + pge * 8
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
