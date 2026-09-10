# Mojo OS

An experimental OS written with Mojo, because why not.

It boots on QEMU's `virt` machine (aarch64), sets up an MMU, exceptions, and
a console, unpacks a cpio initrd into a tiny ramfs, ELF-loads `/init`, and
runs it in **user mode (EL0)**, servicing its Linux syscalls back through
the kernel.

## Prerequisites

- A **patched build of Mojo** (see [mojo.patch](./mojo.patch)) that
  auto-selects the "baremetal" stdlib plugin for `-none-` target triples so
  `debug_assert`/`abort` work without libc. See the comment in `Makefile`.
- The Mojo **CompilerRT** shared library (`work/modular/bazel-bin/Mojo/...`),
  needed only to build the native `mkcpio` tool (see `Makefile`).
- `clang`/`ld.lld` (kernel + freestanding userspace), `llvm-objcopy`, QEMU,
  GNU Make.

## Running

```sh
# Full Linux-style boot: raw image + DTB + cpio initrd, runs /init at EL0.
# Default build is the 4KB granule (runs on cortex-a57).
make run-linux

# 16KB-granule build (needs a CPU with the 16KB granule; Makefile picks
# cortex-a76 automatically).
make PAGE_SHIFT=14 run-linux

# Boot the kernel by itself (ELF path, no initrd/userspace).
make run
```

PAGE_SHIFT selects the translation granule (12 = 4KB default, 14 = 16KB)
and is passed to both boot.S (TCR TG0 + table geometry) and Mojo
(phys.mojo/paging.mojo). See docs/16k-pages.md.

## Filesystem & busybox

The kernel mounts the cpio initrd as a small read-only VFS (src/fs/vfs.mojo) and
serves it to userspace through real file syscalls: `openat`, `close`, `read`,
`write`/`writev` (stdout → UART), `lseek`, `fstat`, `newfstatat`, `getcwd`,
`getdents64`, plus identity syscalls (uid/gid 0). A static musl busybox as
`/init` can then walk the filesystem. argv[1..] for the applet comes from the
DTB cmdline (anything that isn't a boot parameter), defaulting to
`busybox echo`:

```sh
# run real busybox over the VFS
make run-linux                 # default: busybox echo ...
qemu-system-aarch64 -M virt -cpu cortex-a57 -nographic \
  -kernel build/kernel.bin -initrd build/bb.cpio \
  -append 'console=ttyAMA0 rdinit=/init ls /'        # list /
  # ... 'cat /hello.txt' prints a file
```

The VFS is exercised directly by src/user/vfstest.c (open/read/lseek/stat/
getdents on an initrd with extra files). The filesystem is intentionally flat
(root dir only) for now -- subdirectories, writes, and a real mount layer are
future work.

## Source layout

Mojo sources live under `src/` as nested packages (`-I src` is the search
root, so imports are e.g. `from mm.paging import map_user`). `__init__.mojo`
is not required by this toolchain; directories are importable as-is.

| path | purpose |
|------|---------|
| `src/kernel.mojo` | top-level build module: runtime `@export`s (`memcpy`/`memset`/`debug_write`) + thin `kmain`/`ksyscall` wrappers delegating to `boot`/`sys` |
| `src/boot.S` | EL1 boot, MMU/page tables, EL0→EL1 syscall trap, `launch_el0` |
| `src/linker.ld` | kernel layout (linked at 0x40080000, matches QEMU's raw + ELF load) |
| `src/boot/kmain.mojo` | boot orchestration: DTB, allocator, user VM, VFS mount, ELF load, drop to EL0 |
| `src/arch/mem.mojo` | raw memory accessors (MMIO, reads, byteswaps, string literals) |
| `src/arch/console.mojo` | PL011 UART + libc-free formatting |
| `src/arch/dtb.mojo` | device-tree parser: `/chosen` (initrd + cmdline) and `/memory` (RAM ranges) |
| `src/mm/phys.mojo` | physical memory allocator seeded from the DTB `/memory` RAM ranges |
| `src/mm/paging.mojo` | real user VA space (low 128MB, VA≠PA): PAGE_SHIFT selects the 4KB/16KB granule; lazily-created leaf tables, per-page EL0 perms, frames from the allocator |
| `src/core/kstate.mojo` | kernel state shared between boot and the syscall layer (free-list head, RAM bounds, L1, brk/mmap cursors, VFS base, syscall trace) |
| `src/fs/cpio.mojo` | cpio 'newc' format constants + hex codec (shared w/ writer) |
| `src/fs/ramfs.mojo` | unpack cpio initrd into a ramfs (lookup / read) |
| `src/fs/vfs.mojo` | minimal VFS over the initrd (flat read-only rootfs) + the fd table and file syscall primitives |
| `src/proc/elf.mojo` | minimal ELF64/aarch64 loader (static ET_EXEC) |
| `src/proc/cmdline.mojo` | parse the DTB cmdline into the initial process argv (skipping boot params) |
| `src/proc/userproc.mojo` | lay out the initial Linux stack (argc/argv/envp/auxv) and drop to EL0 |
| `src/sys/syscall_nr.mojo` | aarch64 Linux syscall numbers + errno values |
| `src/sys/syscalls.mojo` | brk/mmap/getrandom/clock_gettime/uname handlers |
| `src/sys/dispatch.mojo` | the syscall switch (`ksyscall` body), served by the VFS + `sys/syscalls` |
| `src/user/` | freestanding userspace source + link script (linked at 0x400000, the standard low VA busybox/musl uses) |
| `tools/mkcpio.mojo` | native Mojo tool that builds the cpio initrd |
| `mojo.patch` | compiler/stdlib patches the patched Mojo build requires |
| `docs/16k-pages.md` | analysis of the 16KB-granule MMU (implemented & selectable via PAGE_SHIFT) |
