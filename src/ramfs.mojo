# A tiny initramfs: unpack the cpio archive into an in-memory filesystem.
#
# This is the kernel-side analog of Linux unpacking its initrd. We walk the
# resident cpio archive (whose location QEMU recorded in the DTB /chosen
# node) once, and record each file in a fixed-capacity table. File *data* is
# referenced zero-copy straight into the archive's RAM (the archive stays
# resident), so nothing needs to be copied or allocated to later load a file
# such as /init.
#
# Lookup treats paths the way Linux does for an initramfs: "/init" and
# "./init" and "init" all resolve to the same root file.
from console import print_cstr, print_str, print_uint, putc
from mem import align4, cstr_eq, read_u8, write_u8

comptime RAMFS_MAX = 128


@always_inline
def hex_val(c: UInt8) -> UInt32:
    if (c >= 0x30) and (c <= 0x39):
        return UInt32(c - 0x30)
    elif (c >= 0x61) and (c <= 0x66):
        return UInt32(c - 0x61 + 10)
    else:
        return UInt32(c - 0x41 + 10)  # uppercase


def read_hex32(addr: Int) -> UInt32:
    """Parse an 8-digit ASCII-hex u32 (cpio newc fields are hex, big-endian)."""
    var v: UInt32 = 0
    for i in range(8):
        v = (v << 4) | hex_val(read_u8(addr + i))
    return v


@always_inline
def is_newc_magic(addr: Int) -> Bool:
    return (
        (read_u8(addr) == 0x30)
        and (read_u8(addr + 1) == 0x37)
        and (read_u8(addr + 2) == 0x30)
        and (read_u8(addr + 3) == 0x37)
        and (read_u8(addr + 4) == 0x30)
        and (read_u8(addr + 5) == 0x31)
    )


def name_matches(addr: Int, lit: StringLiteral) -> Bool:
    """Path compare tolerant of a leading '/' or './' on either side."""
    var p = lit.ptr()
    # normalize the stored name: skip a leading '/' or './'
    var sa = addr
    while read_u8(sa) == 0x2F:  # '/'
        sa += 1
    if (read_u8(sa) == 0x2E) and (read_u8(sa + 1) == 0x2F):
        sa += 2  # "./"
    # normalize the literal path: skip a leading '/' or './'
    var i: Int = 0
    while p[unsafe_offset=i] == 0x2F:
        i += 1
    if (p[unsafe_offset=i] == 0x2E) and (p[unsafe_offset=i + 1] == 0x2F):
        i += 2
    # compare the tails
    while True:
        var lc = p[unsafe_offset=i]
        if lc == 0:
            return read_u8(sa) == 0
        if read_u8(sa) != lc:
            return False
        sa += 1
        i += 1


struct RamFs:
    """Fixed-capacity table of files unpacked from a cpio initrd.

    Fields are parallel scalar arrays (rather than an array of structs) to
    keep entry writes trivial-copy on a target with no heap/allocator.
    """

    var count: Int
    var names: Array[Int, RAMFS_MAX]  # addr of each NUL-terminated name
    var datas: Array[Int, RAMFS_MAX]  # addr of each file's data
    var sizes: Array[Int, RAMFS_MAX]
    var modes: Array[UInt32, RAMFS_MAX]

    def __init__(out self):
        self.count = 0
        self.names = Array[Int, RAMFS_MAX](uninitialized=True)
        self.datas = Array[Int, RAMFS_MAX](uninitialized=True)
        self.sizes = Array[Int, RAMFS_MAX](uninitialized=True)
        self.modes = Array[UInt32, RAMFS_MAX](uninitialized=True)

    def total(self) -> Int:
        return self.count

    def name_addr(self, i: Int) -> Int:
        return self.names[i]

    def data_addr(self, i: Int) -> Int:
        return self.datas[i]

    def entry_size(self, i: Int) -> Int:
        return self.sizes[i]

    def entry_mode(self, i: Int) -> UInt32:
        return self.modes[i]

    def lookup(self, path: StringLiteral) -> Int:
        """Index of the entry matching `path`, or -1."""
        for i in range(self.count):
            if name_matches(self.names[i], path):
                return i
        return -1

    def read(self, i: Int, dest: Int, maxbytes: Int) -> Int:
        """Copy up to `maxbytes` of file `i` into `dest`. Returns bytes read."""
        var n = self.sizes[i]
        if n > maxbytes:
            n = maxbytes
        var src = self.datas[i]
        for k in range(n):
            write_u8(dest + k, read_u8(src + k))
        return n

    def list(self):
        for i in range(self.count):
            print_str("  /")
            print_cstr(self.names[i], 256)
            print_str("  size=")
            print_uint(UInt64(self.sizes[i]), 10)
            putc(0x0A)


def unpack_cpio(start: Int, end: Int) -> RamFs:
    """Parse a cpio 'newc' archive at [start, end) into a RamFs."""
    var fs = RamFs()
    var off = start
    while (off + 110) <= end:
        if not is_newc_magic(off):
            print_str("[ramfs] bad magic\n")
            break
        var mode = read_hex32(off + 14)
        var fsize = Int(read_hex32(off + 54))
        var nsize = Int(read_hex32(off + 94))
        var name = off + 110

        # Trailer entry terminates the archive.
        if nsize == 11 and cstr_eq(name, "TRAILER!!!"):
            break

        var data = name + align4(nsize)
        if fs.count < RAMFS_MAX:
            fs.names[fs.count] = name
            fs.datas[fs.count] = data
            fs.sizes[fs.count] = fsize
            fs.modes[fs.count] = mode
            fs.count += 1
        else:
            print_str("[ramfs] table full, stopping\n")
            break
        off = data + align4(fsize)
    return fs^
