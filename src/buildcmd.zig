//! `ztcl build [--target T] [--embed PATH]... -o OUT script.tcl...`
//! `ztcl build --wasm [--base FILE] [--embed PATH]... -o OUT script.tcl...`
//!
//! The native form writes a copy of the runtime binary of the target
//! with a zip payload (`src/buildnative.zig`): the scripts, the files,
//! and the manifest. The runtime is the file of `--runtime`, or
//! `T/ztcl` in the folder of ZTCL_RUNTIME_DIR, or in
//! `../lib/ztcl/runtime/` next to the folder of the program, or for the
//! host target the program itself.
//!
//! The wasm form writes a copy of ztcl.wasm with the scripts and the files in it. The
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

const usage =
    \\usage: ztcl build [--target T] [--runtime FILE] [--allow LIST] [--root PATH] [--no-jit]
    \\                  [--compress] [--embed PATH]... -o OUT script.tcl...
    \\       ztcl build --wasm [--base ztcl.wasm] [--embed PATH]... -o OUT.wasm script.tcl...
    \\
;

/// Runs the command. `args` are the words after `build`. Gives the exit
/// code.
pub fn run(io: Io, a: std.mem.Allocator, env: anytype, args: []const [:0]const u8, out: *Io.Writer) !u8 {
    var wasm = false;
    var base: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var embeds: std.ArrayList([]const u8) = .empty;
    var scripts: std.ArrayList([]const u8) = .empty;
    var nat: Native = .{};
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
        } else if (std.mem.eql(u8, arg, "--target") and has_value) {
            i += 1;
            nat.target = args[i];
        } else if (std.mem.eql(u8, arg, "--runtime") and has_value) {
            i += 1;
            nat.runtime = args[i];
        } else if (std.mem.eql(u8, arg, "--allow") and has_value) {
            i += 1;
            nat.allow = args[i];
        } else if (std.mem.eql(u8, arg, "--root") and has_value) {
            i += 1;
            nat.root = args[i];
        } else if (std.mem.eql(u8, arg, "--no-jit")) {
            nat.jit = false;
        } else if (std.mem.eql(u8, arg, "--compress")) {
            nat.compress = true;
        } else if (std.mem.eql(u8, arg, "-o") and has_value) {
            i += 1;
            output = args[i];
        } else if (arg.len > 0 and arg[0] == '-') {
            try out.writeAll(usage);
            return 2;
        } else try scripts.append(a, arg);
    }
    if (output == null or scripts.items.len == 0) {
        try out.writeAll(usage);
        return 2;
    }

    const cwd = Io.Dir.cwd();
    const base_path = base orelse env.get("ZTCL_WASM") orelse blk: {
        const dir = try std.process.executableDirPathAlloc(io, a);
        break :blk try std.fs.path.join(a, &.{ dir, "..", "lib", "ztcl.wasm" });
    };
    const base_bytes = if (!wasm) "" else cwd.readFileAlloc(io, base_path, a, .limited(64 << 20)) catch |e| {
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

    if (!wasm) return native(io, a, env, nat, entries.items, output.?, out);
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

const bn = tcl.buildnative;

const Native = struct {
    target: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    allow: []const u8 = "",
    root: ?[]const u8 = null,
    jit: bool = true,
    compress: bool = false,
};

fn native(io: Io, a: std.mem.Allocator, env: anytype, nat: Native, entries: []const wb.Entry, output: []const u8, out: *Io.Writer) !u8 {
    const target = nat.target orelse bn.hostTarget();
    var file: ?[]const u8 = null;
    for (bn.targets) |t| if (std.mem.eql(u8, t.name, target)) {
        file = t.file;
    };
    if (file == null) {
        try out.print("ztcl build: unknown target \"{s}\". The targets are:", .{target});
        for (bn.targets) |t| try out.print(" {s}", .{t.name});
        try out.writeAll("\n");
        return 2;
    }
    if (nat.allow.len > 0 and tcl.interp.Capability.parse(nat.allow) == null) {
        try out.print("ztcl build: unknown capability in \"{s}\"\n", .{nat.allow});
        return 2;
    }
    const cwd = Io.Dir.cwd();
    const exe_dir = try std.process.executableDirPathAlloc(io, a);
    const rt_path: []const u8 = nat.runtime orelse blk: {
        if (env.get("ZTCL_RUNTIME_DIR")) |d| break :blk try std.fs.path.join(a, &.{ d, target, file.? });
        const shipped = try std.fs.path.join(a, &.{ exe_dir, "..", "lib", "ztcl", "runtime", target, file.? });
        if (cwd.access(io, shipped, .{})) |_| break :blk shipped else |_| {}
        if (std.mem.eql(u8, target, bn.hostTarget())) break :blk try std.process.executablePathAlloc(io, a);
        break :blk shipped;
    };
    const runtime = cwd.readFileAlloc(io, rt_path, a, .limited(256 << 20)) catch |e| {
        try out.print("ztcl build: the runtime of {s}: {s}: {s}. Make it with `zig build runtimes`, or pass --runtime.\n", .{ target, rt_path, @errorName(e) });
        return 1;
    };
    var zips: std.ArrayList(tcl.zipwrite.Entry) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        for (zips.items) |z| if (std.mem.eql(u8, z.name, e.name)) {
            try out.print("ztcl build: {s} is in the input twice\n", .{e.name});
            return 1;
        };
        try zips.append(a, .{ .name = e.name, .data = e.data });
        if (e.kind == .script) try names.append(a, e.name);
    }
    const manifest: bn.Manifest = .{ .scripts = names.items, .allow = nat.allow, .root = nat.root, .jit = nat.jit };
    try zips.append(a, .{ .name = bn.manifest_name, .data = try manifest.write(a) });
    const payload = tcl.zipwrite.write(a, zips.items, nat.compress) catch |e| {
        try out.print("ztcl build: the payload: {s}\n", .{@errorName(e)});
        return 1;
    };
    // The Mach-O signature of an app has the entitlement of the JIT, which
    // a signature with the hardened runtime needs for MAP_JIT, and with
    // `vm` the entitlement of Virtualization.framework. ELF and PE files
    // have no entitlements.
    const vm_bit = @backingInt(tcl.interp.Capability.vm);
    const wants_vm = nat.allow.len > 0 and (tcl.interp.Capability.parse(nat.allow) orelse 0) & vm_bit != 0;
    const ents: []const []const u8 = if (wants_vm)
        &.{ "com.apple.security.cs.allow-jit", "com.apple.security.virtualization" }
    else
        &.{"com.apple.security.cs.allow-jit"};
    const bin = bn.bundle(a, runtime, payload, std.fs.path.basename(output), ents) catch |e| {
        try out.print("ztcl build: {s}: {s}\n", .{ rt_path, switch (e) {
            error.UnknownFormat => "not an ELF, PE, or Mach-O file",
            error.NoSlot => "no app slot: use a runtime of this version of ztcl",
            error.TwoSlots => "two app slots",
            error.AlreadyBundle => "the runtime is a bundle already",
            error.BadMachO => "a Mach-O file with a form that ztcl build does not read",
            error.NoRoom => "no space for a code signature after the load commands: use a runtime of `zig build runtimes`",
            error.OutOfMemory => "out of memory",
        } });
        return 1;
    };
    cwd.writeFile(io, .{ .sub_path = output, .data = bin, .flags = .{ .permissions = .executable_file } }) catch |e| {
        try out.print("ztcl build: {s}: {s}\n", .{ output, @errorName(e) });
        return 1;
    };
    try out.print("{s}: {d} bytes ({s} runtime: {d} bytes, payload: {d} bytes)\n", .{ output, bin.len, target, runtime.len, payload.len });
    return 0;
}
