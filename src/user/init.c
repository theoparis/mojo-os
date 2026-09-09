// /init probe: validates the kernel's Linux exec ABI (argc/argv/envp/auxv
// on the initial stack, AT_PAGESZ etc.) and exercises the brk/mmap
// syscalls that any real program needs. Pure inline-asm Linux syscalls,
// no libc.
//
// Compiled freestanding and linked at 0x400000 by src/user/user.ld (the same
// low VA a static musl/busybox uses); the kernel maps it into the real user
// VA space and erets to _start with the initial SP arranged like Linux:
// [sp] = argc, [sp+8..] = argv[], NULL, envp[], NULL, auxv[].
typedef unsigned long u64;
typedef unsigned char u8;
typedef long s64;

static u64 sys3(u64 nr, u64 a0, u64 a1, u64 a2) {
  register u64 x8 __asm__("x8") = nr;
  register u64 x0 __asm__("x0") = a0;
  register u64 x1 __asm__("x1") = a1;
  register u64 x2 __asm__("x2") = a2;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
  return x0;
}

static u64 sys6(u64 nr, u64 a0, u64 a1, u64 a2, u64 a3, u64 a4, u64 a5) {
  register u64 x8 __asm__("x8") = nr;
  register u64 x0 __asm__("x0") = a0;
  register u64 x1 __asm__("x1") = a1;
  register u64 x2 __asm__("x2") = a2;
  register u64 x3 __asm__("x3") = a3;
  register u64 x4 __asm__("x4") = a4;
  register u64 x5 __asm__("x5") = a5;
  __asm__ volatile("svc #0"
                   : "+r"(x0)
                   : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                   : "memory");
  return x0;
}

static u64 strlen_(const char *s) {
  u64 n = 0;
  while (s[n]) n++;
  return n;
}

static void puts_(const char *s) {
  sys3(64, 1, (u64)s, strlen_(s));  // __NR_write, fd 1
}

static void puthex(u64 v) {
  static const char hex[] = "0123456789abcdef";
  char buf[20];
  int i = 19;
  buf[i--] = 0;
  do {
    buf[i--] = hex[v & 0xF];
    v >>= 4;
  } while (v);
  puts_("0x");
  sys3(64, 1, (u64)(buf + i + 1), (u64)(18 - i));  // remainder of buf
}

static void putdec(u64 v) {
  char buf[24];
  int i = 23;
  buf[i--] = 0;
  do {
    buf[i--] = '0' + (v % 10);
    v /= 10;
  } while (v);
  sys3(64, 1, (u64)(buf + i + 1), (u64)(23 - i));
}

static u64 sys1_(u64 nr, u64 a0) { return sys3(nr, a0, 0, 0); }

void probe(u64 argc, u64 *argv) {
  puts_("mojo-os probe: argc=");
  putdec(argc);
  puts_("\n");
  u64 i;
  for (i = 0; i < argc; i++) {
    puts_("  argv[");
    putdec(i);
    puts_("]=\"");
    puts_((const char *)argv[i]);
    puts_("\"\n");
  }
  // argv is followed by NULL, envp (NULL-terminated), then auxv pairs.
  u64 *p = argv + argc;
  while (*p) p++;        // argv terminator
  p++;                   // envp[] -- empty for now, so next is its NULL
  while (*p) p++;        // envp terminator
  p++;                   // start of auxv
  int have_pagesz = 0;
  for (;;) {
    u64 type = p[0], val = p[1];
    if (type == 0) break;
    if (type == 6) {  // AT_PAGESZ
      have_pagesz = 1;
      puts_("  auxv AT_PAGESZ=");
      putdec(val);
      puts_(" (0x");
      puthex(val);
      puts_(")\n");
    } else if (type == 3) {  // AT_PHDR
      puts_("  auxv AT_PHDR=0x");
      puthex(val);
      puts_("\n");
    } else if (type == 25) {  // AT_RANDOM
      puts_("  auxv AT_RANDOM=0x");
      puthex(val);
      puts_("\n");
    }
    p += 2;
  }
  if (!have_pagesz) puts_("  !! no AT_PAGESZ in auxv\n");

  // brk(0) query, then brk growth
  u64 b0 = sys1_(214, 0);
  puts_("brk(0)=0x");
  puthex(b0);
  puts_("\n");
  u64 b1 = sys1_(214, b0 + 0x8000);
  puts_("brk(+0x8000)=0x");
  puthex(b1);
  puts_("\n");

  // anonymous mmap
  u64 m = sys6(222, 0, 4096, 3 /*RW*/, 0x22 /*PRIVATE|ANON*/, ~0UL, 0);
  puts_("mmap(4096, anon)=");
  if ((s64)m < 0) {
    puts_("FAILED (0x");
    puthex(m);
    puts_(")\n");
  } else {
    puts_("0x");
    puthex(m);
    puts_("\n");
    // touch it
    *((volatile u8 *)m) = 0xAB;
    *((volatile u8 *)(m + 4095)) = 0xCD;
    puts_("mmap page read/write ok\n");
  }
  sys3(93, 0, 0, 0);  // exit(0)
}

// Entry point. Reads argc/argv off the initial stack (Linux ABI) and hands
// them to probe(); exits via __NR_exit when it returns.
__attribute__((naked)) void _start(void) {
  __asm__ volatile(
      "mov x29, xzr\n"
      "mov x30, xzr\n"
      "ldr x0, [sp]\n"       // argc
      "add x1, sp, #8\n"     // argv
      "bl probe\n"
      "mov x8, #93\n"        // __NR_exit
      "mov x0, #0\n"
      "svc #0\n");
}
