//! A runner for Tcl scripts: `ztcl [--time] [--fuel N] [--mem N] [--repeat N] file.tcl ...`.
//!
//! It runs the files in order in one interpreter and writes the output
//! of `puts` to stdout. With no file, it reads commands from stdin, one
//! line at a time. The runner reads the files itself; a script has no
//! command that reads a file.
//!
//! `--mem N` sets the memory limit in bytes. The default is 2 GiB.
//! `--repeat N` runs each file N times in one interpreter. With `--time`,
//! it prints the best time: the warm time of the file.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const tcl = @import("ztcl");

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const w: *Io.Writer = @ptrCast(@alignCast(ctx.?));
    w.writeAll(bytes) catch {};
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [1 << 16]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var it: tcl.Interp = undefined;
    try it.init(init.gpa);
    defer it.deinit();
    it.output = .{ .ctx = out, .write = write };
    it.mem_limit = 2 << 30;

    var timed = false;
    var keep_going = false;
    var verbose = false;
    var ran = false;
    var repeat: usize = 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
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
            _ = try it.eval("set tt_verbose 1");
            continue;
        }
        if (std.mem.eql(u8, arg, "--fuel") and i + 1 < args.len) {
            i += 1;
            it.fuel = try std.fmt.parseInt(u64, args[i], 10);
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
        const text = Io.Dir.cwd().readFileAlloc(io, arg, arena, .limited(64 << 20)) catch |e| {
            try out.print("{s}: {s}\n", .{ arg, @errorName(e) });
            out.flush() catch {};
            std.process.exit(2);
        };
        it.error_line = 0;
        if (keep_going) {
            // Run each command of the file; an error does not stop the file.
            const script = it.compile(text) catch {
                try out.print("{s}:{d}: {s}\n", .{ arg, it.error_line, it.str(it.result) catch "" });
                continue;
            };
            var errors: usize = 0;
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
            const start = Io.Clock.awake.now(io);
            _ = it.eval(text) catch |e| {
                const msg = if (e == error.TclError) it.str(it.result) catch "out of memory" else @errorName(e);
                try out.print("{s}:{d}: {s}\n", .{ arg, it.error_line, msg });
                out.flush() catch {};
                std.process.exit(1);
            };
            best = @min(best, start.untilNow(io, .awake).toNanoseconds());
        }
        if (timed) try out.print("{s}: {d:.1} ms\n", .{ arg, @as(f64, @floatFromInt(best)) / 1e6 });
    }
    if (ran) return;

    // The command line: one command for each line of stdin.
    var in_buf: [1 << 16]u8 = undefined;
    var in_r: Io.File.Reader = .init(.stdin(), io, &in_buf);
    const in = &in_r.interface;
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
