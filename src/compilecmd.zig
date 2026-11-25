//! `ztcl compile FILE -proc NAME -o OUT.wasm [-simd on|off]
//! [-max-mem BYTES] [-features a,b,...]`
//!
//! Runs FILE in an interpreter with `point proc`, checks and compiles
//! the point proc NAME, and writes its standalone WebAssembly module
//! (`src/point_wasm.zig`). A proc that fails the check gives the error
//! of the check, with the line and the reason.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const tcl = @import("ztcl");
const point = tcl.point;

const usage = "usage: ztcl compile FILE -proc NAME -o OUT.wasm ?-simd on|off? ?-max-mem BYTES? ?-features a,b,...?\n";

pub fn run(io: Io, gpa: std.mem.Allocator, a: std.mem.Allocator, args: []const [:0]const u8, out: *Io.Writer) !u8 {
    var file: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var opts: tcl.point_wasm.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "-proc") and value != null) {
            name = value;
        } else if (std.mem.eql(u8, arg, "-o") and value != null) {
            output = value;
        } else if (std.mem.eql(u8, arg, "-simd") and value != null) {
            if (std.mem.eql(u8, value.?, "on")) {
                opts.simd = true;
            } else if (std.mem.eql(u8, value.?, "off")) {
                opts.simd = false;
            } else {
                try out.writeAll(usage);
                return 2;
            }
        } else if (std.mem.eql(u8, arg, "-max-mem") and value != null) {
            opts.max_mem = std.fmt.parseInt(u64, value.?, 10) catch {
                try out.print("bad -max-mem \"{s}\"\n", .{value.?});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-features") and value != null) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, value.?, ',');
            while (it.next()) |f| try list.append(a, f);
            opts.features = list.items;
        } else if (file == null and arg.len > 0 and arg[0] != '-') {
            file = arg;
            continue;
        } else {
            try out.writeAll(usage);
            return 2;
        }
        i += 1;
    }
    if (file == null or name == null or output == null) {
        try out.writeAll(usage);
        return 2;
    }
    const text = Io.Dir.cwd().readFileAlloc(io, file.?, a, .limited(64 << 20)) catch |e| {
        try out.print("cannot read {s}: {s}\n", .{ file.?, @errorName(e) });
        return 1;
    };
    var interp: tcl.Interp = undefined;
    try interp.init(gpa);
    defer interp.deinit();
    var state: point.State = .{ .features = opts.features };
    try point.install(&interp, &state);
    _ = interp.eval(text) catch {
        try out.print("{s}\n", .{try interp.str(interp.result)});
        return 1;
    };
    const prog = state.program(name.?) orelse {
        try out.print("\"{s}\" is not a point proc\n", .{name.?});
        return 1;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    opts.source_sha256 = &hex;
    const compiled = tcl.point_wasm.compile(a, prog, opts) catch |e| {
        try out.print("cannot compile \"{s}\": {s}\n", .{ name.?, @errorName(e) });
        return 1;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = output.?, .data = compiled.bytes }) catch |e| {
        try out.print("cannot write {s}: {s}\n", .{ output.?, @errorName(e) });
        return 1;
    };
    return 0;
}
