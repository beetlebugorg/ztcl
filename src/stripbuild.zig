//! `ztcl build --strip`: a runtime with only the features that the
//! scripts use.
//!
//! The steps:
//!
//! 1. Read the manifest (`ztcl-strip.txt` in the current folder, or the
//!    file of `--strip-manifest`) and the flags `--keep`, `--keep-module`,
//!    `--drop-module`, and `--trust-scan`.
//! 2. Scan each script and each embedded `.tcl` or `.tm` file
//!    (`stripscan.zig`), and map the records to the features of
//!    `features_table.zig`. With `--profile`, first run the tests in a
//!    binary of the full runtime with an execution trace on each command
//!    of a feature, and keep the features of the commands that ran.
//! 3. Build the runtime with `zig build app-runtime -Ddrop=...` (or
//!    `zig build wasm -Ddrop=...` for `--wasm`) in the source folder of
//!    ztcl, into a cache folder named by a hash of the target and the
//!    drop list. Zig rebuilds only what changed. Without a source folder,
//!    a runtime in the cache is used as it is.
//! 4. Print the report: the size of the full and the stripped runtime,
//!    each feature with the reason it stays or goes, and the dynamic
//!    sites.
//! 5. With `--check`, build a binary of the stripped runtime with the
//!    tests as its scripts, run it, and fail when it exits with an error
//!    or prints the error of a stripped command.
//!
//! The tests are the files of `--test` and of the `test` lines of the
//! manifest. With no test, `--check` and `--profile` run the program
//! itself with no arguments.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const ft = @import("features_table.zig");
const scan = @import("stripscan.zig");
const wb = @import("wasmbundle.zig");
const Interp = @import("interp.zig").Interp;

/// The program that runs the strip mode: `ztcl build` or `ztk bundle`.
pub const Tool = struct {
    /// The start of each message, such as "ztcl build".
    name: []const u8,
    /// The environment variable of the source folder.
    src_env: []const u8,
    /// The default manifest in the current folder.
    manifest: []const u8,
    /// The program in the runtime folder: "ztcl" or "ztk".
    program: []const u8,
    /// The build step of the runtime: `app-runtime` (ztcl) or `runtimes`
    /// (ztk).
    ztk: bool = false,
    /// The features of the embedder, such as the widget classes of ztk.
    /// A name in `needs` of one of them can be a feature of ztcl.
    extra: []const ft.Feature = &.{},
};

pub const ztcl_tool: Tool = .{ .name = "ztcl build", .src_env = "ZTCL_SRC", .manifest = "ztcl-strip.txt", .program = "ztcl" };

const Allocator = std.mem.Allocator;

pub const Flags = struct {
    on: bool = false,
    keep: std.ArrayList(u8) = .empty,
    drop: std.ArrayList(u8) = .empty,
    trust: bool = false,
    check: bool = false,
    profile: bool = false,
    manifest: ?[]const u8 = null,
    src: ?[]const u8 = null,
    tests: std.ArrayList([]const u8) = .empty,
    timeout_s: u32 = 120,

    /// Reads the flag at `args[i.*]`. Gives false when it is not a flag
    /// of the strip mode.
    pub fn parse(f: *Flags, a: Allocator, args: []const [:0]const u8, i: *usize) !bool {
        const arg: []const u8 = args[i.*];
        const has_value = i.* + 1 < args.len;
        const eql = std.mem.eql;
        if (eql(u8, arg, "--strip")) {
            f.on = true;
        } else if (eql(u8, arg, "--trust-scan")) {
            f.trust = true;
        } else if (eql(u8, arg, "--check")) {
            f.check = true;
        } else if (eql(u8, arg, "--profile")) {
            f.profile = true;
        } else if ((eql(u8, arg, "--keep") or eql(u8, arg, "--keep-module")) and has_value) {
            i.* += 1;
            try addList(a, &f.keep, args[i.*]);
        } else if (eql(u8, arg, "--drop-module") and has_value) {
            i.* += 1;
            try addList(a, &f.drop, args[i.*]);
        } else if (eql(u8, arg, "--strip-manifest") and has_value) {
            i.* += 1;
            f.manifest = args[i.*];
        } else if (eql(u8, arg, "--src") and has_value) {
            i.* += 1;
            f.src = args[i.*];
        } else if (eql(u8, arg, "--test") and has_value) {
            i.* += 1;
            try f.tests.append(a, args[i.*]);
        } else if (eql(u8, arg, "--check-timeout") and has_value) {
            i.* += 1;
            f.timeout_s = std.fmt.parseInt(u32, args[i.*], 10) catch return false;
        } else return false;
        return true;
    }
};

fn addList(a: Allocator, list: *std.ArrayList(u8), text: []const u8) !void {
    var parts = std.mem.tokenizeAny(u8, text, ", \t");
    while (parts.next()) |p| {
        if (list.items.len > 0) try list.append(a, ',');
        try list.appendSlice(a, p);
    }
}

/// Reads the manifest: lines `keep LIST`, `drop LIST`, `test FILE`, and
/// `trust`. A `#` starts a comment line.
fn readManifest(comptime tool: Tool, io: Io, a: Allocator, f: *Flags, out: *Io.Writer) !bool {
    const path = f.manifest orelse tool.manifest;
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| {
        if (f.manifest == null and e == error.FileNotFound) return true;
        try out.print("{s}: {s}\n", .{ path, @errorName(e) });
        return false;
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const key = line[0..sp];
        const rest = std.mem.trim(u8, line[sp..], " \t");
        if (std.mem.eql(u8, key, "keep")) {
            try addList(a, &f.keep, rest);
        } else if (std.mem.eql(u8, key, "drop")) {
            try addList(a, &f.drop, rest);
        } else if (std.mem.eql(u8, key, "test") and rest.len > 0) {
            try f.tests.append(a, rest);
        } else if (std.mem.eql(u8, key, "trust") and rest.len == 0) {
            f.trust = true;
        } else {
            try out.print(tool.name ++ ": {s}:{d}: unknown line \"{s}\" (keep LIST, drop LIST, test FILE, trust)\n", .{ path, n, line });
            return false;
        }
    }
    return true;
}

/// Checks that each name of a list is a feature or a command of one.
fn checkNames(comptime tool: Tool, list: []const u8, flag: []const u8, out: *Io.Writer) !bool {
    var parts = std.mem.splitScalar(u8, list, ',');
    outer: while (parts.next()) |p| {
        if (p.len == 0) continue;
        if (ft.index(p) != null) continue;
        if (ft.ofCommand(std.mem.trimStart(u8, p, ":")) != null) continue;
        inline for (tool.extra) |x| {
            if (std.mem.eql(u8, x.name, p)) continue :outer;
            inline for (x.commands) |c| if (std.mem.eql(u8, c, std.mem.trimStart(u8, p, ":"))) continue :outer;
        }
        try out.print(tool.name ++ ": {s}: no feature or command \"{s}\". The features are:", .{ flag, p });
        for (ft.table) |x| try out.print(" {s}", .{x.name});
        inline for (tool.extra) |x| try out.print(" {s}", .{x.name});
        try out.writeAll("\n");
        return false;
    }
    return true;
}

fn isScript(e: wb.Entry) bool {
    if (e.kind == .script) return true;
    return std.mem.endsWith(u8, e.name, ".tcl") or std.mem.endsWith(u8, e.name, ".tm");
}

pub const Input = struct {
    target: []const u8,
    wasm: bool,
    allow: []const u8,
    jit: bool,
    /// The runtime of a build with no strip, for the report, or empty.
    full_runtime: []const u8 = "",
};

pub const Result = struct {
    /// The path of the stripped runtime, or of the stripped ztcl.wasm.
    runtime: []const u8,
    plan: scan.Plan,
};

/// Builds the stripped runtime. `build_test` writes a binary of the
/// entries with a runtime (null: the full runtime) to a path, for
/// `--check` and `--profile`. Gives null after a message.
pub fn run(
    comptime tool: Tool,
    io: Io,
    a: Allocator,
    env: anytype,
    f: *Flags,
    in: Input,
    entries: []const wb.Entry,
    ctx: anytype,
    comptime build_test: fn (@TypeOf(ctx), ?[]const u8, []const wb.Entry, []const u8) anyerror!bool,
    out: *Io.Writer,
) !?Result {
    if (!try readManifest(tool, io, a, f, out)) return null;
    if (!try checkNames(tool, f.keep.items, "--keep", out)) return null;
    if (!try checkNames(tool, f.drop.items, "--drop-module", out)) return null;

    var it: Interp = undefined;
    try it.init(a);
    var s = scan.Scan.init(a);
    var tests: std.ArrayList(wb.Entry) = .empty;
    for (f.tests.items) |path| {
        const data = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| {
            try out.print(tool.name ++ ": --test {s}: {s}\n", .{ path, @errorName(e) });
            return null;
        };
        try tests.append(a, .{ .kind = .script, .name = std.fs.path.basename(path), .data = data });
    }
    for (entries) |e| if (isScript(e)) try s.script(&it, e.name, e.data);

    var prof: ?std.StringArrayHashMapUnmanaged(void) = null;
    if (f.profile) {
        prof = try profileRun(io, a, env, f, entries, tests.items, ctx, build_test, out) orelse return null;
    }
    // The embedder of a wasm module turns on its capabilities, so each
    // capability counts as allowed there.
    var allow: std.ArrayList(u8) = .empty;
    if (in.wasm) {
        for (ft.table) |x| if (x.kind == .capability) {
            try allow.appendSlice(a, x.capability);
            try allow.append(a, ',');
        };
    } else try allow.appendSlice(a, in.allow);
    const o: scan.Options = .{
        .allow = allow.items,
        .trust = f.trust,
        .jit = in.jit and !in.wasm,
        .keep = f.keep.items,
        .drop = f.drop.items,
        .profile = if (prof) |*x| x else null,
    };
    var p = scan.plan(&s, o);
    const px = scan.planFor(tool.extra, &s, o);
    // A feature of the embedder in the build keeps the features of ztcl
    // in its `needs`.
    for (tool.extra, px.on) |x, v| {
        if (!v) continue;
        for (x.needs) |n| if (ft.index(n)) |j| if (!p.on[j]) {
            p.on[j] = true;
            p.why[j] = "a feature of the program needs it";
        };
    }
    var drop: std.ArrayList(u8) = .empty;
    try drop.appendSlice(a, try p.dropList(a));
    const dx = try px.dropListOf(a, tool.extra);
    if (dx.len > 0) {
        if (drop.items.len > 0) try drop.append(a, ',');
        try drop.appendSlice(a, dx);
    }
    const rt = try buildRuntime(tool, io, a, env, f, in, drop.items, out) orelse return null;
    try report(&ft.table, io, p.on[0..], p.why[0..], in, rt, out, true);
    if (tool.extra.len > 0) try report(tool.extra, io, px.on[0..], px.why[0..], in, rt, out, false);
    try reportSites(&s, out);

    if (f.check) {
        const tmp = try std.fmt.allocPrint(a, "{s}.check{s}", .{ rt, if (std.mem.endsWith(u8, rt, ".exe")) ".exe" else "" });
        const list = try testEntries(a, entries, tests.items, "");
        if (!try build_test(ctx, rt, list, tmp)) return null;
        const r = try runTest(io, a, f, tmp, out) orelse return null;
        if (!r.term.success() or std.mem.indexOf(u8, r.stdout, "is not in this build") != null or std.mem.indexOf(u8, r.stderr, "is not in this build") != null) {
            try out.print(tool.name ++ ": --check: the tests failed on the stripped runtime ({s}):\n{s}{s}", .{ termText(r.term), tail(r.stdout), tail(r.stderr) });
            return null;
        }
        try out.print("check: the tests passed on the stripped runtime\n", .{});
    }
    return .{ .runtime = rt, .plan = p };
}

fn tail(t: []const u8) []const u8 {
    return if (t.len > 4000) t[t.len - 4000 ..] else t;
}

fn termText(t: std.process.Child.Term) []const u8 {
    return switch (t) {
        .exited => "exit code not 0",
        else => "the process stopped on a signal",
    };
}

/// The entries of a test binary: the files and scripts of the program as
/// files, then `prelude`, the tests (or the scripts of the program when
/// there is no test), and with a prelude the dump of the profile.
fn testEntries(a: Allocator, entries: []const wb.Entry, tests: []const wb.Entry, pre: []const u8) ![]const wb.Entry {
    var list: std.ArrayList(wb.Entry) = .empty;
    if (pre.len > 0) try list.append(a, .{ .kind = .script, .name = "ztcl-strip-prelude.tcl", .data = pre });
    if (tests.len == 0) {
        try list.appendSlice(a, entries);
    } else {
        for (entries) |e| try list.append(a, .{ .kind = .file, .name = e.name, .data = e.data });
        try list.appendSlice(a, tests);
    }
    if (pre.len > 0) try list.append(a, .{ .kind = .script, .name = "ztcl-strip-dump.tcl", .data = "::ztcl_strip::dump\n" });
    // Keep the first entry of each name: a test with the name of a file
    // of the program replaces the file.
    var keep: std.ArrayList(wb.Entry) = .empty;
    outer: for (list.items, 0..) |e, i| {
        for (list.items[i + 1 ..]) |later| if (std.mem.eql(u8, later.name, e.name) and later.kind == .script and e.kind == .file) continue :outer;
        for (keep.items) |k| if (std.mem.eql(u8, k.name, e.name)) continue :outer;
        try keep.append(a, e);
    }
    return keep.items;
}

fn runTest(io: Io, a: Allocator, f: *const Flags, path: []const u8, out: *Io.Writer) !?std.process.RunResult {
    const abs = try std.fs.path.resolveAlloc(a, &.{path});
    return std.process.run(a, io, .{
        .argv = &.{abs},
        .timeout = .{ .duration = .{ .raw = .fromSeconds(f.timeout_s), .clock = .awake } },
        .stdout_limit = .limited(64 << 20),
        .stderr_limit = .limited(64 << 20),
    }) catch |e| {
        try out.print("strip: {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
}

/// The marker of the line of the profile on standard output.
const marker = "\x01ztcl-strip-profile:";

/// The Tcl code of the profile: an execution trace on each command of a
/// feature that exists, and `dump`, which prints the commands that ran.
fn prelude(a: Allocator) ![]const u8 {
    var t: std.ArrayList(u8) = .empty;
    try t.appendSlice(a,
        \\namespace eval ::ztcl_strip {
        \\    variable seen {}
        \\    proc hit {name args} { variable seen; dict set seen $name 1 }
        \\    proc dump {} { variable seen; puts "\x01ztcl-strip-profile: [dict keys $seen]" }
        \\    proc watch {name} {
        \\        if {[info commands ::$name] ne ""} {
        \\            trace add execution ::$name enter [list ::ztcl_strip::hit $name]
        \\        }
        \\    }
        \\}
        \\rename ::exit ::ztcl_strip::exit0
        \\proc ::exit {{code 0}} { ::ztcl_strip::dump; ::ztcl_strip::exit0 $code }
        \\
    );
    for (ft.table) |f| {
        if (f.kind == .engine or f.kind == .module) continue;
        for (f.commands) |c| {
            if (std.mem.indexOfScalar(u8, c, ' ') != null) continue;
            if (std.mem.endsWith(u8, c, "::")) {
                try t.print(a, "foreach c [info commands ::{s}*] {{ ::ztcl_strip::watch [string range $c 2 end] }}\n", .{c});
            } else try t.print(a, "::ztcl_strip::watch {s}\n", .{c});
        }
    }
    return t.items;
}

fn profileRun(
    io: Io,
    a: Allocator,
    env: anytype,
    f: *const Flags,
    entries: []const wb.Entry,
    tests: []const wb.Entry,
    ctx: anytype,
    comptime build_test: fn (@TypeOf(ctx), ?[]const u8, []const wb.Entry, []const u8) anyerror!bool,
    out: *Io.Writer,
) !?std.StringArrayHashMapUnmanaged(void) {
    const dir = try cacheDir(io, a, env, null);
    const tmp = try std.fs.path.join(a, &.{ dir, "profile-run" });
    const list = try testEntries(a, entries, tests, try prelude(a));
    if (!try build_test(ctx, null, list, tmp)) return null;
    const r = try runTest(io, a, f, tmp, out) orelse return null;
    const at = std.mem.lastIndexOf(u8, r.stdout, marker) orelse {
        try out.print("strip: --profile: the run gave no profile ({s}):\n{s}{s}", .{ termText(r.term), tail(r.stdout), tail(r.stderr) });
        return null;
    };
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var line = r.stdout[at + marker.len ..];
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    var words = std.mem.tokenizeAny(u8, line, " \t\r");
    while (words.next()) |w| try set.put(a, w, {});
    try out.print("profile: {d} commands of features ran\n", .{set.count()});
    return set;
}

/// The cache folder of stripped runtimes: ZTCL_STRIP_CACHE, or
/// `ztcl/strip` in XDG_CACHE_HOME or in `~/.cache` (LOCALAPPDATA on
/// Windows). With `key`, the folder of that key.
fn cacheDir(io: Io, a: Allocator, env: anytype, key: ?[]const u8) ![]const u8 {
    const base = env.get("ZTCL_STRIP_CACHE") orelse blk: {
        if (env.get("XDG_CACHE_HOME")) |x| break :blk try std.fs.path.join(a, &.{ x, "ztcl", "strip" });
        if (env.get("LOCALAPPDATA")) |x| break :blk try std.fs.path.join(a, &.{ x, "ztcl", "strip" });
        const home = env.get("HOME") orelse ".";
        break :blk try std.fs.path.join(a, &.{ home, ".cache", "ztcl", "strip" });
    };
    const dir = if (key) |k| try std.fs.path.join(a, &.{ base, k }) else base;
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// The folder of the source of ztcl: `--src`, ZTCL_SRC, or the folder
/// two levels above the program (`zig-out/bin/ztcl`) when it has
/// build.zig. Null when none has build.zig.
fn sourceDir(comptime tool: Tool, io: Io, a: Allocator, env: anytype, f: *const Flags) !?[]const u8 {
    const cwd = Io.Dir.cwd();
    var list: std.ArrayList([]const u8) = .empty;
    if (f.src) |s| try list.append(a, s);
    if (env.get(tool.src_env)) |s| try list.append(a, s);
    const exe_dir = try std.process.executableDirPathAlloc(io, a);
    try list.append(a, try std.fs.path.join(a, &.{ exe_dir, "..", ".." }));
    for (list.items) |d| {
        const bz = try std.fs.path.join(a, &.{ d, "build.zig" });
        const ft_path = try std.fs.path.join(a, &.{ d, "src", "features_table.zig" });
        // The same name in ztk and ztcl: the build.zig of each reads it.
        if (cwd.access(io, bz, .{})) |_| {
            if (cwd.access(io, ft_path, .{})) |_| return d else |_| {}
        } else |_| {}
    }
    return null;
}

fn buildRuntime(comptime tool: Tool, io: Io, a: Allocator, env: anytype, f: *const Flags, in: Input, drop: []const u8, out: *Io.Writer) !?[]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(if (in.wasm) "wasm" else in.target);
    h.update("\x00");
    h.update(drop);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    const dir = try cacheDir(io, a, env, &hex);
    const windows = std.mem.endsWith(u8, in.target, "-windows");
    const exe = if (windows) tool.program ++ ".exe" else tool.program;
    const rt = if (in.wasm)
        try std.fs.path.join(a, &.{ dir, "lib", "ztcl.wasm" })
    else if (tool.ztk)
        try std.fs.path.join(a, &.{ dir, "lib", "ztk", "runtime", in.target, exe })
    else
        try std.fs.path.join(a, &.{ dir, "bin", exe });
    const src = try sourceDir(tool, io, a, env, f) orelse {
        if (Io.Dir.cwd().access(io, rt, .{})) |_| {
            try out.print("strip: no source folder of ztcl; using the cached runtime {s}\n", .{rt});
            return rt;
        } else |_| {}
        try out.print(tool.name ++ ": --strip needs the source of " ++ tool.program ++ " and Zig: pass --src DIR or set " ++ tool.src_env ++ " (no cached runtime for this feature set)\n", .{});
        return null;
    };
    const zig = env.get("ZIG") orelse "zig";
    const prefix = try std.fs.path.resolveAlloc(a, &.{dir});
    const dflag = try std.fmt.allocPrint(a, "-Ddrop={s}", .{drop});
    const argv: []const []const u8 = if (in.wasm)
        &.{ zig, "build", "wasm", dflag, "--prefix", prefix }
    else if (tool.ztk)
        &.{ zig, "build", "runtimes", try std.fmt.allocPrint(a, "-Druntime-targets={s}", .{in.target}), dflag, "--prefix", prefix }
    else
        &.{ zig, "build", "app-runtime", try std.fmt.allocPrint(a, "-Dapp-target={s}", .{in.target}), dflag, "--prefix", prefix };
    try out.print("strip: building the runtime ({s})\n", .{if (drop.len == 0) "no feature dropped" else drop});
    try out.flush();
    const r = std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = src }, .stderr_limit = .limited(16 << 20), .stdout_limit = .limited(16 << 20) }) catch |e| {
        try out.print(tool.name ++ ": cannot run {s}: {s}\n", .{ zig, @errorName(e) });
        return null;
    };
    if (!r.term.success()) {
        try out.print(tool.name ++ ": the build of the stripped runtime failed:\n{s}\n", .{tail(r.stderr)});
        return null;
    }
    return rt;
}

fn fileSize(io: Io, path: []const u8) u64 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.size;
}

fn report(comptime tbl: []const ft.Feature, io: Io, on: []const bool, why_list: []const []const u8, in: Input, rt: []const u8, out: *Io.Writer, first: bool) !void {
    if (first) {
        const after = fileSize(io, rt);
        const before = if (in.full_runtime.len > 0) fileSize(io, in.full_runtime) else 0;
        if (before > 0) {
            try out.print("strip: runtime {d} bytes, stripped {d} bytes ({d} bytes less)\n", .{ before, after, before -| after });
        } else try out.print("strip: stripped runtime {d} bytes\n", .{after});
    }
    // One line for each state and reason, with the features of it.
    for ([_]bool{ true, false }) |state| {
        for (tbl, 0..) |_, i| {
            const v = on[i];
            const why = why_list[i];
            if (v != state) continue;
            const seen = for (0..i) |j| {
                if (on[j] == state and std.mem.eql(u8, why_list[j], why)) break true;
            } else false;
            if (seen) continue;
            try out.print("strip: {s} ({s}):", .{ if (state) "kept" else "dropped", why });
            for (tbl, 0..) |g, j| {
                if (on[j] == state and std.mem.eql(u8, why_list[j], why)) try out.print(" {s}", .{g.name});
            }
            try out.writeAll("\n");
        }
    }
}

fn reportSites(s: *const scan.Scan, out: *Io.Writer) !void {
    if (s.sites.items.len > 0) {
        const keeping = s.count(.computed_command) + s.count(.computed_script);
        try out.print("strip: {d} dynamic sites ({d} keep each command group when --trust-scan and --profile are off; the scan reads each embedded script, so a computed source path keeps no feature):\n", .{ s.sites.items.len, keeping });
        for (s.sites.items, 0..) |x, i| {
            if (i == 20) {
                try out.print("  ... {d} more\n", .{s.sites.items.len - 20});
                break;
            }
            try out.print("  {s}:{d}: {s}: {s}\n", .{ x.file, x.line, x.kind.text(), x.text });
        }
    }
}
