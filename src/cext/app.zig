//! The slots of an application that links libztcl in place of libtcl8.6:
//! `Tcl_CreateInterp`, `Tcl_DeleteInterp`, `Tcl_Exit`, the exit handlers,
//! and the startup script. `Tcl_MainEx`, `Tcl_PkgInitStubsCheck`, and
//! `Tcl_GetMemoryInfo` are in `tcl.h`, with `Tcl_Main`, and not in the stubs table, so
//! `src/libztcl.zig` exports them from `extra`.
//!
//! An interp of `Tcl_CreateInterp` is a ztcl interp on the C heap with
//! the capabilities of tclsh in host mode: files, channels on the
//! standard streams, `exec` with the environment of the process,
//! sockets with the policy `any`, the clock, and the event loop. The
//! `Tcl_Interp` pointer is its shadow (`cext.shadowOf`), so the slots
//! of the other groups reach it by its handle, as for a package.
//!
//! `Tcl_MainEx` follows the manual page of Tcl_Main: the first word of
//! `argv` that does not start with `-` is the script, `argv0`, `argv`,
//! `argc`, and `tcl_interactive` are set, the init function of the
//! application runs, and then the script runs or the commands of the
//! standard input run one complete command at a time.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const cext = @import("cext.zig");
const obj = @import("obj.zig");
const interp_mod = @import("../interp.zig");
const value = @import("../value.zig");
const Interp = interp_mod.Interp;
const Shadow = cext.Shadow;
const Value = value.Value;
const Error = interp_mod.Error;
const Cmd = interp_mod.Cmd;

const gpa = cext.gpa;

/// The capabilities of an interp of `Tcl_CreateInterp`.
const caps = "package,interp,clock,channels,file,event,socket,exec,thread,random,env,sqlite,cext";

/// The interps of `Tcl_CreateInterp` that are not deleted.
var live: std.ArrayList(*Interp) = .empty;
var live_lock: std.atomic.Mutex = .unlocked;

fn grab() void {
    while (!live_lock.tryLock()) {}
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn hostNow(_: ?*anyopaque) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io()).toNanoseconds(), 1000));
}

fn hostTicks(_: ?*anyopaque) i64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io()).toNanoseconds(), 1000));
}

fn hostSleep(_: ?*anyopaque, micros: i64) void {
    std.Io.sleep(io(), .fromNanoseconds(micros * 1000), .awake) catch {};
}

fn hostZone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const path = std.fmt.allocPrint(a, "/usr/share/zoneinfo/{s}", .{name}) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io(), path, a, .limited(1 << 20)) catch null;
}

fn writeOut(_: ?*anyopaque, bytes: []const u8) void {
    _ = @import("../sys.zig").write(1, bytes);
}

/// The environment of the process as `NAME=value` strings, for `exec`.
fn processEnv() []const [:0]const u8 {
    if (comptime builtin.os.tag == .windows) return &.{};
    var list: std.ArrayList([:0]const u8) = .empty;
    var p: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    var i: usize = 0;
    while (p[i]) |e| : (i += 1) list.append(gpa, std.mem.span(e)) catch break;
    _ = &p;
    return list.items;
}

/// A ztcl interp with the capabilities of tclsh in host mode.
fn newInterp() !*Interp {
    const it = try gpa.create(Interp);
    errdefer gpa.destroy(it);
    try it.init(gpa);
    errdefer it.deinit();
    it.mem_limit = std.math.maxInt(@TypeOf(it.mem_limit));
    it.output = .{ .ctx = null, .write = writeOut };
    it.clock_host = .{ .now = hostNow, .zone = hostZone };
    it.event_host = .{ .now = hostTicks, .sleep = hostSleep };
    it.net = .any;
    if (comptime @import("../proc.zig").supported) it.exec_host.env = processEnv();
    @import("../sys.zig").ignorePipeSignal();
    try it.allow(interp_mod.Capability.parse(caps).?);
    if (it.chans.table.get("stdin") == null) try @import("../chan.zig").useStdio(it);
    @import("../fsroot.zig").setHost(it) catch {};
    try it.register("exit", cmdExit);
    if (exe_name.*) |e| it.exe_name = std.mem.span(e);
    return it;
}

fn cmdExit(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("exit ?returnCode?");
    var code: i64 = 0;
    if (argv.len == 2) code = argv[1].asInt() orelse return it.fail("expected integer but got \"{s}\"", .{try it.str(argv[1])});
    slots.Tcl_Exit(@truncate(code));
}

/// The value of `Tcl_FindExecutable`, from `pkgs.zig`.
const exe_name = &@import("pkgs.zig").exe_name;

const ExitHandler = struct { proc: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque };
var exit_handlers: std.ArrayList(ExitHandler) = .empty;
var startup_script: ?*obj.Obj = null;
var startup_encoding: ?[*:0]const u8 = null;
var exiting = false;

/// Runs the exit handlers, last in first, and deletes each interp, so
/// the channels flush.
fn finalize() void {
    if (exiting) return;
    exiting = true;
    while (exit_handlers.pop()) |h| h.proc(h.data);
    grab();
    const all = live.toOwnedSlice(gpa) catch &.{};
    live_lock.unlock();
    for (all) |it| free(it);
}

/// Flushes and drops the channels of the standard streams, so the
/// descriptors 0, 1, and 2 stay open for the program, as in Tcl. Then
/// frees the interp.
fn free(it: *Interp) void {
    _ = it.eval("foreach c {stdout stderr} {catch {flush $c}}") catch {};
    for ([_][]const u8{ "stdin", "stdout", "stderr" }) |n| _ = it.chans.table.orderedRemove(n);
    it.deinit();
    gpa.destroy(it);
}

pub const slots = struct {
    pub fn Tcl_CreateInterp() callconv(.c) ?*Shadow {
        const it = newInterp() catch return null;
        const sh = cext.shadowOf(it) catch {
            it.deinit();
            gpa.destroy(it);
            return null;
        };
        grab();
        defer live_lock.unlock();
        live.append(gpa, it) catch {};
        return sh;
    }

    /// Deletes the interp at once. Tcl waits for each `Tcl_Release` of
    /// the interp first.
    pub fn Tcl_DeleteInterp(sh: *Shadow) callconv(.c) void {
        const it = sh.it;
        grab();
        for (live.items, 0..) |x, i| {
            if (x == it) {
                _ = live.swapRemove(i);
                break;
            }
        }
        live_lock.unlock();
        free(it);
    }

    /// An interp is deleted at once, so a pointer that C code still has
    /// is never in the middle of a delete.
    pub fn Tcl_InterpDeleted(_: *Shadow) callconv(.c) c_int {
        return 0;
    }

    pub fn Tcl_Exit(status: c_int) callconv(.c) noreturn {
        finalize();
        std.c.exit(status);
    }

    pub fn Tcl_Finalize() callconv(.c) void {
        finalize();
    }

    pub fn Tcl_CreateExitHandler(proc: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) callconv(.c) void {
        exit_handlers.append(gpa, .{ .proc = proc, .data = data }) catch {};
    }

    pub fn Tcl_DeleteExitHandler(proc: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) callconv(.c) void {
        for (exit_handlers.items, 0..) |h, i| {
            if (h.proc == proc and h.data == data) {
                _ = exit_handlers.orderedRemove(i);
                return;
            }
        }
    }

    pub fn Tcl_SetStartupScript(path: ?*obj.Obj, encoding: ?[*:0]const u8) callconv(.c) void {
        if (path) |p| obj.incr(p);
        if (startup_script) |p| obj.decr(p);
        startup_script = path;
        startup_encoding = encoding;
    }

    pub fn Tcl_GetStartupScript(encoding: ?*?[*:0]const u8) callconv(.c) ?*obj.Obj {
        if (encoding) |e| e.* = startup_encoding;
        return startup_script;
    }
};

pub const AppInitFn = *const fn (*Shadow) callconv(.c) c_int;

/// The functions of `tcl.h` outside the stubs table.
pub const extra = struct {
    pub fn Tcl_MainEx(argc: c_int, argv: [*]const [*:0]const u8, app_init: ?AppInitFn, sh_in: ?*Shadow) callconv(.c) noreturn {
        const sh = sh_in orelse {
            _ = @import("../sys.zig").write(2, "libztcl: Tcl_CreateInterp failed\n");
            std.c.exit(1);
        };
        main(sh, argv[0..@intCast(argc)], app_init) catch {};
        slots.Tcl_Exit(0);
    }

    /// The function form of the macro `Tcl_Main` of `tcl.h`, for a
    /// program built against older headers. libtcl8.6 exports it too.
    pub fn Tcl_Main(argc: c_int, argv: [*]const [*:0]const u8, app_init: ?AppInitFn) callconv(.c) noreturn {
        Tcl_MainEx(argc, argv, app_init, slots.Tcl_CreateInterp());
    }

    pub fn Tcl_PkgInitStubsCheck(sh: *Shadow, version: [*:0]const u8, exact: c_int) callconv(.c) ?[*:0]const u8 {
        return @import("host.zig").slots.Tcl_PkgRequireEx(&sh.core, "Tcl", version, exact, null);
    }

    /// The text of the memory use of `Tcl_GetMemoryInfo`, which needs a
    /// build of Tcl with its own allocator. libztcl adds no text.
    pub fn Tcl_GetMemoryInfo(_: *anyopaque) callconv(.c) void {}
};

fn writeErr(text: []const u8) void {
    _ = @import("../sys.zig").write(2, text);
}

fn main(sh: *Shadow, args: []const [*:0]const u8, app_init: ?AppInitFn) !void {
    const it = sh.it;
    const a = it.alloc();
    var rest: []const [*:0]const u8 = if (args.len > 0) args[1..] else args;
    var argv0: []const u8 = if (args.len > 0) std.mem.span(args[0]) else "tclsh";
    // `-encoding name fileName` or `fileName` gives the startup script.
    if (startup_script == null and rest.len > 0) {
        const w = std.mem.span(rest[0]);
        if (std.mem.eql(u8, w, "-encoding") and rest.len > 2 and rest[2][0] != '-') {
            slots.Tcl_SetStartupScript(obj.Tcl_NewStringObj(rest[2], -1), rest[1]);
            rest = rest[3..];
        } else if (w.len > 0 and w[0] != '-') {
            slots.Tcl_SetStartupScript(obj.Tcl_NewStringObj(rest[0], -1), null);
            rest = rest[1..];
        }
    }
    const script: ?[]const u8 = if (startup_script) |p| obj.text(p) else null;
    if (script) |s| argv0 = s;
    var list: std.ArrayList(Value) = .empty;
    for (rest) |w| try list.append(a, .{ .str = std.mem.span(w) });
    try it.setVar("::argv", try value.wrapList(a, list.items));
    try it.setVar("::argc", .{ .int = @intCast(list.items.len) });
    try it.setVar("::argv0", .{ .str = argv0 });
    const tty = script == null and std.c.isatty(0) != 0;
    try it.setVar("::tcl_interactive", .{ .int = @intFromBool(tty) });

    if (app_init) |f| {
        if (f(sh) != cext.TCL_OK) {
            const msg = std.mem.span(obj.Tcl_GetStringResult(&sh.core));
            writeErr("application-specific initialization failed: ");
            writeErr(msg);
            writeErr("\n");
        }
    }

    if (script) |s| {
        const cmd = try std.fmt.allocPrint(a, "source {s}", .{try it.str(try value.newList(a, &.{.{ .str = s }}))});
        _ = it.eval(cmd) catch |e| {
            if (e == error.TclError) {
                const info = it.getVarPlain("::errorInfo") catch it.result;
                var t = it.str(info) catch "error";
                // Tcl_Main runs the file with no `source` command, so its
                // trace ends at the line of the file.
                const tail = try std.fmt.allocPrint(a, "\n    invoked from within\n\"{s}\"", .{cmd});
                if (std.mem.endsWith(u8, t, tail)) t = t[0 .. t.len - tail.len];
                writeErr(t);
                writeErr("\n");
                slots.Tcl_Exit(1);
            }
            return e;
        };
        return;
    }
    // The commands of the standard input, one complete command at a time.
    // In a terminal, the rc file runs first, each result shows, and the
    // prompt is "% ".
    _ = it.eval(
        \\apply {{} {
        \\    if {$::tcl_interactive && [info exists ::tcl_rcFileName]} {
        \\        catch {
        \\            set f [file normalize $::tcl_rcFileName]
        \\            if {[file readable $f]} {uplevel #0 [list source $f]}
        \\        }
        \\    }
        \\    set cmd {}
        \\    if {$::tcl_interactive} {puts -nonewline "% "; flush stdout}
        \\    while {[gets stdin line] >= 0} {
        \\        append cmd $line \n
        \\        if {![info complete $cmd]} continue
        \\        set now $cmd
        \\        set cmd {}
        \\        if {[catch {uplevel #0 $now} msg]} {
        \\            puts stderr $msg
        \\        } elseif {$::tcl_interactive && $msg ne {}} {
        \\            puts $msg
        \\        }
        \\        if {$::tcl_interactive} {puts -nonewline "% "; flush stdout}
        \\    }
        \\    if {$cmd ne {}} {catch {uplevel #0 $cmd}}
        \\}}
    ) catch |e| {
        if (e == error.TclError) {
            writeErr(it.str(it.result) catch "error");
            writeErr("\n");
            return;
        }
        return e;
    };
}
