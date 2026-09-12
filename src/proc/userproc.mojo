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
    """Lay out a Darwin / XNU user process stack in the mapped stack region
    below `top` and return the initial sp.

    Darwin 64-bit initial stack ABI (XNU kern_exec.c: exec_copyout_strings):
      [sp]                  = argc (64-bit)
      [sp + 8 ..]           = argv[0..argc-1] (64-bit pointers)
      [sp + 8*(argc+1)]     = NULL (argv terminator)
      [sp + 8*(argc+2) ..]  = envp[0..envc-1] (64-bit pointers)
      [sp + ...]            = NULL (envp terminator)
      [sp + ...]            = apple[0..applec-1] (executable path etc.)
      [sp + ...]            = NULL (apple terminator)
      Strings and executable path follow the pointers.
    """
    # 1) Copy string data down from top
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

    # Also place an exec_path string for apple[0]
    var exec_path_addr = strp
    write_u8(exec_path_addr + 0, 0x2F)  # '/'
    write_u8(exec_path_addr + 1, 0x69)  # 'i'
    write_u8(exec_path_addr + 2, 0x6E)  # 'n'
    write_u8(exec_path_addr + 3, 0x69)  # 'i'
    write_u8(exec_path_addr + 4, 0x74)  # 't'
    write_u8(exec_path_addr + 5, 0)  # NUL
    strp += 8

    # 2) Lay out pointer arrays aligned to 16 bytes:
    # argc (8 bytes) + argv (8*argc) + NULL (8) + envp (NULL, 8) + apple (exec_path, NULL, 16)
    # Total pointers count = 1 + argc + 1 + 1 + 2 = argc + 5 words = (argc + 5)*8 bytes
    var total_words = 1 + argc + 1 + 1 + 2
    var total_bytes = total_words * 8
    var s = (top - 0x300 - total_bytes) & ~15

    var p = s
    # [sp] = argc
    write_u64(p, UInt64(argc))
    p += 8

    # argv pointers
    for i in range(argc):
        write_u64(p, UInt64(uaddrs[i]))
        p += 8
    write_u64(p, 0)  # argv NULL terminator
    p += 8

    # envp pointers (empty for now)
    write_u64(p, 0)  # envp NULL terminator
    p += 8

    # apple array: apple[0] = exec_path, followed by NULL
    write_u64(p, UInt64(exec_path_addr))
    p += 8
    write_u64(p, 0)  # apple NULL terminator
    p += 8

    return s


def run_user(entry: Int, sp: Int):
    """Drop to EL0 at `entry` with the EL0 stack pointer at `sp`.

    Pages the image needs must already be mapped with EL0 access (see
    mm/paging.mojo / proc/elf.mojo); boot.S:run_user just erets.
    """
    external_call["run_user", NoneType](entry, sp)
