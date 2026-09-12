# Dynamic libSystem implementation written in Mojo for Mojo OS / Darwin userspace.
# Uses centralized syscall helper functions with Darwin ARM64 ABI instead of
# duplicate inline assembly in each exported API wrapper.
from std.sys import inlined_assembly
from std.sys.defines import get_defined_string
from std.sys.info import CompilationTarget
from sys.syscall_nr import (
    BSD_SYS_CLOSE,
    BSD_SYS_EXIT,
    BSD_SYS_GETPID,
    BSD_SYS_MMAP,
    BSD_SYS_MUNMAP,
    BSD_SYS_OPEN,
    BSD_SYS_READ,
    BSD_SYS_WRITE,
)

comptime ARCH = get_defined_string[
    "ARCH", StringLiteral[CompilationTarget[].__triple_arch()]()
]()


# ------------------------------------------------------------------------
# Centralized Darwin Syscall Dispatchers
# ------------------------------------------------------------------------
# Darwin ARM64 Calling Convention:
#   x16 = syscall or trap number
#   x0..x5 = arguments
#   trap via 'svc #0x80'
#   Returns x0 result
# ------------------------------------------------------------------------


@always_inline
def darwin_syscall6(
    nr: UInt64,
    a0: UInt64,
    a1: UInt64,
    a2: UInt64,
    a3: UInt64,
    a4: UInt64,
    a5: UInt64,
) -> UInt64:
    comptime if ARCH == "x86_64":
        # XNU x86_64 uses class 2 in the high syscall-number byte and the
        # SysV argument registers, with argument four moved to r10.
        return inlined_assembly[
            "syscall\n",
            UInt64,
            constraints="={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory},~{cc}",
            has_side_effect=True,
        ](nr | 0x02000000, a0, a1, a2, a3, a4, a5)
    else:
        return inlined_assembly[
            "svc #0x80\n",
            UInt64,
            constraints="={x0},{x16},{x0},{x1},{x2},{x3},{x4},{x5}",
            has_side_effect=True,
        ](nr, a0, a1, a2, a3, a4, a5)


@always_inline
def darwin_syscall0(nr: UInt64) -> UInt64:
    return darwin_syscall6(nr, 0, 0, 0, 0, 0, 0)


@always_inline
def darwin_syscall1(nr: UInt64, a0: UInt64) -> UInt64:
    return darwin_syscall6(nr, a0, 0, 0, 0, 0, 0)


@always_inline
def darwin_syscall2(nr: UInt64, a0: UInt64, a1: UInt64) -> UInt64:
    return darwin_syscall6(nr, a0, a1, 0, 0, 0, 0)


@always_inline
def darwin_syscall3(nr: UInt64, a0: UInt64, a1: UInt64, a2: UInt64) -> UInt64:
    return darwin_syscall6(nr, a0, a1, a2, 0, 0, 0)


# ------------------------------------------------------------------------
# Generic syscall() function
# ------------------------------------------------------------------------
@export
def syscall(
    nr: UInt64,
    a0: UInt64 = 0,
    a1: UInt64 = 0,
    a2: UInt64 = 0,
    a3: UInt64 = 0,
    a4: UInt64 = 0,
    a5: UInt64 = 0,
) -> UInt64:
    """Invoke arbitrary Darwin system call with up to 6 arguments."""
    return darwin_syscall6(nr, a0, a1, a2, a3, a4, a5)


# ------------------------------------------------------------------------
# Exported Darwin libSystem APIs
# ------------------------------------------------------------------------
@export
def exit(status: Int32):
    _ = darwin_syscall1(BSD_SYS_EXIT, UInt64(status))


@export
def read(fd: Int32, buf: Int, len: UInt64) -> UInt64:
    return darwin_syscall3(BSD_SYS_READ, UInt64(fd), UInt64(buf), UInt64(len))


@export
def write(fd: Int32, buf: Int, len: UInt64) -> UInt64:
    return darwin_syscall3(BSD_SYS_WRITE, UInt64(fd), UInt64(buf), UInt64(len))


@export
def open(path: Int, flags: Int32, mode: Int32) -> Int32:
    var res = darwin_syscall3(
        BSD_SYS_OPEN, UInt64(path), UInt64(flags), UInt64(mode)
    )
    return Int32(res)


@export
def close(fd: Int32) -> Int32:
    var res = darwin_syscall1(BSD_SYS_CLOSE, UInt64(fd))
    return Int32(res)


@export
def getpid() -> Int32:
    var res = darwin_syscall0(BSD_SYS_GETPID)
    return Int32(res)


@export
def munmap(addr: Int, len: UInt64) -> Int32:
    var res = darwin_syscall2(BSD_SYS_MUNMAP, UInt64(addr), UInt64(len))
    return Int32(res)


@export
def mmap(
    addr: Int, len: UInt64, prot: Int32, flags: Int32, fd: Int32, offset: UInt64
) -> Int:
    var res = darwin_syscall6(
        BSD_SYS_MMAP,
        UInt64(addr),
        UInt64(len),
        UInt64(prot),
        UInt64(flags),
        UInt64(fd),
        offset,
    )
    return Int(res)
