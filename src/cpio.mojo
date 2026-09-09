# Shared cpio 'newc' (SVR4) archive format knowledge.
#
# Used by both the kernel-side reader (ramfs.mojo, compiled freestanding
# for bare-metal aarch64) and the host-side writer (tools/mkcpio.mojo, a
# normal hosted build) -- this is the one place that knows a cpio 'newc'
# header field is an 8-digit *ASCII-hex* number (not binary!), which is
# the main thing worth not getting subtly wrong in two places.
#
# This module intentionally sticks to plain integer logic (no I/O, no
# collections, no pointers) so it compiles unmodified for any target.
comptime CPIO_MAGIC = "070701"
comptime CPIO_HEADER_LEN = 110  # magic(6) + 13 * 8-hex-digit fields
comptime CPIO_NUM_FIELDS = 13
comptime CPIO_TRAILER_NAME = "TRAILER!!!"


@always_inline
def cpio_align4(n: Int) -> Int:
    return (n + 3) & ~3


@always_inline
def hex_val(c: UInt8) -> UInt32:
    """Decode one ASCII hex digit (any case) to its 0-15 value."""
    if (c >= 0x30) and (c <= 0x39):
        return UInt32(c - 0x30)
    elif (c >= 0x61) and (c <= 0x66):
        return UInt32(c - 0x61 + 10)
    else:
        return UInt32(c - 0x41 + 10)


@always_inline
def hex_digit(v: UInt32) -> UInt8:
    """Encode one nibble (0-15) as an uppercase ASCII hex digit."""
    if v < 10:
        return UInt8(0x30 + Int(v))
    return UInt8(0x41 + Int(v) - 10)
