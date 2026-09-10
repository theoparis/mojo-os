# Mojo OS kernel entry point.
#
# This is the top-level module passed to `mojo build`, so it is the only
# place the @export's below are guaranteed to be emitted (an @export in an
# imported module is only kept if that module is referenced, and boot.S
# needs these symbols regardless). It deliberately contains only:
#   * the runtime glue a freestanding program must provide:
#       - memcpy   - the LLVM backend can lower some copies to a libcall
#       - memset
#       - __mojo_baremetal_debug_write - debug_assert failure sink (see the
#         BareMetalPlugin in the patched stdlib)
#   * the two EL1 entry points boot.S jumps to, which delegate to the real
#     implementations:
#       - kmain    -> boot/kmain.mojo:boot    (boot orchestration)
#       - ksyscall -> sys/dispatch.mojo:dispatch (Linux syscall dispatcher)
from std.memory.pointer import Pointer
from std.origin import MutUntrackedOrigin, UntrackedOrigin

from arch.console import print_str, putc
from boot.kmain import boot
from sys.dispatch import dispatch


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


@export("memset")
def _memset(dest: Int, val: Int, n: Int) abi("C") -> Int:
    var d = Pointer[mut=True, T=UInt8, origin=MutUntrackedOrigin](
        unsafe_from_address=dest
    )
    var v = UInt8(val)
    for i in range(n):
        d[unsafe_offset=i] = v
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
    """EL0 trap entry: delegate to the syscall dispatcher."""
    return dispatch(n, a0, a1, a2, a3, a4, a5)


@export("kmain")
def kmain(x0: Int, x1: Int, x2: Int, x3: Int) abi("C"):
    """EL1 entry from boot.S: run the boot sequence."""
    boot(x0, x1, x2, x3)
