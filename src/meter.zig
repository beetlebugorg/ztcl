//! Meters (ztcl#243): the use of compute units, time, memory, and I/O of
//! the threads and interpreters that a host runs for a customer.
//!
//! A meter is a set of counters with a name, in the registry of a thread
//! group (or of a root interpreter with no threads). An interpreter with
//! a meter adds to it at each sync point:
//!
//! - Compute units: the interpreter counts down `compute_limit`. A sync
//!   adds `meter_mark - compute_limit` and moves the mark. The JIT and
//!   the interpreter count the same units (rule 10 of AGENTS.md), so the
//!   units do not depend on the JIT, the machine, or the load.
//! - Wall time and CPU time of the thread since the last sync.
//! - Memory: the peak of the counter of the interpreter, and the bytes
//!   in use times the time since the last sync (a time-weighted sum).
//!
//! The sync points are the safe points of the collector, the end of each
//! script of a thread, a read of the meter in the same interpreter, and
//! the end of the thread. A read from another thread sees the counts of
//! the last sync point.
//!
//! The channels add their bytes to the meter of their interpreter at
//! each system read and write, per kind (file, socket, pipe), and a
//! socket also per host word. An isolated thread adds the counts that
//! its child reports, the system counts of the child, and the messages
//! and bytes of its transport (`isothread.zig`).
//!
//! A meter can have a budget of compute units. A thread that starts with
//! the meter gets at most the units that are left, as a reservation, so
//! threads that run at the same time cannot spend more than the budget.
//!
//! A record is a JSON object of one line with the counts, the tenant, a
//! sequence number, and the SHA-256 of the previous record of the meter,
//! so a removed or changed record breaks the chain. With a key, the
//! record ends with an Ed25519 signature of the text before it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Allocator = std.mem.Allocator;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const thread = @import("thread.zig");

/// The clocks of the system. A UEFI enclave and the wasm builds read no
/// clock (the WASI component imports no clock of preview 1), so their
/// time counts are 0.
const has_clock = switch (builtin.os.tag) {
    .linux, .macos, .ios, .windows, .freebsd, .netbsd, .openbsd => true,
    else => false,
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Nanoseconds of a clock that does not go back, or 0 with no clock.
pub fn monoNs() u64 {
    if (comptime !has_clock) return 0;
    const t = std.Io.Clock.awake.now(io()).nanoseconds;
    return if (t < 0) 0 else @intCast(t);
}

/// The CPU time of the calling thread in nanoseconds, or 0.
pub fn cpuNs() u64 {
    if (comptime !has_clock) return 0;
    const t = std.Io.Clock.cpu_thread.now(io()).nanoseconds;
    return if (t < 0) 0 else @intCast(t);
}

fn realMs() i64 {
    if (comptime !has_clock) return 0;
    return @intCast(@divTrunc(std.Io.Clock.real.now(io()).nanoseconds, std.time.ns_per_ms));
}

/// The kinds of channel I/O.
pub const IoKind = enum { file, socket, pipe };

/// The counters of a meter. Each field adds on a merge, except the
/// fields that end in `_peak`, which keep the larger value.
pub const Counts = struct {
    units: u64 = 0,
    wall_ns: u64 = 0,
    cpu_ns: u64 = 0,
    mem_peak: u64 = 0,
    mem_byte_ns: u128 = 0,
    threads_interp: u64 = 0,
    threads_process: u64 = 0,
    file_read: u64 = 0,
    file_write: u64 = 0,
    socket_read: u64 = 0,
    socket_write: u64 = 0,
    pipe_read: u64 = 0,
    pipe_write: u64 = 0,
    connections: u64 = 0,
    process_messages: u64 = 0,
    process_bytes: u64 = 0,
    process_start_ns: u64 = 0,
    os_cpu_ns: u64 = 0,
    os_mem_peak: u64 = 0,
    vm_guests: u64 = 0,
    vm_run_ns: u64 = 0,
    vm_mem_byte_ns: u128 = 0,

    pub fn add(a: *Counts, b: Counts) void {
        inline for (@typeInfo(Counts).@"struct".field_names, @typeInfo(Counts).@"struct".field_types) |fname, _| {
            if (comptime std.mem.endsWith(u8, fname, "_peak")) {
                @field(a, fname) = @max(@field(a, fname), @field(b, fname));
            } else @field(a, fname) +|= @field(b, fname);
        }
    }

    pub fn io(c: *Counts, kind: IoKind, read: bool, n: u64) void {
        switch (kind) {
            .file => if (read) {
                c.file_read +|= n;
            } else {
                c.file_write +|= n;
            },
            .socket => if (read) {
                c.socket_read +|= n;
            } else {
                c.socket_write +|= n;
            },
            .pipe => if (read) {
                c.pipe_read +|= n;
            } else {
                c.pipe_write +|= n;
            },
        }
    }

    /// The counts as bytes for the `USAGE` frame of an isolated child:
    /// each field as a little-endian u64 (a u128 field is cut to 64 bits
    /// of byte-milliseconds).
    pub fn encode(c: Counts, out: *[frame_len]u8) void {
        var at: usize = 0;
        inline for (@typeInfo(Counts).@"struct".field_names, @typeInfo(Counts).@"struct".field_types) |fname, ftype| {
            const v: u64 = if (ftype == u128) @truncate(@field(c, fname) / std.time.ns_per_ms) else @field(c, fname);
            std.mem.writeInt(u64, out[at..][0..8], v, .little);
            at += 8;
        }
    }

    pub fn decode(b: []const u8) ?Counts {
        if (b.len < frame_len) return null;
        var c: Counts = .{};
        var at: usize = 0;
        inline for (@typeInfo(Counts).@"struct".field_names, @typeInfo(Counts).@"struct".field_types) |fname, ftype| {
            const v = std.mem.readInt(u64, b[at..][0..8], .little);
            @field(c, fname) = if (ftype == u128) @as(u128, v) * std.time.ns_per_ms else v;
            at += 8;
        }
        return c;
    }

    pub const frame_len = @typeInfo(Counts).@"struct".field_names.len * 8;
};

/// The counts of one host word of a socket.
pub const Net = struct { read: u64 = 0, write: u64 = 0, connections: u64 = 0 };

/// The most host words that a meter counts one by one. The bytes of
/// further hosts go to the word "other".
pub const max_hosts = 256;

pub const Meter = struct {
    gpa: Allocator,
    name: []u8,
    tenant: []u8 = &.{},
    lock: std.atomic.Mutex = .unlocked,
    counts: Counts = .{},
    net: std.StringArrayHashMapUnmanaged(Net) = .empty,
    /// The budget of compute units, or the largest number for none.
    budget: u64 = std.math.maxInt(u64),
    /// The units that running threads hold and did not use yet.
    reserved: u64 = 0,
    refs: std.atomic.Value(u32) = .init(1),
    /// The chain of records: the count and the SHA-256 of the last one.
    seq: u64 = 0,
    prev: [32]u8 = @splat(0),
    /// The real time of the create or of the last reset, in ms.
    since_ms: i64 = 0,

    pub fn create(gpa: Allocator, name: []const u8) Allocator.Error!*Meter {
        const m = try gpa.create(Meter);
        errdefer gpa.destroy(m);
        m.* = .{ .gpa = gpa, .name = try gpa.dupe(u8, name), .since_ms = realMs() };
        return m;
    }

    pub fn retain(m: *Meter) void {
        _ = m.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(m: *Meter) void {
        if (m.refs.fetchSub(1, .acq_rel) != 1) return;
        for (m.net.keys()) |k| m.gpa.free(k);
        m.net.deinit(m.gpa);
        m.gpa.free(m.name);
        m.gpa.free(m.tenant);
        m.gpa.destroy(m);
    }

    pub fn acquire(m: *Meter) void {
        while (!m.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(m: *Meter) void {
        m.lock.unlock();
    }

    /// Adds counts from another source, such as the child of an isolated
    /// thread.
    pub fn merge(m: *Meter, c: Counts) void {
        m.acquire();
        defer m.unlock();
        m.counts.add(c);
    }

    pub fn addIo(m: *Meter, kind: IoKind, read: bool, n: u64, host: []const u8) void {
        m.acquire();
        defer m.unlock();
        m.counts.io(kind, read, n);
        if (kind == .socket and host.len > 0) {
            const h = m.hostSlot(host) orelse return;
            if (read) h.read +|= n else h.write +|= n;
        }
    }

    pub fn addConnection(m: *Meter, host: []const u8) void {
        m.acquire();
        defer m.unlock();
        m.counts.connections += 1;
        if (m.hostSlot(host)) |h| h.connections += 1;
    }

    /// The counts of a host word. The caller holds the lock.
    fn hostSlot(m: *Meter, host: []const u8) ?*Net {
        if (m.net.getPtr(host)) |h| return h;
        const key: []const u8 = if (m.net.count() >= max_hosts) "other" else host;
        if (m.net.getPtr(key)) |h| return h;
        const k = m.gpa.dupe(u8, key) catch return null;
        const r = m.net.getOrPut(m.gpa, k) catch {
            m.gpa.free(k);
            return null;
        };
        r.value_ptr.* = .{};
        return r.value_ptr;
    }

    /// The units left in the budget, or the largest number for none.
    pub fn left(m: *Meter) u64 {
        m.acquire();
        defer m.unlock();
        return m.leftLocked();
    }

    fn leftLocked(m: *Meter) u64 {
        if (m.budget == std.math.maxInt(u64)) return m.budget;
        return m.budget -| (m.counts.units +| m.reserved);
    }

    /// Holds at most `want` units of the budget for a thread. Gives the
    /// units that the thread gets.
    pub fn reserve(m: *Meter, want: u64) u64 {
        m.acquire();
        defer m.unlock();
        const got = @min(want, m.leftLocked());
        if (m.budget != std.math.maxInt(u64)) m.reserved += got;
        return got;
    }

    /// Gives back the rest of a reservation.
    pub fn unreserve(m: *Meter, n: u64) void {
        m.acquire();
        defer m.unlock();
        m.reserved -|= n;
    }

    pub fn reset(m: *Meter) void {
        m.acquire();
        defer m.unlock();
        m.counts = .{};
        for (m.net.keys()) |k| m.gpa.free(k);
        m.net.clearRetainingCapacity();
        m.since_ms = realMs();
    }

    /// A copy of the counts and of the hosts, in `a`.
    pub fn snapshot(m: *Meter, a: Allocator) Allocator.Error!Snapshot {
        m.acquire();
        defer m.unlock();
        const keys = try a.alloc([]const u8, m.net.count());
        const nets = try a.alloc(Net, m.net.count());
        for (m.net.keys(), m.net.values(), 0..) |k, v, i| {
            keys[i] = try a.dupe(u8, k);
            nets[i] = v;
        }
        return .{ .counts = m.counts, .hosts = keys, .nets = nets, .budget = m.budget, .left = m.leftLocked(), .since_ms = m.since_ms };
    }
};

pub const Snapshot = struct {
    counts: Counts,
    hosts: []const []const u8,
    nets: []const Net,
    budget: u64,
    left: u64,
    since_ms: i64,
};

/// The meters of a thread group or of a root interpreter.
pub const Registry = struct {
    gpa: Allocator,
    lock: std.atomic.Mutex = .unlocked,
    meters: std.StringArrayHashMapUnmanaged(*Meter) = .empty,
    /// The Ed25519 key of the host for `record -sign`, set by an
    /// embedder. A script never reads it.
    key: ?Ed25519.KeyPair = null,

    pub fn acquire(r: *Registry) void {
        while (!r.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn deinit(r: *Registry) void {
        for (r.meters.values()) |m| m.release();
        r.meters.deinit(r.gpa);
    }

    /// The meter of a name, retained, or null.
    pub fn get(r: *Registry, name: []const u8) ?*Meter {
        r.acquire();
        defer r.lock.unlock();
        const m = r.meters.get(name) orelse return null;
        m.retain();
        return m;
    }

    /// The meter of a name, retained. A new name makes a meter.
    pub fn obtain(r: *Registry, name: []const u8) Allocator.Error!*Meter {
        r.acquire();
        defer r.lock.unlock();
        if (r.meters.get(name)) |m| {
            m.retain();
            return m;
        }
        const m = try Meter.create(r.gpa, name);
        errdefer m.release();
        try r.meters.put(r.gpa, m.name, m);
        m.retain();
        return m;
    }

    pub fn remove(r: *Registry, name: []const u8) bool {
        r.acquire();
        defer r.lock.unlock();
        const kv = r.meters.fetchOrderedRemove(name) orelse return false;
        kv.value.release();
        return true;
    }
};

// ---- The interpreter side ----

/// Starts to count the use of `it` in `m`. `reserved` is the part of the
/// budget of `m` that `it` holds.
pub fn attach(it: *Interp, m: *Meter, reserved: u64) void {
    m.retain();
    it.meter = m;
    it.meter_mark = it.compute_limit;
    it.meter_resv = reserved;
    it.meter_ns = monoNs();
    it.meter_cpu = cpuNs();
}

/// Adds the use of `it` since the last sync to its meter.
pub fn sync(it: *Interp) void {
    const m = it.meter orelse return;
    const now = monoNs();
    const cpu = cpuNs();
    // A refill of the limit by the embedder moves the mark up.
    const used = it.meter_mark -| it.compute_limit;
    it.meter_mark = it.compute_limit;
    const dt = now -| it.meter_ns;
    it.meter_ns = now;
    const dcpu = cpu -| it.meter_cpu;
    it.meter_cpu = cpu;
    const back = @min(used, it.meter_resv);
    it.meter_resv -= back;
    m.acquire();
    defer m.unlock();
    m.reserved -|= back;
    m.counts.units +|= used;
    m.counts.wall_ns +|= dt;
    m.counts.cpu_ns +|= dcpu;
    m.counts.mem_peak = @max(m.counts.mem_peak, @max(it.counter.mem_peak, it.counter.used));
    m.counts.mem_byte_ns +|= @as(u128, it.counter.used) * dt;
}

/// Ends the count of `it`: a last sync, and the rest of its reservation
/// goes back to the budget.
pub fn detach(it: *Interp) void {
    const m = it.meter orelse return;
    sync(it);
    if (it.meter_resv != 0) m.unreserve(it.meter_resv);
    it.meter_resv = 0;
    it.meter = null;
    m.release();
}

/// The meter of `it` or of the nearest parent with one.
pub fn of(it: *Interp) ?*Meter {
    var p: ?*Interp = it;
    while (p) |x| : (p = x.parent) if (x.meter) |m| return m;
    return null;
}

/// Counts the bytes of one system read or write of a channel.
pub fn countIo(it: *Interp, kind: IoKind, read: bool, n: usize, host: []const u8) void {
    const m = of(it) orelse return;
    m.addIo(kind, read, n, host);
}

/// The registry of `it`: the one of its thread group, or of its root.
pub fn registry(it: *Interp) Allocator.Error!*Registry {
    var root = it;
    while (root.parent) |p| root = p;
    if (comptime thread.supported) {
        if (root.worker) |w| {
            const g = w.group;
            g.lock.lock();
            defer g.lock.unlock();
            if (g.meters) |p| return @ptrCast(@alignCast(p));
            const r = try g.gpa.create(Registry);
            errdefer g.gpa.destroy(r);
            r.* = .{ .gpa = g.gpa, .key = root.meter_key };
            try g.finalizers.append(g.gpa, finalizeGroup);
            g.meters = r;
            return r;
        }
    }
    if (root.meters) |r| return r;
    const gpa = root.counter.child;
    const r = try gpa.create(Registry);
    r.* = .{ .gpa = gpa, .key = root.meter_key };
    root.meters = r;
    return r;
}

fn finalizeGroup(g: *thread.Group) void {
    const r: *Registry = @ptrCast(@alignCast(g.meters orelse return));
    r.deinit();
    g.gpa.destroy(r);
    g.meters = null;
}

/// Ends the meter of an interpreter and frees the registry that a root
/// interpreter with no threads made.
pub fn deinitInterp(it: *Interp) void {
    detach(it);
    if (it.meters) |r| {
        r.deinit();
        r.gpa.destroy(r);
    }
    it.meters = null;
}

// ---- The forms of a count ----

fn us(ns: anytype) u64 {
    return @truncate(ns / std.time.ns_per_us);
}

fn toInt(v: u64) i64 {
    return @intCast(@min(v, std.math.maxInt(i64)));
}

fn avg(c: Counts) u64 {
    if (c.wall_ns == 0) return 0;
    return @truncate(c.mem_byte_ns / c.wall_ns);
}

/// The dict of `ztcl::meter get`.
pub fn dict(it: *Interp, name: []const u8, s: Snapshot) Error!Value {
    const a = it.alloc();
    const c = s.counts;
    var items: std.ArrayList(Value) = .empty;
    const pairs = struct {
        fn n(al: Allocator, l: *std.ArrayList(Value), k: []const u8, v: u64) Allocator.Error!void {
            try l.append(al, .{ .str = k });
            try l.append(al, .{ .int = toInt(v) });
        }
        fn sub(al: Allocator, l: *std.ArrayList(Value), k: []const u8, kv: []const struct { []const u8, u64 }) Allocator.Error!void {
            var inner: std.ArrayList(Value) = .empty;
            for (kv) |p| try n(al, &inner, p[0], p[1]);
            try l.append(al, .{ .str = k });
            try l.append(al, try value.newList(al, inner.items));
        }
    };
    try items.append(a, .{ .str = "name" });
    try items.append(a, .{ .str = try a.dupe(u8, name) });
    try pairs.n(a, &items, "units", c.units);
    try pairs.n(a, &items, "wall_us", us(c.wall_ns));
    try pairs.n(a, &items, "cpu_us", us(c.cpu_ns));
    try pairs.n(a, &items, "mem_peak", c.mem_peak);
    try pairs.n(a, &items, "mem_avg", avg(c));
    try pairs.n(a, &items, "mem_byte_ms", @truncate(c.mem_byte_ns / std.time.ns_per_ms));
    try pairs.sub(a, &items, "threads", &.{ .{ "interp", c.threads_interp }, .{ "process", c.threads_process } });
    try items.append(a, .{ .str = "io" });
    {
        var io_l: std.ArrayList(Value) = .empty;
        try pairs.sub(a, &io_l, "file", &.{ .{ "read", c.file_read }, .{ "write", c.file_write } });
        try pairs.sub(a, &io_l, "socket", &.{ .{ "read", c.socket_read }, .{ "write", c.socket_write } });
        try pairs.sub(a, &io_l, "pipe", &.{ .{ "read", c.pipe_read }, .{ "write", c.pipe_write } });
        try items.append(a, try value.newList(a, io_l.items));
    }
    try pairs.n(a, &items, "connections", c.connections);
    try items.append(a, .{ .str = "net" });
    {
        var net_l: std.ArrayList(Value) = .empty;
        for (s.hosts, s.nets) |h, v| try pairs.sub(a, &net_l, h, &.{ .{ "read", v.read }, .{ "write", v.write }, .{ "connections", v.connections } });
        try items.append(a, try value.newList(a, net_l.items));
    }
    try pairs.sub(a, &items, "process", &.{
        .{ "messages", c.process_messages },
        .{ "bytes", c.process_bytes },
        .{ "start_us", us(c.process_start_ns) },
        .{ "os_cpu_us", us(c.os_cpu_ns) },
        .{ "os_mem_peak", c.os_mem_peak },
    });
    try pairs.sub(a, &items, "vm", &.{ .{ "guests", c.vm_guests }, .{ "run_us", us(c.vm_run_ns) }, .{ "mem_byte_ms", @truncate(c.vm_mem_byte_ns / std.time.ns_per_ms) } });
    try items.append(a, .{ .str = "budget" });
    try items.append(a, if (s.budget == std.math.maxInt(u64)) Value.empty else .{ .int = toInt(s.budget) });
    try items.append(a, .{ .str = "left" });
    try items.append(a, if (s.left == std.math.maxInt(u64)) Value.empty else .{ .int = toInt(s.left) });
    return value.newList(a, items.items);
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

pub const RecordOpts = struct {
    tenant: []const u8,
    script_hash: ?[32]u8 = null,
    key: ?Ed25519.KeyPair = null,
};

/// The JSON record of a meter, and the next link of its chain. The
/// record is one line with no space. With a key, it ends with
/// `,"sig":"HEX"}`, the Ed25519 signature of the text before `,"sig"`
/// with a `}` after it.
pub fn record(a: Allocator, m: *Meter, o: RecordOpts) (Allocator.Error || error{Sign})![]u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    const w = &buf.writer;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const s = try m.snapshot(arena.allocator());
    const c = s.counts;
    m.acquire();
    const seq = m.seq + 1;
    const prev = m.prev;
    m.unlock();
    const hex = std.fmt.bytesToHex;
    write: {
        w.writeAll("{\"version\":1,\"meter\":") catch break :write;
        jsonStr(w, m.name) catch break :write;
        w.writeAll(",\"tenant\":") catch break :write;
        jsonStr(w, o.tenant) catch break :write;
        w.print(",\"seq\":{d},\"start_ms\":{d},\"end_ms\":{d}", .{ seq, s.since_ms, realMs() }) catch break :write;
        if (o.script_hash) |h| w.print(",\"script_sha256\":\"{s}\"", .{&hex(h, .lower)}) catch break :write;
        w.print(",\"units\":{d},\"wall_us\":{d},\"cpu_us\":{d},\"mem_peak\":{d},\"mem_avg\":{d},\"mem_byte_ms\":{d}", .{ c.units, us(c.wall_ns), us(c.cpu_ns), c.mem_peak, avg(c), @as(u64, @truncate(c.mem_byte_ns / std.time.ns_per_ms)) }) catch break :write;
        w.print(",\"threads\":{{\"interp\":{d},\"process\":{d}}}", .{ c.threads_interp, c.threads_process }) catch break :write;
        w.print(",\"io\":{{\"file\":{{\"read\":{d},\"write\":{d}}},\"socket\":{{\"read\":{d},\"write\":{d}}},\"pipe\":{{\"read\":{d},\"write\":{d}}}}}", .{ c.file_read, c.file_write, c.socket_read, c.socket_write, c.pipe_read, c.pipe_write }) catch break :write;
        w.print(",\"connections\":{d},\"net\":{{", .{c.connections}) catch break :write;
        for (s.hosts, s.nets, 0..) |h, v, i| {
            if (i > 0) w.writeByte(',') catch break :write;
            jsonStr(w, h) catch break :write;
            w.print(":{{\"read\":{d},\"write\":{d},\"connections\":{d}}}", .{ v.read, v.write, v.connections }) catch break :write;
        }
        w.print("}},\"process\":{{\"messages\":{d},\"bytes\":{d},\"start_us\":{d},\"os_cpu_us\":{d},\"os_mem_peak\":{d}}}", .{ c.process_messages, c.process_bytes, us(c.process_start_ns), us(c.os_cpu_ns), c.os_mem_peak }) catch break :write;
        w.print(",\"vm\":{{\"guests\":{d},\"run_us\":{d},\"mem_byte_ms\":{d}}}", .{ c.vm_guests, us(c.vm_run_ns), @as(u64, @truncate(c.vm_mem_byte_ns / std.time.ns_per_ms)) }) catch break :write;
        w.print(",\"prev\":\"{s}\"", .{&hex(prev, .lower)}) catch break :write;
        if (o.key) |k| {
            w.print(",\"key\":\"{s}\"", .{&hex(k.public_key.toBytes(), .lower)}) catch break :write;
            const body_end = buf.written().len;
            w.writeByte('}') catch break :write;
            const sig = k.sign(buf.written(), null) catch return error.Sign;
            buf.shrinkRetainingCapacity(body_end);
            w.print(",\"sig\":\"{s}\"", .{&hex(sig.toBytes(), .lower)}) catch break :write;
        }
        w.writeByte('}') catch break :write;
        const out = try a.dupe(u8, buf.written());
        var h: [32]u8 = undefined;
        Sha256.hash(out, &h, .{});
        m.acquire();
        m.seq = seq;
        m.prev = h;
        m.unlock();
        return out;
    }
    return error.OutOfMemory;
}

pub const VerifyError = error{ NoSignature, BadSignature, BadKey };

/// Checks the signature of a record with the public key `pk`.
pub fn verify(rec: []const u8, pk: [32]u8) VerifyError!void {
    const tail_len = ",\"sig\":\"\"}".len + 128;
    if (rec.len < tail_len or !std.mem.endsWith(u8, rec, "\"}")) return error.NoSignature;
    const at = rec.len - tail_len;
    if (!std.mem.startsWith(u8, rec[at..], ",\"sig\":\"")) return error.NoSignature;
    var sig_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig_bytes, rec[at + 8 .. at + 8 + 128]) catch return error.NoSignature;
    const key = Ed25519.PublicKey.fromBytes(pk) catch return error.BadKey;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    var v = sig.verifier(key) catch return error.BadSignature;
    v.update(rec[0..at]);
    v.update("}");
    v.verify() catch return error.BadSignature;
}

test "a record chain and its signature" {
    const a = std.testing.allocator;
    const m = try Meter.create(a, "t1");
    defer m.release();
    m.counts.units = 1234;
    m.addIo(.socket, true, 10, "api.example");
    const seed: [32]u8 = @splat(7);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const r1 = try record(a, m, .{ .tenant = "acme", .key = kp });
    defer a.free(r1);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"units\":1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1, "\"api.example\":{\"read\":10") != null);
    try verify(r1, kp.public_key.toBytes());
    // A changed count breaks the signature.
    const bad = try a.dupe(u8, r1);
    defer a.free(bad);
    const k = std.mem.indexOf(u8, bad, "1234").?;
    bad[k] = '9';
    try std.testing.expectError(error.BadSignature, verify(bad, kp.public_key.toBytes()));
    // The second record links to the hash of the first.
    const r2 = try record(a, m, .{ .tenant = "acme" });
    defer a.free(r2);
    var h: [32]u8 = undefined;
    Sha256.hash(r1, &h, .{});
    try std.testing.expect(std.mem.indexOf(u8, r2, &std.fmt.bytesToHex(h, .lower)) != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"seq\":2") != null);
}

test "a budget holds units for running threads" {
    const a = std.testing.allocator;
    const m = try Meter.create(a, "b");
    defer m.release();
    m.budget = 100;
    try std.testing.expectEqual(@as(u64, 60), m.reserve(60));
    try std.testing.expectEqual(@as(u64, 40), m.reserve(60));
    try std.testing.expectEqual(@as(u64, 0), m.left());
    m.unreserve(40);
    try std.testing.expectEqual(@as(u64, 40), m.left());
}

test "the frame form of the counts" {
    var c: Counts = .{ .units = 5, .mem_byte_ns = 3 * std.time.ns_per_ms, .pipe_write = 9 };
    var b: [Counts.frame_len]u8 = undefined;
    c.encode(&b);
    const d = Counts.decode(&b).?;
    try std.testing.expectEqual(c.units, d.units);
    try std.testing.expectEqual(c.mem_byte_ns, d.mem_byte_ns);
    try std.testing.expectEqual(c.pipe_write, d.pipe_write);
}
