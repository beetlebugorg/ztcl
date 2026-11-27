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
//! The commands exist only after `ztcl_web_allow`, so they are absent by
//! default and in `ztcl.wasm`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const Interp = ztcl.Interp;
const Value = ztcl.Value;
const Error = ztcl.interp.Error;

pub const Op = enum(u32) {
    root = 1,
    get = 2,
    set = 3,
    call = 4,
    release = 5,
    call_async = 6,
};

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

        fn cmdRelease(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len != 2) return it.wrongArgs("web::release obj");
            _ = try call(it, gpa, .release, try handleOf(it, argv[1]), "", "");
            return Value.empty;
        }

        pub fn register(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("web::root", cmdRoot);
            try it.register("web::get", cmdGet);
            try it.register("web::set", cmdSet);
            try it.register("web::call", cmdCall);
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

/// Runs the script of one event of the host at the global level. `vals`
/// is a list in the form of the replies.
pub fn runEvent(it: *Interp, script: []const u8, vals: []const u8) Error!Value {
    var at: usize = 0;
    const list = (try readValue(it.alloc(), vals, &at)) orelse return it.fail("web: a bad event of the host", .{});
    const text = try appendWords(it.alloc(), script, try it.readList(list));
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
