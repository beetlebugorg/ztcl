# References for the C variadic arguments

The variadic entry points of the C API on aarch64 Linux (`src/cext/va.zig`, issue #616) use these sources. ztcl copies no code from them.

## Procedure Call Standard for the Arm 64-bit Architecture (AAPCS64)

The calling convention of Arm for 64-bit code, with the appendix on variable argument lists: the `va_list` struct (`__stack`, `__gr_top`, `__vr_top`, `__gr_offs`, `__vr_offs`), the save areas of the general registers x0 to x7 and of the vector registers q0 to q7, and the rules of `va_arg`. https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst

**How ztcl uses it:** `va.Aapcs64` is that struct, and `Aapcs64.arg` follows the rules of `va_arg` for integers, pointers, and doubles. `va.Stub` stores the registers in the save areas, as the prologue of a C variadic function does, and makes the `va_list` for the body.

## suirad/zig-varargs

A proof of concept in Zig, under the MIT license, of C variadic functions with no support of the compiler, for x86-64 System V. https://github.com/suirad/zig-varargs

**How ztcl uses it:** the idea only, as issue #616 describes it: a function that saves the argument registers itself and reads the arguments with its own `va_arg`. No file of the project was read for this code. The code of ztcl comes from the ABI document above.
