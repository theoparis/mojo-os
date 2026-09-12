# Minimal flattened device tree (DTB) parser.
#
# On AArch64 the boot firmware/bootloader (here, QEMU running the kernel as
# a Linux arm64 image) places a big-endian DTB in RAM and hands its physical
# address to the kernel in x0.
#
# We currently extract three things in one pass over the structure block:
#   * `/chosen` -> linux,initrd-start/end (where the cpio initrd lives) and
#     bootargs (the kernel command line)
#   * `/memory` -> the physical RAM ranges (address+size), using the root
#     node's #address-cells / #size-cells, so we can build a real physical
#     memory allocator instead of hard-coding RAM size.
from arch.mem import align4, cstr_eq, read_u32be, read_u8


comptime FDT_BEGIN_NODE: UInt32 = 1
comptime FDT_END_NODE: UInt32 = 2
comptime FDT_PROP: UInt32 = 3
comptime FDT_NOP: UInt32 = 4
comptime FDT_END: UInt32 = 9

comptime MEM_MAX: Int = 4


struct BootParams:
    """Interesting bits parsed out of the /chosen node of the DTB."""

    var has_dtb: Bool
    var dtb_start: UInt64  # where the whole DTB image sits in RAM
    var dtb_end: UInt64
    var initrd_start: UInt64
    var initrd_end: UInt64
    var has_initrd: Bool
    var cmdline_addr: Int
    var cmdline_len: Int

    def __init__(out self):
        self.has_dtb = False
        self.dtb_start = 0
        self.dtb_end = 0
        self.initrd_start = 0
        self.initrd_end = 0
        self.has_initrd = False
        self.cmdline_addr = 0
        self.cmdline_len = 0


struct MemRegions:
    """Physical RAM ranges read from the /memory node.

    Parallel scalar arrays (not an array of structs) so that writes are
    trivial copies -- there is no heap on this bare-metal target.
    """

    var count: Int
    var bases: Array[UInt64, MEM_MAX]
    var sizes: Array[UInt64, MEM_MAX]

    def __init__(out self):
        self.count = 0
        self.bases = Array[UInt64, MEM_MAX](uninitialized=True)
        self.sizes = Array[UInt64, MEM_MAX](uninitialized=True)

    def n(self) -> Int:
        return self.count

    def base(self, i: Int) -> UInt64:
        return self.bases[i]

    def size(self, i: Int) -> UInt64:
        return self.sizes[i]

    def end(self, i: Int) -> UInt64:
        return self.bases[i] + self.sizes[i]

    def add(mut self, b: UInt64, s: UInt64):
        if self.count < MEM_MAX:
            self.bases[self.count] = b
            self.sizes[self.count] = s
            self.count += 1


def be64(addr: Int) -> UInt64:
    var hi = UInt64(read_u32be(addr))
    var lo = UInt64(read_u32be(addr + 4))
    return hi * 0x100000000 + lo


def name_has_prefix(addr: Int, lit: StringLiteral) -> Bool:
    """True if the NUL-terminated node name at `addr` starts with literal."""
    var p = lit.ptr()
    var i: Int = 0
    while p[unsafe_offset=i] != 0:
        if read_u8(addr + i) != p[unsafe_offset=i]:
            return False
        i += 1
    return True


def read_cells(addr: Int, ncells: Int) -> UInt64:
    """Read `ncells` (<=2) big-endian u32 cells into a UInt64 address."""
    var v: UInt64 = 0
    for i in range(ncells):
        v = (v << 32) | UInt64(read_u32be(addr + i * 4))
    return v


def parse_dtb(dtb: Int, mut mem: MemRegions) -> BootParams:
    """Parse the flattened device tree at `dtb`.

    Fills `/chosen` boot params (returned) and `/memory` RAM ranges (into
    the caller-provided `mem`) in a single walk of the structure block.
    """
    var bp = BootParams()
    if dtb == 0 or read_u32be(dtb) != 0xD00DFEED:
        return bp^
    bp.has_dtb = True
    bp.dtb_start = UInt64(dtb)
    bp.dtb_end = UInt64(dtb) + UInt64(read_u32be(dtb + 4))

    var struct_off = Int(read_u32be(dtb + 8))
    var strings_off = Int(read_u32be(dtb + 12))
    var struct_size = Int(read_u32be(dtb + 36))
    var struct_end = dtb + struct_off + struct_size

    var pos = dtb + struct_off
    var in_chosen = False
    var in_mem = False
    var depth: Int = 0
    var acroot: Int = 2  # default for aarch64 if root omits #address-cells
    var scroot: Int = 2  # default for aarch64 if root omits #size-cells
    while pos < struct_end:
        var tok = read_u32be(pos)
        if tok == FDT_BEGIN_NODE:
            # node name: NUL-terminated, padded to a 4-byte boundary
            var name = pos + 4
            var n: Int = 0
            while read_u8(name + n) != 0:
                n += 1
            if depth == 1:
                # direct child of the root node
                in_chosen = cstr_eq(name, "chosen")
                in_mem = name_has_prefix(name, "memory")
            depth += 1
            pos += 4 + align4(n + 1)
        elif tok == FDT_END_NODE:
            in_chosen = False
            in_mem = False
            depth -= 1
            pos += 4
        elif tok == FDT_PROP:
            var plen = Int(read_u32be(pos + 4))
            var nameoff = Int(read_u32be(pos + 8))
            var data = pos + 12
            var pname = dtb + strings_off + nameoff
            if depth == 1:
                # root-level properties set the addressing used by /memory
                if cstr_eq(pname, "#address-cells") and plen >= 4:
                    acroot = Int(read_u32be(data))
                elif cstr_eq(pname, "#size-cells") and plen >= 4:
                    scroot = Int(read_u32be(data))
            elif in_chosen:
                if cstr_eq(pname, "linux,initrd-start"):
                    if plen == 8:
                        bp.initrd_start = be64(data)
                    else:
                        bp.initrd_start = UInt64(read_u32be(data))
                    bp.has_initrd = True
                elif cstr_eq(pname, "linux,initrd-end"):
                    if plen == 8:
                        bp.initrd_end = be64(data)
                    else:
                        bp.initrd_end = UInt64(read_u32be(data))
                elif cstr_eq(pname, "bootargs"):
                    bp.cmdline_addr = data
                    bp.cmdline_len = plen
            elif in_mem and cstr_eq(pname, "reg"):
                # /memory reg = one or more (addr, size) cell pairs using the
                # root's #address-cells / #size-cells.
                var off = data
                var left = plen
                while left >= (acroot + scroot) * 4:
                    var b = read_cells(off, acroot)
                    off += acroot * 4
                    var s = read_cells(off, scroot)
                    off += scroot * 4
                    left -= (acroot + scroot) * 4
                    mem.add(b, s)
            pos = data + align4(plen)
        elif tok == FDT_END:
            break
        else:
            # FDT_NOP and anything unknown
            pos += 4
    return bp^
