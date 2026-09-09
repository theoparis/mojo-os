from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin, UntrackedOrigin
from std.format import Writer
from std.collections.string.string_span import StringSpan
from std.collections.array import Array
from std.sys.defines import MOJO_VERSION
from std.sys.info import CompilationTarget

comptime FR_TXFF: UInt32 = 0x20
comptime FR_RXFE: UInt32 = 0x10

comptime HEX_DIGITS = "0123456789abcdef"


@always_inline
def mmio_read_u32[addr: IntLiteral]() -> UInt32:
    var p = Pointer[mut=True, T=UInt32, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    return p.unsafe_load[volatile=True]()


@always_inline
def mmio_write_u32[addr: IntLiteral](value: UInt32):
    var p = Pointer[mut=True, T=UInt32, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p.unsafe_store[volatile=True](value)


@always_inline
def putc(c: UInt8):
    """Transmit a byte, blocking until the TX FIFO has room."""
    while (mmio_read_u32[0x09000018]() & FR_TXFF) != 0:
        _ = 0
    mmio_write_u32[0x09000000](UInt32(c))


@always_inline
def getc() -> UInt8:
    """Receive a byte, blocking until the RX FIFO is non-empty."""
    while (mmio_read_u32[0x09000018]() & FR_RXFE) != 0:
        _ = 0
    return UInt8(mmio_read_u32[0x09000000]() & 0xFF)


def print_str(s: StringLiteral):
    var ptr = s.ptr()
    while ptr[] != 0:
        putc(ptr[])
        ptr = ptr.unsafe_offset(1)


def print_uint(value: UInt64, base: UInt64):
    """Emit an unsigned integer in `base` (2..16), most-significant digit first.

    Uses a fixed stack buffer — no heap allocation, no libc.
    """
    var buf = Array[UInt8, 64](uninitialized=True)
    var n: Int = 0
    var rem: UInt64 = value

    if rem == 0:
        buf[0] = 0x30  # '0'
        n = 1
    else:
        while rem > 0:
            var d = Int(rem % base)
            buf[n] = HEX_DIGITS.ptr().unsafe_offset(d)[]
            rem = rem // base
            n += 1

    while n > 0:
        n -= 1
        putc(buf[n])


@always_inline
def print_int(value: Int):
    if value < 0:
        putc(0x2D)  # '-'
        print_uint(UInt64(-value), 10)
    else:
        print_uint(UInt64(value), 10)


@always_inline
def print_hex(value: UInt64):
    putc(0x30)  # '0'
    putc(0x78)  # 'x'
    print_uint(value, 16)


struct UARTWriter(Writer):
    def __init__(out self):
        pass

    def write_string(mut self, string: StringSpan):
        var ptr = string.unsafe_ptr()
        for _ in range(string.byte_length()):
            putc(ptr[])
            ptr = ptr.unsafe_offset(1)


def write[V: Writable](v: V):
    var w = UARTWriter()
    v.write_to(w)


def println[V: Writable](v: V):
    var w = UARTWriter()
    v.write_to(w)
    putc(0x0A)


@export("memcpy")
def _memcpy(dest: Int, src: Int, n: Int) abi("C") -> Int:
    var d = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=dest
    )
    var s = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=src
    )
    for i in range(n):
        d[unsafe_offset=i] = s[unsafe_offset=i]
    return dest


@export("__mojo_baremetal_debug_write")
def _mojo_baremetal_debug_write(message_addr: Int, length: Int) abi("C"):
    var ptr = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=message_addr
    )
    var msg_len = length
    if msg_len > 0 and ptr[unsafe_offset=msg_len - 1] == 0:
        msg_len -= 1
    print_str("[ASSERT] ")
    for i in range(msg_len):
        putc(ptr[unsafe_offset=i])
    putc(0x0A)


@export("kmain")
def kmain() abi("C"):
    var arch = StringLiteral[CompilationTarget[].__triple_arch()]()
    println(
        t"Hello from bare-metal {arch}, built with Mojo"
        t" {MOJO_VERSION.major}.{MOJO_VERSION.minor}.{MOJO_VERSION.patch},"
        t" running on QEMU!\n"
    )

    while True:
        _ = 0
