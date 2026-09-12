# Mach-O 64-bit user process loader.
#
# Parses LC_SEGMENT_64 commands, maps memory pages via mm/paging.mojo,
# copies initialized segment bytes, zeroes BSS portions, and retrieves the
# entry point from LC_MAIN or LC_UNIXTHREAD.
from arch.console import print_str, print_uint
from arch.mem import read_u16, read_u32, read_u64, read_u8, write_u8
from loader import (
    CPU_TYPE_ARM64,
    CPU_TYPE_X86_64,
    LC_SEGMENT_64,
    VM_PROT_EXECUTE,
    macho_cputype,
    macho_find_chained_fixups,
    macho_find_entry,
    macho_image_end,
    macho_is_valid as _loader_macho_is_valid,
    macho_lookup_symbol,
    macho_ncmds,
    macho_read_u32,
    macho_read_u64,
    macho_write_u64,
)
from mm.paging import map_user
from mm.phys import PhysAlloc


def macho_is_valid(base: Int) -> Bool:
    if not _loader_macho_is_valid(base):
        return False
    var cpu = macho_cputype(base)
    if cpu != CPU_TYPE_ARM64 and cpu != CPU_TYPE_X86_64:
        return False
    return True


def macho_bind_fixups(base: Int, dylib_base: Int, dylib_slide: UInt64):
    """Resolve and bind chained fixups in the loaded Mach-O image using symbols from dylib_base.
    """
    var fixups_off: UInt32 = 0
    var fixups_size: UInt32 = 0
    if not macho_find_chained_fixups(base, fixups_off, fixups_size):
        return

    var fixups_hdr = base + Int(fixups_off)
    var starts_off = Int(read_u32(fixups_hdr + 4))
    var imports_off = Int(read_u32(fixups_hdr + 8))
    var symbols_off = Int(read_u32(fixups_hdr + 12))
    var imports_count = Int(read_u32(fixups_hdr + 16))

    var starts_in_image = fixups_hdr + starts_off
    var seg_count = Int(read_u32(starts_in_image))

    var imports_data = fixups_hdr + imports_off
    var symbols_pool = fixups_hdr + symbols_off

    for s in range(seg_count):
        var seg_info_off = Int(read_u32(starts_in_image + 4 + s * 4))
        if seg_info_off == 0:
            continue
        var seg_starts = starts_in_image + seg_info_off
        var page_size = Int(read_u16(seg_starts + 4))
        if page_size == 0:
            continue
        var pointer_format = read_u16(seg_starts + 6)
        var seg_offset = Int(read_u64(seg_starts + 8))
        var page_count = Int(read_u16(seg_starts + 20))

        # page_start array is at offset 22
        for p in range(page_count):
            var start_val = Int(read_u16(seg_starts + 22 + p * 2))
            if start_val == 0xFFFF:
                continue

            var page_off = seg_offset + p * page_size
            var chain_off = page_off + start_val

            # DYLD_CHAINED_PTR_64 = 2
            if pointer_format == 2:
                while True:
                    # In user memory, segment is mapped at seg_offset (or vmaddr)
                    # For DYLD_CHAINED_PTR_64:
                    # chain_off is relative to the binary's mapped image!
                    # Specifically, seg_offset was the file offset / segment vmaddr offset.
                    # In our binary, __DATA_CONST vmaddr is e.g. 0x10000 + seg_offset
                    # Let us locate the virtual address for chain_off:
                    var target_va = 0x10000 + chain_off
                    var raw = read_u64(target_va)

                    var is_bind = (raw & 0x8000000000000000) != 0
                    var next = Int((raw >> 51) & 0xFFF)

                    if is_bind:
                        var ord = Int(raw & 0x00FFFFFF)
                        if ord < imports_count:
                            var imp_raw = read_u32(imports_data + ord * 4)
                            var name_off = Int(imp_raw >> 9)
                            var sym_ptr = symbols_pool + name_off
                            # Calculate length of symbol
                            var sym_len = 0
                            while read_u8(sym_ptr + sym_len) != 0:
                                sym_len += 1

                            # Lookup in dylib
                            var sym_val = macho_lookup_symbol(
                                dylib_base, sym_ptr, sym_len
                            )
                            if sym_val != 0:
                                var bound_addr = dylib_slide + sym_val
                                macho_write_u64(target_va, bound_addr)
                            else:
                                print_str("[dyld] unresolved symbol!\n")

                    if next == 0:
                        break
                    chain_off += next * 4


def load_macho_dylib(
    mut alloc: PhysAlloc, l1: Int, base: Int, slide: Int
) -> Bool:
    """Map a dynamic library into user space with a given base slide."""
    if not macho_is_valid(base):
        return False
    var ncmds = Int(macho_ncmds(base))
    var curr = base + 32

    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_SEGMENT_64:
            var vmaddr = Int(macho_read_u64(curr + 24)) + slide
            var vmsize = Int(macho_read_u64(curr + 32))
            var fileoff = Int(macho_read_u64(curr + 40))
            var filesize = Int(macho_read_u64(curr + 48))
            var initprot = macho_read_u32(curr + 60)

            # Skip __PAGEZERO if any
            if vmaddr == slide and initprot == 0 and filesize == 0:
                curr += cmdsize
                continue

            if vmsize > 0:
                var exec = (initprot & VM_PROT_EXECUTE) != 0
                if not map_user(alloc, l1, vmaddr, vmsize, exec):
                    return False

                var src = base + fileoff
                for k in range(filesize):
                    write_u8(vmaddr + k, read_u8(src + k))
                for k in range(filesize, vmsize):
                    write_u8(vmaddr + k, 0)
        curr += cmdsize
    return True


def load_macho(mut alloc: PhysAlloc, l1: Int, base: Int) -> Int:
    """Map and load the Mach-O 64 image at `base` into the user VA space.

    `base` points to the raw file bytes in RAM (e.g. within the ramfs).
    `l1` is the root level-1 page-table address.
    Returns entry point address, or 0 on error.
    """
    if not macho_is_valid(base):
        print_str("[macho] invalid or unsupported Mach-O image\n")
        return 0

    var entry = macho_find_entry(base)
    if entry == 0:
        print_str("[macho] could not find entry point\n")
        return 0

    var ncmds = Int(macho_ncmds(base))
    var curr = base + 32  # sizeof(mach_header_64)

    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))

        if cmd == LC_SEGMENT_64:
            var vmaddr = Int(macho_read_u64(curr + 24))
            var vmsize = Int(macho_read_u64(curr + 32))
            var fileoff = Int(macho_read_u64(curr + 40))
            var filesize = Int(macho_read_u64(curr + 48))
            var initprot = macho_read_u32(curr + 60)

            # Skip __PAGEZERO (vmsize > 0, filesize == 0, vmaddr == 0, initprot == 0)
            if vmaddr == 0 and initprot == 0 and filesize == 0:
                curr += cmdsize
                continue

            if vmsize > 0:
                var exec = (initprot & VM_PROT_EXECUTE) != 0
                print_str("[macho] LC_SEGMENT_64 vmaddr=0x")
                print_uint(UInt64(vmaddr), 16)
                print_str(" vmsize=0x")
                print_uint(UInt64(vmsize), 16)
                print_str(" filesize=0x")
                print_uint(UInt64(filesize), 16)
                print_str(" exec=")
                print_uint(UInt64(1 if exec else 0), 10)
                print_str("\n")

                if not map_user(alloc, l1, vmaddr, vmsize, exec):
                    print_str("[macho] map_user failed\n")
                    return 0

                var src = base + fileoff
                for k in range(filesize):
                    write_u8(vmaddr + k, read_u8(src + k))
                for k in range(filesize, vmsize):
                    write_u8(vmaddr + k, 0)

        curr += cmdsize

    return Int(entry)
