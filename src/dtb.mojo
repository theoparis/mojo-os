# Minimal flattened device tree (DTB) parser.
#
# On AArch64 the boot firmware/bootloader (here, QEMU running the kernel as
# a Linux arm64 image) places a big-endian DTB in RAM and hands its physical
# address to the kernel in x0. We only need the `/chosen` node for now:
#   * linux,initrd-start / linux,initrd-end  -> where the cpio initrd lives
#   * bootargs                               -> the kernel command line
# A proper OS will later want `/memory` (RAM ranges) and the interrupt/uart
# descriptions too, but those can be added as needed.
from mem import align4, cstr_eq, read_u32be, read_u8


struct BootParams:
    """Interesting bits parsed out of the /chosen node of the DTB."""

    var has_dtb: Bool
    var initrd_start: UInt64
    var initrd_end: UInt64
    var has_initrd: Bool
    var cmdline_addr: Int
    var cmdline_len: Int

    def __init__(out self):
        self.has_dtb = False
        self.initrd_start = 0
        self.initrd_end = 0
        self.has_initrd = False
        self.cmdline_addr = 0
        self.cmdline_len = 0


comptime FDT_BEGIN_NODE: UInt32 = 1
comptime FDT_END_NODE: UInt32 = 2
comptime FDT_PROP: UInt32 = 3
comptime FDT_NOP: UInt32 = 4
comptime FDT_END: UInt32 = 9


def be64(addr: Int) -> UInt64:
    var hi = UInt64(read_u32be(addr))
    var lo = UInt64(read_u32be(addr + 4))
    return hi * 0x100000000 + lo


def parse_dtb(dtb: Int) -> BootParams:
    """Parse the Flattened Device Tree at `dtb` and pull out /chosen info."""
    var bp = BootParams()
    if read_u32be(dtb) != 0xD00DFEED:
        return bp^
    bp.has_dtb = True

    var struct_off = Int(read_u32be(dtb + 8))
    var strings_off = Int(read_u32be(dtb + 12))
    var struct_size = Int(read_u32be(dtb + 36))
    var struct_end = dtb + struct_off + struct_size

    var pos = dtb + struct_off
    var in_chosen = False
    while pos < struct_end:
        var tok = read_u32be(pos)
        if tok == FDT_BEGIN_NODE:
            # node name: NUL-terminated, padded to a 4-byte boundary
            var n = 0
            while read_u8(pos + 4 + n) != 0:
                n += 1
            if in_chosen == False:
                in_chosen = cstr_eq(pos + 4, "chosen")
            pos += 4 + align4(n + 1)
        elif tok == FDT_END_NODE:
            in_chosen = False
            pos += 4
        elif tok == FDT_PROP:
            var plen = Int(read_u32be(pos + 4))
            var nameoff = Int(read_u32be(pos + 8))
            var data = pos + 12
            if in_chosen:
                var pname = dtb + strings_off + nameoff
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
            pos = data + align4(plen)
        elif tok == FDT_END:
            break
        else:
            # FDT_NOP and anything unknown
            pos += 4
    return bp^
