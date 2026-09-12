# The Mojo half of the smallest possible UEFI application.
#
# Compiled with Windows / UEFI PE/COFF target where abi("C")
# automatically targets the Win64/AArch64 MSVC ABI.
from std.ffi import external_call


@export("efi_main")
def efi_main(image_handle: Int, system_table: Int) abi("C") -> Int:
    """Load kernel as Mach-O/ELF with XNU boot args and transfer control to it.
    """
    var res = external_call["uefi_load_and_boot", Int](
        image_handle, system_table
    )
    # A successful load never returns. Propagate failures to firmware rather
    # than spinning silently, so its boot manager can report the EFI status.
    return res
