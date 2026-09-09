# Mojo OS kernel entry point.
#
# This module owns kmain (boot orchestration) plus the two runtime glue
# exports the compiler/stdlib expect a freestanding program to provide:
#   * memcpy                    - the LLVM backend can lower some copies to a
#                                 libcall rather than inline them
#   * __mojo_baremetal_debug_write - debug_assert failure sink (see the
#                                 BareMetalPlugin in the patched stdlib)
# These exports must live in the top-level module passed to `mojo build`,
# because an @export in an imported-but-unreferenced module is not emitted.
from std.memory.pointer import Pointer
from std.ffi import external_call
from std.origin import MutUntrackedOrigin, UntrackedOrigin
from std.sys.defines import MOJO_VERSION
from std.sys.info import CompilationTarget

from console import print_int, print_str, print_uint, println, putc
from dtb import BootParams, MemRegions, parse_dtb
from elf import load_elf
from mem import read_u8
from phys import PhysAlloc
from ramfs import unpack_cpio


@export("memcpy")
def _memcpy(dest: Int, src: Int, n: Int) abi("C") -> Int:
    var d = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=dest
    )
    var s = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=src
    )
    for i in range(n):
        d[unsafe_offset=i] = s[unsafe_offset=i]
    return dest


@export("__mojo_baremetal_debug_write")
def _mojo_baremetal_debug_write(message_addr: Int, length: Int) abi("C"):
    var ptr = Pointer[mut=False, T=UInt8, origin=UntrackedOrigin[mut=False]](
        unsafe_from_address=message_addr
    )
    var msg_len = length
    if msg_len > 0 and ptr[unsafe_offset=msg_len - 1] == 0:
        msg_len -= 1
    print_str("[ASSERT] ")
    for i in range(msg_len):
        putc(ptr[unsafe_offset=i])
    putc(0x0A)


comptime USER_REGION_BASE: Int = 0x41000000
comptime USER_REGION_SIZE: Int = 0x400000


def _report_memory(mem: MemRegions):
    """Print the RAM regions read from the DTB /memory node."""
    print_str("[mem] ")
    print_uint(UInt64(mem.n()), 10)
    print_str(" region(s):\n")
    for i in range(mem.n()):
        print_str("      [0x")
        print_uint(mem.base(i), 16)
        print_str(", 0x")
        print_uint(mem.end(i), 16)
        print_str(")  size=0x")
        print_uint(mem.size(i), 16)
        putc(0x0A)


def _setup_allocator(
    mut alloc: PhysAlloc,
    mem: MemRegions,
    bp: BootParams,
    klo: UInt64,
    khi: UInt64,
) -> Bool:
    """Configure `alloc` over the first DTB RAM region, reserving all the
    ranges the kernel already occupies so it won't hand them out."""
    if mem.n() < 1:
        return False
    # the running kernel image (text..stack), from boot.S
    alloc.reserve(klo, khi)
    # the EL0-accessible user carve-out in the page tables (see boot.S)
    alloc.reserve(
        UInt64(USER_REGION_BASE), UInt64(USER_REGION_BASE + USER_REGION_SIZE)
    )
    # the cpio initrd and the DTB image itself
    if bp.has_initrd:
        alloc.reserve(bp.initrd_start, bp.initrd_end)
    if bp.dtb_end > bp.dtb_start:
        alloc.reserve(bp.dtb_start, bp.dtb_end)
    alloc.init(mem.base(0), mem.end(0))
    return True


@export("ksyscall")
def ksyscall(
    n: UInt64,
    a0: UInt64,
    a1: UInt64,
    a2: UInt64,
    a3: UInt64,
    a4: UInt64,
    a5: UInt64,
) abi("C") -> UInt64:
    """Linux syscall dispatcher (arm64 numbers). Called from the EL0 trap.

    x8 holds the number; args are in x0..x5. For now a minimal subset that
    our tiny static userspace needs.
    """
    _ = a3
    _ = a4
    _ = a5
    # __NR_write = 64: write(fd, buf, count). We ignore fd and write to UART.
    if n == 64:
        var buf = Int(a1)
        var cnt = Int(a2)
        for i in range(cnt):
            putc(read_u8(buf + i))
        return UInt64(cnt)
    # __NR_exit = 93 / __NR_exit_group = 94: never return.
    if n == 93 or n == 94:
        while True:
            _ = 0
    # Unsupported: return -ENOSYS (-38).
    return 0xFFFFFFFFFFFFFFDA


def _run_user(entry: Int):
    """Drop to EL0 at `entry` with a fresh stack (see boot.S:run_user)."""
    external_call["run_user", NoneType](entry)


@export("kmain")
def kmain(x0: Int, x1: Int, x2: Int, x3: Int) abi("C"):
    var arch = StringLiteral[CompilationTarget[].__triple_arch()]()
    println(
        t"Hello from bare-metal {arch}, built with Mojo"
        t" {MOJO_VERSION.major}.{MOJO_VERSION.minor}.{MOJO_VERSION.patch},"
        t" running on QEMU!\n"
    )

    # x0 = DTB physical address (Linux boot protocol); x1/x2 = kernel image
    # static extent [start, end) as loaded by boot.S from linker symbols.
    var kernel_lo = UInt64(x1)
    var kernel_hi = UInt64(x2)
    var mem = MemRegions()
    var bp = parse_dtb(x0, mem)
    if not bp.has_dtb:
        print_str("[dtb] none passed in x0\n")
    else:
        print_str("[dtb] @0x")
        print_uint(UInt64(x0), 16)
        if bp.has_initrd:
            print_str("  initrd [0x")
            print_uint(bp.initrd_start, 16)
            print_str(", 0x")
            print_uint(bp.initrd_end, 16)
            print_str(")")
        else:
            print_str("  no initrd in /chosen")
        putc(0x0A)
        if bp.cmdline_len > 0:
            print_str('[cmdline] "')
            var n = bp.cmdline_len
            if read_u8(bp.cmdline_addr + n - 1) == 0:
                n -= 1
            for i in range(n):
                putc(read_u8(bp.cmdline_addr + i))
            print_str('"\n')
        else:
            print_str("[cmdline] (none)\n")

    # Report the RAM we learned about from the DTB, then build a physical
    # allocator over it (reserving everything the kernel already owns) and
    # exercise alloc/free. This is the memory backend brk/mmap will draw
    # pages from as we move toward running busybox.
    _report_memory(mem)
    var alloc = PhysAlloc()
    if _setup_allocator(alloc, mem, bp, kernel_lo, kernel_hi):
        print_str("[alloc] total free: 0x")
        print_uint(alloc.free_total(), 16)
        putc(0x0A)
        var pa = alloc.alloc(64)
        var pb = alloc.alloc(0x1000)
        print_str("[alloc] alloc(64)=0x")
        print_uint(pa, 16)
        print_str("  alloc(4096)=0x")
        print_uint(pb, 16)
        putc(0x0A)
        alloc.free(pa)
        alloc.free(pb)
        print_str("[alloc] after free:  0x")
        print_uint(alloc.free_total(), 16)
        putc(0x0A)
    else:
        print_str("[alloc] no RAM region from /memory\n")

    # If QEMU loaded a cpio initrd for us, unpack it into a ramfs and
    # demonstrate that we can list and look up files in it (the first step
    # toward exec'ing /init).
    if bp.has_initrd:
        var fs = unpack_cpio(Int(bp.initrd_start), Int(bp.initrd_end))
        print_str("[ramfs] unpacked ")
        print_uint(UInt64(fs.total()), 10)
        print_str(" file(s)\n")
        fs.list()
        var idx = fs.lookup("/init")
        if idx >= 0:
            print_str('[ramfs] lookup "/init" -> entry ')
            print_int(idx)
            print_str(" (size=")
            print_uint(UInt64(fs.entry_size(idx)), 10)
            print_str(", mode=")
            print_uint(UInt64(fs.entry_mode(idx)), 8)
            print_str(")\n")

            var entry = load_elf(fs.data_addr(idx))
            if entry != 0:
                print_str("[elf] entry=0x")
                print_uint(UInt64(entry), 16)
                print_str("\n[user] dropping to EL0...\n")
                _run_user(entry)
            else:
                print_str("[elf] failed to load /init\n")
        else:
            print_str("[ramfs] /init not found\n")

    while True:
        _ = 0
