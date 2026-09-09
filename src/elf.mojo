# Minimal ELF64/AArch64 loader.
#
# We only need to support what our own userspace toolchain produces: a
# static, non-PIE ET_EXEC binary with a handful of PT_LOAD segments. No
# relocations, no dynamic linking, no PIE base slide -- p_vaddr is taken
# literally as a physical/identity-mapped address, which the caller must
# have already made sure lands inside the EL0-accessible region.
from console import print_str, print_uint
from mem import read_u16, read_u32, read_u64, read_u8, write_u8

comptime ET_EXEC: UInt16 = 2
comptime EM_AARCH64: UInt16 = 183
comptime PT_LOAD: UInt32 = 1


def elf_is_valid(base: Int) -> Bool:
    if read_u8(base + 0) != 0x7F:
        return False
    if read_u8(base + 1) != 0x45:  # 'E'
        return False
    if read_u8(base + 2) != 0x4C:  # 'L'
        return False
    if read_u8(base + 3) != 0x46:  # 'F'
        return False
    if read_u8(base + 4) != 2:  # ELFCLASS64
        return False
    if read_u8(base + 5) != 1:  # ELFDATA2LSB
        return False
    if read_u16(base + 18) != EM_AARCH64:
        return False
    return True


def load_elf(base: Int) -> Int:
    """Load PT_LOAD segments from the ELF64/AArch64 image at `base`.

    `base` points at the file bytes in memory (e.g. a ramfs entry); each
    segment is copied to its literal p_vaddr and the p_memsz-p_filesz tail
    is zeroed (bss). Returns the entry point address, or 0 on failure.
    """
    if not elf_is_valid(base):
        print_str("[elf] not a recognized ELF64/aarch64 image\n")
        return 0

    var e_type = read_u16(base + 16)
    if e_type != ET_EXEC:
        print_str(
            "[elf] unsupported e_type (need ET_EXEC, no PIE support yet)\n"
        )
        return 0

    var e_entry = read_u64(base + 24)
    var phoff = Int(read_u64(base + 32))
    var phentsize = Int(read_u16(base + 54))
    var phnum = Int(read_u16(base + 56))

    var i = 0
    while i < phnum:
        var ph = base + phoff + i * phentsize
        var p_type = read_u32(ph + 0)
        if p_type == PT_LOAD:
            var p_offset = Int(read_u64(ph + 8))
            var p_vaddr = Int(read_u64(ph + 16))
            var p_filesz = Int(read_u64(ph + 32))
            var p_memsz = Int(read_u64(ph + 40))
            var src = base + p_offset

            print_str("[elf] PT_LOAD vaddr=0x")
            print_uint(UInt64(p_vaddr), 16)
            print_str(" filesz=")
            print_uint(UInt64(p_filesz), 10)
            print_str(" memsz=")
            print_uint(UInt64(p_memsz), 10)
            print_str("\n")

            var k = 0
            while k < p_filesz:
                write_u8(p_vaddr + k, read_u8(src + k))
                k += 1
            while k < p_memsz:
                write_u8(p_vaddr + k, 0)
                k += 1
        i += 1

    return Int(e_entry)
