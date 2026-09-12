# Freestanding Mach-O definitions, validation, and loading primitives.
#
# Shared between the bare-metal OS kernel and userspace loader.
# Free of libc dependencies; uses only freestanding pointer primitives.
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin, UntrackedOrigin

# ------------------------------------------------------------------------
# Mach-O Identification & Constants
# ------------------------------------------------------------------------
comptime MH_MAGIC: UInt32 = 0xFEEDFACE
comptime MH_CIGAM: UInt32 = 0xCEFAEDFE
comptime MH_MAGIC_64: UInt32 = 0xFEEDFACF
comptime MH_CIGAM_64: UInt32 = 0xCFFAEDFE

comptime CPU_TYPE_X86_64: UInt32 = 0x01000007
comptime CPU_TYPE_ARM64: UInt32 = 0x0100000C

comptime MH_EXECUTE: UInt32 = 0x2

# Load commands
comptime LC_SEGMENT: UInt32 = 0x1
comptime LC_SYMTAB: UInt32 = 0x2
comptime LC_UNIXTHREAD: UInt32 = 0x5
comptime LC_DYSYMTAB: UInt32 = 0xB
comptime LC_LOAD_DYLIB: UInt32 = 0xC
comptime LC_LOAD_DYLINKER: UInt32 = 0xE
comptime LC_SEGMENT_64: UInt32 = 0x19
comptime LC_MAIN: UInt32 = 0x80000028
comptime LC_DYLD_CHAINED_FIXUPS: UInt32 = 0x80000034

# VM Protection flags
comptime VM_PROT_READ: UInt32 = 0x1
comptime VM_PROT_WRITE: UInt32 = 0x2
comptime VM_PROT_EXECUTE: UInt32 = 0x4

# Thread states
comptime ARM_THREAD_STATE64: UInt32 = 6
comptime X86_THREAD_STATE64: UInt32 = 4


# ------------------------------------------------------------------------
# Headers
# ------------------------------------------------------------------------
@fieldwise_init
struct mach_header_64(RegisterPassable):
    var magic: UInt32
    var cputype: UInt32
    var cpusubtype: UInt32
    var filetype: UInt32
    var ncmds: UInt32
    var sizeofcmds: UInt32
    var flags: UInt32
    var reserved: UInt32


@fieldwise_init
struct load_command(RegisterPassable):
    var cmd: UInt32
    var cmdsize: UInt32


@fieldwise_init
struct segment_command_64(RegisterPassable):
    var cmd: UInt32
    var cmdsize: UInt32
    var segname_0: UInt64  # 16 bytes name
    var segname_1: UInt64
    var vmaddr: UInt64
    var vmsize: UInt64
    var fileoff: UInt64
    var filesize: UInt64
    var maxprot: UInt32
    var initprot: UInt32
    var nsects: UInt32
    var flags: UInt32


@fieldwise_init
struct entry_point_command(RegisterPassable):
    var cmd: UInt32
    var cmdsize: UInt32
    var entryoff: UInt64
    var stacksize: UInt64


# ------------------------------------------------------------------------
# Memory Access Helpers
# ------------------------------------------------------------------------
@always_inline
def macho_read_u8(addr: Int) -> UInt8:
    var p = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def macho_read_u16(addr: Int) -> UInt16:
    var p = Pointer[mut=False, T=UInt16, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def macho_read_u32(addr: Int) -> UInt32:
    var p = Pointer[mut=False, T=UInt32, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def macho_read_u64(addr: Int) -> UInt64:
    var p = Pointer[mut=False, T=UInt64, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=addr
    )
    return p[]


@always_inline
def macho_write_u8(addr: Int, val: UInt8):
    var p = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


@always_inline
def macho_write_u64(addr: Int, val: UInt64):
    var p = Pointer[mut=True, T=UInt64, origin=MutUntrackedOrigin](
        unsafe_from_address=addr
    )
    p[] = val


# ------------------------------------------------------------------------
# Validation & Inspection
# ------------------------------------------------------------------------
def macho_is_valid(base: Int) -> Bool:
    """Verify memory at `base` is a 64-bit Mach-O executable."""
    var magic = macho_read_u32(base)
    if magic != MH_MAGIC_64:
        return False
    return True


def macho_cputype(base: Int) -> UInt32:
    return macho_read_u32(base + 4)


def macho_ncmds(base: Int) -> UInt32:
    return macho_read_u32(base + 16)


def macho_sizeofcmds(base: Int) -> UInt32:
    return macho_read_u32(base + 20)


def macho_find_chained_fixups(
    base: Int, mut out_dataoff: UInt32, mut out_datasize: UInt32
) -> Bool:
    """Find LC_DYLD_CHAINED_FIXUPS command in Mach-O binary."""
    if not macho_is_valid(base):
        return False
    var ncmds = Int(macho_ncmds(base))
    var curr = base + 32
    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            out_dataoff = macho_read_u32(curr + 8)
            out_datasize = macho_read_u32(curr + 12)
            return True
        curr += cmdsize
    return False


def macho_find_symtab(
    base: Int,
    mut out_symoff: UInt32,
    mut out_nsyms: UInt32,
    mut out_stroff: UInt32,
    mut out_strsize: UInt32,
) -> Bool:
    """Find LC_SYMTAB command in Mach-O binary."""
    if not macho_is_valid(base):
        return False
    var ncmds = Int(macho_ncmds(base))
    var curr = base + 32
    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_SYMTAB:
            out_symoff = macho_read_u32(curr + 8)
            out_nsyms = macho_read_u32(curr + 12)
            out_stroff = macho_read_u32(curr + 16)
            out_strsize = macho_read_u32(curr + 20)
            return True
        curr += cmdsize
    return False


def macho_lookup_symbol(
    base: Int, sym_name_addr: Int, sym_name_len: Int
) -> UInt64:
    """Look up an exported symbol in a Mach-O binary (e.g. libSystem)."""
    var symoff: UInt32 = 0
    var nsyms: UInt32 = 0
    var stroff: UInt32 = 0
    var strsize: UInt32 = 0
    if not macho_find_symtab(base, symoff, nsyms, stroff, strsize):
        return 0

    var sym_tab = base + Int(symoff)
    var str_tab = base + Int(stroff)

    for i in range(Int(nsyms)):
        var off = sym_tab + i * 16
        var strx = Int(macho_read_u32(off))
        var ntype = macho_read_u8(off + 4)
        var nvalue = macho_read_u64(off + 8)

        # Check for external defined symbol: (ntype & 1) != 0 and (ntype & 0x0e) == 0x0e
        if (ntype & 1) != 0 and (ntype & 0x0E) == 0x0E:
            if strx < Int(strsize):
                var name_ptr = str_tab + strx
                # Match symbol name
                var matches = True
                for k in range(sym_name_len):
                    if macho_read_u8(name_ptr + k) != macho_read_u8(
                        sym_name_addr + k
                    ):
                        matches = False
                        break
                if matches and macho_read_u8(name_ptr + sym_name_len) == 0:
                    return nvalue
    return 0


def macho_find_entry(base: Int) -> UInt64:
    if not macho_is_valid(base):
        return 0
    var ncmds = Int(macho_ncmds(base))
    var cmd_offset = base + 32  # sizeof(mach_header_64)

    # First pass: look for __TEXT vmaddr to compute LC_MAIN absolute address
    var text_vmaddr: UInt64 = 0
    var curr = cmd_offset
    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_SEGMENT_64:
            # check segment name (__TEXT)
            var name_u64 = macho_read_u64(curr + 8)
            # "__TEXT\0\0" in ASCII little-endian:
            # '_'=0x5f, '_'=0x5f, 'T'=0x54, 'E'=0x45, 'X'=0x58, 'T'=0x54
            if (name_u64 & 0xFFFFFFFFFFFF) == 0x545845545F5F:
                text_vmaddr = macho_read_u64(curr + 24)
        curr += cmdsize

    # Second pass: look for entry point
    curr = cmd_offset
    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_MAIN:
            var entryoff = macho_read_u64(curr + 8)
            return text_vmaddr + entryoff
        if cmd == LC_UNIXTHREAD:
            # Flavor and count follow cmd and cmdsize
            # curr+8 = flavor, curr+12 = count
            var flavor = macho_read_u32(curr + 8)
            if flavor == ARM_THREAD_STATE64:
                # arm_thread_state64: pc is at offset 8 + 8 + 29*8 + 8 + 8 = 32 + 232 + 16 = 280
                # In thread_command:
                # cmd (4), cmdsize (4), flavor (4), count (4) -> state starts at +16
                # in arm_thread_state64:
                # x[29] is 29*8 = 232 bytes
                # fp is at +232
                # lr is at +240
                # sp is at +248
                # pc is at +256
                return macho_read_u64(curr + 16 + 256)
            elif flavor == X86_THREAD_STATE64:
                # x86_thread_state64: rip is at offset 16 + 16*8 = 16 + 128 = 144
                # (rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp, r8-r15 = 16 regs -> rip is 17th = index 16)
                return macho_read_u64(curr + 16 + 16 * 8)
        curr += cmdsize

    return 0


def macho_image_end(base: Int) -> Int:
    """Highest address mapped by any LC_SEGMENT_64 (vmaddr + vmsize)."""
    if not macho_is_valid(base):
        return 0
    var ncmds = Int(macho_ncmds(base))
    var curr = base + 32
    var end: Int = 0
    for _ in range(ncmds):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_SEGMENT_64:
            var vmaddr = Int(macho_read_u64(curr + 24))
            var vmsize = Int(macho_read_u64(curr + 32))
            var e = vmaddr + vmsize
            if e > end:
                end = e
        curr += cmdsize
    return end


def macho_load_bounds(
    base: Int, mut min_addr: UInt64, mut max_addr: UInt64
) -> Bool:
    """Find extent covering all loadable (non-PAGEZERO) 64-bit segments."""
    if not macho_is_valid(base):
        return False
    var curr = base + 32
    var found = False
    var low: UInt64 = 0xFFFFFFFFFFFFFFFF
    var high: UInt64 = 0
    for _ in range(Int(macho_ncmds(base))):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_SEGMENT_64:
            var vmsize = macho_read_u64(curr + 32)
            # PAGEZERO has no permissions and must not be allocated.
            var initprot = macho_read_u32(curr + 60)
            if vmsize != 0 and initprot != 0:
                var vmaddr = macho_read_u64(curr + 24)
                if vmaddr < low:
                    low = vmaddr
                if vmaddr + vmsize > high:
                    high = vmaddr + vmsize
                found = True
        curr += cmdsize
    if found:
        min_addr = low
        max_addr = high
    return found


def macho_load_image(base: Int, load_bias: Int = 0) -> Bool:
    """Copy each loadable LC_SEGMENT_64 and clear its BSS tail."""
    if not macho_is_valid(base):
        return False
    var curr = base + 32
    for _ in range(Int(macho_ncmds(base))):
        var cmd = macho_read_u32(curr)
        var cmdsize = Int(macho_read_u32(curr + 4))
        if cmd == LC_SEGMENT_64:
            var vmsize = Int(macho_read_u64(curr + 32))
            var initprot = macho_read_u32(curr + 60)
            if vmsize != 0 and initprot != 0:
                var dst = Int(macho_read_u64(curr + 24)) + load_bias
                var src = base + Int(macho_read_u64(curr + 40))
                var filesize = Int(macho_read_u64(curr + 48))
                for b in range(filesize):
                    macho_write_u8(dst + b, macho_read_u8(src + b))
                for b in range(filesize, vmsize):
                    macho_write_u8(dst + b, 0)
        curr += cmdsize
    return True
