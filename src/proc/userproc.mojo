# Construct and launch the initial user process.
#
# build_user_stack lays out a Linux initial stack (argc/argv/envp/auxv) in
# the already-mapped EL0 stack region; run_user drops to EL0 at the entry
# point. The argv strings themselves were collected from the cmdline by
# proc/cmdline.mojo into a kernel scratch buffer.
from std.ffi import external_call

from arch.mem import read_u8, read_u64, write_u8, write_u64
from mm.phys import PAGE_SIZE
from proc.cmdline import MAX_ARGV


def build_user_stack(
    top: Int, entry: Int, phdr: Int, phnum: Int, argc: Int, argaddrs: Int
) -> Int:
    """Lay out an initial Linux process stack (argc/argv/envp/auxv) in the
    mapped stack region just below `top` and return the initial sp.

    `argc` argv strings (each NUL-terminated) are copied out of the kernel
    argv list at `argaddrs` (an array of `argc` u64 kernel addresses, as
    built by cmdline.collect_argv) into the user stack region.
    """
    var s = (top - 0x300) & ~15
    # 1) copy each argv string (kernel -> user), remembering the user addrs
    var strp = top - 0x200
    var uaddrs = Array[Int, MAX_ARGV](uninitialized=True)
    for i in range(argc):
        var src = Int(read_u64(argaddrs + i * 8))
        var d = strp
        while True:
            var b = read_u8(src)
            write_u8(d, b)
            d += 1
            src += 1
            if b == 0:
                break
        uaddrs[i] = strp
        strp = d
    # AT_RANDOM: 16 zero bytes right after the strings
    for i in range(16):
        write_u8(strp + i, 0)
    var rnd = strp
    strp += 16

    # 2) arrays from s: argc, argv[], NULL, envp NULL, auxv pairs, AT_NULL
    var p = s
    write_u64(p, UInt64(argc))
    p += 8
    for i in range(argc):
        write_u64(p, UInt64(uaddrs[i]))
        p += 8
    write_u64(p, 0)  # argv terminator
    p += 8
    write_u64(p, 0)  # envp terminator (no environment yet)
    p += 8
    write_u64(p, 6)  # AT_PAGESZ
    p += 8
    write_u64(p, UInt64(PAGE_SIZE))
    p += 8
    write_u64(p, 25)  # AT_RANDOM
    p += 8
    write_u64(p, UInt64(rnd))
    p += 8
    if phdr > 0:
        write_u64(p, 3)  # AT_PHDR
        p += 8
        write_u64(p, UInt64(phdr))
        p += 8
        write_u64(p, 4)  # AT_PHENT
        p += 8
        write_u64(p, 56)
        p += 8
        write_u64(p, 5)  # AT_PHNUM
        p += 8
        write_u64(p, UInt64(phnum))
        p += 8
    write_u64(p, 0)  # AT_NULL
    p += 8
    write_u64(p, 0)
    return s


def run_user(entry: Int, sp: Int):
    """Drop to EL0 at `entry` with the EL0 stack pointer at `sp`.

    Pages the image needs must already be mapped with EL0 access (see
    mm/paging.mojo / proc/elf.mojo); boot.S:run_user just erets.
    """
    external_call["run_user", NoneType](entry, sp)
