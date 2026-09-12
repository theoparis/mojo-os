# Pure Mojo UEFI PE loader implementing standard UEFI structs with @fieldwise_init
from std.memory import Pointer

comptime EFI_SUCCESS: UInt64 = 0
comptime EFI_LOAD_ERROR: UInt64 = 0x8000000000000001
comptime EFI_INVALID_PARAMETER: UInt64 = 0x8000000000000002
comptime EFI_UNSUPPORTED: UInt64 = 0x8000000000000003
comptime EFI_BUFFER_TOO_SMALL: UInt64 = 0x8000000000000005

comptime EFI_FILE_MODE_READ: UInt64 = 1

comptime IMAGE_DOS_SIGNATURE: UInt16 = 0x5A4D
comptime IMAGE_NT_SIGNATURE: UInt32 = 0x00004550
comptime IMAGE_FILE_MACHINE_AMD64: UInt16 = 0x8664
comptime PE32PLUS_MAGIC: UInt16 = 0x020B
comptime IMAGE_SUBSYSTEM_NATIVE: UInt16 = 1

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
    var Close: EFI_HANDLE
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
    var AllocatePages: EFI_HANDLE
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


# PE/COFF Headers
@fieldwise_init
struct ImageDosHeader(RegisterPassable):
    var e_magic: UInt16  # 0
    var e_cblp: UInt16  # 2
    var e_cp: UInt16  # 4
    var e_crlc: UInt16  # 6
    var e_cparhdr: UInt16  # 8
    var e_minalloc: UInt16  # 10
    var e_maxalloc: UInt16  # 12
    var e_ss: UInt16  # 14
    var e_sp: UInt16  # 16
    var e_csum: UInt16  # 18
    var e_ip: UInt16  # 20
    var e_cs: UInt16  # 22
    var e_lfarlc: UInt16  # 24
    var e_ovno: UInt16  # 26
    var e_res_0: UInt32  # 28
    var e_res_1: UInt32  # 32
    var e_oemid: UInt16  # 36
    var e_oeminfo: UInt16  # 38
    var e_res2_0: UInt32  # 40
    var e_res2_1: UInt32  # 44
    var e_res2_2: UInt32  # 48
    var e_res2_3: UInt32  # 52
    var e_res2_4: UInt32  # 56
    var e_lfanew: UInt32  # 60


@fieldwise_init
struct ImageFileHeader(RegisterPassable):
    var Machine: UInt16
    var NumberOfSections: UInt16
    var TimeDateStamp: UInt32
    var PointerToSymbolTable: UInt32
    var NumberOfSymbols: UInt32
    var SizeOfOptionalHeader: UInt16
    var Characteristics: UInt16


@fieldwise_init
struct ImageOptionalHeader64(RegisterPassable):
    var Magic: UInt16
    var MajorLinkerVersion: UInt8
    var MinorLinkerVersion: UInt8
    var SizeOfCode: UInt32
    var SizeOfInitializedData: UInt32
    var SizeOfUninitializedData: UInt32
    var AddressOfEntryPoint: UInt32
    var BaseOfCode: UInt32
    var ImageBase: UInt64
    var SectionAlignment: UInt32
    var FileAlignment: UInt32
    var MajorOperatingSystemVersion: UInt16
    var MinorOperatingSystemVersion: UInt16
    var MajorImageVersion: UInt16
    var MinorImageVersion: UInt16
    var MajorSubsystemVersion: UInt16
    var MinorSubsystemVersion: UInt16
    var Win32VersionValue: UInt32
    var SizeOfImage: UInt32
    var SizeOfHeaders: UInt32
    var CheckSum: UInt32
    var Subsystem: UInt16
    var DllCharacteristics: UInt16


@fieldwise_init
struct ImageSectionHeader(RegisterPassable):
    var Name: UInt64
    var VirtualSize: UInt32
    var VirtualAddress: UInt32
    var SizeOfRawData: UInt32
    var PointerToRawData: UInt32
    var PointerToRelocations: UInt32
    var PointerToLinenumbers: UInt32
    var NumberOfRelocations: UInt16
    var NumberOfLinenumbers: UInt16
    var Characteristics: UInt32


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
    var path: Array[UInt16, 12] = [
        UInt16(ord("\\")),
        UInt16(ord("M")),
        UInt16(ord("O")),
        UInt16(ord("J")),
        UInt16(ord("O")),
        UInt16(ord("O")),
        UInt16(ord("S")),
        UInt16(ord(".")),
        UInt16(ord("E")),
        UInt16(ord("F")),
        UInt16(ord("I")),
        UInt16(0),
    ]
    var path_ptr = Pointer[UInt16, MutAnyOrigin](
        unsafe_from_address=Int(Pointer(to=path))
    )
    var file_handle: EFI_HANDLE = 0
    status = root[].Open(
        root, any_ptr(file_handle), path_ptr, EFI_FILE_MODE_READ, 0
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

    var raw_buf: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, file_size, any_ptr(raw_buf))
    if status != EFI_SUCCESS:
        return status

    var read_bytes = file_size
    status = file[].Read(file, any_ptr(read_bytes), raw_buf)
    if status != EFI_SUCCESS or read_bytes != file_size:
        return status if status != EFI_SUCCESS else EFI_LOAD_ERROR

    # Parse PE headers
    var dos_hdr = Pointer[ImageDosHeader, MutAnyOrigin](
        unsafe_from_address=raw_buf
    )
    if dos_hdr[].e_magic != IMAGE_DOS_SIGNATURE:
        return EFI_LOAD_ERROR

    var raw_addr = raw_buf
    var nt_headers_addr = raw_addr + Int(dos_hdr[].e_lfanew)
    var pe_sig = Pointer[UInt32, MutAnyOrigin](
        unsafe_from_address=nt_headers_addr
    ).unsafe_load()
    if pe_sig != IMAGE_NT_SIGNATURE:
        return EFI_LOAD_ERROR

    var file_hdr = Pointer[ImageFileHeader, MutAnyOrigin](
        unsafe_from_address=nt_headers_addr + 4
    )
    if file_hdr[].Machine != IMAGE_FILE_MACHINE_AMD64:
        return EFI_LOAD_ERROR

    var opt_hdr = Pointer[ImageOptionalHeader64, MutAnyOrigin](
        unsafe_from_address=nt_headers_addr + 24
    )
    if opt_hdr[].Magic != PE32PLUS_MAGIC:
        return EFI_LOAD_ERROR
    if opt_hdr[].Subsystem != IMAGE_SUBSYSTEM_NATIVE:
        return EFI_LOAD_ERROR

    var image_size = UInt64(opt_hdr[].SizeOfImage)
    var entry_rva = UInt64(opt_hdr[].AddressOfEntryPoint)
    var headers_size = UInt64(opt_hdr[].SizeOfHeaders)

    var image_base_handle: EFI_HANDLE = 0
    status = bs[].AllocatePool(2, image_size, any_ptr(image_base_handle))
    if status != EFI_SUCCESS:
        return status

    var base_ptr = Pointer[UInt8, MutAnyOrigin](
        unsafe_from_address=image_base_handle
    )
    # Zero image buffer
    for i in range(Int(image_size)):
        base_ptr[unsafe_offset=i] = 0

    # Copy headers
    var raw_ptr = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=raw_buf)
    for i in range(Int(headers_size)):
        base_ptr[unsafe_offset=i] = raw_ptr[unsafe_offset=i]

    # Map sections
    var section_hdr_addr = (
        nt_headers_addr + 24 + Int(file_hdr[].SizeOfOptionalHeader)
    )
    var section_ptr = Pointer[ImageSectionHeader, MutAnyOrigin](
        unsafe_from_address=section_hdr_addr
    )
    var num_sections = Int(file_hdr[].NumberOfSections)

    for s in range(num_sections):
        var sec = section_ptr.unsafe_offset(s)
        var raw_sec_size = Int(sec[].SizeOfRawData)
        if raw_sec_size > 0:
            var src_offset = Int(sec[].PointerToRawData)
            var dst_offset = Int(sec[].VirtualAddress)
            for b in range(raw_sec_size):
                base_ptr[unsafe_offset=dst_offset + b] = raw_ptr[
                    unsafe_offset=src_offset + b
                ]

    # Entry point
    var entry_addr = image_base_handle + Int(entry_rva)
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
