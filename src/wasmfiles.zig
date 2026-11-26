//! The files of a bundle (`src/wasmbundle.zig`) for the scripts of
//! ztcl.wasm: `source`, `glob`, and `open` for reading with `read`,
//! `gets`, `eof`, and `close`.
//!
//! The files are read-only and are under the mount `//zipfs:/app/`. A
//! relative name is relative to the mount. `read` and `gets` give the
//! bytes of the file with no encoding and no end-of-line translation.
//! A folder is each prefix of a name that ends at a slash. `glob` matches
//! each part of a name with `string match`, so `*` stops at a slash.
//! The host turns the commands on with the `file` capability. The full
//! virtual file system of issue #40 replaces this table.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const bundle = @import("wasmbundle.zig");
const Interp = interp.Interp;
const Value = @import("value.zig").Value;
const Cmd = interp.Cmd;
const Error = interp.Error;
const globMatch = @import("cmds.zig").globMatch;

pub const mount = "//zipfs:/app/";

const Chan = struct { data: []const u8, pos: usize = 0, eof: bool = false };

/// The files and the open channels of one interpreter.
pub const State = struct {
    payload: []const u8 = &.{},
    /// True after the commands are registered.
    on: bool = false,
    chans: std.ArrayList(?Chan) = .empty,

    pub fn deinit(s: *State, a: std.mem.Allocator) void {
        s.chans.deinit(a);
    }
};

/// The data of the file `path`, or null. Each entry of the bundle is a
/// file under the mount.
pub fn lookup(payload: []const u8, path: []const u8) ?[]const u8 {
    var rest = path;
    if (std.mem.startsWith(u8, rest, mount)) {
        rest = rest[mount.len..];
    } else if (rest.len > 0 and rest[0] == '/') return null;
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var iter = std.mem.tokenizeScalar(u8, rest, '/');
    while (iter.next()) |w| {
        if (std.mem.eql(u8, w, ".")) continue;
        if (std.mem.eql(u8, w, "..")) {
            if (len == 0) return null;
            len = if (std.mem.lastIndexOfScalar(u8, buf[0..len], '/')) |k| k else 0;
            continue;
        }
        const sep: usize = @intFromBool(len > 0);
        if (len + sep + w.len > buf.len) return null;
        if (sep == 1) buf[len] = '/';
        @memcpy(buf[len + sep ..][0..w.len], w);
        len += sep + w.len;
    }
    var r: bundle.Reader = .init(payload);
    while (r.next()) |e| if (std.mem.eql(u8, e.name, buf[0..len])) return e.data;
    return null;
}

/// The commands for the state that `stateOf` gives for an interpreter.
pub fn Commands(comptime stateOf: fn (*Interp) *State, comptime gpa: std.mem.Allocator) type {
    return struct {
        pub fn register(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("source", source);
            try it.register("open", open);
            try it.register("read", read);
            try it.register("gets", gets);
            try it.register("eof", eof);
            try it.register("close", close);
            try it.register("glob", glob);
        }

        fn notFound(it: *Interp, what: []const u8, path: []const u8) Error {
            return it.failCode("POSIX ENOENT {no such file or directory}", "couldn't {s} \"{s}\": no such file or directory", .{ what, path });
        }

        fn source(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2 and argv.len != 4) return it.wrongArgs("source ?-encoding name? fileName");
            const path = try it.str(argv[argv.len - 1]);
            var body = lookup(stateOf(it).payload, path) orelse return notFound(it, "read file", path);
            // The ^Z character ends a script.
            if (std.mem.indexOfScalar(u8, body, 26)) |k| body = body[0..k];
            const a = it.alloc();
            const saved = it.script_name;
            it.script_name = try a.dupe(u8, path);
            defer it.script_name = saved;
            const script = try it.compile(body);
            return it.evalScript(script) catch |e| {
                if (e == error.TclReturn and it.ret_level <= 1 and it.ret_code == .ok) return it.result;
                if (e == error.TclError and it.in_error) {
                    it.error_info.print(a, "\n    (file \"{s}\" line {d})", .{ path, it.proc_line }) catch {};
                }
                return e;
            };
        }

        fn open(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 2 or argv.len > 4) return it.wrongArgs("open fileName ?access? ?permissions?");
            const path = try it.str(argv[1]);
            if (argv.len >= 3) {
                const mode = try it.str(argv[2]);
                if (!std.mem.eql(u8, mode, "r") and !std.mem.eql(u8, mode, "rb") and !std.mem.eql(u8, mode, "RDONLY")) {
                    return it.failCode("POSIX EROFS {read-only file system}", "couldn't open \"{s}\": read-only file system", .{path});
                }
            }
            const data = lookup(stateOf(it).payload, path) orelse return notFound(it, "open", path);
            const s = stateOf(it);
            const n = for (s.chans.items, 0..) |c, i| {
                if (c == null) break i;
            } else blk: {
                try s.chans.append(gpa, null);
                break :blk s.chans.items.len - 1;
            };
            s.chans.items[n] = .{ .data = data };
            return .{ .str = try std.fmt.allocPrint(it.alloc(), "zipfs{d}", .{n}) };
        }

        fn index(it: *Interp, v: Value) Error!usize {
            const name = try it.str(v);
            const s = stateOf(it);
            if (std.mem.startsWith(u8, name, "zipfs")) {
                if (std.fmt.parseInt(usize, name[5..], 10)) |n| {
                    if (n < s.chans.items.len and s.chans.items[n] != null) return n;
                } else |_| {}
            }
            return it.failCode("TCL LOOKUP CHANNEL", "can not find channel named \"{s}\"", .{name});
        }

        fn find(it: *Interp, v: Value) Error!*Chan {
            const n = try index(it, v);
            return &stateOf(it).chans.items[n].?;
        }

        fn text(it: *Interp, bytes: []const u8) Error!Value {
            const v: Value = .{ .str = try it.alloc().dupe(u8, bytes) };
            try it.checkMem();
            return v;
        }

        fn read(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            const usage = "read channelId ?numChars?\" or \"read ?-nonewline? channelId";
            if (argv.len < 2 or argv.len > 3) return it.wrongArgs(usage);
            const nonl = std.mem.eql(u8, try it.str(argv[1]), "-nonewline");
            if (nonl and argv.len != 3) return it.wrongArgs(usage);
            const c = try find(it, argv[if (nonl) 2 else 1]);
            var end = c.data.len;
            if (argv.len == 3 and !nonl) {
                const n = try it.int(argv[2]);
                if (n < 0) return it.fail("expected non-negative integer but got \"{d}\"", .{n});
                end = @min(end, c.pos + @as(usize, @intCast(n)));
            }
            var chunk = c.data[c.pos..end];
            c.pos = end;
            if (c.pos == c.data.len) c.eof = true;
            if (nonl and chunk.len > 0 and chunk[chunk.len - 1] == '\n') chunk = chunk[0 .. chunk.len - 1];
            return text(it, chunk);
        }

        fn gets(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2 and argv.len != 3) return it.wrongArgs("gets channelId ?varName?");
            const c = try find(it, argv[1]);
            const rest = c.data[c.pos..];
            var line: []const u8 = rest;
            const got = rest.len > 0;
            if (std.mem.indexOfScalar(u8, rest, '\n')) |k| {
                line = rest[0..k];
                c.pos += k + 1;
            } else {
                c.pos = c.data.len;
                c.eof = true;
            }
            if (!got) c.eof = true;
            const v = try text(it, line);
            if (argv.len == 2) return v;
            try it.setVar(try it.str(argv[2]), v);
            return .{ .int = if (got) @intCast(line.len) else -1 };
        }

        fn eof(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("eof channelId");
            return .{ .int = @intFromBool((try find(it, argv[1])).eof) };
        }

        fn glob(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            const usage = "glob ?-nocomplain? ?-types d|f? ?--? pattern ?pattern ...?";
            var nocomplain = false;
            var types: u8 = 0;
            var k: usize = 1;
            while (k < argv.len) : (k += 1) {
                const o = try it.str(argv[k]);
                if (std.mem.eql(u8, o, "--")) {
                    k += 1;
                    break;
                } else if (std.mem.eql(u8, o, "-nocomplain")) {
                    nocomplain = true;
                } else if (std.mem.eql(u8, o, "-types") and k + 1 < argv.len) {
                    k += 1;
                    const t = try it.str(argv[k]);
                    if (!std.mem.eql(u8, t, "d") and !std.mem.eql(u8, t, "f")) return it.fail("bad argument to \"-types\": {s}", .{t});
                    types = t[0];
                } else if (o.len > 0 and o[0] == '-') {
                    return it.fail("bad option \"{s}\": must be -nocomplain, -types, or --", .{o});
                } else break;
            }
            if (k >= argv.len) return it.wrongArgs(usage);
            const a = it.alloc();
            var found: std.ArrayList(Value) = .empty;
            var pats = std.ArrayList([]const u8).empty;
            for (argv[k..]) |v| try pats.append(a, try it.str(v));
            for (pats.items) |full| {
                const in_mount = std.mem.startsWith(u8, full, mount);
                const pat = if (in_mount) full[mount.len..] else full;
                const parts = std.mem.count(u8, pat, "/");
                var r: bundle.Reader = .init(stateOf(it).payload);
                while (r.next()) |e| {
                    // The name, then each folder above it.
                    var end = e.name.len;
                    var is_dir = false;
                    while (true) {
                        const name = e.name[0..end];
                        if (std.mem.count(u8, name, "/") == parts and (types == 0 or types == (if (is_dir) @as(u8, 'd') else 'f')) and globMatch(pat, name, false)) {
                            const out = if (in_mount) try std.fmt.allocPrint(a, "{s}{s}", .{ mount, name }) else try a.dupe(u8, name);
                            const dup = for (found.items) |f| {
                                if (std.mem.eql(u8, f.str, out)) break true;
                            } else false;
                            if (!dup) try found.append(a, .{ .str = out });
                        }
                        end = std.mem.lastIndexOfScalar(u8, name, '/') orelse break;
                        is_dir = true;
                    }
                }
            }
            if (found.items.len == 0 and !nocomplain) return it.fail("no files matched glob pattern{s} \"{s}\"", .{ if (pats.items.len > 1) "s" else "", std.mem.join(a, " ", pats.items) catch "" });
            return @import("value.zig").newList(a, found.items);
        }

        fn close(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 2 or argv.len > 3) return it.wrongArgs("close channelId ?direction?");
            stateOf(it).chans.items[try index(it, argv[1])] = null;
            return Value.empty;
        }
    };
}

test "a name resolves under the mount" {
    const a = std.testing.allocator;
    const p = try bundle.encode(a, &.{
        .{ .kind = .script, .name = "app.tcl", .data = "puts hi" },
        .{ .kind = .file, .name = "data/a.txt", .data = "one\n" },
    });
    defer a.free(p);
    try std.testing.expectEqualStrings("one\n", lookup(p, "//zipfs:/app/data/a.txt").?);
    try std.testing.expectEqualStrings("one\n", lookup(p, "data/./a.txt").?);
    try std.testing.expectEqualStrings("one\n", lookup(p, "./x/../data/a.txt").?);
    try std.testing.expectEqualStrings("puts hi", lookup(p, "app.tcl").?);
    try std.testing.expect(lookup(p, "/data/a.txt") == null);
    try std.testing.expect(lookup(p, "../app.tcl") == null);
    try std.testing.expect(lookup(p, "data") == null);
}

test "glob gives the files and the folders of the bundle" {
    const a = std.testing.allocator;
    const p = try bundle.encode(a, &.{
        .{ .kind = .script, .name = "app.tcl", .data = "" },
        .{ .kind = .file, .name = "data/a.txt", .data = "" },
        .{ .kind = .file, .name = "data/b.txt", .data = "" },
    });
    defer a.free(p);
    var it: Interp = undefined;
    try it.init(a);
    defer it.deinit();
    var st: State = .{ .payload = p, .on = true };
    defer st.deinit(a);
    test_state = &st;
    try Commands(testState, a).register(&it);
    const cases = [_][2][]const u8{
        .{ "glob -nocomplain *", "app.tcl data" },
        .{ "glob -nocomplain -types d -- d*", "data" },
        .{ "glob -types f data/*", "data/a.txt data/b.txt" },
        .{ "glob //zipfs:/app/a*", "//zipfs:/app/app.tcl" },
        .{ "glob -nocomplain x*", "" },
        .{ "catch {glob x*} m; set m", "no files matched glob pattern \"x*\"" },
    };
    for (cases) |c| {
        const v = try it.eval(c[0]);
        try std.testing.expectEqualStrings(c[1], try it.str(v));
    }
}

var test_state: *State = undefined;
fn testState(_: *Interp) *State {
    return test_state;
}
