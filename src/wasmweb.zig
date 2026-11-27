//! The commands `web::` of `ztcl-host.wasm` (#251, task 01 of
//! docs/dev/web-api-tasks/README.md): a bridge to the Web APIs of the
//! page through a table of the Web IDL of the specs.
//!
//!   web::root name                   a root object, for example navigator.serial
//!   web::get obj attr                the value of an attribute
//!   web::set obj attr value          sets an attribute
//!   web::call obj method ?arg ...? ?-command script?
//!                                    calls a method; for a promise, the
//!                                    script gets the result later
//!   web::on obj event script         runs script for each event of obj
//!   web::off obj event               ends the script of `web::on`
//!   web::release obj                 ends the handle
//!
//! An object of the page is a handle `webN` in a table of
//! `web/ztcl-web.mjs`, so Tcl never gets a pointer. The table of the Web
//! IDL (`web/webidl-table.mjs`) lists each interface with its group, its
//! attributes, and its methods with the types of their arguments. The host
//! calls only a member of that table, and it converts each value by its
//! type. A member of a group that the page did not grant gives the error
//! `web: the group "serial" is not allowed`.
//!
//! Each command makes one call of the import
//! `ztcl_host.web(op, handle, a, a_len, b, b_len)` and costs one compute
//! unit. `a` is a name and `b` has the arguments as words. A word is the
//! byte `s`, a length (u32, little endian), and the bytes. A list is the
//! byte `l`, a count (u32), and the items. The host gives an integer. For
//! a value it puts one word or list into the memory of the module
//! (`ztcl_alloc`) and its address and length into `ztcl_web_reply`. A
//! negative integer is an error, with the message as a word of the reply.
//! A method that gives a promise needs `-command script`. The host puts
//! the result into a queue, and `Interp.runEvents` of `web/ztcl.mjs`
//! gives each one to `ztcl_web_event`, which runs the script at the
//! global level with two words appended: `ok` and the value, or `error`
//! and the message.
//!
//! `web::on` needs the attribute `on<event>` of the type `EventHandler`
//! in the table. The host puts each event into the same queue, and
//! `ztcl_web_event` puts the values of the event in place of `%type`,
//! `%target`, and `%detail` (`%%` is one `%`).
//!
//! Web Serial (task 06) gives a port as a channel of `wasmfiles.zig`:
//!
//!   web::serial::request ?-filters list? -command script
//!   web::serial::ports -command script
//!
//! The script gets `ok` and the name of a port (for `ports`, a list of
//! names), or `error` and the message. `open` of the name with `r+` gives
//! the channel, and `fconfigure -mode` opens the port at its baud. The
//! host reads the `ReadableStream` of the port into the channel with
//! `ztcl_web_serial_data`, so `gets`, `read`, and `fileevent readable`
//! work as for a pipe. A write goes to the `WritableStream` at each
//! flush.
//!
//! The commands exist only after `ztcl_web_allow`, so they are absent by
//! default and in `ztcl.wasm`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const Interp = ztcl.Interp;
const Value = ztcl.Value;
const Error = ztcl.interp.Error;
const wasmfiles = @import("wasmfiles.zig");

pub const Op = enum(u32) {
    root = 1,
    get = 2,
    set = 3,
    call = 4,
    release = 5,
    call_async = 6,
    on = 7,
    off = 8,
    serial_request = 9,
    serial_write = 10,
    serial_mode = 11,
    serial_close = 12,
    serial_handshake = 13,
    serial_ttycontrol = 14,
    serial_ports = 15,
};

/// The names of the substitutions of `web::on`, in the order of the
/// values of an event.
pub const subs = [_][]const u8{ "type", "target", "detail" };

const host = struct {
    extern "ztcl_host" fn web(op: u32, handle: i32, a: [*]const u8, a_len: usize, b: [*]const u8, b_len: usize) i32;
};

/// The reply of the last call: the address and the length of bytes that
/// the host put in the memory of the module with `ztcl_alloc`.
pub export var ztcl_web_reply: [2]u32 = .{ 0, 0 };

/// Appends `s` as one word.
pub fn putWord(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    try out.append(a, 's');
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(s.len))));
    try out.appendSlice(a, s);
}

/// Reads one word or list at `at.*` of `bytes` as a value. A list is a
/// Tcl list of its items. Gives null for bytes that are not in the form.
pub fn readValue(a: std.mem.Allocator, bytes: []const u8, at: *usize) std.mem.Allocator.Error!?Value {
    if (at.* + 5 > bytes.len) return null;
    const tag = bytes[at.*];
    const n = std.mem.readInt(u32, bytes[at.* + 1 ..][0..4], .little);
    at.* += 5;
    switch (tag) {
        's' => {
            if (n > bytes.len - at.*) return null;
            const s = try a.dupe(u8, bytes[at.*..][0..n]);
            at.* += n;
            return .{ .str = s };
        },
        'l' => {
            if (n > bytes.len - at.*) return null;
            const items = try a.alloc(Value, n);
            for (items) |*v| v.* = (try readValue(a, bytes, at)) orelse return null;
            return try ztcl.value.wrapList(a, items);
        },
        else => return null,
    }
}

fn call(it: *Interp, gpa: std.mem.Allocator, op: Op, handle: i32, a: []const u8, b: []const u8) Error!struct { rc: i32, value: Value } {
    if (it.compute_limit == 0) return it.fail("compute limit reached", .{});
    if (it.compute_limit != std.math.maxInt(u64)) it.compute_limit -= 1;
    ztcl_web_reply = .{ 0, 0 };
    const rc = host.web(@backingInt(op), handle, a.ptr, a.len, b.ptr, b.len);
    var value = Value.empty;
    if (ztcl_web_reply[1] > 0) {
        const p: [*]u8 = @ptrFromInt(ztcl_web_reply[0]);
        const bytes = p[0..ztcl_web_reply[1]];
        defer gpa.free(bytes);
        var at: usize = 0;
        value = (try readValue(it.alloc(), bytes, &at)) orelse return it.fail("web: a bad reply of the host", .{});
    }
    if (rc < 0) return it.fail("{s}", .{try it.str(value)});
    return .{ .rc = rc, .value = value };
}

fn handleOf(it: *Interp, v: Value) Error!i32 {
    const s = try it.str(v);
    if (std.mem.startsWith(u8, s, "web")) {
        if (std.fmt.parseInt(i32, s[3..], 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return it.fail("invalid web handle \"{s}\"", .{s});
}

/// The words of `args`, each one in the form of `putWord`.
fn words(it: *Interp, args: []const Value) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args) |v| try putWord(it.alloc(), &out, try it.str(v));
    return out.items;
}

pub fn Commands(comptime gpa: std.mem.Allocator) type {
    return struct {
        fn cmdRoot(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("web::root name");
            const r = try call(it, gpa, .root, 0, try it.str(argv[1]), "");
            return .{ .str = try std.fmt.allocPrint(it.alloc(), "web{d}", .{r.rc}) };
        }

        fn cmdGet(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 3) return it.wrongArgs("web::get obj attr");
            return (try call(it, gpa, .get, try handleOf(it, argv[1]), try it.str(argv[2]), "")).value;
        }

        fn cmdSet(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 4) return it.wrongArgs("web::set obj attr value");
            _ = try call(it, gpa, .set, try handleOf(it, argv[1]), try it.str(argv[2]), try words(it, argv[3..]));
            return Value.empty;
        }

        fn cmdCall(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len < 3) return it.wrongArgs("web::call obj method ?arg ...? ?-command script?");
            const n = argv.len;
            if (n >= 5 and std.mem.eql(u8, try it.str(argv[n - 2]), "-command")) {
                var out: std.ArrayList(u8) = .empty;
                try putWord(it.alloc(), &out, try it.str(argv[n - 1]));
                try out.appendSlice(it.alloc(), try words(it, argv[3 .. n - 2]));
                _ = try call(it, gpa, .call_async, try handleOf(it, argv[1]), try it.str(argv[2]), out.items);
                return Value.empty;
            }
            return (try call(it, gpa, .call, try handleOf(it, argv[1]), try it.str(argv[2]), try words(it, argv[3..]))).value;
        }

        fn cmdOn(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 4) return it.wrongArgs("web::on obj event script");
            var out: std.ArrayList(u8) = .empty;
            try putWord(it.alloc(), &out, try it.str(argv[3]));
            _ = try call(it, gpa, .on, try handleOf(it, argv[1]), try it.str(argv[2]), out.items);
            return Value.empty;
        }

        fn cmdOff(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 3) return it.wrongArgs("web::off obj event");
            _ = try call(it, gpa, .off, try handleOf(it, argv[1]), try it.str(argv[2]), "");
            return Value.empty;
        }

        fn cmdRelease(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("web::release obj");
            _ = try call(it, gpa, .release, try handleOf(it, argv[1]), "", "");
            return Value.empty;
        }

        fn cmdSerialRequest(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            const usage = "web::serial::request ?-filters list? -command script";
            var filters: []const u8 = "";
            var script: ?[]const u8 = null;
            var k: usize = 1;
            while (k + 1 < argv.len) : (k += 2) {
                const o = try it.str(argv[k]);
                if (std.mem.eql(u8, o, "-filters")) {
                    filters = try it.str(argv[k + 1]);
                } else if (std.mem.eql(u8, o, "-command")) {
                    script = try it.str(argv[k + 1]);
                } else return it.fail("bad option \"{s}\": must be -command or -filters", .{o});
            }
            if (k != argv.len or script == null) return it.wrongArgs(usage);
            var out: std.ArrayList(u8) = .empty;
            try putWord(it.alloc(), &out, script.?);
            try putWord(it.alloc(), &out, filters);
            _ = try call(it, gpa, .serial_request, 0, "", out.items);
            return Value.empty;
        }

        fn cmdSerialPorts(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 3 or !std.mem.eql(u8, try it.str(argv[1]), "-command")) return it.wrongArgs("web::serial::ports -command script");
            var out: std.ArrayList(u8) = .empty;
            try putWord(it.alloc(), &out, try it.str(argv[2]));
            _ = try call(it, gpa, .serial_ports, 0, "", out.items);
            return Value.empty;
        }

        /// The calls of the channels of the ports to the host.
        fn streamCall(it: *Interp, op: wasmfiles.StreamOp, id: u32, data: []const u8) Error!void {
            _ = try call(it, gpa, @fromBackingInt(@intCast(@backingInt(op))), @intCast(id), "", data);
        }

        pub const stream_host: wasmfiles.StreamHost = .{ .call = streamCall };

        /// Adds `web::serial::request` and `web::serial::ports`.
        pub fn registerSerial(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("web::serial::request", cmdSerialRequest);
            try it.register("web::serial::ports", cmdSerialPorts);
        }

        pub fn register(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("web::root", cmdRoot);
            try it.register("web::get", cmdGet);
            try it.register("web::set", cmdSet);
            try it.register("web::call", cmdCall);
            try it.register("web::on", cmdOn);
            try it.register("web::off", cmdOff);
            try it.register("web::release", cmdRelease);
        }
    };
}

/// Gives `script` with each value of `vals` appended as one list
/// element.
pub fn appendWords(a: std.mem.Allocator, script: []const u8, vals: []const Value) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, script);
    for (vals) |v| {
        try out.append(a, ' ');
        try ztcl.value.appendElement(a, &out, try v.toStr(a), false);
    }
    return out.toOwnedSlice(a);
}

/// Gives `script` with each `%name` of `subs` replaced by its value of
/// `vals` as one list element, and `%%` replaced by `%`.
pub fn substitute(a: std.mem.Allocator, script: []const u8, vals: []const Value) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    outer: while (k < script.len) {
        if (script[k] == '%' and k + 1 < script.len) {
            if (script[k + 1] == '%') {
                try out.append(a, '%');
                k += 2;
                continue;
            }
            for (subs, 0..) |n, j| {
                if (std.mem.startsWith(u8, script[k + 1 ..], n)) {
                    const v = if (j < vals.len) try vals[j].toStr(a) else "";
                    try ztcl.value.appendElement(a, &out, v, true);
                    k += 1 + n.len;
                    continue :outer;
                }
            }
        }
        try out.append(a, script[k]);
        k += 1;
    }
    return out.toOwnedSlice(a);
}

/// Runs the script of one event of the host at the global level. `vals`
/// is a list in the form of the replies. For a result of a promise
/// (`subst` false) the values go after the script. For an event of
/// `web::on` they go in place of the names of `subs`.
pub fn runEvent(it: *Interp, script: []const u8, vals: []const u8, subst: bool) Error!Value {
    var at: usize = 0;
    const list = (try readValue(it.alloc(), vals, &at)) orelse return it.fail("web: a bad event of the host", .{});
    const items = try it.list(list);
    const text = if (subst) try substitute(it.alloc(), script, items) else try appendWords(it.alloc(), script, items);
    const frame = it.frame;
    const ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    defer {
        it.frame = frame;
        it.ns = ns;
    }
    return it.eval(text);
}

/// Splits the Tcl list `text` for the host, which converts a sequence
/// or a dictionary of the Web IDL from a list. Gives the count of the
/// items, with a list of words in `ztcl_web_reply`, or -1 for a text
/// that is not a list, or -2 when the memory is full.
pub fn split(gpa: std.mem.Allocator, text: []const u8) i32 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = ztcl.value.parseList(arena.allocator(), text) catch |e| return if (e == error.OutOfMemory) -2 else -1;
    var out: std.ArrayList(u8) = .empty;
    out.append(gpa, 'l') catch return -2;
    out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(items.len)))) catch return -2;
    for (items) |v| {
        const s = v.toStr(arena.allocator()) catch return -2;
        putWord(gpa, &out, s) catch return -2;
    }
    const bytes = out.toOwnedSlice(gpa) catch return -2;
    ztcl_web_reply = .{ @intCast(@intFromPtr(bytes.ptr)), @intCast(bytes.len) };
    return @intCast(items.len);
}

test "the words of a promise go after the script as list elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const vals = [_]Value{ .{ .str = "ok" }, .{ .str = "a b" } };
    try std.testing.expectEqualStrings("done x ok {a b}", try appendWords(aa, "done x", &vals));
}

test "web::on puts the values of an event in place of %type, %target, and %detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const vals = [_]Value{ .{ .str = "connect" }, .{ .str = "web4" }, .{ .str = "" } };
    try std.testing.expectEqualStrings("got connect web4 {} 100%", try substitute(aa, "got %type %target %detail 100%%", &vals));
}

test "a reply of words and lists reads as a Tcl list" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.append(aa, 'l');
    try out.appendSlice(aa, &std.mem.toBytes(std.mem.nativeToLittle(u32, 2)));
    try putWord(aa, &out, "a b");
    try putWord(aa, &out, "web3");
    var at: usize = 0;
    const v = (try readValue(aa, out.items, &at)).?;
    try std.testing.expectEqualStrings("{a b} web3", try v.toStr(aa));
    at = 0;
    try std.testing.expect((try readValue(aa, out.items[0..7], &at)) == null);
}
