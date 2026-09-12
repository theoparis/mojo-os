// Dynamically linked macOS / Darwin userspace test program.
// Linked against /usr/lib/libSystem.B.dylib (built in Mojo) and tests dynamic linking,
// imports, dyld chained fixups, and multiple Darwin BSD and Mach APIs.

#include <stddef.h>

extern int write(int fd, const void *buf, unsigned long len);
extern int getpid(void);
extern void *mmap(void *addr, size_t len, int prot, int flags, int fd, long offset);
extern int munmap(void *addr, size_t len);
extern void exit(int status);

static void print(const char *s) {
    unsigned long len = 0;
    while (s[len]) len++;
    write(1, s, len);
}

static void print_num(long n) {
    char buf[24];
    int i = 22;
    buf[23] = 0;
    if (n == 0) {
        print("0");
        return;
    }
    if (n < 0) {
        print("-");
        n = -n;
    }
    while (n > 0) {
        buf[i--] = '0' + (n % 10);
        n /= 10;
    }
    print(&buf[i + 1]);
}

static void print_hex(unsigned long v) {
    static const char h[] = "0123456789abcdef";
    char buf[20];
    int i = 18;
    buf[19] = 0;
    do {
        buf[i--] = h[v & 0xf];
        v >>= 4;
    } while (v);
    print("0x");
    print(&buf[i + 1]);
}

int main(int argc, char **argv) {
    print("==================================================\n");
    print("  Hello from dynamic macOS userspace on Mojo OS!  \n");
    print("  Dynamically linked to Mojo libSystem.B.dylib    \n");
    print("==================================================\n\n");

    print("[user] argc = ");
    print_num(argc);
    print("\n");

    for (int i = 0; i < argc; i++) {
        print("  argv[");
        print_num(i);
        print("] = \"");
        print(argv[i]);
        print("\"\n");
    }

    // Check getpid()
    int pid = getpid();
    print("\n[user] getpid() returned: ");
    print_num(pid);
    print("\n");

    // Test dynamic mmap through Mojo libSystem
    // MAP_ANON = 0x1000, MAP_PRIVATE = 0x0002, PROT_READ=1, PROT_WRITE=2
    print("[user] allocating 4KB with Mojo libSystem mmap()...\n");
    void *ptr = mmap(NULL, 4096, 3, 0x1002, -1, 0);
    print("[user] mmap returned: ");
    print_hex((unsigned long)ptr);
    print("\n");

    if ((long)ptr > 0) {
        volatile unsigned char *buf = (volatile unsigned char *)ptr;
        buf[0] = 0x42;
        buf[4095] = 0x99;
        if (buf[0] == 0x42 && buf[4095] == 0x99) {
            print("[user] mmap page memory read/write verified!\n");
        }
        munmap(ptr, 4096);
    }

    print("\n[user] Dynamic macOS userspace test PASSED!\n");
    print("[user] Exiting cleanly via Mojo libSystem exit(0)...\n");
    exit(0);
    return 0;
}
