from std.sys._assembly import inlined_assembly

# Address constant targeting PL011 Data Register inside QEMU Emulated Environment
comptime PL011_UART0_DR: Int = 0x09000000


@always_inline
def mmio_write_byte(addr: Int, byte: UInt8):
    """Outputs a raw byte directly into memory mapped volatile system space."""
    _ = inlined_assembly[
        "strb ${0:w}, [$1]", NoneType, constraints="r,r", has_side_effect=True
    ](byte, addr)


@always_inline
def putc(c: UInt8):
    mmio_write_byte(PL011_UART0_DR, c)


def print_str(s: StringLiteral):
    var ptr = s.unsafe_ptr()
    while ptr[] != 0:
        putc(ptr[])
        ptr = ptr.unsafe_offset(1)


@export("kmain")
def kmain() abi("C"):
    print_str("Hello from Bare-Metal Mojo 1.0.0 running inside src/ !\n")

    while True:
        _ = inlined_assembly[
            "wfi", NoneType, constraints="", has_side_effect=True
        ]()
