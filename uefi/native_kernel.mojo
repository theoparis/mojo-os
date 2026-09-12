# Minimal payload for the manual PE loader. This is a native subsystem image
# that receives the system table pointer.
from std.ffi import external_call


@export("native_kernel_main")
def native_kernel_main(system_table: Int) abi("C") -> Int:
    _ = external_call["native_hello", Int](system_table)
    while True:
        pass
