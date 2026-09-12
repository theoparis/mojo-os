# Minimal synchronous VirtIO block driver using the transitional PCI device's
# legacy I/O-port interface. QEMU exposes this as virtio-blk-pci-transitional.
from arch.mem import read_u8, read_u16, volatile_read_u16, write_u8, write_u16, write_u32, write_u64
from arch.pci import find_device, io_bar0, io_read16, io_read32, io_write8, io_write16, io_write32
from arch.virtio_blk import sync_dma, wait_for_device
from mm.phys import PhysAlloc

comptime VIRTIO_VENDOR: UInt16 = 0x1af4
comptime VIRTIO_BLK_LEGACY_DEVICE: UInt16 = 0x1001
comptime QUEUE_SIZE: Int = 256
comptime DESC_F_NEXT: UInt16 = 1
comptime DESC_F_WRITE: UInt16 = 2


struct VirtioBlkPci:
    var io: UInt16
    var desc: UInt64
    var avail: UInt64
    var used: UInt64
    var request: UInt64
    var data: UInt64
    var last_used: UInt16
    var capacity_sectors: UInt64
    var ready: Bool

    def __init__(out self):
        self.io = 0
        self.desc = 0
        self.avail = 0
        self.used = 0
        self.request = 0
        self.data = 0
        self.last_used = 0
        self.capacity_sectors = 0
        self.ready = False

    def init(mut self, mut alloc: PhysAlloc) -> Bool:
        var device = find_device(VIRTIO_VENDOR, VIRTIO_BLK_LEGACY_DEVICE)
        if device < 0:
            return False
        self.io = io_bar0(device)
        if self.io == 0:
            return False

        io_write8(self.io + 18, 0)
        io_write8(self.io + 18, 1 | 2)
        io_write32(self.io + 4, 0)  # no optional legacy features
        io_write16(self.io + 14, 0)
        if io_read16(self.io + 12) != UInt16(QUEUE_SIZE):
            return False

        # Legacy PCI fixes the ring at QueueNum entries (QEMU: 256):
        # descriptors in page 0, avail in page 1, used in page 2.
        var queue = alloc.alloc_pages(3)
        self.request = alloc.alloc(32)
        self.data = alloc.alloc(512)
        if queue == 0 or self.request == 0 or self.data == 0:
            return False
        self.desc = queue
        self.avail = queue + UInt64(16 * QUEUE_SIZE)
        self.used = queue + 8192
        for i in range(12288):
            write_u8(Int(queue) + i, 0)
        io_write32(self.io + 8, UInt32(queue >> 12))
        self.capacity_sectors = UInt64(io_read32(self.io + 20)) | (UInt64(io_read32(self.io + 24)) << 32)
        io_write8(self.io + 18, 1 | 2 | 4)
        self.ready = True
        return True

    def read_sector(mut self, sector: UInt64) -> Bool:
        if not self.ready or sector >= self.capacity_sectors:
            return False
        write_u32(Int(self.request), 0)
        write_u32(Int(self.request + 4), 0)
        write_u64(Int(self.request + 8), sector)
        write_u8(Int(self.request + 16), 0xff)

        write_u64(Int(self.desc), self.request)
        write_u32(Int(self.desc + 8), 16)
        write_u16(Int(self.desc + 12), DESC_F_NEXT)
        write_u16(Int(self.desc + 14), 1)
        write_u64(Int(self.desc + 16), self.data)
        write_u32(Int(self.desc + 24), 512)
        write_u16(Int(self.desc + 28), DESC_F_NEXT | DESC_F_WRITE)
        write_u16(Int(self.desc + 30), 2)
        write_u64(Int(self.desc + 32), self.request + 16)
        write_u32(Int(self.desc + 40), 1)
        write_u16(Int(self.desc + 44), DESC_F_WRITE)
        write_u16(Int(self.desc + 46), 0)

        var idx = read_u16(Int(self.avail + 2))
        write_u16(Int(self.avail + 4 + UInt64((idx % UInt16(QUEUE_SIZE)) * 2)), 0)
        idx += 1
        write_u16(Int(self.avail + 2), idx)
        sync_dma(self.desc, 48)
        sync_dma(self.request, 32)
        sync_dma(self.data, 512)
        sync_dma(self.avail, 8)
        io_write16(self.io + 16, 0)
        while True:
            sync_dma(self.used, 12)
            if volatile_read_u16(Int(self.used + 2)) != self.last_used:
                break
            wait_for_device()
        sync_dma(self.request, 32)
        sync_dma(self.data, 512)
        self.last_used += 1
        return read_u8(Int(self.request + 16)) == 0

    def first_byte(self) -> UInt8:
        return read_u8(Int(self.data))
