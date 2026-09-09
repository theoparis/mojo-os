# Supporting 16KB pages (granule) on mojo-os

This documents what switching the kernel's MMU from the current **4KB page
granule** to a **16KB granule** would take. It is an analysis/design note,
not yet implemented. All page-size-dependent code in this tree is marked
with comments saying so; grepping for `4096`, `0x200000`, `512`, `>> 12`,
`<< 21` and `ALIGN(4096)` finds most of it.

## Translation granule background

AArch64 translation tables always hold 8-byte descriptors. The *granule*
only changes how many entries fit per table (hence the table index width
and the page offset):

| granule | table index | entries/table | table size | page offset |
|---------|-------------|---------------|------------|-------------|
| 4KB     | 9 bits      | 512           | 4KB        | 12 bits     |
| 16KB    | 11 bits     | 2048          | 16KB       | 14 bits     |
| 64KB    | 13 bits     | 8192          | 64KB       | 16 bits     |

(QEMU derives this as `index_bits = granule_bits - 3` in `target/arm/ptw.c`.)

Descriptor *format* (valid bit, type 0b01/0b11, AF, AP[2:1], UXN/PXN,
AttrIndx, etc.) is identical across granules — only the walk geometry and
the TCR granule field change.

Level count for a given VA size (`arch/arm64/Kconfig`, PGTABLE_LEVELS):
- 4KB granule: 39-bit VA = 3 levels, 48-bit = 4 levels.
- 16KB granule: **47-bit VA = 3 levels**, 48-bit = 4 levels. A smaller VA
  (e.g. our current 32-bit, T0SZ=32) uses 2 levels: a top table whose
  entries each cover one leaf table's region, then the leaf (page) table.
- 64KB granule: 42-bit = 2 levels, 48-bit = 3 levels.

Block (huge-page) sizes scale too: with 16KB pages a "block" at the level
above the leaf covers 2048 x 16KB = **32MB** (cf. 2MB blocks for 4KB
pages). Leaf-table *regions* are therefore 32MB, which is also why 16KB
paging uses less page-table memory per byte of RAM: fully leaf-mapping 1GB
needs 32 x 16KB = 512KB of tables vs 512 x 4KB = 2MB at 4KB granularity.

## Hardware support

The 16KB granule is *optional* in ARMv8.0 (4KB and 64KB are not). Check
`ID_AA64MMFR0_EL1.TGran16` (bits [23:20]): 0 = not implemented, 1 = 16KB
granule implemented, 2 = also supports 52-bit addresses.

Measured under QEMU (`mrs x0, id_aa64mmfr0_el1`):

| `-cpu`      | TGran4 | TGran64 | TGran16 |
|-------------|--------|---------|---------|
| cortex-a57  | IMP    | IMP     | **NI**  |
| cortex-a76  | IMP    | IMP     | IMP     |
| max         | 52-bit | IMP     | 52-bit  |

So a 16KB build cannot run with the current default `-cpu cortex-a57`;
QEMU must use `-cpu cortex-a76` (or `max`), and the kernel should verify
TGran16 at boot before programming TCR.

## Where the page size shows up in mojo-os today (4KB)

- **src/boot.S** — `TCR_VALUE = 0x803520`: TG0 (bits 15:14) = 0b00 = 4KB
  granule, T0SZ=32 (4GB VA). Two static tables:
  - `__page_table` (L1): 512 x 8B. For a 4GB VA space only entries 0-3 are
    used; entry 1 (0x40000000, the 1GB range containing RAM + peripherals)
    points at the L2 table.
  - `__page_table_l2`: 512 x 2MB **block** descriptors covering the whole
    1GB range EL1-only (zeroed + filled in 512-entry loops).
- **src/linker.ld** — the two tables live in reserved `.` + 4096 sections
  after BSS (`ALIGN(4096)`), before the kernel stack.
- **src/paging.mojo** — user pages: converts a 2MB L2 *block* slot into a
  lazily-allocated L3 table of 512 x 4KB pages (`_ensure_l3`), then flips
  individual PTEs to EL0 perms. Constants: PAGE_SIZE 4096, 512 pages/slot,
  slot = 0x200000.
- **src/phys.mojo** — `alloc_pages()` hard-codes 4KB alignment.
- **src/elf.mojo / src/user/user.ld** — segment addresses are page-mapped
  by rounding; the clang toolchain already aligns segments to 0x10000, so
  they satisfy any of 4K/16K/64K alignment.

## What a 16KB build must change

1. **CPU check**: read `ID_AA64MMFR0_EL1`; halt with a message unless
   TGran16 != 0. Run QEMU with `-cpu cortex-a76` or `-cpu max`.

2. **TCR_EL1**: set `TG0 = 0b10` (bits 15:14) for the 16KB granule on
   TTBR0. T0SZ stays 32 (same 4GB identity VA space). TCR/MAIR/SCTLR
   handling is otherwise unchanged.

3. **Static identity-map tables (boot.S + linker.ld)**:
   - The walk for T0SZ=32 now partitions VA[31:14] = 18 index bits over 2
     levels: a top table indexed by VA[31:25] (7 bits -> 128 of 2048
     entries used) whose entries are either 32MB blocks or pointers to
     leaf tables, then leaf tables indexed by VA[24:14] (2048 x 16KB
     pages).
   - So the single flat "L2 of 2MB blocks" table becomes a **top table**
     (2048 entries, 16KB, aligned 16KB) plus lazily-created **leaf
     tables** (2048 entries each, 16KB, covering 32MB).
   - Every `str xzr` zero-loop and descriptor-fill loop count changes from
     512 to 2048; table addresses must be 16KB-aligned (linker `. = ALIGN
     (0x4000)` and 16KB reservations instead of 4096).
   - A block descriptor now means 32MB, so "map RAM as big blocks, split
     only where user pages are needed" still works but with 32MB lumps
     (fine: everything not user-mapped stays EL1-only anyway).

4. **src/paging.mojo**: PAGE_SIZE/PAGE_MASK 4096 -> 0x4000; `_ensure_l3`
   fills 2048 identity pages of 16KB each (32MB per leaf); page index bits
   are VA[24:14]; slot constant 0x200000 -> 0x2000000. The AP/UXN perms and
   the overall map-then-copy flow are granule-independent.

5. **src/phys.mojo**: `alloc_pages()` alignment 4096 -> 0x4000, and frames
   it returns for user data/stack should become 16KB multiples too (Linux
   page sizes apply to everything below the kernel).

6. **ELF/user ABI**: a static busybox-style binary only needs its PT_LOAD
   addresses 16KB-aligned (user.ld uses 0x10000 alignment already). Note
   AArch32 emulation would require 16KB-aligned segments; we don't do
   AArch32.

7. **Perf/geometry notes**: fewer, larger pages mean fewer TLB entries for
   the same RAM and 4x less leaf-table memory at full granularity, at the
   cost of 16KB minimum allocations (a 100-byte program still takes one
   16KB page) and 16KB-aligned stack/heap breaks.

## Suggested implementation path

Make the granule a single configuration value instead of scattered
constants:
- A `PAGE_SHIFT`/`PAGE_SIZE` comptime in `paging.mojo` and a matching
  assembler `.equ` (or `-D`) driving boot.S table geometry + TCR TG0.
- `phys.mojo` derives frame alignment from PAGE_SIZE.
- Keep the VA space at 4GB (T0SZ=32) so only table geometry and TG0
  change; the DTB-derived RAM ranges, the physical allocator, the ELF
  loader, and the EL0 trap path are all page-size agnostic already.
- Add a `QEMU_CPU ?= cortex-a76` override for 16K testing and a boot-time
  TGran16 check that prints a clear error instead of silently faulting.
