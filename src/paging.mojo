# Userspace page mapping.
#
# At boot, boot.S maps the whole RAM range EL1-only with 2MB level-2 block
# descriptors. That gives EL0 nothing to run on. This module grants EL0
# access at *4KB page granularity*, on demand: for each 2MB slot that a
# requested range touches, it replaces the slot's block descriptor with a
# fresh level-3 table (a 4KB frame from the physical allocator) whose 512
# page descriptors default to identity EL1-only, then flips the specific
# pages to carry EL0 permissions:
#     exec pages: AP=11 (EL1 RW / EL0 RO) + executable  -> user code
#     data pages: AP=01 (EL1 RW / EL0 RW) + UXN          -> user data/stack
# Because the map is identity (VA == PA), the caller writes the segment
# bytes at the same addresses the user will read them from.
#
# All of the shifts/counts below are 4KB-granule-specific; the notes on
# what changes for a 16KB granule are in docs/16k-pages.md.
from std.ffi import external_call

from mem import read_u64, write_u64
from phys import PhysAlloc

comptime PAGE_SIZE: Int = 4096
comptime PAGE_MASK: Int = 4095
comptime SLOT_SIZE: Int = 0x200000  # one 2MB level-2 slot (512 x 4KB pages)
comptime RAM_BASE: Int = 0x40000000  # where the L2 table's coverage starts
comptime RAM_SPAN: Int = 0x40000000  # the L2 table covers 1GB

# descriptor bits (4KB granule, stage 1)
comptime D_PAGE: UInt64 = 0x3  # page descriptor at level 3
comptime D_TABLE: UInt64 = 0x3  # table descriptor at level 2
comptime D_AF: UInt64 = 0x400
comptime D_SH_INNER: UInt64 = 0x300
comptime D_AP_RW_EL0: UInt64 = 0x40  # AP[2:1]=01: EL1 RW, EL0 RW
# AP[2:1]=0b11 (0xC0) is nominally EL1 RW/EL0 RO, but QEMU reports an
# EL1 write-permission fault on it, so read-only+exec pages (mprotect-style)
# would need a two-phase map: write with EL0 access off, then flip AP. For
# now executable pages are mapped EL0 RW+exec and data EL0 RW non-exec.
comptime D_UXN: UInt64 = 0x0040000000000000  # bit 54: EL0 cannot execute
comptime D_ADDR_MASK: UInt64 = 0x0000FFFFFFFFF000  # table address [47:12]


def flush_tlb_all():
    """Invalidate all stage-1 TLB entries (see boot.S:flush_tlb_all)."""
    external_call["flush_tlb_all", NoneType]()


def _ensure_l3(mut alloc: PhysAlloc, l2: Int, slot: Int) -> UInt64:
    """Return the level-3 table address covering 2MB `slot`, creating it if
    the slot is still a plain block descriptor (or unmapped).

    A new table is a zero-fill of identity, EL1-only 4KB pages so the slot
    keeps covering the same RAM it covered as a block; EL0 stays out until
    individual pages are flipped below.
    """
    var ent = read_u64(l2 + slot * 8)
    if (ent & UInt64(0x3)) == D_TABLE:
        return ent & D_ADDR_MASK

    var table = alloc.alloc_pages(1)
    if table == 0:
        return 0
    var tbase = Int(table)
    var slot_base = RAM_BASE + slot * SLOT_SIZE
    for i in range(512):
        var pa = slot_base + i * PAGE_SIZE
        write_u64(tbase + i * 8, UInt64(pa) | D_PAGE | D_AF | D_SH_INNER)
    write_u64(l2 + slot * 8, table | D_TABLE)
    return table


def map_user_region(
    mut alloc: PhysAlloc, l2: Int, va: Int, size: Int, exec: Bool
) -> Bool:
    """Grant EL0 access to [va, va+size) page by page (identity-mapped).

    `exec=True` maps executable pages (read-write for now, see the AP note
    above); `False` maps read-write but non-executable (data/stack).
    Returns False if a page can't be mapped (no table frame, or the range
    escapes the L2 table's RAM span).
    """
    if size <= 0:
        return True
    var addr = va & ~PAGE_MASK
    var endp = (va + size + PAGE_MASK) & ~PAGE_MASK
    while addr < endp:
        if addr < RAM_BASE or addr >= RAM_BASE + RAM_SPAN:
            return False
        var slot = (addr - RAM_BASE) // SLOT_SIZE
        var tbl = _ensure_l3(alloc, l2, slot)
        if tbl == 0:
            return False
        var pge = (addr // PAGE_SIZE) % 512
        var pte = UInt64(addr) | D_PAGE | D_AF | D_SH_INNER
        if exec:
            # executable segment: EL0 read/write+execute for now (see note)
            pte = pte | D_AP_RW_EL0
        else:
            # user read/write, no user execute
            pte = pte | D_AP_RW_EL0 | D_UXN
        write_u64(Int(tbl) + pge * 8, pte)
        addr += PAGE_SIZE
    flush_tlb_all()
    return True
