# A tiny physical-memory allocator.
#
# The RAM bounds come from the DTB's /memory node (parsed into MemRegions by
# dtb.mojo) rather than being hard-coded. Before handing out any bytes we
# reserve the ranges the kernel already owns: the loaded kernel image
# (text..stack, whose extent boot.S passes to kmain), the EL0-accessible
# "user" region carve-out in the page tables, the cpio initrd, and the DTB
# itself.
#
# Implementation: a singly-linked free list of blocks. Each free block
# carries a small header at its start:
#     +0   magic (UInt64)  sanity marker
#     +8   blk  (UInt64)   total block size in bytes, header INCLUDED
#     +16  next (UInt64)   address of the next free block header (0 = none)
#     +24  (padding to keep payload 16-byte aligned)
# The payload handed to callers starts at block + PH_HDR. `alloc` unlinks
# the first block that fits and splits off any large remainder back into the
# free list; `free` relinks a block. Blocks are not coalesced -- acceptable
# for a first allocator whose main consumer will be handing out pages for
# user (brk/mmap) mappings, which grow monotonically for the most part.
from mem import read_u64, write_u64

comptime PH_MAGIC: UInt64 = 0xF3EE_F3EE_F3EE_F3EE
comptime PH_HDR: Int = 32  # header size; payload at block + PH_HDR
comptime PH_ALIGN: Int = 16
comptime PH_MIN_BLOCK: Int = PH_HDR + PH_ALIGN
comptime PH_RES_MAX: Int = 16


@always_inline
def _a16(v: UInt64) -> UInt64:
    """Round a physical address up to a 16-byte boundary."""
    return (v + 15) & ~15


struct PhysAlloc:
    """First-fit free-list allocator over one physical RAM region."""

    var ram_base: UInt64
    var ram_end: UInt64
    var nres: Int
    var rlo: Array[UInt64, PH_RES_MAX]  # reserved range lower bound
    var rhi: Array[UInt64, PH_RES_MAX]  # reserved range upper bound
    var free_head: UInt64  # physical addr of first free block header (0 none)

    def __init__(out self):
        self.ram_base = 0
        self.ram_end = 0
        self.nres = 0
        self.free_head = 0
        self.rlo = Array[UInt64, PH_RES_MAX](uninitialized=True)
        self.rhi = Array[UInt64, PH_RES_MAX](uninitialized=True)

    def reserve(mut self, lo: UInt64, hi: UInt64):
        """Mark [lo, hi) as in-use so `init` won't hand out of it."""
        if lo >= hi:
            return
        if self.nres < PH_RES_MAX:
            self.rlo[self.nres] = lo
            self.rhi[self.nres] = hi
            self.nres += 1

    def _link_free(mut self, lo: UInt64, hi: UInt64):
        """Insert one contiguous free block spanning [lo, hi)."""
        var block = _a16(lo)
        if block + UInt64(PH_HDR) > hi:
            return
        var blk = hi - block
        if blk < UInt64(PH_MIN_BLOCK):
            return
        write_u64(Int(block), PH_MAGIC)
        write_u64(Int(block + 8), blk)
        write_u64(Int(block + 16), self.free_head)
        self.free_head = block

    def init(mut self, base: UInt64, end: UInt64):
        """Carve the reserved ranges out of [base, end) and free the rest."""
        self.ram_base = base
        self.ram_end = end
        self.free_head = 0

        # Sort reservations ascending by lower bound (bubble sort).
        for _ in range(self.nres):
            var swapped = False
            for j in range(self.nres - 1):
                if self.rlo[j] > self.rlo[j + 1]:
                    var t = self.rlo[j]
                    self.rlo[j] = self.rlo[j + 1]
                    self.rlo[j + 1] = t
                    t = self.rhi[j]
                    self.rhi[j] = self.rhi[j + 1]
                    self.rhi[j + 1] = t
                    swapped = True
            if not swapped:
                break

        # Walk [base, end) adding the free gaps between reservations.
        var cur = base
        for r in range(self.nres):
            var lo = self.rlo[r]
            var hi = self.rhi[r]
            if hi <= cur:
                continue
            if lo >= end:
                break
            if lo < base:
                lo = base
            if hi > end:
                hi = end
            if lo > cur:
                self._link_free(cur, lo)
            if hi > cur:
                cur = hi
        if cur < end:
            self._link_free(cur, end)

    def attach(mut self, head: UInt64, base: UInt64, end: UInt64):
        """Adopt an existing free list (e.g. rebuilt from kernel state) so
        syscall handlers can alloc/map without re-running `init` (which
        would need the reservation list we no longer keep).
        """
        self.ram_base = base
        self.ram_end = end
        self.nres = 0
        self.free_head = head

    def alloc(mut self, n: Int) -> UInt64:
        """Return the physical address of `n` bytes (payload), or 0 on fail."""
        if n <= 0:
            return 0
        var need: UInt64 = UInt64(PH_HDR + ((n + 15) & ~15))
        var prev: UInt64 = 0
        var b = self.free_head
        while b != 0:
            var blk = read_u64(Int(b + 8))
            var nxt = read_u64(Int(b + 16))
            if blk >= need:
                # unlink `b`
                if prev == 0:
                    self.free_head = nxt
                else:
                    write_u64(Int(prev + 16), nxt)
                # split off a remainder if there's room for another block
                if blk - need >= UInt64(PH_MIN_BLOCK):
                    var rest = b + need
                    write_u64(Int(rest), PH_MAGIC)
                    write_u64(Int(rest + 8), blk - need)
                    write_u64(Int(rest + 16), self.free_head)
                    self.free_head = rest
                # hand out the (possibly shrunk) block `b`
                write_u64(Int(b + 8), need)
                write_u64(Int(b + 16), 0)
                return b + UInt64(PH_HDR)
            prev = b
            b = nxt
        return 0

    def alloc_pages(mut self, npages: Int) -> UInt64:
        """Return a 4KB-aligned, physically contiguous frame of `npages` pages.

        The free-list allocator is 16-byte aligned, so we over-allocate by
        one page and round the returned payload up to a 4KB boundary (the
        rounded-up prefix is wasted on purpose). These frames are used for
        kernel page tables (never freed), so there is deliberately no
        matching free.
        """
        if npages <= 0:
            return 0
        var raw = self.alloc(npages * 4096 + 4096)
        if raw == 0:
            return 0
        return (raw + UInt64(4095)) & 0xFFFFFFFFFFFFF000

    def free(mut self, addr: UInt64):
        """Return a block previously handed out by `alloc` to the free list."""
        if addr == 0 or addr < UInt64(PH_HDR):
            return
        var block = addr - UInt64(PH_HDR)
        var blk = read_u64(Int(block + 8))
        if blk < UInt64(PH_MIN_BLOCK):
            return
        write_u64(Int(block), PH_MAGIC)
        write_u64(Int(block + 8), blk)
        write_u64(Int(block + 16), self.free_head)
        self.free_head = block

    def free_total(self) -> UInt64:
        """Total free payload bytes (walks the list; for diagnostics)."""
        var total: UInt64 = 0
        var b = self.free_head
        while b != 0:
            var blk = read_u64(Int(b + 8))
            if blk > UInt64(PH_HDR):
                total += blk - UInt64(PH_HDR)
            b = read_u64(Int(b + 16))
        return total
