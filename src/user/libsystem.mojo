# Dynamic libSystem implementation written in Mojo for Mojo OS / Darwin userspace.
# Uses centralized syscall helper functions with Darwin ARM64 ABI instead of
# duplicate inline assembly in each exported API wrapper.
from std.sys import inlined_assembly
from std.sys.defines import get_defined_string
from std.sys.info import CompilationTarget

comptime ARCH = get_defined_string[
    "ARCH", StringLiteral[CompilationTarget[].__triple_arch()]()
]()

# Darwin BSD Syscall Numbers
comptime SYS_EXIT: Int64 = 1
comptime SYS_READ: Int64 = 3
comptime SYS_WRITE: Int64 = 4
comptime SYS_OPEN: Int64 = 5
comptime SYS_CLOSE: Int64 = 6
comptime SYS_GETPID: Int64 = 20
comptime SYS_MUNMAP: Int64 = 73
comptime SYS_MMAP: Int64 = 197


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
    nr: Int64,
    a0: Int64,
    a1: Int64,
    a2: Int64,
    a3: Int64,
    a4: Int64,
    a5: Int64,
) -> Int64:
    comptime if ARCH == "x86_64":
        # XNU x86_64 uses class 2 in the high syscall-number byte and the
        # SysV argument registers, with argument four moved to r10.
        return inlined_assembly[
            "syscall\n",
            Int64,
            constraints="={rax},{rax},{rdi},{rsi},{rdx},{r10},{r8},{r9},~{rcx},~{r11},~{memory},~{cc}",
            has_side_effect=True,
        ](nr | 0x02000000, a0, a1, a2, a3, a4, a5)
    else:
        return inlined_assembly[
            "svc #0x80\n",
            Int64,
            constraints="={x0},{x16},{x0},{x1},{x2},{x3},{x4},{x5}",
            has_side_effect=True,
        ](nr, a0, a1, a2, a3, a4, a5)


@always_inline
def darwin_syscall0(nr: Int64) -> Int64:
    return darwin_syscall6(nr, 0, 0, 0, 0, 0, 0)


@always_inline
def darwin_syscall1(nr: Int64, a0: Int64) -> Int64:
    return darwin_syscall6(nr, a0, 0, 0, 0, 0, 0)


@always_inline
def darwin_syscall2(nr: Int64, a0: Int64, a1: Int64) -> Int64:
    return darwin_syscall6(nr, a0, a1, 0, 0, 0, 0)


@always_inline
def darwin_syscall3(nr: Int64, a0: Int64, a1: Int64, a2: Int64) -> Int64:
    return darwin_syscall6(nr, a0, a1, a2, 0, 0, 0)


# ------------------------------------------------------------------------
# Generic syscall() function
# ------------------------------------------------------------------------
@export
def syscall(
    nr: Int64,
    a0: Int64 = 0,
    a1: Int64 = 0,
    a2: Int64 = 0,
    a3: Int64 = 0,
    a4: Int64 = 0,
    a5: Int64 = 0,
) -> Int64:
    """Invoke arbitrary Darwin system call with up to 6 arguments."""
    return darwin_syscall6(nr, a0, a1, a2, a3, a4, a5)


# ------------------------------------------------------------------------
# Exported Darwin libSystem APIs
# ------------------------------------------------------------------------
@export
def exit(status: Int32):
    _ = darwin_syscall1(SYS_EXIT, Int64(status))


@export
def read(fd: Int32, buf: Int, len: UInt64) -> Int64:
    return darwin_syscall3(SYS_READ, Int64(fd), Int64(buf), Int64(len))


@export
def write(fd: Int32, buf: Int, len: UInt64) -> Int64:
    return darwin_syscall3(SYS_WRITE, Int64(fd), Int64(buf), Int64(len))


@export
def open(path: Int, flags: Int32, mode: Int32) -> Int32:
    var res = darwin_syscall3(SYS_OPEN, Int64(path), Int64(flags), Int64(mode))
    return Int32(res)


@export
def close(fd: Int32) -> Int32:
    var res = darwin_syscall1(SYS_CLOSE, Int64(fd))
    return Int32(res)


@export
def getpid() -> Int32:
    var res = darwin_syscall0(SYS_GETPID)
    return Int32(res)


@export
def munmap(addr: Int, len: UInt64) -> Int32:
    var res = darwin_syscall2(SYS_MUNMAP, Int64(addr), Int64(len))
    return Int32(res)


@export
def mmap(
    addr: Int, len: UInt64, prot: Int32, flags: Int32, fd: Int32, offset: Int64
) -> Int:
    var res = darwin_syscall6(
        SYS_MMAP,
        Int64(addr),
        Int64(len),
        Int64(prot),
        Int64(flags),
        Int64(fd),
        offset,
    )
    return Int(res)
