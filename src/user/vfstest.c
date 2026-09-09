// /init VFS exercise: validates the kernel's file syscalls (openat, read,
// close, lseek, newfstatat, fstat, getdents64) against the rootfs built
// from the initrd. Pure inline-asm Linux syscalls, no libc.
//
// See src/user/init.c for the shared syscall scaffolding. Linked at 0x400000
// by src/user/user.ld and eret'd to at EL0 with a Linux initial stack.
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

static u64 sys4(u64 nr, u64 a0, u64 a1, u64 a2, u64 a3) {
  register u64 x8 __asm__("x8") = nr;
  register u64 x0 __asm__("x0") = a0;
  register u64 x1 __asm__("x1") = a1;
  register u64 x2 __asm__("x2") = a2;
  register u64 x3 __asm__("x3") = a3;
  __asm__ volatile("svc #0"
                   : "+r"(x0)
                   : "r"(x8), "r"(x1), "r"(x2), "r"(x3)
                   : "memory");
  return x0;
}

static u64 strlen_(const char *s) {
  u64 n = 0;
  while (s[n]) n++;
  return n;
}

static void puts_(const char *s) { sys3(64, 1, (u64)s, strlen_(s)); }

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
  sys3(64, 1, (u64)(buf + i + 1), (u64)(18 - i));
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

#define AT_FDCWD ((u64)-100)
#define O_RDONLY 0
#define O_DIRECTORY 0x10000

struct linux_dirent64 {
  u64 d_ino;
  s64 d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[255];
};

static void read_whole(u64 fd, const char *label) {
  char buf[64];
  puts_(label);
  for (;;) {
    u64 n = sys3(63, fd, (u64)buf, 64);  // __NR_read
    if ((s64)n <= 0) break;
    sys3(64, 1, (u64)buf, n);  // echo to stdout
  }
  puts_("\n");
}

int test(void) {
  // 1) newfstatat /hello.txt and print its mode + size
  u64 st[16] = {0};
  u64 r = sys4(79, AT_FDCWD, (u64)"/hello.txt", (u64)st, 0);  // newfstatat
  puts_("newfstatat(/hello.txt)=");
  if ((s64)r < 0) {
    puts_("FAIL\n");
  } else {
    putdec((st[16 / 8] >> 0) & 0xFFFFFFFFu);  // st_mode
    puts_(" mode, size=");
    putdec(st[48 / 8]);
    puts_("\n");
  }

  // 2) openat + read the whole file
  u64 fd = sys4(56, AT_FDCWD, (u64)"/hello.txt", O_RDONLY, 0);  // openat
  puts_("openat(/hello.txt)=");
  puthex(fd);
  puts_("\n");
  read_whole(fd, "contents: ");
  sys3(57, fd, 0, 0);  // close

  // 3) fstat + lseek on it
  fd = sys4(56, AT_FDCWD, (u64)"/hello.txt", O_RDONLY, 0);
  u64 st2[16] = {0};
  sys3(80, fd, (u64)st2, 0);  // fstat
  puts_("fstat size=");
  putdec(st2[48 / 8]);
  puts_("\n");
  u64 o = sys3(62, fd, 2, 2);  // lseek(fd, 2, SEEK_END) -> end
  puts_("lseek(END)=0x");
  puthex(o);
  puts_("\n");
  sys3(57, fd, 0, 0);

  // 4) open "/" (a directory) and getdents64 the names
  u64 dfd = sys4(56, AT_FDCWD, (u64)"/", O_RDONLY | O_DIRECTORY, 0);
  puts_("open(/,dir)=");
  puthex(dfd);
  puts_("\n  / entries:\n");
  char dbuf[512];
  for (;;) {
    u64 n = sys3(61, dfd, (u64)dbuf, sizeof(dbuf));  // getdents64
    if ((s64)n <= 0) break;
    u64 off = 0;
    while (off < n) {
      struct linux_dirent64 *d = (struct linux_dirent64 *)(dbuf + off);
      puts_("    ");
      puts_(d->d_name);
      puts_("  (type ");
      putdec(d->d_type);
      puts_(")\n");
      off += d->d_reclen;
    }
  }
  sys3(57, dfd, 0, 0);
  return 0;
}

__attribute__((naked)) void _start(void) {
  __asm__ volatile(
      "mov x29, xzr\n"
      "mov x30, xzr\n"
      "bl test\n"
      "mov x8, #93\n"  // __NR_exit
      "mov x0, #0\n"
      "svc #0\n");
}
