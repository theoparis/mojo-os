# Detection and parsing of XNU boot_args & AFDT structures.
from arch.dtb import BootParams, MemRegions
from arch.mem import read_u16, read_u32, read_u64, read_u8
from arch.xnu_boot import (
    BA_BOOT_FLAGS,
    BA_COMMAND_LINE,
    BA_DEVICE_TREE_LEN,
    BA_DEVICE_TREE_P,
    BA_MEM_SIZE,
    BA_PHYS_BASE,
    BA_REVISION,
    BA_TOP_OF_KERNEL_DATA,
    BA_VERSION,
    BA_VIRT_BASE,
    kBootArgsRevision2,
    kBootArgsVersion2,
    xnu_dt_find_node,
    xnu_dt_get_prop,
)


def is_xnu_boot_args(addr: Int) -> Bool:
    """Check if address contains a valid XNU arm64 boot_args structure."""
    if addr == 0:
        return False
    var rev = read_u16(addr + BA_REVISION)
    var ver = read_u16(addr + BA_VERSION)
    if (rev == 1 or rev == 2) and (ver == 1 or ver == 2):
        var phys = read_u64(addr + BA_PHYS_BASE)
        var mem = read_u64(addr + BA_MEM_SIZE)
        if phys != 0 and mem != 0:
            return True
    return False


def parse_xnu_boot_args(
    addr: Int, mut mem: MemRegions, mut bp: BootParams
) -> Bool:
    """Parse XNU boot_args and embedded AFDT /chosen/memory-map RAMDisk."""
    if not is_xnu_boot_args(addr):
        return False

    var phys_base = read_u64(addr + BA_PHYS_BASE)
    var mem_size = read_u64(addr + BA_MEM_SIZE)
    mem.add(phys_base, mem_size)

    var dt_base = Int(read_u64(addr + BA_DEVICE_TREE_P))
    var dt_len = Int(read_u32(addr + BA_DEVICE_TREE_LEN))

    bp.has_dtb = True
    bp.dtb_start = UInt64(dt_base)
    bp.dtb_end = UInt64(dt_base + dt_len)
    bp.cmdline_addr = addr + BA_COMMAND_LINE
    var clen = 0
    while read_u8(bp.cmdline_addr + clen) != 0 and clen < 1024:
        clen += 1
    bp.cmdline_len = clen

    # Search for RAMDisk in /chosen/memory-map
    if dt_base != 0 and dt_len > 0:
        var mm_node = xnu_dt_find_node(dt_base, dt_len, "memory-map")
        if mm_node != 0:
            var prop_len: UInt32 = 0
            var val_ptr = xnu_dt_get_prop(mm_node, "RAMDisk", prop_len)
            if val_ptr != 0 and prop_len >= 16:
                bp.initrd_start = read_u64(val_ptr)
                var rd_size = read_u64(val_ptr + 8)
                bp.initrd_end = bp.initrd_start + rd_size
                bp.has_initrd = True
    return True
