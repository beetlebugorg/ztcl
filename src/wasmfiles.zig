//! The files and the channels of the scripts of ztcl.wasm and of the
//! shell of the site: `source`, `glob`, `open`, `read`, `gets`, `puts`
//! to a channel, `flush`, `eof`, `fblocked`, `fconfigure`, `fileevent`,
//! `close`, and `chan pipe`.
//!
//! The files of a bundle (`src/wasmbundle.zig`) are under the mount
//! `//zipfs:/app/`. A relative name is relative to the mount. A script
//! can also write files under the mount. These files are in memory, in
//! the memory limit of the interpreter, and they go away with it. A file
//! in memory hides a file of the bundle with the same name.
//!
//! `chan pipe` makes a pair of channels in memory. The bytes that go
//! into the second channel come out of the first.
//!
//! A read gives the bytes with no encoding and no end-of-line
//! translation. A read of a pipe gives only the bytes that are in the
//! pipe, as a channel with `-blocking 0` does: `gets` of a line with no
//! end yet gives -1, and `fblocked` gives 1. The output of a channel goes
//! to its file or pipe at `flush`, at `close`, and as `-buffering` sets:
//! `full` at 4,096 bytes, `line` at each newline, and `none` at each
//! `puts`.
//!
//! `fileevent` adds a channel to the event loop of `event.zig` through
//! `Interp.soft_chans`. A readable handler runs while bytes or the end of
//! the input wait in the channel. A writable handler runs on each pass.
//!
//! A folder is each prefix of a name that ends at a slash. `glob` matches
//! each part of a name with `string match`, so `*` stops at a slash.
//! A stream is a channel of the host, such as a serial port of Web Serial
//! (`src/wasmweb.zig`). The host adds its name with `addPort`, and `open`
//! of the name gives a channel. The bytes of the host come in through
//! `feed`, and a read gives the bytes that are there, as for a pipe. The
//! output goes to `StreamHost.call` at each flush. `fconfigure` of a
//! stream also has `-mode`, `-handshake`, `-ttycontrol`, and `-queue`,
//! which go to the host.
//!
//! The host turns the commands on with the `file` capability. With
//! `writable` false, as in ztcl.wasm, the files are read-only, as the
//! mount of a native program of `ztcl build` is: `open` for writing
//! gives `read-only file system`, and the commands for writes and pipes
//! are absent. The shell of the site sets `writable`. The full virtual
//! file system of issue #40 replaces this table.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const bundle = @import("wasmbundle.zig");
const event = @import("event.zig");
const Interp = interp.Interp;
const Value = @import("value.zig").Value;
const Cmd = interp.Cmd;
const Error = interp.Error;
const globMatch = @import("cmds.zig").globMatch;

pub const mount = "//zipfs:/app/";

/// True in `ztcl-host.wasm`, the only build with streams of the host.
/// Elsewhere the code of the streams ends at compile time.
const streams = blk: {
    const o = @import("build_options");
    break :blk @hasDecl(o, "wasm_host") and o.wasm_host;
};

fn streamOf(c: anytype) ?*Stream {
    if (comptime !streams) return null;
    return c.stream;
}

/// The size of the output of a channel with `-buffering full` that goes
/// to its file or pipe.
const buffer_size = 4096;

const Buffering = enum { full, line, none };

/// A file that a script wrote.
const File = struct { data: std.ArrayList(u8) = .empty };

/// The bytes between the two channels of `chan pipe`.
const Pipe = struct {
    data: std.ArrayList(u8) = .empty,
    /// The bytes before `pos` are read.
    pos: usize = 0,
    reader: bool = true,
    writer: bool = true,
};

/// The bytes of a stream of the host.
const Stream = struct {
    id: u32,
    data: std.ArrayList(u8) = .empty,
    /// The bytes before `pos` are read.
    pos: usize = 0,
    ended: bool = false,
    /// True when bytes or the end came after the last run of the readable
    /// handler. A partial line runs the handler once, as in Tcl.
    fresh: bool = false,
    /// The error of the host that ended the stream, or empty.
    err: []const u8 = "",
    mode: []const u8 = "",
};

/// The calls of the channels of streams to the host. `call` gives an
/// error of the interpreter for an error of the host.
pub const StreamOp = enum(u32) { write = 10, mode = 11, close = 12, handshake = 13, ttycontrol = 14 };
pub const StreamHost = struct {
    call: *const fn (it: *Interp, op: StreamOp, id: u32, data: []const u8) Error!void,
};

const Chan = struct {
    name: []const u8,
    /// A file of the bundle, for reading.
    fixed: []const u8 = &.{},
    file: ?*File = null,
    pipe: ?*Pipe = null,
    stream: ?*Stream = null,
    pos: usize = 0,
    readable: bool = true,
    writable: bool = false,
    append: bool = false,
    eof: bool = false,
    blocked: bool = false,
    blocking: bool = true,
    buffering: Buffering = .full,
    /// The output that did not go to the file or the pipe yet.
    out: std.ArrayList(u8) = .empty,
    on_read: ?[]const u8 = null,
    on_write: ?[]const u8 = null,
};

/// The files and the open channels of one interpreter.
pub const State = struct {
    payload: []const u8 = &.{},
    /// True after the commands are registered.
    on: bool = false,
    chans: std.ArrayList(?Chan) = .empty,
    /// The files in memory, by their name under the mount.
    files: std.StringArrayHashMapUnmanaged(*File) = .empty,
    /// The streams of the host, by name, after `addPort`.
    streams: std.StringArrayHashMapUnmanaged(*Stream) = .empty,
    stream_host: ?*const StreamHost = null,

    pub fn deinit(s: *State, a: std.mem.Allocator) void {
        s.chans.deinit(a);
        s.files.deinit(a);
        s.streams.deinit(a);
    }

    /// The most bytes that wait in a stream. More input ends the stream
    /// with an error.
    pub const stream_max = 1 << 20;

    /// Adds the stream `name` with the id `id` of the host. The streams
    /// are in the memory of `gpa`, outside the heap of the interpreter,
    /// because the host feeds them between two runs of a script.
    pub fn addPort(s: *State, gpa: std.mem.Allocator, name: []const u8, id: u32) std.mem.Allocator.Error!void {
        if (s.streams.get(name) != null) return;
        const st = try gpa.create(Stream);
        st.* = .{ .id = id };
        try s.streams.put(gpa, try gpa.dupe(u8, name), st);
    }

    /// Puts bytes of the host into the stream `id`: data (`kind` 0), the
    /// end (1), or an error that ends it (2, with the message in
    /// `bytes`). Gives false for an unknown id.
    pub fn feed(s: *State, gpa: std.mem.Allocator, id: u32, bytes: []const u8, kind: u32) std.mem.Allocator.Error!bool {
        for (s.streams.values()) |st| {
            if (st.id != id) continue;
            if (st.ended) return true;
            st.fresh = true;
            switch (kind) {
                0 => {
                    // Moves the bytes that wait to the start.
                    const left = st.data.items.len - st.pos;
                    std.mem.copyForwards(u8, st.data.items[0..left], st.data.items[st.pos..]);
                    st.data.items.len = left;
                    st.pos = 0;
                    if (left + bytes.len > stream_max) return s.feed(gpa, id, "the input buffer is full", 2);
                    try st.data.appendSlice(gpa, bytes);
                },
                1 => st.ended = true,
                else => {
                    st.ended = true;
                    gpa.free(st.err);
                    st.err = try gpa.dupe(u8, bytes);
                },
            }
            return true;
        }
        return false;
    }

    /// Empties a stream for the next `open` of its name.
    fn reset(st: *Stream, gpa: std.mem.Allocator) void {
        st.data.clearAndFree(gpa);
        st.pos = 0;
        st.ended = false;
        gpa.free(st.err);
        st.err = "";
        gpa.free(st.mode);
        st.mode = "";
    }
};

/// The name under the mount of `path`, in `buf`, or null for a path
/// outside the mount.
fn normalize(path: []const u8, buf: *[1024]u8) ?[]const u8 {
    var rest = path;
    if (std.mem.startsWith(u8, rest, mount)) {
        rest = rest[mount.len..];
    } else if (rest.len > 0 and rest[0] == '/') return null;
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
    return buf[0..len];
}

fn bundleData(payload: []const u8, name: []const u8) ?[]const u8 {
    var r: bundle.Reader = .init(payload);
    while (r.next()) |e| if (std.mem.eql(u8, e.name, name)) return e.data;
    return null;
}

/// The data of the file `path` of the bundle, or null. Each entry of the
/// bundle is a file under the mount.
pub fn lookup(payload: []const u8, path: []const u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    return bundleData(payload, normalize(path, &buf) orelse return null);
}

const Access = struct { read: bool = false, write: bool = false, create: bool = false, trunc: bool = false, append: bool = false };

/// The access of `open`: `r`, `w`, or `a` with `+` and `b`, or a list
/// of the POSIX flags.
fn parseAccess(m: []const u8) ?Access {
    if (m.len > 0 and std.ascii.isLower(m[0])) {
        var acc: Access = switch (m[0]) {
            'r' => .{ .read = true },
            'w' => .{ .write = true, .create = true, .trunc = true },
            'a' => .{ .write = true, .create = true, .append = true },
            else => return null,
        };
        for (m[1..]) |ch| switch (ch) {
            '+' => {
                acc.read = true;
                acc.write = true;
            },
            'b' => {},
            else => return null,
        };
        return acc;
    }
    var acc: Access = .{};
    var words = std.mem.tokenizeAny(u8, m, " \t\n");
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "RDONLY")) {
            acc.read = true;
        } else if (std.mem.eql(u8, w, "WRONLY")) {
            acc.write = true;
        } else if (std.mem.eql(u8, w, "RDWR")) {
            acc.read = true;
            acc.write = true;
        } else if (std.mem.eql(u8, w, "APPEND")) {
            acc.append = true;
        } else if (std.mem.eql(u8, w, "CREAT")) {
            acc.create = true;
        } else if (std.mem.eql(u8, w, "TRUNC")) {
            acc.trunc = true;
        } else if (!std.mem.eql(u8, w, "BINARY") and !std.mem.eql(u8, w, "NOCTTY") and !std.mem.eql(u8, w, "NONBLOCK")) return null;
    }
    if (!acc.read and !acc.write) return null;
    return acc;
}

/// The commands for the state that `stateOf` gives for an interpreter.
pub fn Commands(comptime stateOf: fn (*Interp) *State, comptime gpa: std.mem.Allocator, comptime writable: bool) type {
    return struct {
        const soft: interp.SoftChans = .{ .puts = putsTo, .ready = ready, .serve = serve };

        /// Adds the commands of the streams of the host: the commands of
        /// `register`, and `flush`, `fblocked`, `fconfigure`, and
        /// `fileevent`, for a build with no writable files.
        pub fn registerStreams(it: *Interp) std.mem.Allocator.Error!void {
            try register(it);
            if (comptime writable) return;
            try it.register("flush", flush);
            try it.register("fblocked", fblocked);
            try it.register("fconfigure", fconfigure);
            try it.register("fileevent", fileevent);
            it.soft_chans = &soft;
        }

        pub fn register(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("source", source);
            @import("cmds.zig").addBodyCommand(source);
            try it.register("open", open);
            try it.register("read", read);
            try it.register("gets", gets);
            try it.register("eof", eof);
            try it.register("close", close);
            try it.register("glob", glob);
            if (comptime !writable) return;
            try it.register("flush", flush);
            try it.register("fblocked", fblocked);
            try it.register("fconfigure", fconfigure);
            try it.register("fileevent", fileevent);
            try it.register("chan", chan);
            it.soft_chans = &soft;
        }

        fn eql(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }

        fn notFound(it: *Interp, what: []const u8, path: []const u8) Error {
            return it.failCode("POSIX ENOENT {no such file or directory}", "couldn't {s} \"{s}\": no such file or directory", .{ what, path });
        }

        /// The data of a file in memory or of the bundle, or null.
        fn fileData(s: *State, path: []const u8) ?[]const u8 {
            var buf: [1024]u8 = undefined;
            const name = normalize(path, &buf) orelse return null;
            if (s.files.get(name)) |f| return f.data.items;
            return bundleData(s.payload, name);
        }

        fn source(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2 and argv.len != 4) return it.wrongArgs("source ?-encoding name? fileName");
            const path = try it.str(argv[argv.len - 1]);
            var body = fileData(stateOf(it), path) orelse return notFound(it, "read file", path);
            // The ^Z character ends a script.
            if (std.mem.indexOfScalar(u8, body, 26)) |k| body = body[0..k];
            const a = it.alloc();
            // A script can write the file that it runs.
            body = try a.dupe(u8, body);
            const saved = it.script_name;
            it.script_name = try a.dupe(u8, path);
            defer it.script_name = saved;
            // In a direct call the script runs in the clean chain
            // (`Interp.evalBody`): the frame keeps the text, the compiled
            // script, and the old script name across the run.
            const script = try it.compile(body);
            const keep = [_]usize{ @intFromPtr(script), @intFromPtr(body.ptr), @intFromPtr(saved.ptr) };
            return it.evalBody(script, argv, &keep) catch |e| {
                if (e == error.TclReturn and it.ret_level <= 1 and it.ret_code == .ok) return it.result;
                if (e == error.TclError and it.in_error) {
                    it.error_info.print(a, "\n    (file \"{s}\" line {d})", .{ path, it.proc_line }) catch {};
                }
                return e;
            };
        }

        /// Adds a channel with the name PREFIX plus its index.
        fn newChan(it: *Interp, prefix: []const u8, c: Chan) Error![]const u8 {
            const s = stateOf(it);
            const n = for (s.chans.items, 0..) |x, i| {
                if (x == null) break i;
            } else blk: {
                try s.chans.append(gpa, null);
                break :blk s.chans.items.len - 1;
            };
            var x = c;
            x.name = try std.fmt.allocPrint(it.alloc(), "{s}{d}", .{ prefix, n });
            s.chans.items[n] = x;
            return x.name;
        }

        fn open(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 2 or argv.len > 4) return it.wrongArgs("open fileName ?access? ?permissions?");
            const path = try it.str(argv[1]);
            const mode = if (argv.len >= 3) try it.str(argv[2]) else "r";
            const acc = parseAccess(mode) orelse return it.fail("illegal access mode \"{s}\"", .{mode});
            const s = stateOf(it);
            if (comptime streams) if (s.streams.get(path)) |st| {
                for (s.chans.items) |x| if (x) |c| if (c.stream == st) return it.fail("couldn't open \"{s}\": the port is open", .{path});
                return .{ .str = try newChan(it, "serial", .{ .name = "", .stream = st, .readable = acc.read, .writable = acc.write }) };
            };
            if (comptime !writable) {
                if (acc.write) return it.failCode("POSIX EROFS {read-only file system}", "couldn't open \"{s}\": read-only file system", .{path});
            }
            var buf: [1024]u8 = undefined;
            const name = normalize(path, &buf) orelse {
                if (!acc.write) return notFound(it, "open", path);
                return it.failCode("POSIX EACCES {permission denied}", "couldn't open \"{s}\": permission denied", .{path});
            };
            if (!writable or !acc.write) {
                if (s.files.get(name)) |f| {
                    return .{ .str = try newChan(it, "file", .{ .name = "", .file = f }) };
                }
                const data = bundleData(s.payload, name) orelse return notFound(it, "open", path);
                return .{ .str = try newChan(it, "zipfs", .{ .name = "", .fixed = data }) };
            }
            if (name.len == 0) return it.failCode("POSIX EISDIR {illegal operation on a directory}", "couldn't open \"{s}\": illegal operation on a directory", .{path});
            const a = it.alloc();
            const f = s.files.get(name) orelse blk: {
                const old = bundleData(s.payload, name);
                if (old == null and !acc.create) return notFound(it, "open", path);
                const f = try a.create(File);
                f.* = .{};
                if (old) |d| try f.data.appendSlice(a, d);
                try s.files.put(gpa, try a.dupe(u8, name), f);
                break :blk f;
            };
            if (acc.trunc) f.data.clearRetainingCapacity();
            try it.checkMem();
            return .{ .str = try newChan(it, "file", .{ .name = "", .file = f, .readable = acc.read, .writable = true, .append = acc.append }) };
        }

        fn index(it: *Interp, name: []const u8) ?usize {
            const s = stateOf(it);
            const prefixes: []const []const u8 = if (streams) &.{ "zipfs", "file", "serial" } else &.{ "zipfs", "file" };
            for (prefixes) |p| {
                if (!std.mem.startsWith(u8, name, p)) continue;
                const n = std.fmt.parseInt(usize, name[p.len..], 10) catch return null;
                if (n < s.chans.items.len) {
                    if (s.chans.items[n]) |c| if (eql(c.name, name)) return n;
                }
            }
            return null;
        }

        fn find(it: *Interp, v: Value) Error!*Chan {
            const name = try it.str(v);
            const n = index(it, name) orelse return it.failCode("TCL LOOKUP CHANNEL", "can not find channel named \"{s}\"", .{name});
            return &stateOf(it).chans.items[n].?;
        }

        fn readableChan(it: *Interp, v: Value) Error!*Chan {
            const c = try find(it, v);
            if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
            try flushOut(it, c);
            return c;
        }

        fn text(it: *Interp, bytes: []const u8) Error!Value {
            const v: Value = .{ .str = try it.alloc().dupe(u8, bytes) };
            try it.checkMem();
            return v;
        }

        /// The bytes that a read of `c` can give now.
        fn input(c: *const Chan) []const u8 {
            if (c.pipe) |p| return p.data.items[p.pos..];
            if (streamOf(c)) |st| return st.data.items[st.pos..];
            const d = if (c.file) |f| f.data.items else c.fixed;
            return d[@min(c.pos, d.len)..];
        }

        fn consume(c: *Chan, n: usize) void {
            if (c.pipe) |p| {
                p.pos += n;
            } else if (streamOf(c)) |st| {
                st.pos += n;
            } else c.pos += n;
        }

        /// True when no more bytes can come: a file, or a pipe with no
        /// writer.
        fn ended(c: *const Chan) bool {
            if (streamOf(c)) |st| return st.ended;
            return if (c.pipe) |p| !p.writer else true;
        }

        /// The error of the host for a stream that ended with one.
        fn streamError(it: *Interp, c: *const Chan) Error!void {
            const st = streamOf(c) orelse return;
            if (st.err.len > 0 and st.pos == st.data.items.len) return it.fail("error reading \"{s}\": {s}", .{ c.name, st.err });
        }

        fn host(it: *Interp, c: *const Chan, op: StreamOp, data: []const u8) Error!void {
            const sh = stateOf(it).stream_host orelse return it.fail("channel \"{s}\": no host for the stream", .{c.name});
            return sh.call(it, op, streamOf(c).?.id, data);
        }

        fn flushOut(it: *Interp, c: *Chan) Error!void {
            if (c.out.items.len == 0) return;
            const a = it.alloc();
            defer c.out.clearRetainingCapacity();
            if (c.file) |f| {
                if (c.append) c.pos = f.data.items.len;
                const end = c.pos + c.out.items.len;
                if (end > f.data.items.len) try f.data.resize(a, end);
                @memcpy(f.data.items[c.pos..end], c.out.items);
                c.pos = end;
            } else if (streamOf(c) != null) {
                try host(it, c, .write, c.out.items);
            } else if (c.pipe) |p| {
                if (!p.reader) return it.failCode("POSIX EPIPE {broken pipe}", "error writing \"{s}\": broken pipe", .{c.name});
                if (p.pos == p.data.items.len) {
                    p.data.clearRetainingCapacity();
                    p.pos = 0;
                }
                try p.data.appendSlice(a, c.out.items);
            }
            try it.checkMem();
        }

        /// `puts` to a channel of this table. Gives false for another name.
        fn putsTo(it: *Interp, name: []const u8, bytes: []const u8, newline: bool) Error!bool {
            const n = index(it, name) orelse return false;
            const c = &stateOf(it).chans.items[n].?;
            if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
            const a = it.alloc();
            try c.out.appendSlice(a, bytes);
            if (newline) try c.out.append(a, '\n');
            try it.checkMem();
            const due = switch (c.buffering) {
                .none => true,
                .line => newline or std.mem.indexOfScalar(u8, bytes, '\n') != null,
                .full => c.out.items.len >= buffer_size,
            };
            if (due) try flushOut(it, c);
            return true;
        }

        fn ready(it: *Interp, name: []const u8) bool {
            const n = index(it, name) orelse return false;
            const c = &stateOf(it).chans.items[n].?;
            if (c.on_write != null) return true;
            if (streamOf(c)) |st| return c.on_read != null and st.fresh;
            return c.on_read != null and (input(c).len > 0 or ended(c));
        }

        /// Runs the handlers of a channel that `ready` gave. Gives true
        /// when a script ran.
        fn serve(cur: *Interp, it: *Interp, name: []const u8) Error!bool {
            var ran = false;
            inline for (.{ true, false }) |reading| {
                const n = index(it, name) orelse return ran;
                const c = &stateOf(it).chans.items[n].?;
                const script = if (reading) c.on_read else c.on_write;
                var due = if (reading) input(c).len > 0 or ended(c) else true;
                if (reading) if (streamOf(c)) |st| {
                    due = st.fresh;
                    st.fresh = false;
                };
                if (script != null and due) {
                    ran = true;
                    if (try event.runHandler(cur, it, script.?) == .gone) return true;
                }
            }
            return ran;
        }

        fn read(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            const usage = "read channelId ?numChars?\" or \"read ?-nonewline? channelId";
            if (argv.len < 2 or argv.len > 3) return it.wrongArgs(usage);
            const nonl = eql(try it.str(argv[1]), "-nonewline");
            if (nonl and argv.len != 3) return it.wrongArgs(usage);
            const c = try readableChan(it, argv[if (nonl) 2 else 1]);
            try streamError(it, c);
            const in = input(c);
            var end = in.len;
            if (argv.len == 3 and !nonl) {
                const n = try it.int(argv[2]);
                if (n < 0) return it.fail("expected non-negative integer but got \"{d}\"", .{n});
                end = @min(end, @as(usize, @intCast(n)));
            }
            var chunk = in[0..end];
            consume(c, end);
            const left = input(c).len;
            c.eof = left == 0 and ended(c);
            c.blocked = left == 0 and !ended(c);
            if (nonl and chunk.len > 0 and chunk[chunk.len - 1] == '\n') chunk = chunk[0 .. chunk.len - 1];
            return text(it, chunk);
        }

        fn gets(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2 and argv.len != 3) return it.wrongArgs("gets channelId ?varName?");
            const c = try readableChan(it, argv[1]);
            try streamError(it, c);
            const rest = input(c);
            var line: []const u8 = "";
            var got = false;
            c.blocked = false;
            if (std.mem.indexOfScalar(u8, rest, '\n')) |k| {
                line = rest[0..k];
                got = true;
                consume(c, k + 1);
            } else if (ended(c)) {
                line = rest;
                got = rest.len > 0;
                consume(c, rest.len);
                c.eof = true;
            } else c.blocked = true;
            const v = try text(it, line);
            if (argv.len == 2) return v;
            try it.setVar(try it.str(argv[2]), v);
            return .{ .int = if (got) @intCast(line.len) else -1 };
        }

        fn eof(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("eof channelId");
            return .{ .int = @intFromBool((try find(it, argv[1])).eof) };
        }

        fn fblocked(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("fblocked channelId");
            const c = try find(it, argv[1]);
            if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{c.name});
            return .{ .int = @intFromBool(c.blocked) };
        }

        fn flush(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("flush channelId");
            const c = try find(it, argv[1]);
            if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{c.name});
            try flushOut(it, c);
            return Value.empty;
        }

        fn fconfigure(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 2) return it.wrongArgs("fconfigure channelId ?-option value ...?");
            const c = try find(it, argv[1]);
            const opts = argv[2..];
            const bad = "bad option \"{s}\": should be one of -blocking or -buffering";
            const bad_port = "bad option \"{s}\": should be one of -blocking, -buffering, -handshake, -mode, -queue, or -ttycontrol";
            if (opts.len == 0) {
                if (streamOf(c)) |st| return .{ .str = try std.fmt.allocPrint(it.alloc(), "-blocking {d} -buffering {s} -mode {s}", .{ @intFromBool(c.blocking), @tagName(c.buffering), if (st.mode.len > 0) st.mode else "{}" }) };
                return .{ .str = try std.fmt.allocPrint(it.alloc(), "-blocking {d} -buffering {s}", .{ @intFromBool(c.blocking), @tagName(c.buffering) }) };
            }
            if (opts.len == 1) {
                const o = try it.str(opts[0]);
                if (eql(o, "-blocking")) return .{ .int = @intFromBool(c.blocking) };
                if (eql(o, "-buffering")) return .{ .str = @tagName(c.buffering) };
                if (streamOf(c)) |st| {
                    if (eql(o, "-mode")) return .{ .str = st.mode };
                    if (eql(o, "-queue")) return .{ .str = try std.fmt.allocPrint(it.alloc(), "{d} 0", .{input(c).len}) };
                    return it.fail(bad_port, .{o});
                }
                return it.fail(bad, .{o});
            }
            if (opts.len % 2 != 0) return it.fail("missing value for option \"{s}\"", .{try it.str(opts[opts.len - 1])});
            var k: usize = 0;
            while (k < opts.len) : (k += 2) {
                const o = try it.str(opts[k]);
                if (eql(o, "-blocking")) {
                    c.blocking = try @import("expr.zig").truthy(it, opts[k + 1]);
                } else if (eql(o, "-buffering")) {
                    const v = try it.str(opts[k + 1]);
                    c.buffering = std.meta.stringToEnum(Buffering, v) orelse return it.failCode("TCL VALUE FCONFIGURE BUFFERING", "bad value for -buffering: must be one of full, line, or none", .{});
                    if (c.buffering == .none) try flushOut(it, c);
                } else if (streamOf(c)) |st| {
                    const v = try it.str(opts[k + 1]);
                    if (eql(o, "-mode")) {
                        try flushOut(it, c);
                        try host(it, c, .mode, v);
                        const m = try gpa.dupe(u8, v);
                        gpa.free(st.mode);
                        st.mode = m;
                    } else if (eql(o, "-handshake")) {
                        try host(it, c, .handshake, v);
                    } else if (eql(o, "-ttycontrol")) {
                        try host(it, c, .ttycontrol, v);
                    } else return it.fail(bad_port, .{o});
                } else return it.fail(bad, .{o});
            }
            return Value.empty;
        }

        fn fileevent(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len != 3 and argv.len != 4) return it.wrongArgs("fileevent channelId event ?script?");
            const ev = try it.str(argv[2]);
            const reading = eql(ev, "readable");
            if (!reading and !eql(ev, "writable")) return it.failCode("TCL LOOKUP INDEX {event name}", "bad event name \"{s}\": must be readable or writable", .{ev});
            const c = try find(it, argv[1]);
            if (reading and !c.readable) return it.fail("channel is not readable", .{});
            if (!reading and !c.writable) return it.fail("channel is not writable", .{});
            const slot = if (reading) &c.on_read else &c.on_write;
            if (argv.len == 3) return .{ .str = slot.* orelse "" };
            const script = try it.str(argv[3]);
            if (script.len == 0) {
                slot.* = null;
                if (c.on_read == null and c.on_write == null) event.unwatch(it, c.name);
            } else {
                slot.* = try it.alloc().dupe(u8, script);
                try event.watch(it, c.name);
            }
            return Value.empty;
        }

        fn chan(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
            if (argv.len < 2) return it.wrongArgs("chan subcommand ?arg ...?");
            const sub = try it.str(argv[1]);
            if (eql(sub, "pipe")) {
                if (argv.len != 2) return it.wrongArgs("chan pipe");
                const a = it.alloc();
                const p = try a.create(Pipe);
                p.* = .{};
                const r = try newChan(it, "file", .{ .name = "", .pipe = p });
                const w = try newChan(it, "file", .{ .name = "", .pipe = p, .readable = false, .writable = true });
                return @import("value.zig").newList(a, &.{ .{ .str = r }, .{ .str = w } });
            }
            const table = [_]struct { []const u8, interp.NativeFn }{
                .{ "blocked", fblocked }, .{ "close", close },     .{ "configure", fconfigure },
                .{ "eof", eof },          .{ "event", fileevent }, .{ "flush", flush },
                .{ "gets", gets },        .{ "read", read },
            };
            for (table) |t| if (eql(sub, t[0])) return t[1](it, argv[1..], cmd);
            return it.failCode("TCL LOOKUP SUBCOMMAND", "unknown or ambiguous subcommand \"{s}\": must be blocked, close, configure, eof, event, flush, gets, pipe, or read", .{sub});
        }

        fn glob(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            const usage = "glob ?-nocomplain? ?-types d|f? ?--? pattern ?pattern ...?";
            var nocomplain = it.tcl9();
            var types: u8 = 0;
            var k: usize = 1;
            while (k < argv.len) : (k += 1) {
                const o = try it.str(argv[k]);
                if (eql(o, "--")) {
                    k += 1;
                    break;
                } else if (eql(o, "-nocomplain")) {
                    nocomplain = true;
                } else if (eql(o, "-types") and k + 1 < argv.len) {
                    k += 1;
                    const t = try it.str(argv[k]);
                    if (!eql(t, "d") and !eql(t, "f")) return it.fail("bad argument to \"-types\": {s}", .{t});
                    types = t[0];
                } else if (o.len > 0 and o[0] == '-') {
                    return it.fail("bad option \"{s}\": must be -nocomplain, -types, or --", .{o});
                } else break;
            }
            if (k >= argv.len) return it.wrongArgs(usage);
            const a = it.alloc();
            const s = stateOf(it);
            // The names of the bundle, then the names of the files in memory.
            var names: std.ArrayList([]const u8) = .empty;
            var r: bundle.Reader = .init(s.payload);
            while (r.next()) |e| try names.append(a, e.name);
            try names.appendSlice(a, s.files.keys());
            var found: std.ArrayList(Value) = .empty;
            var pats = std.ArrayList([]const u8).empty;
            for (argv[k..]) |v| try pats.append(a, try it.str(v));
            for (pats.items) |full| {
                const in_mount = std.mem.startsWith(u8, full, mount);
                const pat = if (in_mount) full[mount.len..] else full;
                const parts = std.mem.count(u8, pat, "/");
                for (names.items) |entry| {
                    // The name, then each folder above it.
                    var end = entry.len;
                    var is_dir = false;
                    while (true) {
                        const name = entry[0..end];
                        if (std.mem.count(u8, name, "/") == parts and (types == 0 or types == (if (is_dir) @as(u8, 'd') else 'f')) and globMatch(pat, name, false)) {
                            const out = if (in_mount) try std.fmt.allocPrint(a, "{s}{s}", .{ mount, name }) else try a.dupe(u8, name);
                            const dup = for (found.items) |f| {
                                if (eql(f.str, out)) break true;
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
            const name = try it.str(argv[1]);
            const n = index(it, name) orelse return it.failCode("TCL LOOKUP CHANNEL", "can not find channel named \"{s}\"", .{name});
            const s = stateOf(it);
            const c = &s.chans.items[n].?;
            const flushed = flushOut(it, c);
            if (c.pipe) |p| {
                if (c.readable) p.reader = false;
                if (c.writable) p.writer = false;
            }
            if (streamOf(c)) |st| {
                host(it, c, .close, "") catch {};
                State.reset(st, gpa);
            }
            if (c.on_read != null or c.on_write != null) event.unwatch(it, c.name);
            s.chans.items[n] = null;
            try flushed;
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
    try Commands(testState, a, true).register(&it);
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
