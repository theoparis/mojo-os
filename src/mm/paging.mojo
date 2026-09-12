# Userspace virtual memory (proper paging: user VA != PA), for either the
# 4KB or 16KB translation granule -- select the granule with the PAGE_SHIFT
# build define (see phys.mojo; default 4KB). Everything here derives from
# PAGE_SHIFT, and the kernel itself always runs on an identity map (VA == PA)
# for device + RAM ranges; userspace gets a *real* low-128MB virtual address
# space ([0, 0x08000000)) mapped onto physical frames from the allocator.
#
# boot.S builds the kernel's static top-level tables (geometry differs by
# granule -- see boot.S). In both cases the low user VA slots are left
# unmapped at boot, and map_user() fills them with lazily-created leaf
# (page) tables:
#   - 16KB (PAGE_SHIFT=14): top table indexed by VA[31:25]; user slots
#     0..3 are entries of that same top table; each leaf table is 2048
#     16KB-page entries covering 32MB. map_user() works directly on l1.
#   - 4KB  (PAGE_SHIFT=12): top (L1) table with 1GB entries; init_user_vm()
#     hangs an L2-A table under L1[0] whose low 64 slots are the user VA
#     space (2MB slots); map_user() hangs 512-entry leaf (L3) tables off
#     L2-A. (RAM keeps its own static L2 via L1[1].)
#
# Executable pages are mapped EL0 read/write+execute (AP[2:1]=01, UXN
# clear) and data/stack pages EL0 read/write non-executable (UXN set).
# Read-only pages (mprotect-style) would need a two-phase map -- deferred
# until a proper mm layer exists.
from std.ffi import external_call
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin
from std.sys.defines import get_defined_string
from std.sys.info import CompilationTarget

from arch.mem import read_u64, write_u64
from mm.phys import PAGE_MASK, PAGE_SHIFT, PAGE_SIZE, PhysAlloc

comptime ARCH = get_defined_string[
    "ARCH", StringLiteral[CompilationTarget[].__triple_arch()]()
]()

# index bits per table = granule_bits - 3 (9 for 4KB, 11 for 16KB)
comptime INDEX_BITS: Int = PAGE_SHIFT - 3
comptime LEAF_ENTRIES: Int = 1 << INDEX_BITS  # 512 or 2048
# each top slot covers one full leaf table: PAGE_SIZE * LEAF_ENTRIES
comptime SLOT_SHIFT: Int = PAGE_SHIFT + INDEX_BITS  # 21 (4KB) or 25 (16KB)
comptime SLOT_SIZE: Int = 1 << SLOT_SHIFT
comptime USER_VA_TOP: Int = 0x08000000  # user VAs live in [0, this)
comptime USER_SLOTS: Int = USER_VA_TOP >> SLOT_SHIFT  # 64 (4KB) or 4 (16KB)

# User process VA layout. The EL0 stack sits at the very top of the user VA
# space and anonymous mmaps descend from just below it; brk grows up from the
# image end and is capped at USER_HEAP_TOP, so brk and mmap never collide.
comptime USER_STACK_SIZE: Int = 0x10000  # 64KB initial user stack
comptime USER_HEAP_TOP: Int = 0x04000000  # brk cap == mmap floor (64MB)

# descriptor bits (stage 1, format identical across granules)
comptime D_PAGE: UInt64 = 0x3  # page descriptor (leaf)
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
    """Zero a PAGE_SIZE physical frame (fresh frames from the allocator are
    not guaranteed clean, and userspace must see zeroed anon/brk pages)."""
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=pa
    )
    for j in range(PAGE_SIZE // 8):
        p[unsafe_offset=j] = 0


def init_user_vm(mut alloc: PhysAlloc, l1: Int) -> Bool:
    """Prepare the low user VA space before any user mapping.

    4KB: L1[0] is a flat 1GB Device block at boot; split it into a level-2
    table (L2-A) whose low USER_SLOTS entries are the (unmapped) user VA
    space and the rest are Device identity blocks (so the kernel's MMIO
    keeps working after L1[0] is repointed).

    16KB: boot.S already left the top table's user slots (0..3) unmapped and
    map_user() creates leaf tables directly in them -- nothing to set up.
    """
    comptime if ARCH == "x86_64":
        return True
    if PAGE_SHIFT == 14:
        return True
    var table = alloc.alloc_pages(1)
    if table == 0:
        return False
    var t = Int(table)
    for i in range(LEAF_ENTRIES):
        write_u64(t + i * 8, 0)  # user slots start invalid (all of L2-A)
    # slots USER_SLOTS..end: Device identity blocks (VAs 0x08000000..)
    for i in range(USER_SLOTS, LEAF_ENTRIES):
        var va = i * SLOT_SIZE
        var d: UInt64 = UInt64(va) | D_DEV | D_AF | D_BLOCK
        if PAGE_SHIFT == 12:
            d = d | D_UXN | D_PXN
        write_u64(t + i * 8, d)
    # repoint L1[0] at L2-A (was a flat Device block descriptor)
    write_u64(l1, UInt64(table) | D_TABLE)
    flush_tlb_all()
    return True


def _leaf_for(mut alloc: PhysAlloc, root: Int, slot: Int) -> Int:
    """Return the leaf-table address covering user slot `slot` of the leaf-
    parent table `root`, creating it (a fresh zeroed frame of invalid
    entries) if needed. Returns 0 on allocation failure."""
    var ent = read_u64(root + slot * 8)
    if (ent & UInt64(0x3)) == D_TABLE:
        return Int(ent & D_ADDR_MASK)
    var lf = alloc.alloc_pages(1)
    if lf == 0:
        return 0
    var leaf = Int(lf)
    for j in range(LEAF_ENTRIES):
        write_u64(leaf + j * 8, 0)  # all PTEs invalid initially
    write_u64(root + slot * 8, UInt64(leaf) | D_TABLE)
    return leaf


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

    comptime if ARCH == "x86_64":
        # Four-level x86-64 paging. UEFI's CR3 supplies an identity-mapped
        # kernel address space; retain it and create/replace only user leaves.
        var addr = start
        while addr < endp:
            var table = l1
            var shift = 39
            while shift >= 21:
                var index = (addr >> shift) & 0x1FF
                var off = table + index * 8
                var ent = read_u64(off)
                if (ent & UInt64(1)) == 0:
                    var next = alloc.alloc_pages(1)
                    if next == 0:
                        return False
                    _zero_page(Int(next))
                    # present | writable | user
                    write_u64(off, UInt64(next) | UInt64(0x7))
                    table = Int(next)
                else:
                    # User permission must be present at every walk level.
                    write_u64(
                        off,
                        (ent | UInt64(0x6)) & UInt64(0x7FFFFFFFFFFFFFFF),
                    )
                    table = Int(ent & D_ADDR_MASK)
                shift -= 9
            var pte_off = table + ((addr >> 12) & 0x1FF) * 8
            var frame = alloc.alloc_pages(1)
            if frame == 0:
                return False
            _zero_page(Int(frame))
            var pte = UInt64(frame) | UInt64(0x7)
            if not exec:
                pte = pte | UInt64(0x8000000000000000)
            write_u64(pte_off, pte)
            addr += PAGE_SIZE
        flush_tlb_all()
        return True

    # The leaf-parent table holding leaf pointers for the user slots:
    #  16KB -> the top table itself (l1); 4KB -> L2-A under L1[0].
    var root: Int
    if PAGE_SHIFT == 14:
        root = l1
    else:
        var l1e = read_u64(l1)
        if (l1e & UInt64(0x3)) != D_TABLE:
            return False  # init_user_vm hasn't split L1[0] yet
        root = Int(l1e & D_ADDR_MASK)

    var addr = start
    while addr < endp:
        var slot = addr >> SLOT_SHIFT
        if slot >= USER_SLOTS:
            return False
        var leaf = _leaf_for(alloc, root, slot)
        if leaf == 0:
            return False
        var pge = (addr >> PAGE_SHIFT) & (LEAF_ENTRIES - 1)
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
