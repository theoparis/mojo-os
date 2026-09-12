# Freestanding ELF64 definitions, validation, and loading primitives.
#
# Shared between the UEFI bootloader and the bare-metal OS kernel.
# Free of libc dependencies; uses only freestanding pointer primitives.
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin, UntrackedOrigin

# ------------------------------------------------------------------------
# ELF Identification & Constants
# ------------------------------------------------------------------------
comptime EI_MAG0: Int = 0
comptime EI_MAG1: Int = 1
comptime EI_MAG2: Int = 2
comptime EI_MAG3: Int = 3
comptime EI_CLASS: Int = 4
comptime EI_DATA: Int = 5
comptime EI_VERSION: Int = 6
comptime EI_OSABI: Int = 7
comptime EI_ABIVERSION: Int = 8
comptime EI_NIDENT: Int = 16

comptime ELFMAG0: UInt8 = 0x7F
comptime ELFMAG1: UInt8 = 0x45  # 'E'
comptime ELFMAG2: UInt8 = 0x4C  # 'L'
comptime ELFMAG3: UInt8 = 0x46  # 'F'

# ELF Class
comptime ELFCLASSNONE: UInt8 = 0
comptime ELFCLASS32: UInt8 = 1
comptime ELFCLASS64: UInt8 = 2

# ELF Data Encoding
comptime ELFDATANONE: UInt8 = 0
comptime ELFDATA2LSB: UInt8 = 1  # 2's complement, little endian
comptime ELFDATA2MSB: UInt8 = 2  # 2's complement, big endian

# ELF Object File Types
comptime ET_NONE: UInt16 = 0
comptime ET_REL: UInt16 = 1
comptime ET_EXEC: UInt16 = 2
comptime ET_DYN: UInt16 = 3
comptime ET_CORE: UInt16 = 4

# ELF Target Machines
comptime EM_NONE: UInt16 = 0
comptime EM_386: UInt16 = 3
comptime EM_X86_64: UInt16 = 62
comptime EM_ARM: UInt16 = 40
comptime EM_AARCH64: UInt16 = 183
comptime EM_RISCV: UInt16 = 243

# Program Header Types
comptime PT_NULL: UInt32 = 0
comptime PT_LOAD: UInt32 = 1
comptime PT_DYNAMIC: UInt32 = 2
comptime PT_INTERP: UInt32 = 3
comptime PT_NOTE: UInt32 = 4
comptime PT_SHLIB: UInt32 = 5
comptime PT_PHDR: UInt32 = 6

# Program Header Flags
comptime PF_X: UInt32 = 1  # Execute
comptime PF_W: UInt32 = 2  # Write
comptime PF_R: UInt32 = 4  # Read


# ------------------------------------------------------------------------
# ELF64 Header Structs
# ------------------------------------------------------------------------
@fieldwise_init
struct Elf64_Ehdr(RegisterPassable):
    var e_ident_0: UInt64  # 0..7
    var e_ident_1: UInt64  # 8..15
    var e_type: UInt16
    var e_machine: UInt16
    var e_version: UInt32
    var e_entry: UInt64
    var e_phoff: UInt64
    var e_shoff: UInt64
    var e_flags: UInt32
    var e_ehsize: UInt16
    var e_phentsize: UInt16
    var e_phnum: UInt16
    var e_shentsize: UInt16
    var e_shnum: UInt16
    var e_shstrndx: UInt16


@fieldwise_init
struct Elf64_Phdr(RegisterPassable):
    var p_type: UInt32
    var p_flags: UInt32
    var p_offset: UInt64
    var p_vaddr: UInt64
    var p_paddr: UInt64
    var p_filesz: UInt64
    var p_memsz: UInt64
    var p_align: UInt64


# ------------------------------------------------------------------------
# Freestanding Memory Access Helpers
# ------------------------------------------------------------------------
@always_inline
def elf_read_u8(addr: Int) -> UInt8:
    var p = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def elf_read_u16(addr: Int) -> UInt16:
    var p = Pointer[mut=False, T=UInt16, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def elf_read_u32(addr: Int) -> UInt32:
    var p = Pointer[mut=False, T=UInt32, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def elf_read_u64(addr: Int) -> UInt64:
    var p = Pointer[mut=False, T=UInt64, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def elf_write_u8(addr: Int, val: UInt8):
    var p = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


# ------------------------------------------------------------------------
# Validation & Header Field Inspection
# ------------------------------------------------------------------------
def elf_is_valid(base: Int) -> Bool:
    """Check that the memory at `base` contains a valid ELF64 little-endian binary."""
    if elf_read_u8(base + 0) != ELFMAG0:
        return False
    if elf_read_u8(base + 1) != ELFMAG1:
        return False
    if elf_read_u8(base + 2) != ELFMAG2:
        return False
    if elf_read_u8(base + 3) != ELFMAG3:
        return False
    if elf_read_u8(base + 4) != ELFCLASS64:
        return False
    if elf_read_u8(base + 5) != ELFDATA2LSB:
        return False
    return True


def elf_machine(base: Int) -> UInt16:
    return elf_read_u16(base + 18)


def elf_entry(base: Int) -> UInt64:
    return elf_read_u64(base + 24)


def elf_phoff(base: Int) -> UInt64:
    return elf_read_u64(base + 32)


def elf_phentsize(base: Int) -> UInt16:
    return elf_read_u16(base + 54)


def elf_phnum(base: Int) -> UInt16:
    return elf_read_u16(base + 56)


# ------------------------------------------------------------------------
# Layout & Loading Helpers
# ------------------------------------------------------------------------
def elf_phdrs(base: Int) -> Int:
    """Virtual address of the program-header table in the loaded image, or
    0 if the headers are not covered by any PT_LOAD segment."""
    if not elf_is_valid(base):
        return 0
    var phoff = Int(elf_phoff(base))
    var phentsize = Int(elf_phentsize(base))
    var phnum = Int(elf_phnum(base))
    var i = 0
    while i < phnum:
        var ph = base + phoff + i * phentsize
        if elf_read_u32(ph + 0) == PT_LOAD:
            var p_offset = Int(elf_read_u64(ph + 8))
            var p_vaddr = Int(elf_read_u64(ph + 16))
            var p_filesz = Int(elf_read_u64(ph + 32))
            if (
                phoff >= p_offset
                and phoff + phnum * phentsize <= p_offset + p_filesz
            ):
                return p_vaddr + (phoff - p_offset)
        i += 1
    return 0


def elf_image_end(base: Int) -> Int:
    """Highest byte past the last PT_LOAD (p_vaddr + p_memsz), 0 if none."""
    if not elf_is_valid(base):
        return 0
    var phoff = Int(elf_phoff(base))
    var phentsize = Int(elf_phentsize(base))
    var phnum = Int(elf_phnum(base))
    var end: Int = 0
    var i = 0
    while i < phnum:
        var ph = base + phoff + i * phentsize
        if elf_read_u32(ph + 0) == PT_LOAD:
            var p_vaddr = Int(elf_read_u64(ph + 16))
            var p_memsz = Int(elf_read_u64(ph + 40))
            var e = p_vaddr + p_memsz
            if e > end:
                end = e
        i += 1
    return end


def elf_load_bounds(
    base: Int, mut min_addr: UInt64, mut max_addr: UInt64
) -> Bool:
    """Find the memory extent [min_addr, max_addr) covering all PT_LOAD segments."""
    if not elf_is_valid(base):
        return False
    var phoff = Int(elf_phoff(base))
    var phentsize = Int(elf_phentsize(base))
    var phnum = Int(elf_phnum(base))
    var found = False
    var min_v: UInt64 = 0xFFFFFFFFFFFFFFFF
    var max_v: UInt64 = 0
    var i = 0
    while i < phnum:
        var ph = base + phoff + i * phentsize
        if elf_read_u32(ph + 0) == PT_LOAD:
            var p_vaddr = elf_read_u64(ph + 16)
            var p_memsz = elf_read_u64(ph + 40)
            if p_vaddr < min_v:
                min_v = p_vaddr
            if p_vaddr + p_memsz > max_v:
                max_v = p_vaddr + p_memsz
            found = True
        i += 1
    if found:
        min_addr = min_v
        max_addr = max_v
    return found


def elf_load_image(base: Int, load_bias: Int = 0) -> Bool:
    """Load PT_LOAD segments of the ELF into memory.

    Copies p_filesz bytes from `base + p_offset` to `p_vaddr + load_bias`
    and zeroes the `p_memsz - p_filesz` bss tail.
    """
    if not elf_is_valid(base):
        return False
    var phoff = Int(elf_phoff(base))
    var phentsize = Int(elf_phentsize(base))
    var phnum = Int(elf_phnum(base))
    var i = 0
    while i < phnum:
        var ph = base + phoff + i * phentsize
        if elf_read_u32(ph + 0) == PT_LOAD:
            var p_offset = Int(elf_read_u64(ph + 8))
            var p_vaddr = Int(elf_read_u64(ph + 16))
            var p_filesz = Int(elf_read_u64(ph + 32))
            var p_memsz = Int(elf_read_u64(ph + 40))

            var dst_addr = p_vaddr + load_bias
            var src_addr = base + p_offset

            # Copy file data
            for b in range(p_filesz):
                elf_write_u8(dst_addr + b, elf_read_u8(src_addr + b))

            # Zero bss tail
            for b in range(p_filesz, p_memsz):
                elf_write_u8(dst_addr + b, 0)
        i += 1
    return True
