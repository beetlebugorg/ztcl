//! Channel transforms: `chan push channel cmdprefix` and
//! `chan pop channel`.
//!
//! A transform is a `Filter` of `chan.zig` on top of the filter of the
//! channel (a TLS channel, a reflected channel, or a lower transform),
//! or on top of the descriptor. The channel keeps one filter, the top
//! of the stack, and each transform has the one below it:
//!
//! - A read of the channel reads the layer below, 4,096 bytes at most,
//!   and gives the bytes to `{*}prefix read rtN BYTES`. The result goes
//!   to the channel. At the end of the data below, `drain rtN` gives
//!   the last bytes, then the transform gives the end of the data.
//! - A write gives the bytes to `write rtN BYTES` and writes the
//!   result to the layer below.
//! - `flush rtN` runs at the close and at `chan pop`, and its result
//!   goes to the layer below. `clear rtN` runs at `seek`, and the
//!   transform drops the bytes that it holds. `finalize rtN` runs at
//!   the close and at `chan pop`.
//!
//! A transform with no `read` method passes the read bytes as they
//! are, and the same for `write`. At `chan pop` the bytes that the
//! transform holds and the result of `drain` go to the read buffer of
//! the channel. The checks and the messages follow tclsh 8.6.16. Two
//! differences: an error of the `read` method is an error of the read
//! (tclsh 8.6.16 gives the end of the data), and the method `limit?`
//! is accepted and not called.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const more = @import("more.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;
const Channel = chan.Channel;

/// The methods of a transform, in the order of the message of Tcl.
const Method = enum { clear, drain, finalize, flush, initialize, @"limit?", read, write };

fn bit(m: Method) u16 {
    return @as(u16, 1) << @backingInt(m);
}

pub const Xform = struct {
    filter: chan.Filter = .{ .read = fRead, .write = fWrite, .closeWrite = fCloseWrite, .deinit = fDeinit },
    it: *Interp,
    c: *Channel,
    name: []const u8,
    prefix: []const Value,
    methods: u16,
    /// The filter below, or null for the descriptor of the channel.
    below: ?*chan.Filter,
    /// The transform below, for `chan pop`.
    under: ?*Xform,
    /// The result of `read` or `drain` that the channel did not take.
    pending: std.ArrayList(u8) = .empty,
    ppos: usize = 0,
    drained: bool = false,
    finalized: bool = false,

    fn has(x: *const Xform, m: Method) bool {
        return x.methods & bit(m) != 0;
    }

    /// Calls the method `m` with the handle and the bytes `data`, if
    /// any, and gives the bytes of the result.
    fn call(x: *Xform, m: Method, data: ?[]const u8) Error![]const u8 {
        const it = x.it;
        const n: usize = if (data != null) 3 else 2;
        const words = try it.alloc().alloc(Value, x.prefix.len + n);
        @memcpy(words[0..x.prefix.len], x.prefix);
        words[x.prefix.len] = .{ .str = @tagName(m) };
        words[x.prefix.len + 1] = .{ .str = x.name };
        if (data) |d| {
            // A copy: the buffers of the channel change after the call.
            const t = try more.fromBytes(it, d);
            words[x.prefix.len + 2] = .{ .str = if (t.ptr == d.ptr) try it.alloc().dupe(u8, t) else t };
        }
        const got = try it.callWords(words);
        return more.toBytes(it, try it.str(got));
    }

    fn readBelow(x: *Xform, buf: []u8) Error!usize {
        if (x.below) |b| return b.read(b, x.it, x.c.fd, buf);
        return chan.rawRead(x.it, x.c, buf);
    }

    fn writeBelow(x: *Xform, data: []const u8) Error!void {
        if (data.len == 0) return;
        if (x.below) |b| return b.write(b, x.it, chan.writeFd(x.c), data);
        return chan.rawWrite(x.it, x.c, data);
    }

    /// `flush`, with its result written below, on a channel that can
    /// write.
    fn flushLayer(x: *Xform) Error!void {
        if (!x.has(.flush)) return;
        const out = try x.call(.flush, null);
        if (x.c.writable) try x.writeBelow(out);
    }

    fn finalize(x: *Xform) Error!void {
        if (x.finalized) return;
        x.finalized = true;
        _ = try x.call(.finalize, null);
    }

    /// `clear` at a seek: the held bytes go.
    pub fn clear(x: *Xform) Error!void {
        x.pending.clearRetainingCapacity();
        x.ppos = 0;
        x.drained = false;
        if (x.has(.clear)) _ = try x.call(.clear, null);
    }
};

fn of(f: *chan.Filter) *Xform {
    return @fieldParentPtr("filter", f);
}

fn fRead(f: *chan.Filter, it: *Interp, _: i32, buf: []u8) Error!usize {
    const x = of(f);
    while (true) {
        if (x.ppos < x.pending.items.len) {
            const n = @min(buf.len, x.pending.items.len - x.ppos);
            @memcpy(buf[0..n], x.pending.items[x.ppos .. x.ppos + n]);
            x.ppos += n;
            return n;
        }
        x.pending.clearRetainingCapacity();
        x.ppos = 0;
        if (x.drained) return 0;
        var tmp: [4096]u8 = undefined;
        const n = try x.readBelow(&tmp);
        if (n == 0) {
            x.drained = true;
            if (x.has(.drain)) try x.pending.appendSlice(it.alloc(), try x.call(.drain, null));
            continue;
        }
        const out = if (x.has(.read)) try x.call(.read, tmp[0..n]) else tmp[0..n];
        try x.pending.appendSlice(it.alloc(), out);
    }
}

fn fWrite(f: *chan.Filter, _: *Interp, _: i32, data: []const u8) Error!void {
    const x = of(f);
    try x.writeBelow(if (x.has(.write)) try x.call(.write, data) else data);
}

/// The close of the write side: `flush`, then the layer below.
fn fCloseWrite(f: *chan.Filter, it: *Interp, fd: i32) void {
    const x = of(f);
    x.flushLayer() catch {};
    if (x.below) |b| b.closeWrite(b, it, fd);
}

fn fDeinit(f: *chan.Filter, it: *Interp) void {
    const x = of(f);
    x.finalize() catch {};
    if (x.below) |b| b.deinit(b, it);
}

/// `chan push channel cmdprefix`.
pub fn push(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 4) return it.wrongArgs("chan push channel cmdprefix");
    const c = try chan.findChannel(it, argv[2]);
    if (c.ext != null) return it.fail("channel \"{s}\" belongs to a C package", .{c.name});
    const prefix = try it.alloc().dupe(Value, try it.list(argv[3]));
    const text = try it.str(argv[3]);
    const name = try std.fmt.allocPrint(it.alloc(), "rt{d}", .{it.chans.next_rt});
    it.chans.next_rt += 1;

    var mode: std.ArrayList(Value) = .empty;
    if (c.readable) try mode.append(it.alloc(), .{ .str = "read" });
    if (c.writable) try mode.append(it.alloc(), .{ .str = "write" });
    const words = try it.alloc().alloc(Value, prefix.len + 3);
    @memcpy(words[0..prefix.len], prefix);
    words[prefix.len] = .{ .str = "initialize" };
    words[prefix.len + 1] = .{ .str = name };
    words[prefix.len + 2] = try value.wrapList(it.alloc(), mode.items);
    const got = try it.callWords(words);

    var methods: u16 = 0;
    for (try it.list(got)) |w| {
        const m = try it.str(w);
        const k = std.meta.stringToEnum(Method, m) orelse
            return it.failWord("TCL LOOKUP INDEX method", m, "chan handler \"{s} initialize\" returned bad method \"{s}\": must be clear, drain, finalize, flush, initialize, limit?, read, or write", .{ text, m });
        methods |= bit(k);
    }
    const need = bit(.initialize) | bit(.finalize);
    if (methods & need != need) return it.fail("chan handler \"{s}\" does not support all required methods", .{text});
    const reads = c.readable and methods & bit(.read) != 0;
    const writes = c.writable and methods & bit(.write) != 0;
    if (!reads and !writes) return it.fail("chan handler \"{s}\" makes the channel inaccessible", .{text});

    // The output so far goes below the new transform.
    try chan.flushChannel(it, c);
    const x = try it.alloc().create(Xform);
    x.* = .{ .it = it, .c = c, .name = name, .prefix = prefix, .methods = methods, .below = c.filter, .under = c.xform };
    c.filter = &x.filter;
    c.xform = x;
    return .{ .str = c.name };
}

/// `chan pop channel`: removes the top transform. A channel with no
/// transform stays as it is.
pub fn pop(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len != 3) return it.wrongArgs("chan pop channel");
    const c = try chan.findChannel(it, argv[2]);
    const x = c.xform orelse return Value.empty;
    try chan.flushChannel(it, c);
    try x.flushLayer();
    if (c.readable) {
        // The bytes of the transform go to the read buffer, after the
        // bytes that the channel read through it before.
        try c.rbuf.appendSlice(it.alloc(), x.pending.items[x.ppos..]);
        if (!x.drained and x.has(.drain)) try c.rbuf.appendSlice(it.alloc(), try x.call(.drain, null));
    }
    c.filter = x.below;
    c.xform = x.under;
    try x.finalize();
    return Value.empty;
}

/// `clear` of each transform of `c`, from the top, at a seek.
pub fn clearAll(c: *Channel) Error!void {
    var x = c.xform;
    while (x) |t| : (x = t.under) try t.clear();
}
