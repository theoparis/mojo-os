# A minimal in-memory VFS, shared between kmain (mount) and the syscall
# dispatcher (file ops) via a persistent kernel region.
#
# Because a Mojo object cannot be shared across the two separately-exported
# functions, the whole filesystem state lives at a fixed raw address (`base`)
# that kmain allocates from the physical allocator and records in kernel state
# (kstate.OFF_VFS); every vfs_*() function takes `base` and reads/writes the
# flat region with mem helpers, mirroring how src/mm/phys.mojo works.
#
# Model: a *flat* read-only rootfs built from the resident initrd cpio
# archive (see src/fs/ramfs.mojo). Nodes are:
#   node 0  = the root directory (virtual; contains every other node)
#   nodes 1..N-1 = the initrd's files, referenced zero-copy into the archive
# Everything lives at the filesystem root for now (no subdirectories), which
# is enough to serve `ls /`, `cat <file>`, stat, and small `sh` pipelines.
#
# FD 0/1/2 are reserved for stdio (not in the fd table): the console. File
# descriptors are opened read-only; writes go to stdout (the UART).

from arch.mem import (
    read_u64,
    read_u8,
    write_u16,
    write_u32,
    write_u64,
    write_u8,
)

comptime VFS_MAXFILES = 48  # files beyond the root directory
comptime VFS_MAXFD = 24  # open file descriptors (0/1/2 are stdio)
comptime NODE_SZ = 32
comptime FD_SZ = 24
# region layout:
#   base+0          u64 node count (>= 1; node 0 is the root dir)
#   base+8          node table [VFS_SLOTS] x NODE_SZ
#   FD_OFF          fd table    [VFS_MAXFD] x FD_SZ
comptime VFS_SLOTS = VFS_MAXFILES + 1
comptime FD_OFF = 8 + VFS_SLOTS * NODE_SZ

# node field offsets (all u64)
comptime N_NAME = 0  # addr of NUL-terminated name (in initrd)
comptime N_DATA = 8  # addr of file data (in initrd)
comptime N_SIZE = 16
comptime N_MODE = 24  # full st_mode incl. S_IFMT type bits
# fd field offsets (all u64)
comptime FD_OPEN = 0  # 0 = closed, else open
comptime FD_NODE = 8  # node index
comptime FD_POS = 16  # read/getdents cursor

# file type bits
comptime S_IFMT: UInt64 = 0xF000
comptime S_IFREG: UInt64 = 0x8000
comptime S_IFDIR: UInt64 = 0x4000
comptime S_IFCHR: UInt64 = 0x2000

# errno values (Linux convention: -errno as UInt64)
comptime E_NOENT: UInt64 = 0xFFFFFFFFFFFFFFFE  # -2
comptime E_BADF: UInt64 = 0xFFFFFFFFFFFFFFF7  # -9
comptime E_ACCES: UInt64 = 0xFFFFFFFFFFFFFFF3  # -13
comptime E_NOTDIR: UInt64 = 0xFFFFFFFFFFFFFFEC  # -20
comptime E_ISDIR: UInt64 = 0xFFFFFFFFFFFFFFEB  # -21
comptime E_INVAL: UInt64 = 0xFFFFFFFFFFFFFFEA  # -22
comptime E_ROFS: UInt64 = 0xFFFFFFFFFFFFFFE2  # -30

comptime O_DIRECTORY: Int = 0x10000


@always_inline
def node_addr(base: Int, idx: Int) -> Int:
    return base + 8 + idx * NODE_SZ


@always_inline
def fd_addr(base: Int, fd: Int) -> Int:
    return base + FD_OFF + fd * FD_SZ


def node_count(base: Int) -> Int:
    return Int(read_u64(base))


def set_node_count(base: Int, n: Int):
    write_u64(base, UInt64(n))


def is_dir(mode: UInt64) -> Bool:
    return (mode & S_IFMT) == S_IFDIR


def mount(base: Int):
    """Reset the region: only the root directory, all fds closed."""
    set_node_count(base, 1)
    var n = node_addr(base, 0)
    write_u64(n + N_NAME, 0)
    write_u64(n + N_DATA, 0)
    write_u64(n + N_SIZE, 0)
    write_u64(n + N_MODE, S_IFDIR | 0x1ED)  # S_IFDIR|0755
    for fd in range(VFS_MAXFD):
        write_u64(fd_addr(base, fd) + FD_OPEN, 0)


def add_file(
    base: Int, name_addr: Int, data_addr: Int, size: Int, mode: UInt64
) -> Bool:
    """Add one root-level file node (zero-copy refs into the archive)."""
    var c = node_count(base)
    if c >= VFS_SLOTS:
        return False
    var n = node_addr(base, c)
    write_u64(n + N_NAME, UInt64(name_addr))
    write_u64(n + N_DATA, UInt64(data_addr))
    write_u64(n + N_SIZE, UInt64(size))
    write_u64(n + N_MODE, mode)
    set_node_count(base, c + 1)
    return True


def f_name(base: Int, idx: Int) -> Int:
    return Int(read_u64(node_addr(base, idx) + N_NAME))


def f_data(base: Int, idx: Int) -> Int:
    return Int(read_u64(node_addr(base, idx) + N_DATA))


def f_size(base: Int, idx: Int) -> Int:
    return Int(read_u64(node_addr(base, idx) + N_SIZE))


def f_mode(base: Int, idx: Int) -> UInt64:
    return read_u64(node_addr(base, idx) + N_MODE)


def node_isdir(base: Int, idx: Int) -> Bool:
    return is_dir(f_mode(base, idx))


def _name_len(addr: Int) -> Int:
    """Length of a NUL-terminated name at `addr` (cap 255)."""
    var i: Int = 0
    while i < 255 and read_u8(addr + i) != 0:
        i += 1
    return i


def _match(t_addr: Int, t_len: Int, node_name: Int) -> Bool:
    """True if the node name equals the target component [t_addr, t_len)."""
    if _name_len(node_name) != t_len:
        return False
    for i in range(t_len):
        if read_u8(node_name + i) != read_u8(t_addr + i):
            return False
    return True


def resolve(base: Int, path: Int) -> Int:
    """Resolve a NUL-terminated kernel `path` to a node index, or -1.

    Paths are single-component, root-relative (leading '/' optional). "",
    ".", and "/" resolve to the root directory (0). A path with a real
    subdirectory (an internal '/') isn't representable in this flat fs and
    fails with -1.
    """
    var p = path
    while read_u8(p) == 0x2F:  # skip leading '/'
        p += 1
    # "." / empty -> root
    var c0 = read_u8(p)
    if c0 == 0 or (c0 == 0x2E and read_u8(p + 1) == 0):
        return 0
    # length of the first component
    var t_len: Int = 0
    while True:
        var b = read_u8(p + t_len)
        if b == 0 or b == 0x2F:
            break
        t_len += 1
        if t_len > 255:
            return -1
    # anything after the component must be only trailing slashes
    var q = p + t_len
    while read_u8(q) == 0x2F:
        q += 1
    if read_u8(q) != 0:
        return -1  # nested path: unsupported (flat fs)
    var nc = node_count(base)
    for idx in range(1, nc):
        if _match(p, t_len, f_name(base, idx)):
            return idx
    return -1


def alloc_fd(base: Int) -> Int:
    # fds 0/1/2 are stdio (the console); file descriptors start at 3.
    for fd in range(3, VFS_MAXFD):
        if read_u64(fd_addr(base, fd) + FD_OPEN) == 0:
            return fd
    return -1


def set_fd(base: Int, fd: Int, node: Int):
    var f = fd_addr(base, fd)
    write_u64(f + FD_OPEN, 1)
    write_u64(f + FD_NODE, UInt64(node))
    write_u64(f + FD_POS, 0)


def fd_open(base: Int, fd: Int) -> Bool:
    return read_u64(fd_addr(base, fd) + FD_OPEN) != 0


def fd_node(base: Int, fd: Int) -> Int:
    return Int(read_u64(fd_addr(base, fd) + FD_NODE))


def fd_pos(base: Int, fd: Int) -> Int:
    return Int(read_u64(fd_addr(base, fd) + FD_POS))


def set_fd_pos(base: Int, fd: Int, pos: Int):
    write_u64(fd_addr(base, fd) + FD_POS, UInt64(pos))


def open(base: Int, path: Int, flags: Int) -> UInt64:
    """open/openat on the rootfs. Returns an fd (>= 3) or -errno."""
    var node = resolve(base, path)
    if node < 0:
        return E_NOENT
    if (flags & O_DIRECTORY) != 0 and not node_isdir(base, node):
        return E_NOTDIR
    var fd = alloc_fd(base)
    if fd < 0:
        return E_ROFS  # too many open files (we have no EMFILE yet)
    set_fd(base, fd, node)
    return UInt64(fd)


def close(base: Int, fd: Int) -> UInt64:
    if fd < 0 or fd >= VFS_MAXFD or not fd_open(base, fd):
        return E_BADF
    write_u64(fd_addr(base, fd) + FD_OPEN, 0)
    return 0


def read_fd(base: Int, fd: Int, dst: Int, count: Int) -> UInt64:
    if fd < 3 or fd >= VFS_MAXFD or not fd_open(base, fd):
        return E_BADF
    var node = fd_node(base, fd)
    if node_isdir(base, node):
        return E_ISDIR
    var size = f_size(base, node)
    var pos = fd_pos(base, fd)
    if pos >= size:
        return 0
    var n = size - pos
    if n > count:
        n = count
    var data = f_data(base, node)
    for k in range(n):
        write_u8(dst + k, read_u8(data + pos + k))
    set_fd_pos(base, fd, pos + n)
    return UInt64(n)


def lseek(base: Int, fd: Int, off: Int, whence: Int) -> UInt64:
    if fd < 3 or fd >= VFS_MAXFD or not fd_open(base, fd):
        return E_BADF
    var node = fd_node(base, fd)
    var size = f_size(base, node)
    var pos = fd_pos(base, fd)
    var npos: Int
    if whence == 0:  # SEEK_SET
        npos = off
    elif whence == 1:  # SEEK_CUR
        npos = pos + off
    elif whence == 2:  # SEEK_END
        npos = size + off
    else:
        return E_INVAL
    if npos < 0:
        return E_INVAL
    set_fd_pos(base, fd, npos)
    return UInt64(npos)


# Linux aarch64 `struct stat` is 128 bytes (== asm-generic/stat.h layout on
# 64-bit). We fill dev=0, uid/gid=0, blksize=4096 and a fixed boot timestamp
# so tools print a sane (if static) date.
comptime STAT_TS: UInt64 = 1700000000


@always_inline
def _put_stat(ubuf: Int, mode: UInt64, size: Int, ino: UInt64):
    # Darwin struct user64_stat64 (XNU /usr/include/sys/stat.h):
    # dev_t     st_dev          (4 bytes, +0)
    # mode_t    st_mode         (2 bytes, +4)
    # nlink_t   st_nlink        (2 bytes, +6)
    # ino64_t   st_ino          (8 bytes, +8)
    # uid_t     st_uid          (4 bytes, +16)
    # gid_t     st_gid          (4 bytes, +20)
    # dev_t     st_rdev         (4 bytes, +24)
    #           [4 bytes pad]
    # timespec  st_atimespec    (16 bytes: 8s + 8ns, +32)
    # timespec  st_mtimespec    (16 bytes, +48)
    # timespec  st_ctimespec    (16 bytes, +64)
    # timespec  st_birthtimespec(16 bytes, +80)
    # off_t     st_size         (8 bytes, +96)
    # blkcnt_t  st_blocks       (8 bytes, +104)
    # blksize_t st_blksize      (4 bytes, +112)
    # uint32_t  st_flags        (4 bytes, +116)
    # uint32_t  st_gen          (4 bytes, +120)
    # int32_t   st_lspare       (4 bytes, +124)
    # int64_t   st_qspare[2]    (16 bytes, +128)
    write_u32(ubuf + 0, 0)  # st_dev
    write_u16(ubuf + 4, UInt16(mode & 0xFFFF))  # st_mode
    write_u16(ubuf + 6, 1)  # st_nlink
    write_u64(ubuf + 8, ino)  # st_ino
    write_u32(ubuf + 16, 0)  # st_uid
    write_u32(ubuf + 20, 0)  # st_gid
    write_u32(ubuf + 24, 0)  # st_rdev
    write_u32(ubuf + 28, 0)  # pad
    write_u64(ubuf + 32, STAT_TS)  # st_atime
    write_u64(ubuf + 40, 0)  # st_atimensec
    write_u64(ubuf + 48, STAT_TS)  # st_mtime
    write_u64(ubuf + 56, 0)  # st_mtimensec
    write_u64(ubuf + 64, STAT_TS)  # st_ctime
    write_u64(ubuf + 72, 0)  # st_ctimensec
    write_u64(ubuf + 80, STAT_TS)  # st_birthtime
    write_u64(ubuf + 88, 0)  # st_birthtimensec
    write_u64(ubuf + 96, UInt64(size))  # st_size
    write_u64(ubuf + 104, UInt64((size + 511) // 512))  # st_blocks
    write_u32(ubuf + 112, 4096)  # st_blksize
    write_u32(ubuf + 116, 0)  # st_flags
    write_u32(ubuf + 120, 0)  # st_gen
    write_u32(ubuf + 124, 0)  # st_lspare
    write_u64(ubuf + 128, 0)  # st_qspare[0]
    write_u64(ubuf + 136, 0)  # st_qspare[1]


def stat_node(base: Int, node: Int, ubuf: Int):
    _put_stat(ubuf, f_mode(base, node), f_size(base, node), UInt64(node))


def fstat(base: Int, fd: Int, ubuf: Int) -> UInt64:
    """fstat on a file descriptor in our table (>= 3)."""
    if fd < 3 or fd >= VFS_MAXFD or not fd_open(base, fd):
        return E_BADF
    stat_node(base, fd_node(base, fd), ubuf)
    return 0


def stat_path(base: Int, path: Int, ubuf: Int) -> UInt64:
    """stat/newfstatat: resolve `path` (NUL string) and fill `ubuf`."""
    var node = resolve(base, path)
    if node < 0:
        return E_NOENT
    stat_node(base, node, ubuf)
    return 0


def stat_stdio(ubuf: Int):
    """stat for the console (fd 0/1/2): a character device, size 0."""
    _put_stat(ubuf, S_IFCHR | 0x180, 0, 1)


def getdents(base: Int, fd: Int, ubuf: Int, count: Int) -> UInt64:
    """getdents64: fill linux_dirent64 records for a directory fd. Returns
    bytes written (0 at end) or -errno. d_off is a monotonic token (child
    index+1); musl's readdir() walks sequentially here."""
    if fd < 3 or fd >= VFS_MAXFD or not fd_open(base, fd):
        return E_BADF
    var node = fd_node(base, fd)
    if not node_isdir(base, node):
        return E_NOTDIR
    var nc = node_count(base)
    var out = 0
    var done = fd_pos(base, fd)  # children 1..done already returned
    var idx = done + 1
    while idx < nc:
        var nm = f_name(base, idx)
        var l = _name_len(nm)
        var reclen = ((19 + 1 + l) + 7) & ~7  # align offsetof(name)+1 to 8
        if out + reclen > count:
            break
        var e = ubuf + out
        write_u64(e + 0, UInt64(idx))  # d_ino
        write_u64(e + 8, UInt64(idx + 1))  # d_off (token)
        write_u16(e + 16, UInt16(reclen))  # d_reclen
        var ty: UInt8 = 8  # DT_REG
        if node_isdir(base, idx):
            ty = 4  # DT_DIR
        write_u8(e + 18, ty)
        for i in range(l):
            write_u8(e + 19 + i, read_u8(nm + i))
        write_u8(e + 19 + l, 0)  # NUL-terminated name
        out += reclen
        done += 1
        idx += 1
    set_fd_pos(base, fd, done)
    return UInt64(out)
