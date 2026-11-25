//! A bundle: Tcl scripts and read-only files in a copy of ztcl.wasm.
//!
//! `ztcl build --wasm` writes the bundle. The scripts and the files go
//! in a new active data segment above the initial memory of the module.
//! The patch makes the initial memory larger by the pages of the
//! segment, so the segment is in memory at the start. The allocator of
//! ztcl.wasm gets new pages from `memory.grow`, so it does not write to
//! the pages of the segment. The patch also writes the address and the
//! length of the segment into the slot of `src/wasm.zig`.
//!
//! The payload has this form, with each number a u32 in little endian:
//!
//!     "ZTB1" count
//!     count times: kind name_len data_len name data
//!
//! `kind` is one byte: 0 for a script and 1 for a file.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "ZTB1";

/// The first 8 bytes of the slot in `src/wasm.zig`. The next 4 bytes
/// are the address of the payload and the last 4 are its length. The
/// value 0xffffffff in both is "no bundle".
pub const slot_marker = "ztclbndl";
pub const slot_words = [4]u32{ 0x6c63747a, 0x6c646e62, 0xffffffff, 0xffffffff };

comptime {
    std.debug.assert(std.mem.eql(u8, std.mem.asBytes(&slot_words)[0..8], slot_marker));
}

pub const Kind = enum(u8) { script = 0, file = 1 };

pub const Entry = struct {
    kind: Kind,
    name: []const u8,
    data: []const u8,
};

/// Writes the payload of `entries`.
pub fn encode(a: Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic);
    try putU32(a, &out, entries.len);
    for (entries) |e| {
        try out.append(a, @intFromEnum(e.kind));
        try putU32(a, &out, e.name.len);
        try putU32(a, &out, e.data.len);
        try out.appendSlice(a, e.name);
        try out.appendSlice(a, e.data);
    }
    return out.toOwnedSlice(a);
}

fn putU32(a: Allocator, out: *std.ArrayList(u8), n: usize) !void {
    if (n > std.math.maxInt(u32)) return error.TooLarge;
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(n), .little);
    try out.appendSlice(a, &b);
}

/// Reads the entries of a payload. A bad payload gives no entries.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 8,
    left: u32 = 0,

    pub fn init(bytes: []const u8) Reader {
        if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], magic)) return .{ .bytes = &.{} };
        return .{ .bytes = bytes, .left = std.mem.readInt(u32, bytes[4..8], .little) };
    }

    pub fn next(r: *Reader) ?Entry {
        if (r.left == 0 or r.bytes.len - r.pos < 9) return null;
        const b = r.bytes[r.pos..];
        const kind = std.enums.fromInt(Kind, b[0]) orelse return null;
        const nl = std.mem.readInt(u32, b[1..5], .little);
        const dl = std.mem.readInt(u32, b[5..9], .little);
        if (b.len - 9 < @as(u64, nl) + dl) return null;
        r.pos += 9 + nl + dl;
        r.left -= 1;
        return .{ .kind = kind, .name = b[9..][0..nl], .data = b[9 + nl ..][0..dl] };
    }
};

pub const PatchError = error{ NotWasm, BadModule, NoSlot, AlreadyBundle, TooLarge, OutOfMemory };

const page = 65536;

const Section = struct { id: u8, start: usize, body: usize, end: usize };

const Cursor = struct {
    b: []const u8,
    pos: usize,

    fn byte(c: *Cursor) PatchError!u8 {
        if (c.pos >= c.b.len) return error.BadModule;
        c.pos += 1;
        return c.b[c.pos - 1];
    }

    fn uleb(c: *Cursor) PatchError!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const x = try c.byte();
            v |= @as(u64, x & 0x7f) << @intCast(shift);
            if (x & 0x80 == 0) return v;
            shift += 7;
            if (shift >= 64) return error.BadModule;
        }
    }

    fn skip(c: *Cursor, n: u64) PatchError!void {
        if (n > c.b.len - c.pos) return error.BadModule;
        c.pos += @intCast(n);
    }

    /// Skips a constant expression: `i32.const` or `global.get`, then `end`.
    fn constExpr(c: *Cursor) PatchError!void {
        switch (try c.byte()) {
            0x41, 0x23 => _ = try c.uleb(),
            else => return error.BadModule,
        }
        if (try c.byte() != 0x0b) return error.BadModule;
    }
};

fn putUleb(a: Allocator, out: *std.ArrayList(u8), v: u64) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) return out.append(a, b);
        try out.append(a, b | 0x80);
    }
}

fn putSleb(a: Allocator, out: *std.ArrayList(u8), v: i64) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if ((x == 0 and b & 0x40 == 0) or (x == -1 and b & 0x40 != 0)) return out.append(a, b);
        try out.append(a, b | 0x80);
    }
}

fn putSection(a: Allocator, out: *std.ArrayList(u8), id: u8, body: []const u8) !void {
    try out.append(a, id);
    try putUleb(a, out, body.len);
    try out.appendSlice(a, body);
}

/// Gives a copy of the module `base` with `payload` in a new data
/// segment. `base` is a ztcl.wasm with its own memory and the slot of
/// `src/wasm.zig`.
pub fn patch(a: Allocator, base: []const u8, payload: []const u8) PatchError![]u8 {
    if (base.len < 8 or !std.mem.eql(u8, base[0..8], "\x00asm\x01\x00\x00\x00")) return error.NotWasm;
    var sections: std.ArrayList(Section) = .empty;
    defer sections.deinit(a);
    var c: Cursor = .{ .b = base, .pos = 8 };
    while (c.pos < base.len) {
        const start = c.pos;
        const id = try c.byte();
        const len = try c.uleb();
        const body = c.pos;
        try c.skip(len);
        try sections.append(a, .{ .id = id, .start = start, .body = body, .end = c.pos });
    }

    // The memory section: one memory with i32 addresses and no sharing.
    var mem_min: u64 = 0;
    var mem_max: ?u64 = null;
    var have_mem = false;
    // The data section: the count of segments and the place of the slot.
    var data_count: u64 = 0;
    var slot: ?usize = null;
    for (sections.items) |s| {
        var r: Cursor = .{ .b = base[0..s.end], .pos = s.body };
        if (s.id == 5) {
            if (try r.uleb() != 1) return error.BadModule;
            const flags = try r.byte();
            if (flags > 1) return error.BadModule;
            mem_min = try r.uleb();
            if (flags == 1) mem_max = try r.uleb();
            have_mem = true;
        } else if (s.id == 11) {
            data_count = try r.uleb();
            for (0..data_count) |_| {
                switch (try r.uleb()) {
                    0 => try r.constExpr(),
                    1 => {},
                    2 => {
                        _ = try r.uleb();
                        try r.constExpr();
                    },
                    else => return error.BadModule,
                }
                const n = try r.uleb();
                const seg = base[r.pos..][0..@min(n, s.end - r.pos)];
                try r.skip(n);
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, seg, from, slot_marker)) |k| : (from = k + 1) {
                    if (seg.len - k < 16) continue;
                    if (slot != null) return error.NoSlot;
                    slot = @intFromPtr(seg.ptr) - @intFromPtr(base.ptr) + k;
                }
            }
        }
    }
    if (!have_mem) return error.BadModule;
    const at = slot orelse return error.NoSlot;
    if (std.mem.readInt(u32, base[at + 8 ..][0..4], .little) != 0xffffffff) return error.AlreadyBundle;

    const addr = mem_min * page;
    const new_min = mem_min + (payload.len + page - 1) / page;
    if (new_min > 65536 or payload.len > std.math.maxInt(u32)) return error.TooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try out.appendSlice(a, base[0..8]);
    for (sections.items) |s| {
        body.clearRetainingCapacity();
        switch (s.id) {
            5 => {
                try body.append(a, 1);
                try body.append(a, @intFromBool(mem_max != null));
                try putUleb(a, &body, new_min);
                if (mem_max) |m| try putUleb(a, &body, @max(m, new_min));
                try putSection(a, &out, 5, body.items);
            },
            12 => {
                var r: Cursor = .{ .b = base[0..s.end], .pos = s.body };
                try putUleb(a, &body, try r.uleb() + 1);
                try putSection(a, &out, 12, body.items);
            },
            11 => {
                var r: Cursor = .{ .b = base[0..s.end], .pos = s.body };
                _ = try r.uleb();
                try putUleb(a, &body, data_count + 1);
                const old = body.items.len;
                try body.appendSlice(a, base[r.pos..s.end]);
                // The slot: the address and the length of the payload.
                const k = old + (at - r.pos);
                std.mem.writeInt(u32, body.items[k + 8 ..][0..4], @intCast(addr), .little);
                std.mem.writeInt(u32, body.items[k + 12 ..][0..4], @intCast(payload.len), .little);
                try body.append(a, 0);
                try body.append(a, 0x41);
                try putSleb(a, &body, @as(i32, @bitCast(@as(u32, @intCast(addr)))));
                try body.append(a, 0x0b);
                try putUleb(a, &body, payload.len);
                try body.appendSlice(a, payload);
                try putSection(a, &out, 11, body.items);
            },
            else => try out.appendSlice(a, base[s.start..s.end]),
        }
    }
    return out.toOwnedSlice(a);
}

test "a payload reads back" {
    const a = std.testing.allocator;
    const p = try encode(a, &.{
        .{ .kind = .script, .name = "app.tcl", .data = "puts hi" },
        .{ .kind = .file, .name = "data/a.txt", .data = "" },
    });
    defer a.free(p);
    var r: Reader = .init(p);
    const e1 = r.next().?;
    try std.testing.expectEqualStrings("app.tcl", e1.name);
    try std.testing.expectEqualStrings("puts hi", e1.data);
    try std.testing.expectEqual(Kind.file, r.next().?.kind);
    try std.testing.expect(r.next() == null);
    // A cut payload gives fewer entries and no read past the end.
    var cut: Reader = .init(p[0 .. p.len - 12]);
    try std.testing.expect(cut.next() != null);
    try std.testing.expect(cut.next() == null);
}

test "the patch adds a segment, grows the memory, and fills the slot" {
    const a = std.testing.allocator;
    // A module with a memory of 2 pages and one data segment at 1024
    // that has the slot.
    const seg = "abcd" ++ slot_marker ++ "\xff" ** 8;
    const base = "\x00asm\x01\x00\x00\x00" ++
        "\x05\x03\x01\x00\x02" ++
        "\x0b\x1b\x01\x00\x41\x80\x08\x0b\x14" ++ seg;
    const payload = "ZTB1\x00\x00\x00\x00";
    const m = try patch(a, base, payload);
    defer a.free(m);
    // The memory has 3 pages.
    try std.testing.expectEqualSlices(u8, "\x05\x03\x01\x00\x03", m[8..13]);
    // The slot has the address 2 * 65536 and the length.
    const k = std.mem.indexOf(u8, m, slot_marker).?;
    try std.testing.expectEqual(@as(u32, 2 * page), std.mem.readInt(u32, m[k + 8 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, payload.len), std.mem.readInt(u32, m[k + 12 ..][0..4], .little));
    // Two segments, and the second is the payload.
    try std.testing.expect(std.mem.endsWith(u8, m, payload));
    try std.testing.expectError(error.AlreadyBundle, patch(a, m, payload));
    try std.testing.expectError(error.NotWasm, patch(a, "nope", payload));
}
