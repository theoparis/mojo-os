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

The kernel mounts the cpio initrd as a small read-only VFS (src/vfs.mojo) and
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

| path | purpose |
|------|---------|
| `src/boot.S` | EL1 boot, MMU/page tables, EL0→EL1 syscall trap, `launch_el0` |
| `src/linker.ld` | kernel layout (linked at 0x40080000, matches QEMU's raw + ELF load) |
| `src/mem.mojo` | raw memory accessors (MMIO, reads, byteswaps) |
| `src/console.mojo` | PL011 UART + libc-free formatting |
| `src/dtb.mojo` | device-tree parser: `/chosen` (initrd + cmdline) and `/memory` (RAM ranges) |
| `src/cpio.mojo` | cpio 'newc' format constants + hex codec (shared w/ writer) |
| `src/ramfs.mojo` | unpack cpio initrd into a ramfs (lookup / read) |
| `src/vfs.mojo` | minimal VFS over the initrd (flat read-only rootfs) + the fd table and file syscall primitives |
| `src/phys.mojo` | physical memory allocator seeded from the DTB `/memory` RAM ranges |
| `src/paging.mojo` | real user VA space (low 128MB, VA≠PA): PAGE_SHIFT selects the 4KB/16KB granule; lazily-created leaf tables, per-page EL0 perms, frames from the allocator |
| `src/elf.mojo` | minimal ELF64/aarch64 loader (static ET_EXEC) |
| `src/kernel.mojo` | `kmain` orchestration + `ksyscall` + runtime `@export`s |
| `src/user/` | freestanding userspace source + link script (linked at 0x400000, the standard low VA busybox/musl uses) |
| `tools/mkcpio.mojo` | native Mojo tool that builds the cpio initrd |
| `mojo.patch` | compiler/stdlib patches the patched Mojo build requires |
| `docs/16k-pages.md` | analysis of the 16KB-granule MMU (implemented & selectable via PAGE_SHIFT) |
