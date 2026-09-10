# Build a minimal cpio 'newc' initrd from name=path pairs.
#
# Usage: mkcpio OUTPUT name=path [name=path ...]
#
# This is a normal hosted Mojo program (unlike the rest of src/, which is
# freestanding aarch64), built and run at `make` time to package the
# userspace binaries into the cpio initrd the kernel boots with. It shares
# the archive format layout (field order, header length, hex codec) with
# the kernel-side reader (src/fs/ramfs.mojo) via src/fs/cpio.mojo, so the
# on-disk format can't drift between writer and reader.
from std.sys import argv

from fs.cpio import CPIO_MAGIC, CPIO_TRAILER_NAME, hex_digit


def append_bytes(mut buf: List[UInt8], lit: StringLiteral, n: Int):
    var p = lit.ptr()
    for i in range(n):
        buf.append(p[unsafe_offset=i])


def append_field(mut buf: List[UInt8], value: UInt32):
    """Append one 8-digit uppercase-hex cpio field."""
    var shift: UInt32 = 28
    while True:
        buf.append(hex_digit((value >> shift) & 0xF))
        if shift == 0:
            break
        shift -= 4


def pad4(mut buf: List[UInt8]):
    while (len(buf) % 4) != 0:
        buf.append(0)


def append_header(
    mut buf: List[UInt8], mode: UInt32, filesize: UInt32, namesize: UInt32
):
    # ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor,
    # rdevmajor, rdevminor, namesize, check -- see src/fs/cpio.mojo.
    append_bytes(buf, CPIO_MAGIC, 6)
    append_field(buf, 1)
    append_field(buf, mode)
    append_field(buf, 0)
    append_field(buf, 0)
    append_field(buf, 1)
    append_field(buf, 0)
    append_field(buf, filesize)
    append_field(buf, 0)
    append_field(buf, 0)
    append_field(buf, 0)
    append_field(buf, 0)
    append_field(buf, namesize)
    append_field(buf, 0)


def append_entry(
    mut buf: List[UInt8], name: String, mode: UInt32, data: List[UInt8]
):
    append_header(buf, mode, UInt32(len(data)), UInt32(name.byte_length() + 1))
    for c in name.as_bytes():
        buf.append(c)
    buf.append(0)
    pad4(buf)
    for b in data:
        buf.append(b)
    pad4(buf)


def append_trailer(mut buf: List[UInt8]):
    comptime trailer_len = 10  # len("TRAILER!!!")
    append_header(buf, 0, 0, trailer_len + 1)
    append_bytes(buf, CPIO_TRAILER_NAME, trailer_len)
    buf.append(0)
    pad4(buf)


def main() raises:
    var args = argv()
    if len(args) < 3:
        print("usage: mkcpio OUTPUT name=path [name=path ...]")
        return

    var buf = List[UInt8]()
    for i in range(2, len(args)):
        var arg = String(args[i])
        var eq = arg.find("=")
        var name = String(arg[byte=0:eq])
        var path = String(arg[byte = eq + 1 : arg.byte_length()])

        var f = open(path, "r")
        var data = f.read_bytes()
        f.close()

        append_entry(buf, name, 0o100755, data)

    append_trailer(buf)

    var out_path = String(args[1])
    var out = open(out_path, "w")
    out.write_bytes(buf)
    out.close()
    print("wrote", out_path, "(", len(buf), "bytes)")
