# XNU Device Tree (Flattened Device Tree / AFDT) and boot_args definitions
# for Mojo OS XNU-compatible bootloader & kernel.
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin, UntrackedOrigin

comptime kPropNameLength: Int = 32
comptime BOOT_LINE_LENGTH: Int = 1024

comptime kBootArgsRevision2: UInt16 = 2
comptime kBootArgsVersion2: UInt16 = 2


@always_inline
def dt_read_u8(addr: Int) -> UInt8:
    var p = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def dt_read_u32(addr: Int) -> UInt32:
    var p = Pointer[mut=False, T=UInt32, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def dt_read_u64(addr: Int) -> UInt64:
    var p = Pointer[mut=False, T=UInt64, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def dt_write_u8(addr: Int, val: UInt8):
    var p = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


@always_inline
def dt_write_u16(addr: Int, val: UInt16):
    var p = Pointer[mut=True, T=UInt16, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


@always_inline
def dt_write_u32(addr: Int, val: UInt32):
    var p = Pointer[mut=True, T=UInt32, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


@always_inline
def dt_write_u64(addr: Int, val: UInt64):
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


# ------------------------------------------------------------------------
# XNU boot_args Structure Accessors
# ------------------------------------------------------------------------
# Offset constants matching Darwin/XNU arm64 struct boot_args (sizeof = 1152)
comptime BA_REVISION: Int = 0  # u16
comptime BA_VERSION: Int = 2  # u16
comptime BA_VIRT_BASE: Int = 8  # u64
comptime BA_PHYS_BASE: Int = 16  # u64
comptime BA_MEM_SIZE: Int = 24  # u64
comptime BA_TOP_OF_KERNEL_DATA: Int = 32  # u64
comptime BA_VIDEO_BASE: Int = 40  # u64
comptime BA_VIDEO_DISPLAY: Int = 48  # u64
comptime BA_VIDEO_ROWBYTES: Int = 56  # u64
comptime BA_VIDEO_WIDTH: Int = 64  # u64
comptime BA_VIDEO_HEIGHT: Int = 72  # u64
comptime BA_VIDEO_DEPTH: Int = 80  # u64
comptime BA_MACHINE_TYPE: Int = 88  # u32
comptime BA_DEVICE_TREE_P: Int = 96  # u64 (void*)
comptime BA_DEVICE_TREE_LEN: Int = 104  # u32
comptime BA_COMMAND_LINE: Int = 108  # char[1024]
comptime BA_BOOT_FLAGS: Int = 1136  # u64
comptime BA_MEM_SIZE_ACTUAL: Int = 1144  # u64
comptime SIZEOF_BOOT_ARGS: Int = 1152


def init_boot_args(
    ba: Int,
    phys_base: UInt64,
    mem_size: UInt64,
    top_of_kernel: UInt64,
    dt_base: UInt64,
    dt_len: UInt32,
    cmdline: StringLiteral = "",
):
    for i in range(SIZEOF_BOOT_ARGS):
        dt_write_u8(ba + i, 0)
    dt_write_u16(ba + BA_REVISION, kBootArgsRevision2)
    dt_write_u16(ba + BA_VERSION, kBootArgsVersion2)
    dt_write_u64(ba + BA_VIRT_BASE, phys_base)
    dt_write_u64(ba + BA_PHYS_BASE, phys_base)
    dt_write_u64(ba + BA_MEM_SIZE, mem_size)
    dt_write_u64(ba + BA_MEM_SIZE_ACTUAL, mem_size)
    dt_write_u64(ba + BA_TOP_OF_KERNEL_DATA, top_of_kernel)
    dt_write_u64(ba + BA_DEVICE_TREE_P, dt_base)
    dt_write_u32(ba + BA_DEVICE_TREE_LEN, dt_len)

    # Copy cmdline
    var p = cmdline.ptr()
    var i = 0
    while p[unsafe_offset=i] != 0 and i < BOOT_LINE_LENGTH - 1:
        dt_write_u8(ba + BA_COMMAND_LINE + i, p[unsafe_offset=i])
        i += 1
    dt_write_u8(ba + BA_COMMAND_LINE + i, 0)


# ------------------------------------------------------------------------
# XNU Flattened Device Tree Parser / AFDT
# ------------------------------------------------------------------------
# Node structure:
#   nProperties: u32
#   nChildren:   u32
# Followed by nProperties of:
#   name: char[32] (NUL-padded)
#   length: u32
#   value: [((length + 3) & ~3)] bytes
# Followed by nChildren of:
#   DeviceTreeNode...


def xnu_dt_find_node(
    base: Int, total_size: Int, node_name: StringLiteral
) -> Int:
    """Find a node named `node_name` within the device tree.

    Returns the address of the DeviceTreeNode, or 0 if not found.
    """
    if base == 0 or total_size < 8:
        return 0
    var curr = base
    var end = base + total_size
    while curr + 8 <= end:
        var n_props = Int(dt_read_u32(curr))
        var n_children = Int(dt_read_u32(curr + 4))
        var p_cur = curr + 8
        var is_target = False
        for _ in range(n_props):
            if p_cur + 36 > end:
                return 0
            var prop_len = Int(dt_read_u32(p_cur + 32))
            var val_ptr = p_cur + 36
            # check if property name is "name"
            if (
                dt_read_u8(p_cur) == UInt8(ord("n"))
                and dt_read_u8(p_cur + 1) == UInt8(ord("a"))
                and dt_read_u8(p_cur + 2) == UInt8(ord("m"))
                and dt_read_u8(p_cur + 3) == UInt8(ord("e"))
                and dt_read_u8(p_cur + 4) == 0
            ):
                var matches = True
                var lit_ptr = node_name.ptr()
                var k = 0
                while lit_ptr[unsafe_offset=k] != 0:
                    if (
                        k >= prop_len
                        or dt_read_u8(val_ptr + k) != lit_ptr[unsafe_offset=k]
                    ):
                        matches = False
                        break
                    k += 1
                if matches and (k == prop_len or dt_read_u8(val_ptr + k) == 0):
                    is_target = True
            var padded_len = (prop_len + 3) & ~3
            p_cur = val_ptr + padded_len

        if is_target:
            return curr

        # Advance to children or next node
        curr = p_cur
    return 0


def xnu_dt_get_prop(
    node: Int, prop_name: StringLiteral, mut out_len: UInt32
) -> Int:
    """Get property value address and length for a node."""
    if node == 0:
        return 0
    var n_props = Int(dt_read_u32(node))
    var p_cur = node + 8
    for _ in range(n_props):
        var prop_len = dt_read_u32(p_cur + 32)
        var val_ptr = p_cur + 36
        var matches = True
        var lit_ptr = prop_name.ptr()
        var k = 0
        while lit_ptr[unsafe_offset=k] != 0:
            if dt_read_u8(p_cur + k) != lit_ptr[unsafe_offset=k]:
                matches = False
                break
            k += 1
        if matches and dt_read_u8(p_cur + k) == 0:
            out_len = prop_len
            return val_ptr
        var padded_len = (Int(prop_len) + 3) & ~3
        p_cur = val_ptr + padded_len
    return 0
