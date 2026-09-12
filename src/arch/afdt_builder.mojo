# Freestanding builder for Apple Flattened Device Tree (AFDT)
# Constructs a valid XNU Device Tree in memory.
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin

from arch.xnu_boot import dt_write_u32, dt_write_u64, dt_write_u8


struct DTBuilder:
    var base: Int
    var cursor: Int
    var max_size: Int

    def __init__(out self, base: Int, max_size: Int):
        self.base = base
        self.cursor = base
        self.max_size = max_size

    def size(self) -> Int:
        return self.cursor - self.base

    def add_node_header(mut self, n_properties: UInt32, n_children: UInt32):
        dt_write_u32(self.cursor, n_properties)
        dt_write_u32(self.cursor + 4, n_children)
        self.cursor += 8

    def add_property(mut self, name: StringLiteral, val_ptr: Int, val_len: Int):
        # Property layout: char[32] name + uint32 length + padded value
        for i in range(32):
            dt_write_u8(self.cursor + i, 0)
        var np = name.ptr()
        var i = 0
        while np[unsafe_offset=i] != 0 and i < 31:
            dt_write_u8(self.cursor + i, np[unsafe_offset=i])
            i += 1
        dt_write_u32(self.cursor + 32, UInt32(val_len))
        self.cursor += 36

        # Write value bytes
        for b in range(val_len):
            var p = Pointer[mut=False, T=UInt8, origin=MutUntrackedOrigin](
                unsafe_from_address=val_ptr + b
            )
            dt_write_u8(self.cursor + b, p[])
        var padded = (val_len + 3) & ~3
        for b in range(val_len, padded):
            dt_write_u8(self.cursor + b, 0)
        self.cursor += padded

    def add_string_property(
        mut self, name: StringLiteral, str_val: StringLiteral
    ):
        var sp = str_val.ptr()
        var len = 0
        while sp[unsafe_offset=len] != 0:
            len += 1
        len += 1  # include NUL
        self.add_property(name, Int(sp), len)

    def add_u64_pair_property(
        mut self, name: StringLiteral, u0: UInt64, u1: UInt64
    ):
        # Write directly: taking a pointer to a Mojo Array is not guaranteed
        # to expose its elements as a contiguous C-style pair.
        for i in range(32):
            dt_write_u8(self.cursor + i, 0)
        var np = name.ptr()
        var i = 0
        while np[unsafe_offset=i] != 0 and i < 31:
            dt_write_u8(self.cursor + i, np[unsafe_offset=i])
            i += 1
        dt_write_u32(self.cursor + 32, 16)
        dt_write_u64(self.cursor + 36, u0)
        dt_write_u64(self.cursor + 44, u1)
        self.cursor += 52
