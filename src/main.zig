//! A runner for Tcl scripts: `ztcl [--time] [--compute N] [--mem N] [--repeat N] file.tcl ...`.
//!
//! `ztcl debug [options] file.tcl` runs a script with probes and writes
//! a report, and `ztcl debug --mcp` serves its tools. See
//! `src/debug.zig` and `src/debugmcp.zig`.
//!
//! `ztcl build --wasm ... -o OUT.wasm file.tcl ...` writes a copy of
//! ztcl.wasm with the scripts in it. See `src/buildcmd.zig`.
//!
//! It runs the files in order in one interpreter and writes the output
//! of `puts` to stdout. With no file, it reads commands from stdin, one
//! line at a time. The runner reads the files itself; a script has no
//! command that reads a file.
//!
//! `--allow a,b` turns on capabilities (`package`, `interp`, `clock`, `channels`, `file`, `event`, `socket`, `exec`, `random`, `env`, `sqlite`, `thread`, `vm`, and the others of `interp.Capability`). `--keychain-allow S,S` and `--defaults-allow D,D` list the keychain services and the defaults domains of `ztcl::mac`. `--root DIR` is
//! the one folder of `file` and channels. Only the
//! suite passes it.
//! `--exec-timeout MS`, `--exec-env NAME=value`, and `--exec-allow a,b`
//! set the time limit, the environment, and the program list of `exec`.
//! `--registry-allow KEY,KEY` lists the registry keys of `registry`.
//! `--exec-allow-root /a,/b` lists the files below the root that `exec`
//! can run.
//! A program of `exec` gets only the environment of `--exec-env`.
//! `--tclsh` makes the runner act as `tclsh` for the Tcl test suite. The
//! first file is the script, and the other words are its `argv`. With
//! the channel capability, `stdin`, `stdout`, and `stderr` are channels
//! on the descriptors of the process, and the script comes from the
//! root folder. With no file, the commands come from `stdin` with no
//! prompt. The mode adds the command `exit`.
//! `--cwd DIR` sets the current folder to a folder below the root.
//! `--net loopback|any|allow=LIST` sets the network policy of `socket`.
//! The default is `loopback`. A rule of the list is a host name, an
//! address, or an address range such as `10.0.0.0/8`, with an optional
//! `:port` or `:port-port`.
//! `--tcl 8.6|9.1` sets the Tcl release that the commands follow. The
//! default is 8.6.
//! `--mem N` sets the memory limit in bytes. The default is 2 GiB.
//! `--gc-stress N` starts a collection at each Nth allocation. `--gc off`
//! turns the collector off.
//! `--report` writes one line to stderr at the end: the compute units used, the
//! bytes held now, and the highest number of bytes held.
//! The JIT is on when the build and the system have it. `--no-jit`, or
//! the environment variable `ZTCL_JIT=off`, turns it off.
//! `--jit-threshold N` sets the calls of a proc before it compiles.
//! `--no-jit-tier2` turns tier 2 off, and `--jit-tier2-count N` sets the
//! passes of a loop before tier 2 compiles it (1000 by default).
//! `--jit-stats` writes the counts and the state of the JIT to stderr at
//! the end.
//! `--jit-stress N` sets the stress modes of the JIT, a set of bits (see
//! `src/jit.zig`). Bits 1 to 16 test tier 1 and the region. Bit 32
//! fails each guard of tier 2 on a schedule. Only the tests use them.
//! `--jit-stress-alloc K` is the allocation that the first compile
//! fails in stress mode 1.
//! `--jit-dump DIR` writes the bytes of each compiled function to a file
//! of DIR, for `tools/jit-scan.sh`.
//! `--threads N` sets the threads that run at one time (capability
//! `thread`). `--thread-compute N` and `--thread-mem N` set the limits of
//! one thread, and `--threads-compute N` and `--threads-mem N` set the
//! totals of all threads.
//! `--repeat N` runs each file N times in one interpreter. With `--time`,
//! it prints the best time: the warm time of the file.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// libghostty-vt logs to stderr. The runner drops the log.
pub const std_options: std.Options = .{ .logFn = @import("ztcl").vt.noLog };
const builtin = @import("builtin");
const Io = std.Io;
const tcl = @import("ztcl");
const shell = struct {
    const shell = tcl.shell;
    const term = tcl.shell_term;
};

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const w: *Io.Writer = @ptrCast(@alignCast(ctx.?));
    w.writeAll(bytes) catch {};
    if (flush_each) w.flush() catch {};
}

/// True for `--verbose`: each write goes out at once, so the output of
/// a file that stops early is complete.
var flush_each = false;

pub fn main(init: std.process.Init) !void {
    return runWith(init, null);
}

/// The services of the system that the options and the scripts of the
/// runner use. `runWith` fills it from `std.process.Init`. The command
/// component of WASI 0.3.2 (`src/wasi/run.zig`) fills it with WASI 0.3.2
/// functions, because `std.Io` on WASI uses preview 1.
pub const Host = struct {
    /// The `Io` of the standard library, or null in the component.
    io: ?Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    args: []const []const u8,
    out: *Io.Writer,
    in: *Io.Reader,
    /// The value of an environment variable of the runner.
    env: *const fn (name: []const u8) ?[]const u8,
    /// The text of a script file.
    read: *const fn (path: []const u8, a: std.mem.Allocator) anyerror![]u8,
    /// Ends the process with the exit code.
    exit: *const fn (code: u8) noreturn,
    /// A monotonic time in nanoseconds, for `--time`.
    nanos: *const fn () i96,
    clock: @typeInfo(@FieldType(tcl.Interp, "clock_host")).optional.child,
    event: tcl.event.Host,
};

var host: *const Host = undefined;
var host_io: Io = undefined;
const chan_ok = tcl.sys.supported;
const exec_ok = tcl.proc.supported;
/// WASI has no terminal interface, so the WASI build has no shell.
const shell_ok = builtin.os.tag != .wasi;

fn hostNow(_: ?*anyopaque) i64 {
    const t = Io.Clock.real.now(host_io);
    return @intCast(@divFloor(t.toNanoseconds(), 1000));
}

fn hostTicks(_: ?*anyopaque) i64 {
    const t = Io.Clock.awake.now(host_io);
    return @intCast(@divFloor(t.toNanoseconds(), 1000));
}

fn hostSleep(_: ?*anyopaque, micros: i64) void {
    Io.sleep(host_io, .fromNanoseconds(micros * 1000), .awake) catch {};
}

/// The TZif file of a zone. The clock module checks the name.
fn hostZone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const path = std.fmt.allocPrint(a, "/usr/share/zoneinfo/{s}", .{name}) catch return null;
    return Io.Dir.cwd().readFileAlloc(host_io, path, a, .limited(1 << 20)) catch null;
}

var host_preopens: std.process.Preopens = .empty;

/// The folder and the path in it of a script file. On WASI, a relative
/// path goes to `Io.Dir.cwd()`, the first preopen. An absolute path goes
/// to the preopen with the longest name that is a prefix of the path at
/// a `/`, and the rest of the path is relative to it. A WASI open
/// refuses an absolute path.
const HostPath = struct { dir: Io.Dir, sub: []const u8 };

fn hostPath(path: []const u8) HostPath {
    if (builtin.os.tag != .wasi or path.len == 0 or path[0] != '/') return .{ .dir = .cwd(), .sub = path };
    var best: ?HostPath = null;
    var best_len: usize = 0;
    for (host_preopens.map.keys(), 0..) |name, fd| {
        if (fd < 3 or name.len == 0 or name[0] != '/') continue;
        const base = std.mem.trimEnd(u8, name, "/");
        if (!std.mem.startsWith(u8, path, base)) continue;
        if (path.len > base.len and path[base.len] != '/') continue;
        if (best != null and base.len < best_len) continue;
        const rest = std.mem.trimStart(u8, path[base.len..], "/");
        best = .{ .dir = .{ .handle = @intCast(fd) }, .sub = if (rest.len == 0) "." else rest };
        best_len = base.len;
    }
    return best orelse .{ .dir = .cwd(), .sub = std.mem.trimStart(u8, path, "/") };
}

/// `ztcl debug script`: the output of the script, then the report.
/// Gives the exit code: 0 for a run with no error, 1 for an error, and
/// 2 for a bad probe.
fn runDebug(it: *tcl.Interp, out: *Io.Writer, a: std.mem.Allocator, text: []const u8, opts: tcl.debug.Options) !u8 {
    var rep = tcl.debug.run(it, text, opts) catch |e| {
        if (e == error.TclError) {
            try out.print("ztcl debug: {s}\n", .{it.str(it.result) catch ""});
            out.flush() catch {};
            return 2;
        }
        return e;
    };
    defer rep.deinit();
    try out.writeAll(if (opts.json) try tcl.debug.writeJson(a, &rep, opts) else try tcl.debug.writeText(a, &rep, opts));
    out.flush() catch {};
    return if (rep.ok) 0 else 1;
}

fn mcpRead(_: ?*anyopaque, path: []const u8, a: std.mem.Allocator) anyerror![]u8 {
    return host.read(path, a);
}

fn readScript(io: Io, path: []const u8, a: std.mem.Allocator) ![]u8 {
    const hp = hostPath(path);
    return hp.dir.readFileAlloc(io, hp.sub, a, .limited(64 << 20));
}

var exit_out: *Io.Writer = undefined;

/// `exit ?returnCode?`: writes the pending output and ends the process.
fn cmdExit(it: *tcl.Interp, argv: []const tcl.Value, _: ?*tcl.interp.Cmd) tcl.Error!tcl.Value {
    if (argv.len > 2) return it.wrongArgs("exit ?returnCode?");
    var code: i64 = 0;
    if (argv.len == 2) code = argv[1].asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(argv[1])});
    leave(it, @truncate(@as(u64, @bitCast(code))));
}

/// True for `--report`.
var report_on = false;
/// The value of `--compute`, to find the compute units used.
var max_compute: u64 = std.math.maxInt(u64);

/// The folder of `--jit-dump` and the count of the files in it.
var dump_dir: []const u8 = "";
var dump_count: usize = 0;

fn dumpCode(_: ?*anyopaque, bytes: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/fn-{d}.bin", .{ dump_dir, dump_count }) catch return;
    dump_count += 1;
    Io.Dir.cwd().writeFile(host_io, .{ .sub_path = path, .data = bytes }) catch {};
}

/// True for `--jit-stats`.
var jit_stats = false;

fn report(it: *const tcl.Interp) void {
    if (jit_stats) tcl.jit.printStats(it);
    if (!report_on) return;
    // The debug `Io` of the component gives no output, so the report
    // goes to descriptor 2 there.
    if (comptime tcl.sys.wasi_p3) {
        var buf: [128]u8 = undefined;
        _ = tcl.sys.write(2, std.fmt.bufPrint(&buf, "report compute={d} mem={d} peak={d}\n", .{ max_compute - it.compute_limit, it.counter.used, it.counter.mem_peak }) catch return);
        return;
    }
    std.debug.print("report compute={d} mem={d} peak={d}\n", .{ max_compute - it.compute_limit, it.counter.used, it.counter.mem_peak });
    if (std.debug.runtime_safety) std.debug.print("gc collections={d}\n", .{it.gcCount()});
}

fn threadFlag(arg: []const u8) bool {
    for ([_][]const u8{ "--threads", "--thread-compute", "--thread-mem", "--threads-compute", "--threads-mem" }) |f| {
        if (std.mem.eql(u8, arg, f)) return true;
    }
    return false;
}

fn leave(it: *tcl.Interp, code: u8) noreturn {
    exit_out.flush() catch {};
    report(it);
    it.deinit();
    host.exit(code);
}

/// The part of `tclsh` that the Tcl tests use for a child process.
fn runTclsh(it: *tcl.Interp, out: *Io.Writer, words: []const []const u8, root: ?[]const u8, cwd: ?[]const u8) !void {
    exit_out = out;
    const channels = chan_ok and it.capabilities & @backingInt(tcl.interp.Capability.channels) != 0;
    if (comptime chan_ok) {
        tcl.sys.ignorePipeSignal();
        if (channels) try tcl.chan.useStdio(it);
        if (root != null and cwd != null and std.mem.startsWith(u8, cwd.?, root.?)) {
            it.fs.cwd = std.mem.trim(u8, cwd.?[root.?.len..], "/");
        }
    }
    try it.register("exit", cmdExit);
    const a = it.alloc();
    var list: std.ArrayList(tcl.Value) = .empty;
    if (words.len > 1) for (words[1..]) |w| try list.append(a, .{ .str = w });
    try it.setVar("argv", try tcl.value.wrapList(a, list.items));
    try it.setVar("argc", .{ .int = @intCast(list.items.len) });
    try it.setVar("argv0", .{ .str = if (words.len > 0) words[0] else "tclsh" });
    try it.setVar("tcl_interactive", .{ .int = 0 });
    const script: []const u8 = if (words.len > 0)
        try std.fmt.allocPrint(a, "source {s}", .{try it.str(try tcl.value.newList(a, &.{.{ .str = words[0] }}))})
    else
        // The commands of stdin, one complete command at a time.
        \\apply {{} {
        \\    set cmd {}
        \\    while {[gets stdin line] >= 0} {
        \\        append cmd $line \n
        \\        if {![info complete $cmd]} continue
        \\        set now $cmd
        \\        set cmd {}
        \\        if {[catch {uplevel #0 $now} msg]} { puts stderr $msg }
        \\    }
        \\    if {$cmd ne {}} { catch {uplevel #0 $cmd} }
        \\}}
    ;
    if (words.len > 0 and !channels) {
        const text = try host.read(words[0], a);
        it.script_name = words[0];
        _ = it.eval(text) catch |e| return tclshError(it, e);
        leave(it, 0);
    }
    _ = it.eval(script) catch |e| return tclshError(it, e);
    leave(it, 0);
}

fn tclshError(it: *tcl.Interp, e: tcl.Error) noreturn {
    if (e == error.TclError) {
        it.finishError() catch {};
        const info = it.getVarPlain("::errorInfo") catch it.result;
        const text = it.str(info) catch "error";
        if (comptime chan_ok) {
            _ = tcl.sys.write(2, text);
            _ = tcl.sys.write(2, "\n");
        }
        leave(it, 1);
    }
    leave(it, 0);
}

/// Runs the payload of a binary of `ztcl build`: mounts it at
/// `//zipfs:/app`, turns on the capabilities of the manifest and
/// `embedded`, and sources each script of the manifest in order. The
/// words after the program name are `$argv`.
fn runApp(init: std.process.Init, args: []const [:0]const u8, off: u64, len: u64) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var out_buf: [1 << 16]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    exit_out = out;
    const bn = tcl.buildnative;
    const exe = try std.process.executablePathAlloc(io, arena);
    const whole = Io.Dir.cwd().readFileAlloc(io, exe, arena, .unlimited) catch |e| {
        try out.print("{s}: cannot read the program file: {s}\n", .{ exe, @errorName(e) });
        out.flush() catch {};
        std.process.exit(70);
    };
    if (off > whole.len or whole.len - off < len) {
        try out.print("{s}: the payload is past the end of the file\n", .{exe});
        out.flush() catch {};
        std.process.exit(70);
    }
    const payload = whole[@intCast(off)..][0..@intCast(len)];

    var it: tcl.Interp = undefined;
    try it.init(init.gpa);
    it.output = .{ .ctx = out, .write = write };
    it.mem_limit = 2 << 30;
    tcl.vfs.mountBytes(&it, "app", "", payload) catch |e| {
        try out.print("{s}: the payload is not a valid zip archive: {s}\n", .{ exe, @errorName(e) });
        out.flush() catch {};
        std.process.exit(70);
    };
    const z = &it.vfs.mounts.items[0].z;
    const m_entry = z.find(bn.manifest_name) orelse return error.NoManifest;
    const m = try bn.Manifest.parse(arena, try z.extract(arena, m_entry));
    const bits = (tcl.interp.Capability.parse(m.allow) orelse 0) | @backingInt(tcl.interp.Capability.embedded);
    it.clock_host = .{ .now = hostNow, .zone = hostZone };
    it.event_host = .{ .now = hostTicks, .sleep = hostSleep };
    if (comptime chan_ok) tcl.sys.ignorePipeSignal();
    if (comptime chan_ok) {
        if (m.root) |r| {
            try tcl.fsroot.setRoot(&it, r);
        } else if (bits & @backingInt(tcl.interp.Capability.file) != 0) {
            // A program gets host mode (#122), as the `ztcl` runner does.
            tcl.fsroot.setHost(&it) catch {};
        }
    }
    try it.allow(bits);
    if (!m.jit) it.disableJit();
    if (comptime chan_ok) {
        if (bits & @backingInt(tcl.interp.Capability.channels) != 0) try tcl.chan.useStdio(&it);
    }
    try it.register("exit", cmdExit);
    const a = it.alloc();
    var list: std.ArrayList(tcl.Value) = .empty;
    for (args[1..]) |w| try list.append(a, .{ .str = w });
    try it.setVar("argv", try tcl.value.wrapList(a, list.items));
    try it.setVar("argc", .{ .int = @intCast(list.items.len) });
    try it.setVar("argv0", .{ .str = args[0] });
    try it.setVar("tcl_interactive", .{ .int = 0 });
    for (m.scripts) |name| {
        const path = try std.fmt.allocPrint(a, "//zipfs:/app/{s}", .{name});
        const cmd = try tcl.value.newList(a, &.{ .{ .str = "source" }, .{ .str = path } });
        _ = it.eval(try it.str(cmd)) catch |e| tclshError(&it, e);
    }
    leave(&it, 0);
}

/// True for `ztcl compile FILE -proc NAME ...`, the compile of a point
/// proc (`src/compilecmd.zig`). Other forms go to `src/compile.zig`.
fn isPointCompile(args: []const [:0]const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, "-proc")) return true;
    return false;
}

/// Runs the runner. `setup` adds commands to the interpreter: the
/// suite runner passes its test commands here.
pub fn runWith(init: std.process.Init, setup: ?*const fn (*tcl.Interp) anyerror!void) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    host_io = io;
    var args = try init.minimal.args.toSlice(arena);
    host_preopens = init.preopens;
    // The child process of an isolated thread (ztcl#209): `--iso-fd N`,
    // or `--iso-handle 0x...` on Windows, the value of an inherited handle.
    if (comptime tcl.isothread.supported) {
        const flag = if (builtin.os.tag == .windows) "--iso-handle" else "--iso-fd";
        if (setup == null and args.len == 3 and std.mem.eql(u8, args[1], flag)) {
            const fd: tcl.isothread.Fd = if (comptime builtin.os.tag == .windows)
                @ptrFromInt(std.fmt.parseInt(usize, args[2], 0) catch std.process.exit(2))
            else
                std.fmt.parseInt(i32, args[2], 10) catch std.process.exit(2);
            std.process.exit(tcl.isothread.childProcess(init.gpa, fd, .{
                .clock = .{ .now = hostNow, .zone = hostZone },
                .event = .{ .now = hostTicks, .sleep = hostSleep },
                .sandbox = true,
            }));
        }
    }
    // A binary of `ztcl build` runs its payload and reads no option.
    if (builtin.os.tag != .wasi and setup == null) if (tcl.buildnative.payloadRange()) |r| return runApp(init, args, r.off, r.len);
    if (args.len > 1 and std.mem.eql(u8, args[1], "compile") and isPointCompile(args[2..])) {
        var out_buf: [4096]u8 = undefined;
        var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
        const code = try @import("compilecmd.zig").run(io, init.gpa, arena, args[2..], &out_w.interface);
        out_w.interface.flush() catch {};
        std.process.exit(code);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "compile")) std.process.exit(try @import("compile.zig").run(init, args[2..]));

    var out_buf: [1 << 16]u8 = undefined;
    var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    if (setup == null and args.len > 1 and std.mem.eql(u8, args[1], "build")) {
        const code = try @import("buildcmd.zig").run(io, arena, init.environ_map, args[2..], out);
        out.flush() catch {};
        if (code != 0) std.process.exit(code);
        return;
    }

    var in_buf: [1 << 16]u8 = undefined;
    var in_r: Io.File.Reader = .init(.stdin(), io, &in_buf);
    const words = try arena.alloc([]const u8, args.len);
    for (args, words) |w, *d| d.* = w;
    native_env = init.environ_map;
    const h: Host = .{
        .io = io,
        .gpa = init.gpa,
        .arena = arena,
        .args = words,
        .out = out,
        .in = &in_r.interface,
        .env = nativeEnv,
        .read = nativeRead,
        .exit = nativeExit,
        .nanos = nativeNanos,
        .clock = .{ .now = hostNow, .zone = hostZone },
        .event = .{ .now = hostTicks, .sleep = hostSleep },
    };
    return runHost(&h, setup);
}

var native_env: *std.process.Environ.Map = undefined;

fn nativeEnv(name: []const u8) ?[]const u8 {
    return native_env.get(name);
}

fn nativeRead(path: []const u8, a: std.mem.Allocator) anyerror![]u8 {
    return readScript(host_io, path, a);
}

fn nativeExit(code: u8) noreturn {
    std.process.exit(code);
}

fn nativeNanos() i96 {
    return Io.Clock.awake.now(host_io).toNanoseconds();
}

/// Runs the options and the scripts of `h.args` with the services of `h`.
pub fn runHost(h: *const Host, setup: ?*const fn (*tcl.Interp) anyerror!void) !void {
    host = h;
    const arena = h.arena;
    var args = h.args;
    const out = h.out;
    defer out.flush() catch {};

    // `ztcl debug`: its options, then the options of the runner.
    var debug_opts: ?tcl.debug.Options = null;
    if (setup == null and args.len > 1 and std.mem.eql(u8, args[1], "debug")) {
        var opts: tcl.debug.Options = .{};
        var keep: std.ArrayList(usize) = .empty;
        tcl.debug.parseArgs(arena, args[2..], &opts, &keep) catch {
            try out.writeAll(tcl.debug.help);
            out.flush() catch {};
            host.exit(2);
        };
        if (keep.items.len == 0 and !opts.mcp) {
            try out.writeAll(tcl.debug.help);
            return;
        }
        const rest = try arena.alloc(@TypeOf(args[0]), keep.items.len + 1);
        rest[0] = args[0];
        for (keep.items, 1..) |k, j| rest[j] = args[k + 2];
        args = rest;
        debug_opts = opts;
    }

    var it: tcl.Interp = undefined;
    try it.init(h.gpa);
    defer it.deinit();
    defer report(&it);
    it.output = .{ .ctx = out, .write = write };
    it.mem_limit = 2 << 30;
    // The runner starts the child process of an isolated thread.
    if (comptime tcl.isothread.supported) it.iso_runner = std.process.executablePathAlloc(h.io.?, arena) catch null;
    if (setup) |f| try f(&it);
    if (h.env("ZTCL_JIT")) |v| {
        if (std.mem.eql(u8, v, "off")) it.disableJit();
    }

    var exec_env: std.ArrayList([:0]const u8) = .empty;
    var tclsh = false;
    var cwd: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var timed = false;
    var keep_going = false;
    var verbose = false;
    var ran = false;
    var repeat: usize = 1;
    var jit_opts: tcl.jit.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        // After `--tclsh`, the script and its arguments end the options.
        if (tclsh and !std.mem.eql(u8, arg, "--cwd")) return runTclsh(&it, out, args[i..], root, cwd);
        if (std.mem.eql(u8, arg, "--time")) {
            timed = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--keep-going")) {
            keep_going = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
            flush_each = true;
            _ = try it.eval("set tt_verbose 1");
            continue;
        }
        if (std.mem.eql(u8, arg, "--compute") and i + 1 < args.len) {
            i += 1;
            it.compute_limit = try std.fmt.parseInt(u64, args[i], 10);
            max_compute = it.compute_limit;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gc-stress") and i + 1 < args.len) {
            i += 1;
            it.setGcStress(try std.fmt.parseInt(u32, args[i], 10));
            continue;
        }
        if (std.mem.eql(u8, arg, "--gc") and i + 1 < args.len) {
            i += 1;
            if (std.mem.eql(u8, args[i], "off")) {
                it.gc_on = false;
            } else if (std.mem.eql(u8, args[i], "on")) {
                it.gc_on = true;
            } else {
                try out.print("--gc needs on or off\n", .{});
                out.flush() catch {};
                host.exit(2);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--tcl") and i + 1 < args.len) {
            i += 1;
            const v = tcl.interp.TclVersion.parse(args[i]) orelse {
                try out.print("--tcl needs 8.6 or 9.1\n", .{});
                out.flush() catch {};
                host.exit(2);
            };
            try it.setTclVersion(v);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-jit")) {
            it.disableJit();
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit-threshold") and i + 1 < args.len) {
            i += 1;
            jit_opts.threshold = try std.fmt.parseInt(u32, args[i], 10);
            if (it.jit) |s| s.options = jit_opts;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit-dump") and i + 1 < args.len) {
            i += 1;
            dump_dir = args[i];
            jit_opts.on_code = dumpCode;
            if (it.jit) |s| s.options = jit_opts;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit-stress") and i + 1 < args.len) {
            i += 1;
            jit_opts.stress = try std.fmt.parseInt(u32, args[i], 10);
            if (it.jit) |s| s.options = jit_opts;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-jit-tier2")) {
            jit_opts.tier2 = false;
            if (it.jit) |s| s.options = jit_opts;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit-tier2-count") and i + 1 < args.len) {
            i += 1;
            jit_opts.tier2_count = try std.fmt.parseInt(u32, args[i], 10);
            if (it.jit) |s| s.options = jit_opts;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit-stress-alloc") and i + 1 < args.len) {
            i += 1;
            jit_opts.fail_from = try std.fmt.parseInt(u32, args[i], 10);
            if (it.jit) |s| s.options = jit_opts;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit-stats")) {
            jit_stats = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--report")) {
            report_on = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tclsh")) {
            tclsh = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cwd") and i + 1 < args.len) {
            i += 1;
            cwd = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--net") and i + 1 < args.len) {
            i += 1;
            it.net = (try tcl.sock.parsePolicy(arena, args[i])) orelse {
                try out.print("bad network policy \"{s}\"\n", .{args[i]});
                out.flush() catch {};
                host.exit(2);
            };
            continue;
        }
        // A test of the sandbox of Windows (`isolate_windows_tests.zig`)
        // runs a script in the sandbox, after the handle of the
        // transport. The runner skips the handle there.
        if (std.mem.eql(u8, arg, "--iso-handle") and i + 1 < args.len) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--exe-name") and i + 1 < args.len) {
            i += 1;
            it.exe_name = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--root") and i + 1 < args.len) {
            i += 1;
            root = args[i];
            tcl.fsroot.setRoot(&it, args[i]) catch {
                try out.print("cannot open the root folder \"{s}\"\n", .{args[i]});
                out.flush() catch {};
                host.exit(2);
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow") and i + 1 < args.len) {
            i += 1;
            const bits = tcl.interp.Capability.parse(args[i]) orelse {
                try out.print("unknown capability in \"{s}\"\n", .{args[i]});
                out.flush() catch {};
                host.exit(2);
            };
            it.clock_host = h.clock;
            it.event_host = h.event;
            // A write to a closed pipe or socket is an error of the
            // script. It must not end the runner.
            if (comptime chan_ok) tcl.sys.ignorePipeSignal();
            try it.allow(bits);
            // The files of the host, as in tclsh, unless --root came first.
            // A --root after this flag turns the jail on.
            const fs_bits = @backingInt(tcl.interp.Capability.file) | @backingInt(tcl.interp.Capability.channels);
            if (root == null and bits & fs_bits != 0 and !it.fs.host) tcl.fsroot.setHost(&it) catch {};
            continue;
        }
        if (std.mem.eql(u8, arg, "--registry-allow") and i + 1 < args.len) {
            i += 1;
            var list: std.ArrayList([]const u8) = .empty;
            var iter = std.mem.tokenizeScalar(u8, args[i], ',');
            while (iter.next()) |w| try list.append(arena, w);
            it.registry_allow = list.items;
            continue;
        }
        if ((std.mem.eql(u8, arg, "--keychain-allow") or std.mem.eql(u8, arg, "--defaults-allow")) and i + 1 < args.len) {
            i += 1;
            var list: std.ArrayList([]const u8) = .empty;
            var parts = std.mem.tokenizeScalar(u8, args[i], ',');
            while (parts.next()) |part| try list.append(arena, part);
            if (arg[2] == 'k') it.keychain_allow = list.items else it.defaults_allow = list.items;
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-timeout") and i + 1 < args.len) {
            i += 1;
            if (comptime exec_ok) it.exec_host.timeout_ms = try std.fmt.parseInt(u32, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-env") and i + 1 < args.len) {
            i += 1;
            if (comptime exec_ok) {
                try exec_env.append(arena, try arena.dupeSentinel(u8, args[i], 0));
                it.exec_host.env = exec_env.items;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-allow-root") and i + 1 < args.len) {
            i += 1;
            if (comptime exec_ok) {
                var list: std.ArrayList([]const u8) = .empty;
                var iter = std.mem.tokenizeScalar(u8, args[i], ',');
                while (iter.next()) |w| try list.append(arena, w);
                it.exec_host.allow_root = list.items;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--exec-allow") and i + 1 < args.len) {
            i += 1;
            if (comptime exec_ok) {
                var list: std.ArrayList([]const u8) = .empty;
                var iter = std.mem.tokenizeScalar(u8, args[i], ',');
                while (iter.next()) |w| try list.append(arena, w);
                it.exec_host.allow = list.items;
            }
            continue;
        }
        if (threadFlag(arg) and i + 1 < args.len) {
            i += 1;
            const n = try std.fmt.parseInt(u64, args[i], 10);
            var lim = it.thread_limits;
            if (std.mem.eql(u8, arg, "--threads")) lim.max_threads = @intCast(@min(n, 1 << 16));
            if (std.mem.eql(u8, arg, "--thread-compute")) lim.compute_limit = n;
            if (std.mem.eql(u8, arg, "--thread-mem")) lim.mem_limit = std.math.cast(usize, n) orelse return error.Overflow;
            if (std.mem.eql(u8, arg, "--threads-compute")) lim.total_compute = n;
            if (std.mem.eql(u8, arg, "--threads-mem")) lim.total_mem = std.math.cast(usize, n) orelse return error.Overflow;
            tcl.thread.setLimits(&it, lim);
            continue;
        }
        if (std.mem.eql(u8, arg, "--repeat") and i + 1 < args.len) {
            i += 1;
            repeat = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--mem") and i + 1 < args.len) {
            i += 1;
            it.mem_limit = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        ran = true;
        const text = h.read(arg, arena) catch |e| {
            try out.print("{s}: {s}\n", .{ arg, @errorName(e) });
            out.flush() catch {};
            host.exit(2);
        };
        it.error_line = 0;
        it.script_name = arg;
        if (debug_opts) |d| if (!d.mcp) host.exit(try runDebug(&it, out, arena, text, d));
        if (keep_going) {
            // Run each command of the file; an error does not stop the file.
            const script = it.compile(text) catch {
                try out.print("{s}:{d}: {s}\n", .{ arg, it.error_line, it.str(it.result) catch "" });
                continue;
            };
            var errors: usize = 0;
            // The script is only in this frame. After `enterHost`, the
            // collector scans the frame.
            it.enterHost();
            defer it.leaveHost();
            for (script.cmds) |*c| {
                _ = it.evalCmd(c) catch |e| {
                    if (e == error.TclReturn) break;
                    if (e == error.OutOfMemory) return e;
                    errors += 1;
                    try it.finishError();
                    if (verbose) try out.print("{s}:{d}: {s}\n", .{ arg, c.line, it.str(it.result) catch "" });
                    it.error_line = 0;
                };
            }
            if (errors > 0) try out.print("{s}: {d} commands failed outside the tests\n", .{ arg, errors });
            continue;
        }
        var best: i96 = std.math.maxInt(i96);
        for (0..@max(repeat, 1)) |_| {
            const start = h.nanos();
            _ = it.eval(text) catch |e| {
                const msg = if (e == error.TclError) it.str(it.result) catch "out of memory" else @errorName(e);
                try out.print("{s}:{d}: {s}\n", .{ arg, it.error_line, msg });
                out.flush() catch {};
                report(&it);
                host.exit(1);
            };
            best = @min(best, h.nanos() - start);
        }
        if (timed) try out.print("{s}: {d:.1} ms\n", .{ arg, @as(f64, @floatFromInt(best)) / 1e6 });
    }
    if (ran) return;
    if (debug_opts) |d| if (d.mcp) {
        var server: tcl.debugmcp.Server = .{ .it = &it, .gpa = h.gpa, .read = mcpRead };
        defer server.captured.deinit(h.gpa);
        return tcl.debugmcp.serve(&server, h.in, out);
    };
    if (tclsh) return runTclsh(&it, out, &.{}, root, cwd);

    // The interactive shell, when stdin and stdout are a terminal.
    const env = h.env;
    if (shell_ok and shell.term.interactive(h.io.?, env("TERM"))) {
        try out.flush();
        // The output of `puts` shows at once, before the next prompt.
        flush_each = true;
        var sh = shell.shell.Shell.init(std.heap.smp_allocator, &it, .{
            .io = h.io.?,
            .home = env("HOME") orelse env("USERPROFILE"),
            .no_color = env("NO_COLOR") != null,
            .editor_cmd = env("VISUAL") orelse env("EDITOR"),
        });
        defer sh.deinit();
        if (sh.loop()) |_| return else |e| if (e != error.NoTerminal) return e;
    }

    // The command line: one command for each line of stdin.
    const in = h.in;
    while (true) {
        try out.writeAll("% ");
        try out.flush();
        const line = in.takeDelimiterExclusive('\n') catch break;
        _ = in.take(1) catch {};
        it.error_line = 0;
        if (it.eval(line)) |v| {
            const s = try it.str(v);
            if (s.len > 0) try out.print("{s}\n", .{s});
        } else |e| {
            const msg = if (e == error.TclError) it.str(it.result) catch "out of memory" else @errorName(e);
            try out.print("error: {s}\n", .{msg});
        }
    }
}
