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
make run-linux

# Boot the kernel by itself (ELF path, no initrd/userspace).
make run
```

## Source layout

| path | purpose |
|------|---------|
| `src/boot.S` | EL1 boot, MMU/page tables, EL0→EL1 syscall trap, `launch_el0` |
| `src/linker.ld` | kernel layout (linked at 0x40080000, matches QEMU's raw + ELF load) |
| `src/mem.mojo` | raw memory accessors (MMIO, reads, byteswaps) |
| `src/console.mojo` | PL011 UART + libc-free formatting |
| `src/dtb.mojo` | device-tree `/chosen` parser (initrd range + cmdline) |
| `src/cpio.mojo` | cpio 'newc' format constants + hex codec (shared w/ writer) |
| `src/ramfs.mojo` | unpack cpio initrd into a ramfs (lookup / read) |
| `src/elf.mojo` | minimal ELF64/aarch64 loader (static ET_EXEC) |
| `src/kernel.mojo` | `kmain` orchestration + `ksyscall` + runtime `@export`s |
| `src/user/` | freestanding userspace source + link script |
| `tools/mkcpio.mojo` | native Mojo tool that builds the cpio initrd |
| `mojo.patch` | compiler/stdlib patches the patched Mojo build requires |
