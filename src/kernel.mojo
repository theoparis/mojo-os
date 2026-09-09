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
from std.origin import MutUntrackedOrigin, UntrackedOrigin
from std.sys.defines import MOJO_VERSION
from std.sys.info import CompilationTarget

from console import print_str, print_uint, println, putc
from dtb import BootParams, parse_dtb
from initrd import print_cpio_summary
from mem import read_u8


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


@export("kmain")
def kmain(x0: Int, x1: Int, x2: Int, x3: Int) abi("C"):
    var arch = StringLiteral[CompilationTarget[].__triple_arch()]()
    println(
        t"Hello from bare-metal {arch}, built with Mojo"
        t" {MOJO_VERSION.major}.{MOJO_VERSION.minor}.{MOJO_VERSION.patch},"
        t" running on QEMU!\n"
    )

    # x0 is the physical address of the DTB handed to us by QEMU (Linux
    # boot protocol). Everything else hangs off it.
    var bp = parse_dtb(x0)
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

    # If QEMU loaded a cpio initrd for us, unpack/list it. This is the first
    # step toward a real userspace: eventually /init is exec'd from here.
    if bp.has_initrd:
        print_cpio_summary(Int(bp.initrd_start), Int(bp.initrd_end))

    while True:
        _ = 0
