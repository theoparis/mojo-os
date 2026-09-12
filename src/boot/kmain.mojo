# Boot orchestration: parse the DTB, seed the allocator, initialize the user
# VA space, mount the initrd as a VFS, ELF-load /init, build its stack and
# drop to EL0.
#
# `boot` is the real body; src/kernel.mojo holds the @export("kmain") wrapper
# that boot.S jumps to (exports must live in the top-level build module).
from std.sys.defines import MOJO_VERSION
from std.sys.info import CompilationTarget

from arch.console import ARCH, print_int, print_str, print_uint, println, putc
from arch.dtb import BootParams, MemRegions, parse_dtb
from arch.xnu_parser import is_xnu_boot_args, parse_xnu_boot_args
from arch.mem import read_u16, read_u8
from core.kstate import (
    OFF_FREE_HEAD,
    OFF_L1,
    OFF_RAM_BASE,
    OFF_RAM_END,
    OFF_USER_BASE,
    OFF_USER_HI,
    set64,
    set_brk,
    set_mmap_next,
    set_vfs,
)
from fs.ramfs import unpack_cpio
from fs.vfs import add_file as vfs_add, mount as vfs_mount
from mm.paging import (
    USER_STACK_SIZE,
    USER_VA_TOP,
    init_user_vm,
    map_user,
)
from mm.phys import PhysAlloc
from proc.cmdline import collect_argv
from proc.elf import elf_image_end, elf_is_valid, elf_phdrs, load_elf
from proc.macho import (
    load_macho,
    load_macho_dylib,
    macho_bind_fixups,
    macho_cputype,
    macho_image_end,
    macho_is_valid,
)
from proc.userproc import build_user_stack, run_user


def report_memory(mem: MemRegions):
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


def setup_allocator(
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
    alloc.reserve(klo, khi)
    # Only the kernel image, initrd and DTB are carved out up front. User
    # pages no longer live in a reserved identity window -- map_user hands
    # out ordinary physical frames from this same allocator on demand.
    if bp.has_initrd:
        alloc.reserve(bp.initrd_start, bp.initrd_end)
    if bp.dtb_end > bp.dtb_start:
        alloc.reserve(bp.dtb_start, bp.dtb_end)
    alloc.init(mem.base(0), mem.end(0))
    return True


def boot(x0: Int, x1: Int, x2: Int, x3: Int):
    var arch = StringLiteral[CompilationTarget[].__triple_arch()]()
    println(
        t"Hello from bare-metal {arch}, built with Mojo"
        t" {MOJO_VERSION.major}.{MOJO_VERSION.minor}.{MOJO_VERSION.patch},"
        t" running on QEMU!\n"
    )

    # x0 = DTB physical address (Linux boot protocol); x1/x2 = kernel image
    # static extent [start, end); x3 = level-1 page-table address, as set up
    # by boot.S from linker symbols.
    var kernel_lo = UInt64(x1)
    var kernel_hi = UInt64(x2)
    var l1base = x3
    var mem = MemRegions()
    var bp = BootParams()
    var is_xnu = False
    if is_xnu_boot_args(x0):
        is_xnu = True
        print_str("[boot] detected XNU boot_args @ 0x")
        print_uint(UInt64(x0), 16)
        print_str("\n")
        _ = parse_xnu_boot_args(x0, mem, bp)
    else:
        bp = parse_dtb(x0, mem)

    if not bp.has_dtb:
        print_str("[dtb] none passed in x0\n")
        if mem.n() == 0:
            # Fallback for systems without a DTB.
            comptime if ARCH == "x86_64":
                mem.add(0x100000, 127 * 1024 * 1024)
            else:
                mem.add(0x40000000, 128 * 1024 * 1024)
    else:
        if is_xnu:
            print_str("[xnu-afdt] @0x")
        else:
            print_str("[dtb] @0x")
        print_uint(UInt64(bp.dtb_start if is_xnu else UInt64(x0)), 16)
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

    report_memory(mem)
    var alloc = PhysAlloc()
    if setup_allocator(alloc, mem, bp, kernel_lo, kernel_hi):
        print_str("[alloc] total free: 0x")
        print_uint(alloc.free_total(), 16)
        putc(0x0A)
        # Prepare the low user VA space before any user mapping. On 16KB
        # this is a no-op; on 4KB it splits L1[0] into a level-2 table.
        if not init_user_vm(alloc, l1base):
            print_str("[paging] init_user_vm failed\n")
    else:
        print_str("[alloc] no RAM region from /memory\n")

    if bp.has_initrd:
        var fs = unpack_cpio(Int(bp.initrd_start), Int(bp.initrd_end))
        print_str("[ramfs] unpacked ")
        print_uint(UInt64(fs.total()), 10)
        print_str(" file(s)\n")
        fs.list()

        # Mount the initrd as the persistent VFS for the file syscalls. The
        # region is allocated (never freed) and its address saved to kernel
        # state before we snapshot the allocator free-list head below.
        var vbase = alloc.alloc_pages(1)
        if vbase != 0:
            vfs_mount(Int(vbase))
            var mounted = 0
            for i in range(fs.total()):
                if vfs_add(
                    Int(vbase),
                    fs.name_addr(i),
                    fs.data_addr(i),
                    fs.entry_size(i),
                    UInt64(fs.entry_mode(i)),
                ):
                    mounted += 1
            set_vfs(Int(vbase))
            print_str("[vfs] mounted ")
            print_uint(UInt64(mounted), 10)
            print_str(" file(s) @0x")
            print_uint(vbase, 16)
            putc(0x0A)
        else:
            print_str("[vfs] alloc failed, files disabled\n")

        # A stable kernel scratch buffer for building the user argv list
        # (from the DTB cmdline). Allocated before the allocator snapshot so
        # syscall-time free-list re-attach doesn't reuse it.
        var argscr = alloc.alloc_pages(1)
        if argscr == 0:
            print_str("[argv] scratch alloc failed\n")

        var idx = fs.lookup("/init")
        if idx >= 0:
            print_str('[ramfs] lookup "/init" -> entry ')
            print_int(idx)
            print_str(" (size=")
            print_uint(UInt64(fs.entry_size(idx)), 10)
            print_str(")\n")

            var fdata = fs.data_addr(idx)
            var entry: Int = 0
            var imgend: Int = 0
            var phdr: Int = 0
            var phnum: Int = 0

            if macho_is_valid(fdata):
                var cpu = macho_cputype(fdata)
                comptime if ARCH == "x86_64":
                    if cpu != 0x01000007:
                        print_str(
                            "[loader] /init is not an x86_64 Mach-O image\n"
                        )
                    else:
                        print_str("[loader] detected Mach-O binary for /init\n")
                        imgend = macho_image_end(fdata)
                        entry = load_macho(alloc, l1base, fdata)
                else:
                    print_str("[loader] detected Mach-O binary for /init\n")
                    imgend = macho_image_end(fdata)
                    entry = load_macho(alloc, l1base, fdata)

                # Look for dynamic library in ramfs: /usr/lib/libSystem.B.dylib
                var sys_idx = fs.lookup("/usr/lib/libSystem.B.dylib")
                if entry != 0 and sys_idx >= 0:
                    var sys_data = fs.data_addr(sys_idx)
                    var sys_slide: Int = 0x200000  # Map libSystem at 2MB VA
                    if load_macho_dylib(alloc, l1base, sys_data, sys_slide):
                        print_str("[loader] mapped libSystem @ 0x")
                        print_uint(UInt64(sys_slide), 16)
                        print_str("\n")
                        macho_bind_fixups(fdata, sys_data, UInt64(sys_slide))
                        print_str(
                            "[loader] chained fixups bound successfully\n"
                        )
            elif elf_is_valid(fdata):
                print_str("[loader] detected ELF binary for /init\n")
                imgend = elf_image_end(fdata)
                phdr = elf_phdrs(fdata)
                phnum = Int(read_u16(fdata + 56))
                entry = load_elf(alloc, l1base, fdata)
            else:
                print_str("[loader] unknown executable format\n")

            if entry != 0 and mem.n() >= 1:
                # EL0 stack at the top of the user VA space, growing down.
                var stack_top = USER_VA_TOP
                var stack_base = stack_top - USER_STACK_SIZE
                if map_user(alloc, l1base, stack_base, USER_STACK_SIZE, False):
                    print_str("[user] stack [0x")
                    print_uint(UInt64(stack_base), 16)
                    print_str(", 0x")
                    print_uint(UInt64(stack_top), 16)
                    print_str(")\n")
                else:
                    print_str("[user] stack mapping failed\n")

                # Snapshot kernel state for the syscall layer once all the
                # static mappings (image + stack) are in place: allocator
                # free-list head, RAM bounds, L1 table, user VA space,
                # brk/mmap cursors.
                var heap_base = (imgend + 0xFFFF) & ~0xFFFF
                set64(OFF_FREE_HEAD, alloc.free_head)
                set64(OFF_RAM_BASE, mem.base(0))
                set64(OFF_RAM_END, mem.end(0))
                set64(OFF_L1, UInt64(l1base))
                set64(OFF_USER_BASE, 0)
                set64(OFF_USER_HI, UInt64(USER_VA_TOP))
                set_brk(heap_base)
                # Anonymous mmaps descend top-down from just below the stack,
                # so they can never collide with brk's upward growth.
                set_mmap_next(stack_base)

                print_str("[user] brk base=0x")
                print_uint(UInt64(heap_base), 16)
                print_str(" phdr=0x")
                print_uint(UInt64(phdr), 16)
                print_str("\n")
                var argc = collect_argv(
                    Int(argscr), bp.cmdline_addr, bp.cmdline_len
                )
                var sp = build_user_stack(
                    stack_top, entry, phdr, phnum, argc, Int(argscr) + 8
                )
                print_str("[user] entry=0x")
                print_uint(UInt64(entry), 16)
                print_str("\n[user] dropping to EL0...\n")
                run_user(entry, sp)
            else:
                print_str("[loader] failed to load /init\n")
        else:
            print_str("[ramfs] /init not found\n")
    else:
        print_str("[boot] system initialized successfully\n")

    while True:
        _ = 0
