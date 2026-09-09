# cpio "newc" (SVR4) initrd unpacker.
#
# A Linux-style initrd is a cpio archive that QEMU loaded into RAM and
# described in the DTB /chosen node (linux,initrd-start..end). The kernel
# unpacks it into a filesystem and eventually exec's `/init`. This module
# walks the archive and reports each entry; a ramfs layer will consume it
# later.
from console import print_cstr, print_str, print_uint, putc
from mem import align4, cstr_eq, read_u8


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


def parse_cpio(start: Int, end: Int) -> Int:
    """Walk a cpio 'newc' archive and report each file. Returns the count.

    cpio newc layout per entry: a 110-byte ASCII header (magic "070701"
    then 13 * 8 hex digit fields: ino mode uid gid nlink mtime filesize
    devmajor devminor rdevmajor rdevminor namesize check), followed by the
    NUL-terminated name padded to 4 bytes, then the file data padded to 4
    bytes. The archive ends with an entry named "TRAILER!!!".
    """
    var off = start
    var count = 0
    while (off + 110) <= end:
        if not is_newc_magic(off):
            print_str("[cpio] bad magic\n")
            break
        var mode = read_hex32(off + 14)
        var fsize = Int(read_hex32(off + 54))
        var nsize = Int(read_hex32(off + 94))
        var name = off + 110

        # Trailer entry terminates the archive.
        if nsize == 11 and cstr_eq(name, "TRAILER!!!"):
            break

        var data = name + align4(nsize)
        print_str('  [file] "/')
        print_cstr(name, nsize)
        print_str('" type=')
        var ft = mode >> 12
        if ft == 8:
            print_str("reg")
        elif ft == 4:
            print_str("dir")
        elif ft == 2:
            print_str("lnk")
        else:
            print_uint(UInt64(mode >> 12), 16)
        print_str(" mode=")
        print_uint(UInt64(mode & 0xFFF), 8)
        print_str(" size=")
        print_uint(UInt64(fsize), 10)
        print_str(" @0x")
        print_uint(UInt64(data), 16)
        putc(0x0A)
        count += 1
        off = data + align4(fsize)
    return count


def print_cpio_summary(start: Int, end: Int):
    print_str("[initrd] unpacking cpio\n")
    var n = parse_cpio(start, end)
    print_str("[initrd] done, ")
    print_uint(UInt64(n), 10)
    print_str(" file(s)\n")
