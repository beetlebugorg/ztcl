//! The layout probe: the byte offsets and tag numbers that machine code
//! reads.
//!
//! `Value` and the cell of a variable are Zig tagged unions, and Zig
//! does not fix their layout. The probe finds the tag byte of a union
//! from two values that differ only in the tag: exactly one byte must
//! differ. It then checks that each tag is the full byte of its number,
//! and that the payloads of the kinds share their offsets. Struct fields
//! use `@offsetOf`, and a slice shows its two words through a known
//! pointer and length. `probe` returns null when a check fails, and the
//! JIT then stays off.
//!
//! Machine code writes a tag as the full byte with the tag number, and
//! reads a tag with the mask.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const value = @import("../value.zig");
const vm = @import("../vm.zig");

const Value = value.Value;
const Var = interp.Var;
const Interp = interp.Interp;

pub const Layout = struct {
    value_size: u32,
    /// The offset of the tag byte.
    value_tag: u32,
    value_mask: u8,
    tag_int: u8,
    tag_double: u8,
    tag_str: u8,
    tag_list: u8,
    /// The offset of the integer, the double, the string pointer, and the
    /// list object. `value_len` is the offset of the two lengths.
    value_payload: u32,
    value_len: u32,
    /// The offset of the tag byte of `Var.v`, from the start of the `Var`.
    var_tag: u32,
    var_mask: u8,
    var_undef: u8,
    var_val: u8,
    var_owned: u8,
    var_link: u8,
    /// The offset of the `Value` or the link pointer in a `Var`.
    var_payload: u32,
    /// `VarEntry`.
    entry_size: u32,
    entry_cell: u32,
    /// The offsets of the pointer and the length of `Frame.vars.items`.
    frame_items: u32,
    frame_len: u32,
    slice_ptr: u32,
    slice_len: u32,
    /// `List` in a `Value`, and `ListObj`.
    list_obj: u32,
    list_len: u32,
    obj_buf: u32,
    obj_buf_len: u32,
    obj_used: u32,
    obj_dict_len: u32,
    obj_index: u32,
    // Offsets in `Interp`.
    it_epoch: u32,
    it_safe_epoch: u32,
    it_step_limit: u32,
    it_mem_used: u32,
    /// `counter.trip`: the count that the limit check of a step reads.
    it_mem_trip: u32,
    it_mem_limit: u32,
    /// `Interp.ns.ptr`.
    it_ns: u32,
    /// The fields of a command site that `Interp.resolve` checks.
    cmd_resolved: u32,
    cmd_epoch: u32,
    cmd_ns: u32,
    code_sites: u32,
    // The offsets of the pointers of `Code.lits` and `Code.ins`.
    code_lits: u32,
    code_ins: u32,
    ins_size: u32,
};

const max_offset = 65535;

/// The offset of the one byte that differs, or null.
fn oneDiff(a: []const u8, b: []const u8) ?u32 {
    var at: ?u32 = null;
    for (a, b, 0..) |x, y, i| {
        if (x == y) continue;
        if (at != null) return null;
        at = @intCast(i);
    }
    return at;
}

fn zeroed(comptime T: type) T {
    var v: T = undefined;
    @memset(std.mem.asBytes(&v), 0);
    return v;
}

fn offset(base: anytype, field: anytype) u32 {
    return @intCast(@intFromPtr(field) - @intFromPtr(base));
}

/// The two words of a slice: the offset of the pointer and of the length.
fn sliceWords() ?[2]u32 {
    const bytes = [_]u8{0} ** 8;
    const s: []const u8 = bytes[0..5];
    var words: [2]usize = undefined;
    @memcpy(std.mem.asBytes(&words), std.mem.asBytes(&s));
    if (words[0] == @intFromPtr(&bytes) and words[1] == 5) return .{ 0, 8 };
    if (words[1] == @intFromPtr(&bytes) and words[0] == 5) return .{ 8, 0 };
    return null;
}

pub fn probe() ?Layout {
    var l: Layout = undefined;
    if (@sizeOf([]const u8) != 16) return null;
    const sw = sliceWords() orelse return null;
    l.slice_ptr = sw[0];
    l.slice_len = sw[1];

    // The tag of a Value.
    l.value_size = @sizeOf(Value);
    if (l.value_size > 32) return null;
    const VTag = std.meta.Tag(Value);
    var obj = zeroed(value.ListObj);
    const text: []const u8 = @as([*]const u8, @ptrCast(&obj))[0..3];
    var vs = zeroed(Value);
    vs = .{ .str = text };
    var vl = zeroed(Value);
    vl = .{ .list = .{ .obj = &obj, .len = 3 } };
    l.value_tag = oneDiff(std.mem.asBytes(&vs), std.mem.asBytes(&vl)) orelse return null;
    l.value_mask = @intCast((1 << @bitSizeOf(VTag)) - 1);
    var vi = zeroed(Value);
    vi = .{ .int = -2 };
    var vd = zeroed(Value);
    vd = .{ .double = 1.5 };
    const kinds = [_]*const Value{ &vi, &vd, &vs, &vl };
    const tags = [_]VTag{ .int, .double, .str, .list };
    for (kinds, tags) |v, t| {
        const b = std.mem.asBytes(v)[l.value_tag];
        if (b != @intFromEnum(t) or b & l.value_mask != @intFromEnum(t)) return null;
    }
    l.tag_int = @intFromEnum(VTag.int);
    l.tag_double = @intFromEnum(VTag.double);
    l.tag_str = @intFromEnum(VTag.str);
    l.tag_list = @intFromEnum(VTag.list);

    // The payloads of a Value.
    l.value_payload = offset(&vi, &vi.int);
    if (offset(&vd, &vd.double) != l.value_payload) return null;
    l.list_obj = offset(&vl.list, &vl.list.obj);
    l.list_len = offset(&vl.list, &vl.list.len);
    const str_ptr = offset(&vs, &vs.str) + l.slice_ptr;
    const str_len = offset(&vs, &vs.str) + l.slice_len;
    if (str_ptr != l.value_payload) return null;
    if (offset(&vl, &vl.list) + l.list_obj != l.value_payload) return null;
    l.value_len = str_len;
    if (offset(&vl, &vl.list) + l.list_len != l.value_len) return null;
    // The payload words come before the tag.
    if (l.value_payload + 8 > l.value_tag or l.value_len + 8 > l.value_tag) return null;

    // The tag of a cell.
    const CTag = std.meta.Tag(@TypeOf(@as(Var, undefined).v));
    var cv = zeroed(Var);
    cv.v = .{ .val = vi };
    var co = zeroed(Var);
    co.v = .{ .owned = vi };
    l.var_tag = oneDiff(std.mem.asBytes(&cv), std.mem.asBytes(&co)) orelse return null;
    l.var_mask = @intCast((1 << @bitSizeOf(CTag)) - 1);
    l.var_payload = offset(&cv, &cv.v.val);
    if (offset(&co, &co.v.owned) != l.var_payload) return null;
    var ck = zeroed(Var);
    ck.v = .{ .link = &cv };
    if (offset(&ck, &ck.v.link) != l.var_payload) return null;
    var cu = zeroed(Var);
    cu.v = .undef;
    var array = zeroed(interp.ArrayMap);
    var ca = zeroed(Var);
    ca.v = .{ .arr = &array };
    const cells = [_]*const Var{ &cu, &cv, &co, &ck, &ca };
    const ctags = [_]CTag{ .undef, .val, .owned, .link, .arr };
    for (cells, ctags) |c, t| {
        const b = std.mem.asBytes(c)[l.var_tag];
        if (b != @intFromEnum(t) or b & l.var_mask != @intFromEnum(t)) return null;
    }
    // The tag byte is outside the Value of the cell.
    if (l.var_tag >= l.var_payload and l.var_tag < l.var_payload + l.value_size) return null;
    l.var_undef = @intFromEnum(CTag.undef);
    l.var_val = @intFromEnum(CTag.val);
    l.var_owned = @intFromEnum(CTag.owned);
    l.var_link = @intFromEnum(CTag.link);

    // Structs.
    l.entry_size = @sizeOf(interp.VarEntry);
    l.entry_cell = @offsetOf(interp.VarEntry, "cell");
    const vars = @offsetOf(interp.Frame, "vars") + @offsetOf(std.ArrayList(interp.VarEntry), "items");
    l.frame_items = vars + l.slice_ptr;
    l.frame_len = vars + l.slice_len;
    l.obj_buf = @offsetOf(value.ListObj, "buf") + l.slice_ptr;
    l.obj_buf_len = @offsetOf(value.ListObj, "buf") + l.slice_len;
    l.obj_used = @offsetOf(value.ListObj, "used");
    l.obj_dict_len = @offsetOf(value.ListObj, "dict_len");
    l.obj_index = @offsetOf(value.ListObj, "index");
    if (@sizeOf(@FieldType(value.ListObj, "index")) != 8 or @sizeOf(@FieldType(value.ListObj, "dict_len")) != 8) return null;
    l.it_epoch = @offsetOf(Interp, "epoch");
    l.it_safe_epoch = @offsetOf(Interp, "safe_epoch");
    l.it_step_limit = @offsetOf(Interp, "step_limit");
    const counter = @offsetOf(Interp, "counter");
    l.it_mem_used = counter + @offsetOf(interp.Counting, "used");
    l.it_mem_trip = counter + @offsetOf(interp.Counting, "trip");
    l.it_mem_limit = @offsetOf(Interp, "mem_limit");
    l.it_ns = @offsetOf(Interp, "ns") + l.slice_ptr;
    l.cmd_resolved = @offsetOf(interp.Cmd, "resolved");
    l.cmd_epoch = @offsetOf(interp.Cmd, "epoch");
    l.cmd_ns = @offsetOf(interp.Cmd, "ns");
    if (@sizeOf(@FieldType(interp.Cmd, "epoch")) != 4 or @sizeOf(@FieldType(Interp, "epoch")) != 4) return null;
    if (@sizeOf(@FieldType(interp.Cmd, "resolved")) != 8) return null;
    l.code_sites = @offsetOf(vm.Code, "sites") + l.slice_ptr;
    l.code_lits = @offsetOf(vm.Code, "lits") + l.slice_ptr;
    l.code_ins = @offsetOf(vm.Code, "ins") + l.slice_ptr;
    l.ins_size = @sizeOf(vm.Ins);
    if (l.ins_size != 16 or @offsetOf(vm.Ins, "b") != 8) return null;

    inline for (std.meta.fields(Layout)) |f| {
        if (f.type == u32 and @field(l, f.name) > max_offset) return null;
    }
    return l;
}
