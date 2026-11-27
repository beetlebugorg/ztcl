//! A pass after the link of a WebAssembly module: it writes each LEB128
//! number of the code section in its shortest form (issue #294).
//!
//! The linker writes each number that it relocates (the function index
//! of a `call`, a memory address, a global index) as a LEB128 number
//! padded to 5 bytes. The pass reads each function body with a table of
//! the operand kinds of each opcode and writes the body again with short
//! numbers. It also writes the size of each body and of each section in
//! the shortest form. No index changes, so the other sections keep their
//! bytes.
//!
//! `wasm-pack IN OUT` writes the packed module to OUT. `wasm-pack --check
//! IN` reads the module, packs it, and checks the output: each body ends
//! with `end` at the last byte of the body, and a second pass of the
//! output gives the same bytes. The exit code is 1 for an error.
//!
//! An opcode that is not in the table stops the pass with an error, so
//! a new instruction from the compiler fails the build.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{ BadModule, UnknownOpcode, OutOfMemory };

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.bytes.len) return error.BadModule;
        r.pos += 1;
        return r.bytes[r.pos - 1];
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.bytes.len - r.pos) return error.BadModule;
        r.pos += n;
        return r.bytes[r.pos - n .. r.pos];
    }

    /// An unsigned LEB128 number of at most `bits` bits.
    fn uleb(r: *Reader, comptime bits: u7) Error!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            if (shift >= 64) return error.BadModule;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) break;
            if (shift >= bits + 7) return error.BadModule;
        }
        if (bits < 64 and v >> @intCast(bits) != 0) return error.BadModule;
        return v;
    }

    /// A signed LEB128 number of at most 64 bits.
    fn sleb(r: *Reader) Error!i64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        var b: u8 = 0;
        while (true) {
            b = try r.byte();
            if (shift >= 64) return error.BadModule;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) break;
            if (shift >= 70) return error.BadModule;
        }
        if (shift < 64 and b & 0x40 != 0) v |= ~@as(u64, 0) << @intCast(shift);
        return @bitCast(v);
    }
};

const Out = struct {
    list: std.ArrayList(u8) = .empty,
    a: Allocator,

    fn byte(o: *Out, b: u8) Error!void {
        try o.list.append(o.a, b);
    }

    fn bytes(o: *Out, s: []const u8) Error!void {
        try o.list.appendSlice(o.a, s);
    }

    fn uleb(o: *Out, v0: u64) Error!void {
        var v = v0;
        while (true) {
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) return o.byte(b);
            try o.byte(b | 0x80);
        }
    }

    fn sleb(o: *Out, v0: i64) Error!void {
        var v = v0;
        while (true) {
            const b: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if ((v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0)) return o.byte(b);
            try o.byte(b | 0x80);
        }
    }
};

/// Copies an unsigned LEB128 number of at most 32 bits.
fn u32Op(r: *Reader, o: *Out) Error!void {
    try o.uleb(try r.uleb(32));
}

/// Copies a memory argument: the alignment, the memory index when bit 6
/// of the alignment is set (multiple memories), and the offset.
fn memarg(r: *Reader, o: *Out) Error!void {
    const al = try r.uleb(32);
    try o.uleb(al);
    if (al & 0x40 != 0) try u32Op(r, o);
    try o.uleb(try r.uleb(64));
}

/// Copies a block type: 0x40, one value type, or a type index (s33).
fn blockType(r: *Reader, o: *Out) Error!void {
    if (r.pos >= r.bytes.len) return error.BadModule;
    const b = r.bytes[r.pos];
    if (b == 0x40 or (b >= 0x6f and b <= 0x7f)) {
        r.pos += 1;
        return o.byte(b);
    }
    const v = try r.sleb();
    if (v < 0) return error.BadModule;
    try o.sleb(v);
}

/// The operands of the opcodes after the prefix 0xFC.
fn prefixFC(r: *Reader, o: *Out) Error!void {
    const sub = try r.uleb(32);
    try o.uleb(sub);
    switch (sub) {
        0...7 => {},
        8, 10, 12, 14 => {
            try u32Op(r, o);
            try u32Op(r, o);
        },
        9, 11, 13, 15, 16, 17 => try u32Op(r, o),
        else => return error.UnknownOpcode,
    }
}

/// The operands of the opcodes after the prefix 0xFD (SIMD and relaxed SIMD).
fn prefixFD(r: *Reader, o: *Out) Error!void {
    const sub = try r.uleb(32);
    try o.uleb(sub);
    switch (sub) {
        0...11, 92, 93 => try memarg(r, o),
        12, 13 => try o.bytes(try r.take(16)),
        21...34 => try o.byte(try r.byte()),
        84...91 => {
            try memarg(r, o);
            try o.byte(try r.byte());
        },
        14...20, 35...83, 94...255, 256...275 => {},
        else => return error.UnknownOpcode,
    }
}

/// The operands of the opcodes after the prefix 0xFE (threads).
fn prefixFE(r: *Reader, o: *Out) Error!void {
    const sub = try r.uleb(32);
    try o.uleb(sub);
    switch (sub) {
        0...2, 0x10...0x4e => try memarg(r, o),
        3 => try o.byte(try r.byte()),
        else => return error.UnknownOpcode,
    }
}

/// Copies one function body (after its size) with short numbers.
fn body(r: *Reader, o: *Out) Error!void {
    const groups = try r.uleb(32);
    try o.uleb(groups);
    for (0..groups) |_| {
        try u32Op(r, o);
        const t = try r.byte();
        if (t < 0x6f or t > 0x7f) return error.BadModule;
        try o.byte(t);
    }
    var depth: usize = 0;
    while (true) {
        const op = try r.byte();
        try o.byte(op);
        switch (op) {
            0x00, 0x01, 0x05, 0x0f, 0x1a, 0x1b, 0x45...0xc4, 0xd1, 0xd3, 0xd4 => {},
            0x02, 0x03, 0x04 => {
                try blockType(r, o);
                depth += 1;
            },
            0x0b => {
                if (depth == 0) {
                    if (r.pos != r.bytes.len) return error.BadModule;
                    return;
                }
                depth -= 1;
            },
            0x0c, 0x0d, 0x10, 0x12, 0x20...0x26, 0x3f, 0x40, 0xd2, 0xd5, 0xd6 => try u32Op(r, o),
            0x0e => {
                const n = try r.uleb(32);
                try o.uleb(n);
                for (0..n + 1) |_| try u32Op(r, o);
            },
            0x11, 0x13 => {
                try u32Op(r, o);
                try u32Op(r, o);
            },
            0x1c => {
                const n = try r.uleb(32);
                try o.uleb(n);
                try o.bytes(try r.take(n));
            },
            0x28...0x3e => try memarg(r, o),
            0x41 => {
                const v = try r.sleb();
                if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.BadModule;
                try o.sleb(v);
            },
            0x42 => try o.sleb(try r.sleb()),
            0x43 => try o.bytes(try r.take(4)),
            0x44 => try o.bytes(try r.take(8)),
            0xd0 => {
                const h = try r.byte();
                if (h & 0x80 != 0) return error.UnknownOpcode;
                try o.byte(h);
            },
            0xfc => try prefixFC(r, o),
            0xfd => try prefixFD(r, o),
            0xfe => try prefixFE(r, o),
            else => return error.UnknownOpcode,
        }
    }
}

/// The position in the input of the last error, for the message.
pub var err_pos: usize = 0;

/// Returns the module with short numbers in the code section and short
/// sizes of the sections and the bodies.
pub fn pack(a: Allocator, in: []const u8) Error![]u8 {
    if (in.len < 8 or !std.mem.eql(u8, in[0..8], "\x00asm\x01\x00\x00\x00")) return error.BadModule;
    var r: Reader = .{ .bytes = in, .pos = 8 };
    var o: Out = .{ .a = a };
    errdefer o.list.deinit(a);
    try o.bytes(in[0..8]);
    var sec: Out = .{ .a = a };
    defer sec.list.deinit(a);
    while (r.pos < in.len) {
        const id = try r.byte();
        const len = try r.uleb(32);
        const start = r.pos;
        const content = try r.take(len);
        try o.byte(id);
        if (id != 10) {
            try o.uleb(content.len);
            try o.bytes(content);
            continue;
        }
        sec.list.clearRetainingCapacity();
        var cr: Reader = .{ .bytes = content };
        const n = try cr.uleb(32);
        try sec.uleb(n);
        var fb: Out = .{ .a = a };
        defer fb.list.deinit(a);
        for (0..n) |_| {
            const size = try cr.uleb(32);
            const at = cr.pos;
            var br: Reader = .{ .bytes = try cr.take(size) };
            fb.list.clearRetainingCapacity();
            body(&br, &fb) catch |e| {
                err_pos = start + at + br.pos;
                return e;
            };
            try sec.uleb(fb.list.items.len);
            try sec.bytes(fb.list.items);
        }
        if (cr.pos != content.len) return error.BadModule;
        try o.uleb(sec.list.items.len);
        try o.bytes(sec.list.items);
    }
    return o.list.toOwnedSlice(a);
}

/// Packs `in` and checks the output: a second pack gives the same bytes,
/// and each body of the output ends with `end` at its last byte.
pub fn packChecked(a: Allocator, in: []const u8) Error![]u8 {
    const out = try pack(a, in);
    const again = try pack(a, out);
    defer a.free(again);
    if (!std.mem.eql(u8, out, again)) return error.BadModule;
    return out;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const check = args.len == 3 and std.mem.eql(u8, args[1], "--check");
    if (!check and args.len != 3) {
        std.debug.print("usage: wasm-pack IN OUT | wasm-pack --check IN\n", .{});
        std.process.exit(2);
    }
    const in_path = if (check) args[2] else args[1];
    const in = try Io.Dir.cwd().readFileAlloc(io, in_path, a, .limited(256 << 20));
    const out = packChecked(a, in) catch |e| {
        std.debug.print("wasm-pack: {s}: {t} at byte {d}\n", .{ in_path, e, err_pos });
        std.process.exit(1);
    };
    if (check) {
        std.debug.print("{s}: {d} bytes, {d} packed\n", .{ in_path, in.len, out.len });
        return;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out });
}

test "padded numbers get short" {
    const a = std.testing.allocator;
    // A module with one type () -> i32, one function, and a code section
    // with padded numbers: the section size, the body size, an i32.const
    // -1 in 5 bytes, a call 0 in 5 bytes, and a load with a padded offset.
    const in = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++ // type
        "\x03\x02\x01\x00" ++ // function
        "\x0a\x9b\x80\x80\x80\x00\x01" ++ // code, size 27
        "\x95\x80\x80\x80\x00" ++ // body size 21
        "\x00" ++ // no locals
        "\x41\xff\xff\xff\xff\x7f" ++ // i32.const -1
        "\x10\x80\x80\x80\x80\x00" ++ // call 0
        "\x1a" ++ // drop
        "\x28\x02\x84\x80\x80\x00" ++ // i32.load align 2 offset 4
        "\x0b";
    const out = try packChecked(a, in);
    defer a.free(out);
    const want = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x0a\x0c\x01" ++
        "\x0a" ++
        "\x00" ++
        "\x41\x7f" ++
        "\x10\x00" ++
        "\x1a" ++
        "\x28\x02\x04" ++
        "\x0b";
    try std.testing.expectEqualSlices(u8, want, out);
}

test "signed numbers keep their values" {
    const a = std.testing.allocator;
    const vals = [_]i64{ 0, 1, -1, 63, 64, -64, -65, std.math.maxInt(i32), std.math.minInt(i32), std.math.maxInt(i64), std.math.minInt(i64) };
    for (vals) |v| {
        var o: Out = .{ .a = a };
        defer o.list.deinit(a);
        try o.sleb(v);
        var r: Reader = .{ .bytes = o.list.items };
        try std.testing.expectEqual(v, try r.sleb());
        try std.testing.expectEqual(o.list.items.len, r.pos);
    }
}

test "an unknown opcode is an error" {
    const a = std.testing.allocator;
    const in = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x03\x02\x01\x00" ++
        "\x0a\x05\x01\x03\x00\x06\x0b";
    try std.testing.expectError(error.UnknownOpcode, pack(a, in));
}
