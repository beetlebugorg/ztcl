//! `ztcl build --wasm [--base FILE] [--embed PATH]... -o OUT script.tcl...`
//!
//! Writes a copy of ztcl.wasm with the scripts and the files in it. The
//! module runs the scripts in order, as `ztcl a.tcl b.tcl` does. The
//! files of `--embed` are under `//zipfs:/app/` with the path as given.
//! A folder adds each file below it. See src/wasmbundle.zig.
//!
//! The base module is the file of `--base`, or of the environment
//! variable ZTCL_WASM, or `../lib/ztcl.wasm` next to the folder of the
//! program. The command needs no Zig toolchain.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const tcl = @import("ztcl");
const wb = tcl.wasmbundle;

const usage = "usage: ztcl build --wasm [--base ztcl.wasm] [--embed PATH]... -o OUT.wasm script.tcl...\n";

/// Runs the command. `args` are the words after `build`. Gives the exit
/// code.
pub fn run(io: Io, a: std.mem.Allocator, env: anytype, args: []const [:0]const u8, out: *Io.Writer) !u8 {
    var wasm = false;
    var base: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var embeds: std.ArrayList([]const u8) = .empty;
    var scripts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, arg, "--wasm")) {
            wasm = true;
        } else if (std.mem.eql(u8, arg, "--base") and has_value) {
            i += 1;
            base = args[i];
        } else if (std.mem.eql(u8, arg, "--embed") and has_value) {
            i += 1;
            try embeds.append(a, args[i]);
        } else if (std.mem.eql(u8, arg, "-o") and has_value) {
            i += 1;
            output = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            try out.writeAll(usage);
            return 2;
        } else try scripts.append(a, arg);
    }
    if (!wasm or output == null or scripts.items.len == 0) {
        if (!wasm) try out.writeAll("ztcl build: only --wasm is supported now\n");
        try out.writeAll(usage);
        return 2;
    }

    const cwd = Io.Dir.cwd();
    const base_path = base orelse env.get("ZTCL_WASM") orelse blk: {
        const dir = try std.process.executableDirPathAlloc(io, a);
        break :blk try std.fs.path.join(a, &.{ dir, "..", "lib", "ztcl.wasm" });
    };
    const base_bytes = cwd.readFileAlloc(io, base_path, a, .limited(64 << 20)) catch |e| {
        try out.print("ztcl build: {s}: {s}. Pass --base with the path of ztcl.wasm.\n", .{ base_path, @errorName(e) });
        return 1;
    };

    var entries: std.ArrayList(wb.Entry) = .empty;
    for (scripts.items) |path| {
        const data = cwd.readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| {
            try out.print("ztcl build: {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        const name = try clean(a, path) orelse std.fs.path.basename(path);
        try entries.append(a, .{ .kind = .script, .name = name, .data = data });
    }
    for (embeds.items) |path| {
        const name = try clean(a, path) orelse {
            try out.print("ztcl build: {s}: use a relative path with no \"..\"\n", .{path});
            return 1;
        };
        var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
            error.NotDir => {
                const data = cwd.readFileAlloc(io, path, a, .limited(64 << 20)) catch |e2| {
                    try out.print("ztcl build: {s}: {s}\n", .{ path, @errorName(e2) });
                    return 1;
                };
                try entries.append(a, .{ .kind = .file, .name = name, .data = data });
                continue;
            },
            else => {
                try out.print("ztcl build: {s}: {s}\n", .{ path, @errorName(e) });
                return 1;
            },
        };
        defer dir.close(io);
        var files: std.ArrayList([]const u8) = .empty;
        var walk = try dir.walk(a);
        defer walk.deinit();
        while (try walk.next(io)) |e| {
            if (e.kind != .file) continue;
            try files.append(a, try a.dupe(u8, e.path));
        }
        // The walk has no fixed order. A sort gives the same bytes on each build.
        std.mem.sort([]const u8, files.items, {}, lessThan);
        for (files.items) |rel| {
            const data = try dir.readFileAlloc(io, rel, a, .limited(64 << 20));
            const full = if (name.len == 0) rel else try std.fmt.allocPrint(a, "{s}/{s}", .{ name, rel });
            try entries.append(a, .{ .kind = .file, .name = (try clean(a, full)).?, .data = data });
        }
    }

    const payload = try wb.encode(a, entries.items);
    const module = wb.patch(a, base_bytes, payload) catch |e| {
        try out.print("ztcl build: {s}: {s}\n", .{ base_path, switch (e) {
            error.NotWasm, error.BadModule => "not a ztcl.wasm module",
            error.NoSlot => "no bundle slot: use the ztcl.wasm of `zig build wasm`",
            error.AlreadyBundle => "the module is a bundle already",
            error.TooLarge => "the bundle is too large",
            error.OutOfMemory => "out of memory",
        } });
        return 1;
    };
    cwd.writeFile(io, .{ .sub_path = output.?, .data = module }) catch |e| {
        try out.print("ztcl build: {s}: {s}\n", .{ output.?, @errorName(e) });
        return 1;
    };
    try out.print("{s}: {d} bytes ({s}: {d} bytes, bundle: {d} bytes)\n", .{ output.?, module.len, std.fs.path.basename(base_path), base_bytes.len, payload.len });
    return 0;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The name of a path in the bundle: separators are `/`, and `.` and
/// empty parts go away. Gives null for an absolute path or a path with
/// `..`.
fn clean(a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) return null;
    while (iter.next()) |w| {
        if (std.mem.eql(u8, w, ".")) continue;
        if (std.mem.eql(u8, w, "..") or std.mem.indexOfScalar(u8, w, ':') != null) return null;
        try parts.append(a, w);
    }
    return try std.mem.join(a, "/", parts.items);
}
