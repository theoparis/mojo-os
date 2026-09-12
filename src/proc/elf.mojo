# ELF64 user process loader.
#
# Uses the freestanding `loader` package for ELF format parsing, validation,
# and program header traversal.
from arch.console import print_str, print_uint
from arch.mem import read_u8, write_u8
from loader import (
    EM_AARCH64,
    EM_X86_64,
    ET_EXEC,
    PF_X,
    PT_LOAD,
    elf_entry,
    elf_image_end,
    elf_is_valid as _loader_elf_is_valid,
    elf_machine,
    elf_phentsize,
    elf_phnum,
    elf_phoff,
    elf_phdrs,
    elf_read_u32,
    elf_read_u64,
)
from mm.paging import map_user
from mm.phys import PhysAlloc


def elf_is_valid(base: Int) -> Bool:
    if not _loader_elf_is_valid(base):
        return False
    var mach = elf_machine(base)
    if mach != EM_AARCH64 and mach != EM_X86_64:
        return False
    return True


def load_elf(mut alloc: PhysAlloc, l1: Int, base: Int) -> Int:
    """Map and load the ELF64 image at `base` into the user VA space.

    `base` points at the file bytes in memory (e.g. a ramfs entry); `l1` is
    the kernel level-1 page-table address. Each PT_LOAD segment is mapped
    with permissions from its p_flags, copied to p_vaddr, and its bss tail
    zeroed. Returns the entry address (0 = fail).
    """
    if not elf_is_valid(base):
        print_str("[elf] not a recognized ELF64 image\n")
        return 0

    var phoff = Int(elf_phoff(base))
    var phentsize = Int(elf_phentsize(base))
    var phnum = Int(elf_phnum(base))
    var e_entry = elf_entry(base)

    var i = 0
    while i < phnum:
        var ph = base + phoff + i * phentsize
        var p_type = elf_read_u32(ph + 0)
        if p_type == PT_LOAD:
            var p_flags = elf_read_u32(ph + 4)
            var p_offset = Int(elf_read_u64(ph + 8))
            var p_vaddr = Int(elf_read_u64(ph + 16))
            var p_filesz = Int(elf_read_u64(ph + 32))
            var p_memsz = Int(elf_read_u64(ph + 40))
            var src = base + p_offset

            # Map the segment's pages before touching them, so EL0 can get
            # at them once we drop privilege. Executable segments are mapped
            # read-only+exec; everything else read-write, non-executable.
            var exec = (p_flags & PF_X) != 0
            print_str("[elf] PT_LOAD vaddr=0x")
            print_uint(UInt64(p_vaddr), 16)
            print_str(" filesz=")
            print_uint(UInt64(p_filesz), 10)
            print_str(" memsz=")
            print_uint(UInt64(p_memsz), 10)
            print_str(" flags=")
            print_uint(UInt64(p_flags), 16)
            print_str("\n")
            if not map_user(alloc, l1, p_vaddr, p_memsz, exec):
                print_str("[elf] map_user failed\n")
                return 0

            var k = 0
            while k < p_filesz:
                write_u8(p_vaddr + k, read_u8(src + k))
                k += 1
            while k < p_memsz:
                write_u8(p_vaddr + k, 0)
                k += 1
        i += 1

    return Int(e_entry)
