# Raw memory access primitives shared across the kernel.
#
# Everything here reads/writes physical memory through `Pointer` objects
# built from a raw address. There is deliberately no allocation and no libc.
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin, UntrackedOrigin


@always_inline
def mmio_read_u32[addr: IntLiteral]() -> UInt32:
    """Volatile read of a device register at a compile-time address."""
    var p = Pointer[mut=True, T=UInt32, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    return p.unsafe_load[volatile=True]()


@always_inline
def mmio_write_u32[addr: IntLiteral](value: UInt32):
    """Volatile write of a device register at a compile-time address."""
    var p = Pointer[mut=True, T=UInt32, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p.unsafe_store[volatile=True](value)


def read_u8(addr: Int) -> UInt8:
    var p = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


def write_u8(addr: Int, value: UInt8):
    var p = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = value


def read_u16(addr: Int) -> UInt16:
    var p = Pointer[mut=False, T=UInt16, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


def read_u32(addr: Int) -> UInt32:
    var p = Pointer[mut=False, T=UInt32, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


def read_u64(addr: Int) -> UInt64:
    """Native (little-endian) 64-bit read -- for ELF fields, not the DTB."""
    var p = Pointer[mut=False, T=UInt64, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


def read_u32be(addr: Int) -> UInt32:
    """Read a big-endian u32 (device trees are BE regardless of the CPU)."""
    var v = read_u32(addr)
    # byteswap on the assumption of a little-endian host CPU (aarch64)
    return (
        ((v & 0xFF) << 24)
        | ((v & 0xFF00) << 8)
        | ((v >> 8) & 0xFF00)
        | ((v >> 24) & 0xFF)
    )


@always_inline
def align4(n: Int) -> Int:
    return (n + 3) & ~3


def cstr_eq(addr: Int, lit: StringLiteral) -> Bool:
    """True if the NUL-terminated C string at `addr` equals literal `lit`."""
    var p = lit.ptr()
    var i: Int = 0
    while True:
        var lc = p[unsafe_offset=i]
        if lc == 0:
            return read_u8(addr + i) == 0
        if read_u8(addr + i) != lc:
            return False
        i += 1
