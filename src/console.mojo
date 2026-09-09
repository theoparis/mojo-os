# PL011 UART driver and libc-free console formatting.
#
# QEMU's `virt` machine exposes the PrimeCell PL011 serial port at
# 0x09000000. We poll the TX FIFO rather than interrupt-drive it. All
# printing goes straight to the UART via `putc`; none of it allocates or
# pulls in libc.
from std.collections.array import Array
from std.collections.string.string_span import StringSpan
from std.format import Writer

from mem import mmio_read_u32, mmio_write_u32, read_u8

comptime FR_TXFF: UInt32 = 0x20
comptime FR_RXFE: UInt32 = 0x10

comptime HEX_DIGITS = "0123456789abcdef"


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


def print_cstr(addr: Int, maxlen: Int):
    """Print a NUL-terminated C string at `addr` (up to `maxlen` bytes)."""
    var i = 0
    while i < maxlen:
        var c = read_u8(addr + i)
        if c == 0:
            break
        putc(c)
        i += 1


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
