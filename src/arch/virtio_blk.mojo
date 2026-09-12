# Minimal VirtIO 1.0 block driver over the MMIO transport.
#
# It deliberately supports one queue, no negotiated optional features, and
# synchronous 512-byte reads. That is enough to prove the transport and block
# protocol before a filesystem consumes it.
from std.ffi import external_call

from arch.mem import read_u8, read_u16, read_u32, read_u64, volatile_read_u16, write_u8, write_u16, write_u32, write_u64
from mm.phys import PhysAlloc

comptime VIRTIO_MAGIC: UInt32 = 0x74726976
comptime VIRTIO_VERSION_1: UInt32 = 2
comptime VIRTIO_DEVICE_BLOCK: UInt32 = 2
comptime VIRTIO_STATUS_ACK: UInt32 = 1
comptime VIRTIO_STATUS_DRIVER: UInt32 = 2
comptime VIRTIO_STATUS_FEATURES_OK: UInt32 = 8
comptime VIRTIO_STATUS_DRIVER_OK: UInt32 = 4
comptime VIRTQ_SIZE: Int = 8
comptime VIRTIO_F_VERSION_1: UInt32 = 1  # bit 32, feature word 1
comptime VIRTQ_DESC_SIZE: Int = 16
comptime VIRTQ_DESC_F_NEXT: UInt16 = 1
comptime VIRTQ_DESC_F_WRITE: UInt16 = 2
comptime VIRTIO_BLK_T_IN: UInt32 = 0


@always_inline
def reg(base: UInt64, off: Int) -> Int:
    return Int(base) + off


@always_inline
def barrier():
    external_call["virtio_mb", NoneType]()


@always_inline
def wait_for_device():
    external_call["virtio_wait", NoneType]()


@always_inline
def sync_dma(addr: UInt64, size: Int):
    external_call["virtio_sync", NoneType](Int(addr), size)


struct VirtioBlk:
    var base: UInt64
    var desc: UInt64
    var avail: UInt64
    var used: UInt64
    var request: UInt64
    var data: UInt64
    var last_used: UInt16
    var capacity_sectors: UInt64
    var ready: Bool

    def __init__(out self):
        self.base = 0
        self.desc = 0
        self.avail = 0
        self.used = 0
        self.request = 0
        self.data = 0
        self.last_used = 0
        self.capacity_sectors = 0
        self.ready = False

    def init(mut self, mut alloc: PhysAlloc, base: UInt64) -> Bool:
        """Bring up queue 0 of a modern VirtIO MMIO block device."""
        if read_u32(reg(base, 0x000)) != VIRTIO_MAGIC:
            return False
        if read_u32(reg(base, 0x004)) != VIRTIO_VERSION_1:
            return False
        if read_u32(reg(base, 0x008)) != VIRTIO_DEVICE_BLOCK:
            return False

        self.base = base
        write_u32(reg(base, 0x070), 0)
        write_u32(reg(base, 0x070), VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER)
        # Modern MMIO transports require VIRTIO_F_VERSION_1. No other
        # optional feature is needed for a basic synchronous read.
        write_u32(reg(base, 0x024), 0)
        write_u32(reg(base, 0x020), 0)
        write_u32(reg(base, 0x024), 1)
        write_u32(reg(base, 0x020), VIRTIO_F_VERSION_1)
        write_u32(reg(base, 0x070), VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK)
        if (read_u32(reg(base, 0x070)) & VIRTIO_STATUS_FEATURES_OK) == 0:
            return False

        write_u32(reg(base, 0x030), 0)
        if read_u32(reg(base, 0x034)) < UInt32(VIRTQ_SIZE):
            return False
        var queue = alloc.alloc_pages(1)
        self.request = alloc.alloc(32)  # 16-byte header plus status byte
        self.data = alloc.alloc(512)
        if queue == 0 or self.request == 0 or self.data == 0:
            return False
        self.desc = queue
        self.avail = self.desc + UInt64(VIRTQ_DESC_SIZE * VIRTQ_SIZE)
        self.used = (self.avail + UInt64(4 + VIRTQ_SIZE * 2) + 3) & ~UInt64(3)
        for off in range(4 + VIRTQ_SIZE * VIRTQ_DESC_SIZE + 4 + VIRTQ_SIZE * 2 + 4 + VIRTQ_SIZE * 8):
            write_u8(Int(self.desc) + off, 0)
        write_u32(reg(base, 0x038), UInt32(VIRTQ_SIZE))
        write_u32(reg(base, 0x080), UInt32(self.desc))
        write_u32(reg(base, 0x084), UInt32(self.desc >> 32))
        write_u32(reg(base, 0x090), UInt32(self.avail))
        write_u32(reg(base, 0x094), UInt32(self.avail >> 32))
        write_u32(reg(base, 0x0a0), UInt32(self.used))
        write_u32(reg(base, 0x0a4), UInt32(self.used >> 32))
        barrier()
        write_u32(reg(base, 0x044), 1)
        write_u32(reg(base, 0x070), VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)
        self.capacity_sectors = read_u64(Int(base) + 0x100)
        self.ready = True
        return True

    def read_sector(mut self, sector: UInt64) -> Bool:
        """Synchronously read one 512-byte sector into the driver's buffer."""
        if not self.ready or sector >= self.capacity_sectors:
            return False
        # struct virtio_blk_outhdr { type, reserved, sector }.
        write_u32(Int(self.request), VIRTIO_BLK_T_IN)
        write_u32(Int(self.request + 4), 0)
        write_u64(Int(self.request + 8), sector)
        write_u8(Int(self.request + 16), 0xff)  # request status byte

        # Three descriptors: request header -> data-in -> status byte.
        write_u64(Int(self.desc), self.request)
        write_u32(Int(self.desc + 8), 16)
        write_u16(Int(self.desc + 12), VIRTQ_DESC_F_NEXT)
        write_u16(Int(self.desc + 14), 1)
        write_u64(Int(self.desc + 16), self.data)
        write_u32(Int(self.desc + 24), 512)
        write_u16(Int(self.desc + 28), VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE)
        write_u16(Int(self.desc + 30), 2)
        write_u64(Int(self.desc + 32), self.request + 16)
        write_u32(Int(self.desc + 40), 1)
        write_u16(Int(self.desc + 44), VIRTQ_DESC_F_WRITE)
        write_u16(Int(self.desc + 46), 0)

        var avail_idx = read_u16(Int(self.avail + 2))
        write_u16(Int(self.avail + 4 + UInt64((avail_idx % UInt16(VIRTQ_SIZE)) * 2)), 0)
        barrier()
        avail_idx += 1
        write_u16(Int(self.avail + 2), avail_idx)
        sync_dma(self.desc, 48)
        sync_dma(self.request, 32)
        sync_dma(self.data, 512)
        sync_dma(self.avail, 8)
        barrier()
        write_u32(reg(self.base, 0x050), 0)
        while True:
            sync_dma(self.used, 12)
            if volatile_read_u16(Int(self.used + 2)) != self.last_used:
                break
            wait_for_device()
        sync_dma(self.data, 512)
        barrier()
        self.last_used += 1
        return read_u8(Int(self.request + 16)) == 0

    def first_byte(self) -> UInt8:
        return read_u8(Int(self.data))
