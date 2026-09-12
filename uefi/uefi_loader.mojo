# Pure Mojo UEFI ELF loader implementing standard UEFI structs with @fieldwise_init
# Uses the freestanding `loader` package to parse and load ELF64 kernels.
from std.memory import Pointer

from loader import (
    EM_X86_64,
    elf_entry,
    elf_is_valid,
    elf_load_bounds,
    elf_load_image,
    elf_machine,
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


@export("uefi_load_and_boot")
def uefi_load_and_boot(
    image_handle: EFI_HANDLE, sys_table: Pointer[EFI_SYSTEM_TABLE, MutAnyOrigin]
) abi("C") -> EFI_STATUS:
    var bs = sys_table[].BootServices

    var loaded_guid = LOADED_IMAGE_PROTOCOL_GUID
    var fs_guid = SIMPLE_FILE_SYSTEM_PROTOCOL_GUID
    var info_guid = FILE_INFO_ID

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

    # Primary path: \kernel.elf
    var path_kernel: Array[UInt16, 12] = [
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
    var path_ptr = Pointer[UInt16, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=path_kernel))
    )
    var file_handle: EFI_HANDLE = 0
    status = root[].Open(
        root, any_ptr(file_handle), path_ptr, EFI_FILE_MODE_READ, 0
    )
    if status != EFI_SUCCESS:
        # Fallback path: \MOJOOS.ELF
        var path_fallback: Array[UInt16, 12] = [
            UInt16(ord("\\")),
            UInt16(ord("M")),
            UInt16(ord("O")),
            UInt16(ord("J")),
            UInt16(ord("O")),
            UInt16(ord("O")),
            UInt16(ord("S")),
            UInt16(ord(".")),
            UInt16(ord("E")),
            UInt16(ord("L")),
            UInt16(ord("F")),
            UInt16(0),
        ]
        var fb_ptr = Pointer[UInt16, MutAnyOrigin](
            unsafe_from_address=Int(Pointer(to=path_fallback))
        )
        status = root[].Open(
            root, any_ptr(file_handle), fb_ptr, EFI_FILE_MODE_READ, 0
        )
        if status != EFI_SUCCESS:
            return 0x400 | status

    var file = Pointer[EFI_FILE_PROTOCOL, MutAnyOrigin](
        unsafe_from_address=file_handle
    )
    var info_size: UInt64 = 0
    status = file[].GetInfo(file, any_ptr(info_guid), any_ptr(info_size), 0)
    if status != EFI_BUFFER_TOO_SMALL:
        return 0x500 | status

    var meta_handle: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, info_size, any_ptr(meta_handle))
    if status != EFI_SUCCESS:
        return status

    status = file[].GetInfo(
        file, any_ptr(info_guid), any_ptr(info_size), meta_handle
    )
    if status != EFI_SUCCESS:
        return status

    var file_info = Pointer[EFI_FILE_INFO, MutAnyOrigin](
        unsafe_from_address=meta_handle
    )
    var file_size = file_info[].FileSize
    _ = bs[].FreePool(meta_handle)

    var raw_buf: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, file_size, any_ptr(raw_buf))
    if status != EFI_SUCCESS:
        return status

    var read_bytes = file_size
    status = file[].Read(file, any_ptr(read_bytes), raw_buf)
    _ = file[].Close(file)
    if status != EFI_SUCCESS or read_bytes != file_size:
        return status if status != EFI_SUCCESS else EFI_LOAD_ERROR

    # Validate ELF header via freestanding loader package
    if not elf_is_valid(raw_buf):
        return EFI_LOAD_ERROR
    if elf_machine(raw_buf) != EM_X86_64:
        return EFI_LOAD_ERROR

    # Determine required memory bounds for PT_LOAD segments
    var min_vaddr: UInt64 = 0
    var max_vaddr: UInt64 = 0
    if not elf_load_bounds(raw_buf, min_vaddr, max_vaddr):
        return EFI_LOAD_ERROR

    var page_count = (max_vaddr - min_vaddr + 4095) // 4096
    var alloc_addr: UInt64 = min_vaddr
    # Try AllocateAddress first (Type 2 = AllocateAddress, MemoryType 2 = EfiLoaderData)
    status = bs[].AllocatePages(2, 2, page_count, any_ptr(alloc_addr))
    if status != EFI_SUCCESS:
        # Fallback to AllocateAnyPages (Type 0)
        status = bs[].AllocatePages(0, 2, page_count, any_ptr(alloc_addr))
        if status != EFI_SUCCESS:
            return status

    var load_bias = Int(alloc_addr - min_vaddr)
    if not elf_load_image(raw_buf, load_bias):
        return EFI_LOAD_ERROR

    var entry_addr = Int(elf_entry(raw_buf)) + load_bias

    _ = bs[].FreePool(raw_buf)

    # Transfer control to kernel entry point
    var entry_fn = Pointer[Int](to=entry_addr).unsafe_bitcast[
        def(Pointer[EFI_SYSTEM_TABLE, MutAnyOrigin]) thin abi("C") -> NoneType
    ]()[]
    entry_fn(sys_table)

    return EFI_SUCCESS


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
