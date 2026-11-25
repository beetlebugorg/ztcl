# Task 13: the layout probe

## Goal

Find the layout facts that machine code needs, at run time, and turn the JIT off when one is not as expected.

## Files

- `src/jit/layout.zig` (new). `src/jit.zig`: `enable` calls the probe.

## Contract

```zig
pub const Layout = struct {
    value_size: u32,          // 24 in the builds of today
    value_tag: u32,           // offset of the tag byte
    value_mask: u8,
    tag_int: u8, tag_double: u8, tag_str: u8, tag_list: u8,
    var_tag: u32,             // offset of the tag byte of Var.v from the Var
    var_mask: u8,
    var_undef: u8, var_val: u8, var_owned: u8, var_link: u8,
    var_payload: u32,         // offset of the Value or the link pointer
    entry_size: u32, entry_cell: u32,      // VarEntry
    frame_items: u32, frame_len: u32,      // Frame.vars.items pointer and length
    slice_ptr: u32, slice_len: u32,
    list_obj: u32, list_len: u32, obj_buf: u32, obj_used: u32,
    // offsets in Interp
    it_epoch: u32, it_safe_epoch: u32, it_step_limit: u32, it_mem_used: u32, it_mem_limit: u32,
    // offsets in vm.Code
    code_lits: u32, code_ins: u32,
};
pub fn probe() ?Layout;
```

## Rules

- The tag of a union: make two values with zeroed bytes that differ only in the tag (`.str` and `.list` with the same pointer and length for `Value`; `.val` and `.owned` with the same value for `Var.v`). Exactly one byte must differ. That byte is the tag offset.
- The mask is `(1 << bits) - 1` for the bit count of the tag type. For each tag of the union, a value with that tag must have `byte & mask == @intFromEnum(tag)`, and the byte must equal the tag number.
- Each payload offset is `@intFromPtr(&v.field) - @intFromPtr(&v)`. The integer, the double, the string pointer, and the list object must be at the same offset, and the two lengths at one other offset.
- A slice: make a slice with a known pointer and length and read its two words.
- Struct fields use `@offsetOf`.
- `probe` returns null when a check fails, when `value_size` is above 32, or when an offset is above 65 535.
- Machine code writes a tag as the full byte with the tag number. It reads a tag with the mask.

## Acceptance

```sh
CAP zig build test
CAP zig build test -Doptimize=ReleaseSafe
CAP zig build test -Doptimize=ReleaseFast
```

New tests: `probe` is not null on x86-64 Linux in each of the three modes; a value that the test builds byte by byte from the layout reads back as the same `Value` through Zig code, for each of the four kinds; a cell built the same way reads back for `.val` and `.link`.

## Must not change

`src/value.zig` and the types of `src/interp.zig`.
