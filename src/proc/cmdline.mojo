# Parse the DTB `/chosen` cmdline into an argv list for the initial process.
#
# Boot parameters (console=, rdinit=, ...) are consumed by the kernel; the
# remaining tokens become the applet arguments for /init. The list is built
# in a kernel scratch region as u64 addresses of NUL-terminated strings.
from arch.mem import copy_lit, read_u8, write_u8, write_u64

comptime MAX_ARGV = 16


def nul_len(addr: Int) -> Int:
    """Bytes of a NUL-terminated string at `addr`, including the NUL."""
    var i: Int = 0
    while read_u8(addr + i) != 0:
        i += 1
    return i + 1


def cmp_word(w: Int, wlen: Int, lit: StringLiteral, want_exact: Bool) -> Bool:
    """Compare a cmdline word to a literal (prefix or exact match)."""
    var p = lit.ptr()
    var i: Int = 0
    while p[unsafe_offset=i] != 0:
        if i >= wlen:
            return False
        if read_u8(w + i) != p[unsafe_offset=i]:
            return False
        i += 1
    if want_exact:
        return i == wlen
    return True  # word starts with the literal


def is_boot_word(w: Int, wlen: Int) -> Bool:
    """True if `w` is a kernel boot parameter (consumed, not passed on)."""
    if cmp_word(w, wlen, "quiet", True) or cmp_word(w, wlen, "rw", True):
        return True
    if cmp_word(w, wlen, "ro", True) or cmp_word(w, wlen, "nosmp", True):
        return True
    if cmp_word(w, wlen, "console=", False):
        return True
    if cmp_word(w, wlen, "rdinit=", False):
        return True
    if cmp_word(w, wlen, "init=", False):
        return True
    if cmp_word(w, wlen, "root=", False):
        return True
    if cmp_word(w, wlen, "earlycon=", False):
        return True
    if cmp_word(w, wlen, "loglevel=", False):
        return True
    return False


def collect_argv(scr: Int, cmd: Int, cmdlen: Int) -> Int:
    """Build the argv list into the kernel scratch region `scr` and return
    argc. Region layout:
      scr+0          u64 argc
      scr+8          u64 argv[N] (kernel addrs of NUL strings)
      scr+8+8*MAX    string bytes
    argv[0] is always "busybox"; argv[1..] come from non-boot tokens on the
    DTB cmdline, or default to busybox "echo ..." when there are none."""
    var strp = scr + 8 + MAX_ARGV * 8
    # argv[0] = "busybox"
    copy_lit(strp, "busybox")
    write_u64(scr + 8, UInt64(strp))
    strp += nul_len(strp)
    var argc = 1

    if cmd != 0 and cmdlen > 0:
        var i: Int = 0
        while i < cmdlen:
            while i < cmdlen:
                var b = read_u8(cmd + i)
                if b != 0x20 and b != 0x09:  # not space / tab
                    break
                i += 1
            var ws = i
            while i < cmdlen:
                var b = read_u8(cmd + i)
                if b == 0x20 or b == 0x09:
                    break
                i += 1
            var wlen = i - ws
            if wlen > 0 and not is_boot_word(cmd + ws, wlen):
                if argc >= MAX_ARGV:
                    break
                for j in range(wlen):
                    write_u8(strp + j, read_u8(cmd + ws + j))
                write_u8(strp + wlen, 0)
                write_u64(scr + 8 + argc * 8, UInt64(strp))
                strp += wlen + 1
                argc += 1

    if argc == 1:  # no app args on the cmdline: default busybox echo
        copy_lit(strp, "echo")
        write_u64(scr + 8 + argc * 8, UInt64(strp))
        strp += nul_len(strp)
        argc += 1
        copy_lit(strp, "hello from busybox on mojo-os!")
        write_u64(scr + 8 + argc * 8, UInt64(strp))
        strp += nul_len(strp)
        argc += 1
    write_u64(scr, UInt64(argc))
    return argc
