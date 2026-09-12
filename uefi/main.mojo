# The Mojo half of the smallest possible UEFI application.
#
# Compiled for x86_64-unknown-uefi where abi("C") automatically targets the
# Microsoft x64 (Win64) ABI.
from std.ffi import external_call


@export("efi_main")
def efi_main(image_handle: Int, system_table: Int) abi("C") -> Int:
    """Load MOJOOS.EFI as a native PE image and transfer control to it."""
    return external_call["uefi_load_and_boot", Int](image_handle, system_table)
