# Minimal x86 PCI configuration-space access through the legacy CF8/CFC ports.
# This is intentionally transport-only; device drivers own vendor/device and
# BAR interpretation.
from std.ffi import external_call


@always_inline
def io_read8(port: UInt16) -> UInt8:
    return UInt8(external_call["x86_in8", Int](Int(port)))


@always_inline
def io_read16(port: UInt16) -> UInt16:
    return UInt16(external_call["x86_in16", Int](Int(port)))


@always_inline
def io_read32(port: UInt16) -> UInt32:
    return UInt32(external_call["x86_in32", Int](Int(port)))


@always_inline
def io_write8(port: UInt16, value: UInt8):
    external_call["x86_out8", NoneType](Int(port), Int(value))


@always_inline
def io_write16(port: UInt16, value: UInt16):
    external_call["x86_out16", NoneType](Int(port), Int(value))


@always_inline
def io_write32(port: UInt16, value: UInt32):
    external_call["x86_out32", NoneType](Int(port), Int(value))


@always_inline
def config_address(bus: UInt8, device: UInt8, function: UInt8, offset: UInt8) -> UInt32:
    return (
        0x80000000
        | (UInt32(bus) << 16)
        | (UInt32(device) << 11)
        | (UInt32(function) << 8)
        | (UInt32(offset) & 0xfc)
    )


def config_read32(bus: UInt8, device: UInt8, function: UInt8, offset: UInt8) -> UInt32:
    io_write32(0xcf8, config_address(bus, device, function, offset))
    return io_read32(0xcfc)


def find_device(vendor: UInt16, device_id: UInt16) -> Int:
    """Return bus-0 device number for a function-zero device, or -1."""
    for device in range(32):
        var id = config_read32(0, UInt8(device), 0, 0)
        if UInt16(id & 0xffff) == vendor and UInt16(id >> 16) == device_id:
            return device
    return -1


def io_bar0(device: Int) -> UInt16:
    """Return function zero's BAR0 I/O base, or zero for a memory BAR."""
    var bar = config_read32(0, UInt8(device), 0, 0x10)
    if (bar & 1) == 0:
        return 0
    return UInt16(bar & 0xfffc)
