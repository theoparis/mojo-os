# Pure Mojo UEFI loader implementing standard UEFI structs with @fieldwise_init
# Supports both ELF64 and Mach-O 64-bit kernels on x86_64 and AArch64.
from std.memory import Pointer
from std.origin import MutUntrackedOrigin
from std.sys.info import CompilationTarget

from arch.afdt_builder import DTBuilder
from arch.xnu_boot import SIZEOF_BOOT_ARGS, init_boot_args
from loader import (
    CPU_TYPE_ARM64,
    CPU_TYPE_X86_64,
    EM_AARCH64,
    EM_X86_64,
    elf_entry,
    elf_is_valid,
    elf_load_bounds,
    elf_load_image,
    elf_machine,
    macho_cputype,
    macho_find_entry,
    macho_is_valid,
    macho_load_bounds,
    macho_load_image,
)

comptime EFI_SUCCESS: UInt64 = 0
comptime EFI_LOAD_ERROR: UInt64 = 0x8000000000000001
comptime EFI_INVALID_PARAMETER: UInt64 = 0x8000000000000002
comptime EFI_UNSUPPORTED: UInt64 = 0x8000000000000003
comptime EFI_BUFFER_TOO_SMALL: UInt64 = 0x8000000000000005

comptime EFI_FILE_MODE_READ: UInt64 = 1

comptime EFI_STATUS = UInt64
comptime EFI_HANDLE = Int


@always_inline
def any_ptr[T: AnyType](mut val: T) -> Pointer[T, MutAnyOrigin]:
    return Pointer[T, MutAnyOrigin](unsafe_from_address=Int(Pointer(to=val)))


@fieldwise_init
struct EFI_GUID(ImplicitlyCopyable, RegisterPassable):
    var data1: UInt32
    var data2: UInt16
    var data3: UInt16
    var data4_0: UInt8
    var data4_1: UInt8
    var data4_2: UInt8
    var data4_3: UInt8
    var data4_4: UInt8
    var data4_5: UInt8
    var data4_6: UInt8
    var data4_7: UInt8


@fieldwise_init
struct EFI_TABLE_HEADER(RegisterPassable):
    var signature: UInt64
    var revision: UInt32
    var header_size: UInt32
    var crc32: UInt32
    var reserved: UInt32


@fieldwise_init
struct EFI_FILE_PROTOCOL(RegisterPassable):
    var Revision: UInt64
    var Open: def(
        Pointer[Self, MutAnyOrigin],
        Pointer[EFI_HANDLE, MutAnyOrigin],
        Pointer[UInt16, MutAnyOrigin],
        UInt64,
        UInt64,
    ) thin abi("C") -> EFI_STATUS
    var Close: def(Pointer[Self, MutAnyOrigin]) thin abi("C") -> EFI_STATUS
    var Delete: EFI_HANDLE
    var Read: def(
        Pointer[Self, MutAnyOrigin], Pointer[UInt64, MutAnyOrigin], EFI_HANDLE
    ) thin abi("C") -> EFI_STATUS
    var Write: EFI_HANDLE
    var GetPosition: EFI_HANDLE
    var SetPosition: EFI_HANDLE
    var GetInfo: def(
        Pointer[Self, MutAnyOrigin],
        Pointer[EFI_GUID, MutAnyOrigin],
        Pointer[UInt64, MutAnyOrigin],
        EFI_HANDLE,
    ) thin abi("C") -> EFI_STATUS


@fieldwise_init
struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL(RegisterPassable):
    var Revision: UInt64
    var OpenVolume: def(
        Pointer[Self, MutAnyOrigin], Pointer[EFI_HANDLE, MutAnyOrigin]
    ) thin abi("C") -> EFI_STATUS


@fieldwise_init
struct EFI_BOOT_SERVICES(RegisterPassable):
    var Hdr: EFI_TABLE_HEADER
    var RaiseTPL: EFI_HANDLE
    var RestoreTPL: EFI_HANDLE
    var AllocatePages: def(
        UInt32, UInt32, UInt64, Pointer[UInt64, MutAnyOrigin]
    ) thin abi("C") -> EFI_STATUS
    var FreePages: EFI_HANDLE
    var GetMemoryMap: EFI_HANDLE
    var AllocatePool: def(
        UInt32, UInt64, Pointer[EFI_HANDLE, MutAnyOrigin]
    ) thin abi("C") -> EFI_STATUS
    var FreePool: def(EFI_HANDLE) thin abi("C") -> EFI_STATUS
    var CreateEvent: EFI_HANDLE
    var SetTimer: EFI_HANDLE
    var WaitForEvent: EFI_HANDLE
    var SignalEvent: EFI_HANDLE
    var CloseEvent: EFI_HANDLE
    var CheckEvent: EFI_HANDLE
    var InstallProtocolInterface: EFI_HANDLE
    var ReinstallProtocolInterface: EFI_HANDLE
    var UninstallProtocolInterface: EFI_HANDLE
    var HandleProtocol: def(
        EFI_HANDLE,
        Pointer[EFI_GUID, MutAnyOrigin],
        Pointer[EFI_HANDLE, MutAnyOrigin],
    ) thin abi("C") -> EFI_STATUS


@fieldwise_init
struct EFI_SYSTEM_TABLE(RegisterPassable):
    var Hdr: EFI_TABLE_HEADER
    var FirmwareVendor: EFI_HANDLE
    var FirmwareRevision: UInt32
    var ConsoleInHandle: EFI_HANDLE
    var ConIn: EFI_HANDLE
    var ConsoleOutHandle: EFI_HANDLE
    var ConOut: EFI_HANDLE
    var StandardErrorHandle: EFI_HANDLE
    var StdErr: EFI_HANDLE
    var RuntimeServices: EFI_HANDLE
    var BootServices: Pointer[EFI_BOOT_SERVICES, MutUntrackedOrigin]


@fieldwise_init
struct EFI_LOADED_IMAGE_PROTOCOL(RegisterPassable):
    var Revision: UInt32
    var ParentHandle: EFI_HANDLE
    var SystemTable: EFI_HANDLE
    var DeviceHandle: EFI_HANDLE


@fieldwise_init
struct EFI_FILE_INFO(RegisterPassable):
    var Size: UInt64
    var FileSize: UInt64
    var PhysicalSize: UInt64
    var CreateTime_0: UInt64
    var CreateTime_1: UInt64
    var LastAccessTime_0: UInt64
    var LastAccessTime_1: UInt64
    var ModificationTime_0: UInt64
    var ModificationTime_1: UInt64
    var Attribute: UInt64


# Standard UEFI protocol GUIDs
comptime LOADED_IMAGE_PROTOCOL_GUID = EFI_GUID(
    0x5B1B31A1, 0x9562, 0x11D2, 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
)

comptime SIMPLE_FILE_SYSTEM_PROTOCOL_GUID = EFI_GUID(
    0x964E5B22, 0x6459, 0x11D2, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
)

comptime FILE_INFO_ID = EFI_GUID(
    0x09576E92, 0x6D3F, 0x11D2, 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
)


def load_file(
    bs: Pointer[EFI_BOOT_SERVICES, MutUntrackedOrigin],
    root: Pointer[EFI_FILE_PROTOCOL, MutAnyOrigin],
    filename_u16: Pointer[UInt16, MutAnyOrigin],
    mut out_buf: EFI_HANDLE,
    mut out_size: UInt64,
) -> EFI_STATUS:
    var info_guid = FILE_INFO_ID
    var file_handle: EFI_HANDLE = 0
    var status = root[].Open(
        root, any_ptr(file_handle), filename_u16, EFI_FILE_MODE_READ, 0
    )
    if status != EFI_SUCCESS:
        return status

    var file = Pointer[EFI_FILE_PROTOCOL, MutAnyOrigin](
        unsafe_from_address=file_handle
    )
    var info_size: UInt64 = 0
    status = file[].GetInfo(file, any_ptr(info_guid), any_ptr(info_size), 0)
    if status != EFI_BUFFER_TOO_SMALL:
        _ = file[].Close(file)
        return status

    var meta_handle: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, info_size, any_ptr(meta_handle))
    if status != EFI_SUCCESS:
        _ = file[].Close(file)
        return status

    status = file[].GetInfo(
        file, any_ptr(info_guid), any_ptr(info_size), meta_handle
    )
    if status != EFI_SUCCESS:
        _ = bs[].FreePool(meta_handle)
        _ = file[].Close(file)
        return status

    var file_info = Pointer[EFI_FILE_INFO, MutAnyOrigin](
        unsafe_from_address=meta_handle
    )
    var file_size = file_info[].FileSize
    _ = bs[].FreePool(meta_handle)

    var raw_buf: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, file_size, any_ptr(raw_buf))
    if status != EFI_SUCCESS:
        _ = file[].Close(file)
        return status

    var read_bytes = file_size
    status = file[].Read(file, any_ptr(read_bytes), raw_buf)
    _ = file[].Close(file)
    if status != EFI_SUCCESS or read_bytes != file_size:
        _ = bs[].FreePool(raw_buf)
        return status if status != EFI_SUCCESS else EFI_LOAD_ERROR

    out_buf = raw_buf
    out_size = file_size
    return EFI_SUCCESS


@export("uefi_load_and_boot")
def uefi_load_and_boot(
    image_handle: EFI_HANDLE, sys_table: Pointer[EFI_SYSTEM_TABLE, MutAnyOrigin]
) abi("C") -> EFI_STATUS:
    var bs = sys_table[].BootServices

    var loaded_guid = LOADED_IMAGE_PROTOCOL_GUID
    var fs_guid = SIMPLE_FILE_SYSTEM_PROTOCOL_GUID

    var li_handle: EFI_HANDLE = 0
    var status = bs[].HandleProtocol(
        image_handle, any_ptr(loaded_guid), any_ptr(li_handle)
    )
    if status != EFI_SUCCESS:
        return 0x100 | status

    var li = Pointer[EFI_LOADED_IMAGE_PROTOCOL, MutAnyOrigin](
        unsafe_from_address=li_handle
    )
    var fs_handle: EFI_HANDLE = 0
    status = bs[].HandleProtocol(
        li[].DeviceHandle, any_ptr(fs_guid), any_ptr(fs_handle)
    )
    if status != EFI_SUCCESS:
        return 0x200 | status

    var fs = Pointer[EFI_SIMPLE_FILE_SYSTEM_PROTOCOL, MutAnyOrigin](
        unsafe_from_address=fs_handle
    )
    var root_handle: EFI_HANDLE = 0
    status = fs[].OpenVolume(fs, any_ptr(root_handle))
    if status != EFI_SUCCESS:
        return 0x300 | status

    var root = Pointer[EFI_FILE_PROTOCOL, MutAnyOrigin](
        unsafe_from_address=root_handle
    )

    # 1. Try loading ramdisk: \initrd.cpio
    var ramdisk_u16: Array[UInt16, 13] = [
        UInt16(ord("\\")),
        UInt16(ord("i")),
        UInt16(ord("n")),
        UInt16(ord("i")),
        UInt16(ord("t")),
        UInt16(ord("r")),
        UInt16(ord("d")),
        UInt16(ord(".")),
        UInt16(ord("c")),
        UInt16(ord("p")),
        UInt16(ord("i")),
        UInt16(ord("o")),
        UInt16(0),
    ]
    var ramdisk_ptr = Pointer[UInt16, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=ramdisk_u16))
    )
    var rd_buf: EFI_HANDLE = 0
    var rd_size: UInt64 = 0
    var has_rd = (
        load_file(bs, root, ramdisk_ptr, rd_buf, rd_size) == EFI_SUCCESS
    )

    # 2. Try loading kernel: \kernel.macho, fallback \kernel.elf
    var path_macho: Array[UInt16, 14] = [
        UInt16(ord("\\")),
        UInt16(ord("k")),
        UInt16(ord("e")),
        UInt16(ord("r")),
        UInt16(ord("n")),
        UInt16(ord("e")),
        UInt16(ord("l")),
        UInt16(ord(".")),
        UInt16(ord("m")),
        UInt16(ord("a")),
        UInt16(ord("c")),
        UInt16(ord("h")),
        UInt16(ord("o")),
        UInt16(0),
    ]
    var macho_ptr = Pointer[UInt16, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=path_macho))
    )
    var k_buf: EFI_HANDLE = 0
    var k_size: UInt64 = 0
    var is_macho = load_file(bs, root, macho_ptr, k_buf, k_size) == EFI_SUCCESS

    if not is_macho:
        var path_elf: Array[UInt16, 12] = [
            UInt16(ord("\\")),
            UInt16(ord("k")),
            UInt16(ord("e")),
            UInt16(ord("r")),
            UInt16(ord("n")),
            UInt16(ord("e")),
            UInt16(ord("l")),
            UInt16(ord(".")),
            UInt16(ord("e")),
            UInt16(ord("l")),
            UInt16(ord("f")),
            UInt16(0),
        ]
        var elf_ptr = Pointer[UInt16, MutAnyOrigin](
            unsafe_from_address=Int(Pointer(to=path_elf))
        )
        status = load_file(bs, root, elf_ptr, k_buf, k_size)
        if status != EFI_SUCCESS:
            return 0x400 | status

    # Determine load bounds
    var min_vaddr: UInt64 = 0
    var max_vaddr: UInt64 = 0
    var entry_addr: Int = 0

    if is_macho or macho_is_valid(k_buf):
        if not macho_load_bounds(k_buf, min_vaddr, max_vaddr):
            return EFI_LOAD_ERROR
        var page_count = (max_vaddr - min_vaddr + 4095) // 4096
        var alloc_addr: UInt64 = min_vaddr
        status = bs[].AllocatePages(2, 1, page_count, any_ptr(alloc_addr))
        if status != EFI_SUCCESS:
            status = bs[].AllocatePages(0, 1, page_count, any_ptr(alloc_addr))
            if status != EFI_SUCCESS:
                return status
        var load_bias = Int(alloc_addr - min_vaddr)
        if not macho_load_image(k_buf, load_bias):
            return EFI_LOAD_ERROR
        entry_addr = Int(macho_find_entry(k_buf)) + load_bias
    elif elf_is_valid(k_buf):
        if not elf_load_bounds(k_buf, min_vaddr, max_vaddr):
            return EFI_LOAD_ERROR
        var page_count = (max_vaddr - min_vaddr + 4095) // 4096
        var alloc_addr: UInt64 = min_vaddr
        status = bs[].AllocatePages(2, 1, page_count, any_ptr(alloc_addr))
        if status != EFI_SUCCESS:
            status = bs[].AllocatePages(0, 1, page_count, any_ptr(alloc_addr))
            if status != EFI_SUCCESS:
                return status
        var load_bias = Int(alloc_addr - min_vaddr)
        if not elf_load_image(k_buf, load_bias):
            return EFI_LOAD_ERROR
        entry_addr = Int(elf_entry(k_buf)) + load_bias
    else:
        return EFI_LOAD_ERROR

    _ = bs[].FreePool(k_buf)

    # 3. Build XNU Flattened Device Tree with /chosen/memory-map RAMDisk property
    var dt_buf: EFI_HANDLE = 0
    var dt_size: UInt64 = 4096
    status = bs[].AllocatePool(2, dt_size, any_ptr(dt_buf))
    if status != EFI_SUCCESS:
        return status

    var dt = DTBuilder(dt_buf, Int(dt_size))
    # Root node: 1 property ("name" = ""), 1 child ("chosen")
    dt.add_node_header(1, 1)
    dt.add_string_property("name", "")

    # Child: "chosen": 1 property ("name" = "chosen"), 1 child ("memory-map")
    dt.add_node_header(1, 1)
    dt.add_string_property("name", "chosen")

    # Child: "memory-map": 2 properties ("name" = "memory-map", "RAMDisk" = [base, size]), 0 children
    if has_rd:
        dt.add_node_header(2, 0)
        dt.add_string_property("name", "memory-map")
        dt.add_u64_pair_property("RAMDisk", UInt64(rd_buf), rd_size)
    else:
        dt.add_node_header(1, 0)
        dt.add_string_property("name", "memory-map")

    # 4. Allocate and construct XNU boot_args structure
    var ba_buf: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, UInt64(SIZEOF_BOOT_ARGS), any_ptr(ba_buf))
    if status != EFI_SUCCESS:
        return status

    var phys_base: UInt64 = 0x40000000
    var mem_size: UInt64 = 256 * 1024 * 1024
    comptime if StringLiteral[
        CompilationTarget[].__triple_arch()
    ]() == "x86_64":
        # q35 conventional RAM starts at physical zero. Keep the first MiB
        # reserved for firmware/legacy regions; this also covers EFI pools.
        phys_base = 0x100000
        mem_size = 127 * 1024 * 1024
    init_boot_args(
        ba_buf,
        phys_base,
        mem_size,
        max_vaddr,
        UInt64(dt_buf),
        UInt32(dt.size()),
        "console=ttyAMA0 rdinit=/init",
    )

    # Transfer control to kernel entry point with boot_args in argument 0
    var entry_fn = Pointer[Int](to=entry_addr).unsafe_bitcast[
        def(Int, Int, Int, Int) thin abi("C") -> NoneType
    ]()[]
    entry_fn(ba_buf, Int(min_vaddr), Int(max_vaddr), 0)

    while True:
        pass


@export("memset")
def memset(
    dst: Pointer[UInt8, MutAnyOrigin], val: Int32, n: UInt64
) abi("C") -> Pointer[UInt8, MutAnyOrigin]:
    for i in range(Int(n)):
        dst[unsafe_offset=i] = UInt8(val)
    return dst


@export("memcpy")
def memcpy(
    dst: Pointer[UInt8, MutAnyOrigin],
    src: Pointer[UInt8, MutAnyOrigin],
    n: UInt64,
) abi("C") -> Pointer[UInt8, MutAnyOrigin]:
    for i in range(Int(n)):
        dst[unsafe_offset=i] = src[unsafe_offset=i]
    return dst
