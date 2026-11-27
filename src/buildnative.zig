//! The core of `ztcl build` for native targets: a copy of a runtime
//! binary with a zip payload (docs/dev/static-build.md).
//!
//! Each runtime binary has the slot `ztcl_app_slot`: a 16-byte marker,
//! then the offset and the length of the payload in the file, each a
//! u64 in little endian. A zero length is "no payload". `bundle` finds
//! the marker in the runtime file, adds the payload at the end of the
//! file at an offset aligned to 16 bytes, and writes the offset and
//! the length into the slot of the copy. The loaders of ELF and PE map
//! only the ranges of their headers, so the payload is outside each
//! segment. A Mach-O file goes to `macho.zig`, which puts the payload
//! in `__LINKEDIT` and signs the file.
//!
//! The marker bytes are in the file once, in the slot. The code reads
//! the marker from its own slot, so no other constant has the bytes.
//! The functions here use only byte slices, so the same code can run
//! in `ztcl.wasm`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const TclVersion = @import("interp.zig").TclVersion;

pub const slot_len = 32;

/// The slot of this binary. `ztcl build` writes the last 16 bytes of
/// the slot in a copy of the file.
pub export var ztcl_app_slot: [slot_len]u8 = ("ztcl.app.slot.v1" ++ @as([16]u8, @splat(0))).*;

fn slot() *volatile [slot_len]u8 {
    return &ztcl_app_slot;
}

/// The offset and the length of the payload of this binary, or null.
pub fn payloadRange() ?struct { off: u64, len: u64 } {
    const s = slot();
    var b: [slot_len]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = s[i];
    const len = std.mem.readInt(u64, b[24..32], .little);
    if (len == 0) return null;
    return .{ .off = std.mem.readInt(u64, b[16..24], .little), .len = len };
}

fn marker() [16]u8 {
    const s = slot();
    var m: [16]u8 = undefined;
    for (&m, 0..) |*x, i| x.* = s[i];
    return m;
}

pub const Format = enum { elf, pe, macho };

pub const Error = error{ UnknownFormat, NoSlot, TwoSlots, AlreadyBundle, BadMachO, NoRoom } || Allocator.Error;

pub fn format(bin: []const u8) ?Format {
    if (bin.len < 64) return null;
    if (std.mem.eql(u8, bin[0..4], "\x7fELF")) return .elf;
    if (std.mem.eql(u8, bin[0..2], "MZ")) return .pe;
    const m = std.mem.readInt(u32, bin[0..4], .little);
    if (m == 0xfeedfacf) return .macho;
    return null;
}

/// The offset of the slot in a runtime file.
pub fn findSlot(bin: []const u8) Error!usize {
    const m = marker();
    const at = std.mem.indexOf(u8, bin, &m) orelse return error.NoSlot;
    if (std.mem.indexOfPos(u8, bin, at + 1, &m) != null) return error.TwoSlots;
    if (bin.len - at < slot_len) return error.NoSlot;
    return at;
}

/// A copy of the runtime `bin` with `payload`. `ident` is the
/// identifier of a Mach-O signature, and `ents` its entitlements.
pub fn bundle(a: Allocator, bin: []const u8, payload: []const u8, ident: []const u8, ents: []const []const u8) Error![]u8 {
    const f = format(bin) orelse return error.UnknownFormat;
    const at = try findSlot(bin);
    if (std.mem.readInt(u64, bin[at + 24 ..][0..8], .little) != 0) return error.AlreadyBundle;
    if (f == .macho) return @import("macho.zig").bundleEnts(a, bin, payload, at, ident, ents);
    const off = std.mem.alignForward(usize, bin.len, 16);
    const out = try a.alloc(u8, off + payload.len);
    @memcpy(out[0..bin.len], bin);
    @memset(out[bin.len..off], 0);
    @memcpy(out[off..], payload);
    std.mem.writeInt(u64, out[at + 16 ..][0..8], off, .little);
    std.mem.writeInt(u64, out[at + 24 ..][0..8], payload.len, .little);
    return out;
}

/// The targets of `--target`, with the name of the runtime file.
pub const targets = [_]struct { name: []const u8, file: []const u8 }{
    .{ .name = "x86_64-linux", .file = "ztcl" },
    .{ .name = "aarch64-linux", .file = "ztcl" },
    .{ .name = "x86_64-macos", .file = "ztcl" },
    .{ .name = "aarch64-macos", .file = "ztcl" },
    .{ .name = "x86_64-windows", .file = "ztcl.exe" },
    .{ .name = "aarch64-windows", .file = "ztcl.exe" },
};

/// The target name of the host.
pub fn hostTarget() []const u8 {
    const builtin = @import("builtin");
    return @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
}

/// The text of `.ztcl/manifest`.
pub const Manifest = struct {
    scripts: []const []const u8 = &.{},
    allow: []const u8 = "",
    root: ?[]const u8 = null,
    /// The JIT is on unless the manifest has `jit off`.
    jit: bool = true,
    /// The Tcl release of the program: `tcl 8.6` in the manifest, or
    /// 9.1.
    tcl: TclVersion = TclVersion.host_default,

    pub fn write(m: Manifest, a: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (m.scripts) |s| try out.print(a, "script {s}\n", .{s});
        if (m.allow.len > 0) try out.print(a, "allow {s}\n", .{m.allow});
        if (m.root) |r| try out.print(a, "root {s}\n", .{r});
        if (!m.jit) try out.appendSlice(a, "jit off\n");
        if (m.tcl != TclVersion.host_default) try out.print(a, "tcl {s}\n", .{m.tcl.version()});
        return out.items;
    }

    /// Reads the text of a manifest. Unknown lines are skipped.
    pub fn parse(a: Allocator, text: []const u8) Allocator.Error!Manifest {
        var m: Manifest = .{};
        var scripts: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = line[0..sp];
            const val = line[sp + 1 ..];
            if (std.mem.eql(u8, key, "script")) try scripts.append(a, val);
            if (std.mem.eql(u8, key, "allow")) m.allow = val;
            if (std.mem.eql(u8, key, "root")) m.root = val;
            if (std.mem.eql(u8, key, "jit")) m.jit = !std.mem.eql(u8, val, "off");
            if (std.mem.eql(u8, key, "tcl")) m.tcl = TclVersion.parse(val) orelse m.tcl;
        }
        m.scripts = scripts.items;
        return m;
    }
};

pub const manifest_name = ".ztcl/manifest";

test "buildnative: bundle writes the slot of an ELF copy" {
    const a = std.testing.allocator;
    var bin: [200]u8 = @splat(0);
    @memcpy(bin[0..4], "\x7fELF");
    const m = marker();
    @memcpy(bin[100..116], &m);
    const out = try bundle(a, &bin, "PAYLOAD", "t", &.{});
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 208 + 7), out.len);
    try std.testing.expectEqual(@as(u64, 208), std.mem.readInt(u64, out[116..124], .little));
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, out[124..132], .little));
    try std.testing.expectEqualStrings("PAYLOAD", out[208..]);
    try std.testing.expectError(error.AlreadyBundle, bundle(a, out, "x", "t", &.{}));
    @memcpy(bin[150..166], &m);
    try std.testing.expectError(error.TwoSlots, bundle(a, &bin, "x", "t", &.{}));
    try std.testing.expectError(error.UnknownFormat, bundle(a, "nope", "x", "t", &.{}));
}

test "buildnative: the manifest" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const m: Manifest = .{ .scripts = &.{ "main.tcl", "lib/a.tcl" }, .allow = "embedded,clock", .jit = false };
    const text = try m.write(arena.allocator());
    try std.testing.expectEqualStrings("script main.tcl\nscript lib/a.tcl\nallow embedded,clock\njit off\n", text);
    const back = try Manifest.parse(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 2), back.scripts.len);
    try std.testing.expectEqualStrings("lib/a.tcl", back.scripts[1]);
    try std.testing.expect(!back.jit);
    const dflt = try Manifest.parse(arena.allocator(), "script main.tcl\n");
    try std.testing.expect(dflt.jit);
    try std.testing.expectEqual(TclVersion.v9_1, dflt.tcl);
    // The release 8.6 is a line of its own, and 9.1 needs none.
    const old: Manifest = .{ .scripts = &.{"main.tcl"}, .tcl = .v8_6 };
    const old_text = try old.write(arena.allocator());
    try std.testing.expectEqualStrings("script main.tcl\ntcl 8.6\n", old_text);
    try std.testing.expectEqual(TclVersion.v8_6, (try Manifest.parse(arena.allocator(), old_text)).tcl);
}
