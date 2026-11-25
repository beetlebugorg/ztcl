//! `ztcl compile --wasm`: the file side of the compiler of procs to
//! WebAssembly (`src/wasm_aot/aot.zig`).
//!
//!     ztcl compile --wasm [--runtime FILE] [--record FILE]... -o OUT [SCRIPT]...
//!
//! The runtime is `ztcl-aot.wasm` from `zig build wasm-aot`. The default
//! is `../lib/ztcl-aot.wasm` next to the folder of the runner. Each
//! script adds the procs that `scan` finds in it. Each `--record` file
//! adds the procs of a run in the record mode of the runtime.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl");
const Io = std.Io;

const usage = "usage: ztcl compile --wasm [--runtime FILE] [--record FILE]... -o OUT [SCRIPT]...\n";

pub fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_w.interface;
    defer err.flush() catch {};

    var wasm_on = false;
    var runtime: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var scripts: std.ArrayList([]const u8) = .empty;
    var records: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, arg, "--wasm")) {
            wasm_on = true;
        } else if (std.mem.eql(u8, arg, "--runtime") and has_value) {
            i += 1;
            runtime = args[i];
        } else if (std.mem.eql(u8, arg, "--record") and has_value) {
            i += 1;
            try records.append(arena, args[i]);
        } else if (std.mem.eql(u8, arg, "-o") and has_value) {
            i += 1;
            out_path = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            try err.writeAll(usage);
            return 2;
        } else try scripts.append(arena, arg);
    }
    if (!wasm_on or out_path == null) {
        try err.writeAll(usage);
        return 2;
    }
    const rt_path = runtime orelse blk: {
        const dir = try std.process.executableDirPathAlloc(io, arena);
        break :blk try std.fs.path.join(arena, &.{ dir, "..", "lib", "ztcl-aot.wasm" });
    };
    const rt_bytes = Io.Dir.cwd().readFileAlloc(io, rt_path, arena, .limited(64 << 20)) catch |e| {
        try err.print("{s}: {s}. Build the runtime with zig build wasm-aot.\n", .{ rt_path, @errorName(e) });
        return 2;
    };

    var it: tcl.Interp = undefined;
    try it.init(init.gpa);
    defer it.deinit();
    // The sources point into the arena, and the bytecode is copied, so
    // the scratch interpreter needs no collection.
    it.gc_on = false;
    var sources: std.ArrayList(tcl.wasm_aot.Source) = .empty;
    for (scripts.items) |path| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch |e| {
            try err.print("{s}: {s}\n", .{ path, @errorName(e) });
            return 2;
        };
        try tcl.wasm_aot.scan(arena, &it, text, &sources, 0);
    }
    for (records.items) |path| {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20)) catch |e| {
            try err.print("{s}: {s}\n", .{ path, @errorName(e) });
            return 2;
        };
        tcl.wasm_aot.readRecord(arena, bytes, &sources) catch |e| {
            try err.print("{s}: {s}\n", .{ path, @errorName(e) });
            return 2;
        };
    }
    const res = tcl.wasm_aot.compile(init.gpa, &it, rt_bytes, sources.items) catch |e| {
        try err.print("compile: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer init.gpa.free(res.bytes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path.?, .data = res.bytes });
    try err.print("{s}: {d} procs compiled to {d} functions, {d} skipped\n", .{ out_path.?, res.compiled, res.functions, res.skipped });
    return 0;
}
