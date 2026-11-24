//! The shared variables of the capability `thread`: `tsv::*`.
//!
//! The store of a group is a table of arrays under a store lock. Each
//! array has its own lock, so threads that use two arrays do not wait
//! for each other. A command holds the store lock only to find or make
//! an array.
//!
//! The lock of an array is a state under a small internal lock: the
//! owner thread and a depth. It is recursive for its owner, so the
//! script of `tsv::lock` can run other `tsv` commands on the array. A
//! wait for it is a loop of slices, and the thread checks its stop flag
//! after each slice. Only the owner reads or writes the elements.
//!
//! An element is a `thread.Shared` tree in the memory of the group. A
//! list stays a list, so `lappend`, `lpush` at the end, and `lpop` at
//! the end need no parse. The other list commands run the core list
//! command of the calling interpreter on a copy and store the result.
//!
//! An array that `tsv::unset` removes leaves the table at once. The last
//! user frees it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const thread = @import("thread.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;
const Group = thread.Group;
const Worker = thread.Worker;
const Shared = thread.Shared;
const Allocator = std.mem.Allocator;

const Array = struct {
    group: *Group,
    lock: thread.Lock = .{},
    ev: thread.Event = .{},
    owner: u64 = 0,
    depth: u32 = 0,
    users: u32 = 0,
    /// True after the array left the table.
    dead: bool = false,
    elems: std.StringArrayHashMapUnmanaged(Shared) = .empty,

    fn free(arr: *Array) void {
        const a = arr.group.alloc();
        var iter = arr.elems.iterator();
        while (iter.next()) |e| {
            a.free(e.key_ptr.*);
            e.value_ptr.deinit(a);
        }
        arr.elems.deinit(a);
        a.destroy(arr);
    }
};

const Store = struct {
    lock: thread.Lock = .{},
    arrays: std.StringArrayHashMapUnmanaged(*Array) = .empty,
    next_obj: u64 = 0,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn finalize(g: *Group) void {
    const s: *Store = @ptrCast(@alignCast(g.tsv orelse return));
    const a = g.alloc();
    for (s.arrays.keys(), s.arrays.values()) |k, arr| {
        a.free(k);
        arr.free();
    }
    s.arrays.deinit(a);
    g.gpa.destroy(s);
    g.tsv = null;
}

fn store(it: *Interp, g: *Group) Error!*Store {
    g.lock.lock();
    defer g.lock.unlock();
    if (g.tsv) |p| return @ptrCast(@alignCast(p));
    const s = try g.gpa.create(Store);
    s.* = .{};
    g.finalizers.append(g.gpa, finalize) catch {
        g.gpa.destroy(s);
        return it.fail("out of memory", .{});
    };
    g.tsv = s;
    return s;
}

fn self(it: *Interp) Error!*Worker {
    return it.worker orelse it.fail("threads are off", .{});
}

/// A locked array. `release` ends the use.
const Held = struct {
    arr: *Array,
    w: *Worker,

    fn release(h: Held) void {
        const arr = h.arr;
        arr.lock.lock();
        arr.depth -= 1;
        if (arr.depth == 0) arr.owner = 0;
        arr.users -= 1;
        const gone = arr.dead and arr.users == 0;
        arr.lock.unlock();
        arr.ev.signal();
        if (gone) arr.free();
    }

    fn alloc(h: Held) Allocator {
        return h.arr.group.alloc();
    }
};

/// Finds the array `name` and takes its lock. With `make`, a missing
/// array comes into being. Without it, a missing array gives null.
fn acquire(it: *Interp, name: []const u8, make: bool) Error!?Held {
    const w = try self(it);
    const g = w.group;
    const s = try store(it, g);
    const a = g.alloc();
    while (true) {
        s.lock.lock();
        const arr = s.arrays.get(name) orelse blk: {
            if (!make) {
                s.lock.unlock();
                return null;
            }
            const n = a.create(Array) catch {
                s.lock.unlock();
                return thread.groupFull(it, error.GroupFull);
            };
            n.* = .{ .group = g };
            const key = a.dupe(u8, name) catch {
                s.lock.unlock();
                a.destroy(n);
                return thread.groupFull(it, error.GroupFull);
            };
            s.arrays.put(a, key, n) catch {
                s.lock.unlock();
                a.free(key);
                a.destroy(n);
                return thread.groupFull(it, error.GroupFull);
            };
            break :blk n;
        };
        arr.lock.lock();
        arr.users += 1;
        s.lock.unlock();
        var stopped = false;
        if (arr.owner != w.id) {
            while (arr.owner != 0) {
                if (w.flags.load(.acquire) != 0) {
                    stopped = true;
                    break;
                }
                arr.ev.wait(&arr.lock, thread.slice_ns);
            }
        }
        // An array that `tsv::unset` removed during the wait is gone
        // for this command. The next pass finds or makes a new one.
        if (stopped or arr.dead) {
            arr.users -= 1;
            const gone = arr.dead and arr.users == 0;
            arr.lock.unlock();
            if (gone) arr.free();
            if (stopped) try thread.checkFlags(it, w);
            continue;
        }
        arr.owner = w.id;
        arr.depth += 1;
        arr.lock.unlock();
        return .{ .arr = arr, .w = w };
    }
}

fn notArray(it: *Interp, name: []const u8) Error {
    return it.fail("\"{s}\" is not a thread shared array", .{name});
}

fn noKey(it: *Interp, arr: []const u8, key: []const u8) Error {
    return it.fail("no key {s}({s})", .{ arr, key });
}

/// The array that must exist, locked.
fn need(it: *Interp, name: []const u8) Error!Held {
    return (try acquire(it, name, false)) orelse notArray(it, name);
}

fn put(it: *Interp, h: Held, key: []const u8, v: Shared) Error!void {
    const a = h.alloc();
    var x = v;
    if (h.arr.elems.getPtr(key)) |slot| {
        slot.deinit(a);
        slot.* = x;
        return;
    }
    const k = a.dupe(u8, key) catch {
        x.deinit(a);
        return thread.groupFull(it, error.GroupFull);
    };
    h.arr.elems.put(a, k, x) catch {
        a.free(k);
        x.deinit(a);
        return thread.groupFull(it, error.GroupFull);
    };
}

fn shareIn(it: *Interp, h: Held, v: Value) Error!Shared {
    return thread.share(h.alloc(), it, v) catch |e| thread.groupFull(it, e);
}

fn storeValue(it: *Interp, h: Held, key: []const u8, v: Value) Error!void {
    try put(it, h, key, try shareIn(it, h, v));
}

fn remove(h: Held, key: []const u8) bool {
    const k = h.arr.elems.getIndex(key) orelse return false;
    const a = h.alloc();
    const old_key = h.arr.elems.keys()[k];
    var old = h.arr.elems.values()[k];
    h.arr.elems.orderedRemoveAt(k);
    a.free(old_key);
    old.deinit(a);
    return true;
}

/// Removes an array from the table. Its last user frees it.
fn dropArray(it: *Interp, name: []const u8) Error!bool {
    const w = try self(it);
    const s = try store(it, w.group);
    s.lock.lock();
    const k = s.arrays.getIndex(name) orelse {
        s.lock.unlock();
        return false;
    };
    const key = s.arrays.keys()[k];
    const arr = s.arrays.values()[k];
    s.arrays.orderedRemoveAt(k);
    s.lock.unlock();
    w.group.alloc().free(key);
    arr.lock.lock();
    arr.dead = true;
    const gone = arr.users == 0;
    arr.lock.unlock();
    if (gone) arr.free();
    return true;
}

fn listOf(it: *Interp, s: Shared) Error![]const Value {
    return it.list(try thread.unshare(it, s));
}

// ---- The commands ----

/// The array, the element, and the other words of a command.
/// `tsv::object` calls the same functions with its array and element.
const Args = struct {
    arr: []const u8,
    key: []const u8,
    rest: []const Value,
    /// The words before `rest`, for the message of a wrong count.
    head: []const Value,
    /// The words that the op takes after `head`.
    usage: []const u8,
};

fn wrong(it: *Interp, usage: []const u8) Error {
    return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s}\"", .{usage});
}

/// The error of a wrong count of words: the words of the call before
/// the arguments of the op, then the usage of the op.
fn wrongArgs(it: *Interp, x: Args) Error {
    var text: std.ArrayList(u8) = .empty;
    for (x.head) |w| {
        try text.appendSlice(it.alloc(), try it.str(w));
        try text.append(it.alloc(), ' ');
    }
    try text.appendSlice(it.alloc(), x.usage);
    const t = std.mem.trimEnd(u8, text.items, " ");
    return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s}\"", .{t});
}

fn opSet(it: *Interp, x: Args) Error!Value {
    if (x.rest.len > 1) return wrongArgs(it, x);
    if (x.rest.len == 0) {
        const h = try need(it, x.arr);
        defer h.release();
        const v = h.arr.elems.get(x.key) orelse return noKey(it, x.arr, x.key);
        return thread.unshare(it, v);
    }
    const h = (try acquire(it, x.arr, true)).?;
    defer h.release();
    try storeValue(it, h, x.key, x.rest[0]);
    return x.rest[0];
}

fn opGet(it: *Interp, x: Args) Error!Value {
    if (x.rest.len > 1) return wrongArgs(it, x);
    const h = (try acquire(it, x.arr, false)) orelse {
        if (x.rest.len == 1) return .{ .int = 0 };
        return notArray(it, x.arr);
    };
    defer h.release();
    const s = h.arr.elems.get(x.key) orelse {
        if (x.rest.len == 1) return .{ .int = 0 };
        return noKey(it, x.arr, x.key);
    };
    const v = try thread.unshare(it, s);
    if (x.rest.len == 0) return v;
    const name = try it.str(x.rest[0]);
    if (name.len > 0) try it.setVar(name, v);
    return .{ .int = 1 };
}

fn opExists(it: *Interp, x: Args) Error!Value {
    if (x.rest.len != 0) return wrongArgs(it, x);
    const h = (try acquire(it, x.arr, false)) orelse return .{ .int = 0 };
    defer h.release();
    return .{ .int = @intFromBool(h.arr.elems.contains(x.key)) };
}

fn opPop(it: *Interp, x: Args) Error!Value {
    if (x.rest.len != 0) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const s = h.arr.elems.get(x.key) orelse return noKey(it, x.arr, x.key);
    const v = try thread.unshare(it, s);
    _ = remove(h, x.key);
    return v;
}

fn opMove(it: *Interp, x: Args) Error!Value {
    if (x.rest.len != 1) return wrongArgs(it, x);
    const to = try it.str(x.rest[0]);
    const h = try need(it, x.arr);
    defer h.release();
    const k = h.arr.elems.getIndex(x.key) orelse return noKey(it, x.arr, x.key);
    if (eql(to, x.key)) return Value.empty;
    if (h.arr.elems.contains(to)) return it.fail("key \"{s}\" exists", .{to});
    // The tree moves to the new key with no copy.
    const old_key = h.arr.elems.keys()[k];
    const v = h.arr.elems.values()[k];
    h.arr.elems.orderedRemoveAt(k);
    h.alloc().free(old_key);
    try put(it, h, to, v);
    return Value.empty;
}

fn opIncr(it: *Interp, x: Args) Error!Value {
    if (x.rest.len > 1) return wrongArgs(it, x);
    const by: i64 = if (x.rest.len == 1) try it.int(x.rest[0]) else 1;
    const h = (try acquire(it, x.arr, true)).?;
    defer h.release();
    if (h.arr.elems.getPtr(x.key)) |slot| {
        const old: i64 = switch (slot.*) {
            .int => |i| i,
            else => blk: {
                const v = try thread.unshare(it, slot.*);
                break :blk v.asInt() orelse return it.failCode("TCL VALUE NUMBER", "expected integer but got \"{s}\"", .{try it.str(v)});
            },
        };
        slot.deinit(h.alloc());
        slot.* = .{ .int = old +% by };
        return .{ .int = old +% by };
    }
    try put(it, h, x.key, .{ .int = by });
    return .{ .int = by };
}

fn opAppend(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 1) return wrongArgs(it, x);
    const h = (try acquire(it, x.arr, true)).?;
    defer h.release();
    var text: std.ArrayList(u8) = .empty;
    if (h.arr.elems.get(x.key)) |s| try text.appendSlice(it.alloc(), try it.str(try thread.unshare(it, s)));
    for (x.rest) |v| try text.appendSlice(it.alloc(), try it.str(v));
    const out: Value = .{ .str = text.items };
    try storeValue(it, h, x.key, out);
    return out;
}

/// The list of an element, made a list in place.
fn listSlot(it: *Interp, h: Held, key: []const u8) Error!*std.ArrayList(Shared) {
    const a = h.alloc();
    if (h.arr.elems.getPtr(key)) |slot| {
        if (slot.* != .list) {
            const items = try listOf(it, slot.*);
            var l: std.ArrayList(Shared) = std.ArrayList(Shared).initCapacity(a, items.len) catch return thread.groupFull(it, error.GroupFull);
            for (items) |v| l.appendAssumeCapacity(thread.share(a, it, v) catch |e| {
                var tmp: Shared = .{ .list = l };
                tmp.deinit(a);
                return thread.groupFull(it, e);
            });
            slot.deinit(a);
            slot.* = .{ .list = l };
        }
        return &slot.list;
    }
    try put(it, h, key, .{ .list = .empty });
    return &h.arr.elems.getPtr(key).?.list;
}

fn opLappend(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 1) return wrongArgs(it, x);
    const h = (try acquire(it, x.arr, true)).?;
    defer h.release();
    const l = try listSlot(it, h, x.key);
    for (x.rest) |v| {
        var s = try shareIn(it, h, v);
        l.append(h.alloc(), s) catch {
            s.deinit(h.alloc());
            return thread.groupFull(it, error.GroupFull);
        };
    }
    return thread.unshare(it, .{ .list = l.* });
}

fn opLlength(it: *Interp, x: Args) Error!Value {
    if (x.rest.len != 0) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const s = h.arr.elems.get(x.key) orelse return noKey(it, x.arr, x.key);
    if (s == .list) return .{ .int = @intCast(s.list.items.len) };
    return .{ .int = @intCast((try listOf(it, s)).len) };
}

/// The position of a list index: an integer, `end`, `end-N`, or `M+N`,
/// read by the core `lindex` command on a list of positions.
fn indexOf(it: *Interp, v: Value, len: usize) Error!i64 {
    if (v.asInt()) |i| return i;
    if (eql(try it.str(v), "end")) return @as(i64, @intCast(len)) - 1;
    const nums = try it.alloc().alloc(Value, len);
    for (nums, 0..) |*n, k| n.* = .{ .int = @intCast(k) };
    const r = try it.callWords(&.{ .{ .str = "::lindex" }, try value.wrapList(it.alloc(), nums), v });
    return r.asInt() orelse -1;
}

fn opLpop(it: *Interp, x: Args) Error!Value {
    if (x.rest.len > 1) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    if (!h.arr.elems.contains(x.key)) return noKey(it, x.arr, x.key);
    const l = try listSlot(it, h, x.key);
    const n = l.items.len;
    const at: i64 = if (x.rest.len == 1) try indexOf(it, x.rest[0], n) else 0;
    if (at < 0 or at >= n) return Value.empty;
    var s = l.orderedRemove(@intCast(at));
    defer s.deinit(h.alloc());
    return thread.unshare(it, s);
}

fn opLpush(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 1 or x.rest.len > 2) return wrongArgs(it, x);
    const h = (try acquire(it, x.arr, true)).?;
    defer h.release();
    const l = try listSlot(it, h, x.key);
    const n = l.items.len;
    var at: i64 = if (x.rest.len == 2) try indexOf(it, x.rest[1], n) else 0;
    // `end` puts the value after the last element.
    if (x.rest.len == 2 and eql(try it.str(x.rest[1]), "end")) at = @intCast(n);
    const pos: usize = @intCast(std.math.clamp(at, 0, @as(i64, @intCast(n))));
    var s = try shareIn(it, h, x.rest[0]);
    l.insert(h.alloc(), pos, s) catch {
        s.deinit(h.alloc());
        return thread.groupFull(it, error.GroupFull);
    };
    return Value.empty;
}

/// Runs a core list command with the element as its list argument.
fn core(it: *Interp, name: []const u8, list: Value, before: []const Value, after: []const Value) Error!Value {
    var words: std.ArrayList(Value) = .empty;
    const a = it.alloc();
    try words.append(a, .{ .str = name });
    try words.appendSlice(a, before);
    try words.append(a, list);
    try words.appendSlice(a, after);
    return it.callWords(words.items);
}

fn element(it: *Interp, h: Held, x: Args) Error!Value {
    const s = h.arr.elems.get(x.key) orelse return noKey(it, x.arr, x.key);
    return thread.unshare(it, s);
}

fn opLindex(it: *Interp, x: Args) Error!Value {
    if (x.rest.len != 1) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const s = h.arr.elems.get(x.key) orelse return noKey(it, x.arr, x.key);
    if (s == .list) {
        if (x.rest[0].asInt()) |i| {
            if (i < 0 or i >= s.list.items.len) return Value.empty;
            return thread.unshare(it, s.list.items[@intCast(i)]);
        }
    }
    const v = try thread.unshare(it, s);
    return core(it, "::lindex", v, &.{}, x.rest);
}

fn opLrange(it: *Interp, x: Args) Error!Value {
    if (x.rest.len != 2) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    return core(it, "::lrange", try element(it, h, x), &.{}, x.rest);
}

fn opLsearch(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 1) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    return core(it, "::lsearch", try element(it, h, x), x.rest[0 .. x.rest.len - 1], x.rest[x.rest.len - 1 ..]);
}

fn opLinsert(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 2) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const r = try core(it, "::linsert", try element(it, h, x), &.{}, x.rest);
    try storeValue(it, h, x.key, r);
    return Value.empty;
}

fn opLreplace(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 2) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const r = try core(it, "::lreplace", try element(it, h, x), &.{}, x.rest);
    try storeValue(it, h, x.key, r);
    return Value.empty;
}

fn opLset(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 2) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const lambda: Value = .{ .str = "{l args} {lset l {*}$args; set l}" };
    const r = try core(it, "::apply", try element(it, h, x), &.{lambda}, x.rest);
    try storeValue(it, h, x.key, r);
    return r;
}

// ---- Keyed lists ----

/// The position of the pair with the key `k` in a keyed list.
fn keylIndex(it: *Interp, pairs: []const Value, k: []const u8) Error!?usize {
    for (pairs, 0..) |p, i| {
        const kv = try it.list(p);
        if (kv.len != 2) return it.fail("keyed list entry must be a two element list, found \"{s}\"", .{try it.str(p)});
        if (eql(try it.str(kv[0]), k)) return i;
    }
    return null;
}

fn keylGet(it: *Interp, list: Value, path: []const u8) Error!?Value {
    var cur = list;
    var rest = path;
    while (true) {
        const dot = std.mem.indexOfScalar(u8, rest, '.');
        const k = if (dot) |d| rest[0..d] else rest;
        const pairs = try it.list(cur);
        const i = (try keylIndex(it, pairs, k)) orelse return null;
        const v = (try it.list(pairs[i]))[1];
        if (dot) |d| {
            cur = v;
            rest = rest[d + 1 ..];
        } else return v;
    }
}

fn keylSet(it: *Interp, list: Value, path: []const u8, v: Value, depth: u32) Error!Value {
    if (depth > 200) return it.fail("keyed list key is too deep", .{});
    const a = it.alloc();
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const k = if (dot) |d| path[0..d] else path;
    if (k.len == 0) return it.fail("empty key", .{});
    const pairs = try it.list(list);
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(a, pairs);
    const i = try keylIndex(it, pairs, k);
    const old: Value = if (i) |n| (try it.list(pairs[n]))[1] else Value.empty;
    const nv = if (dot) |d| try keylSet(it, old, path[d + 1 ..], v, depth + 1) else v;
    const pair = try value.newList(a, &.{ .{ .str = k }, nv });
    if (i) |n| out.items[n] = pair else try out.append(a, pair);
    return value.wrapList(a, out.items);
}

fn keylDel(it: *Interp, list: Value, path: []const u8, depth: u32) Error!?Value {
    if (depth > 200) return null;
    const a = it.alloc();
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const k = if (dot) |d| path[0..d] else path;
    const pairs = try it.list(list);
    const i = (try keylIndex(it, pairs, k)) orelse return null;
    var out: std.ArrayList(Value) = .empty;
    try out.appendSlice(a, pairs);
    if (dot) |d| {
        const inner = (try it.list(pairs[i]))[1];
        const nv = (try keylDel(it, inner, path[d + 1 ..], depth + 1)) orelse return null;
        out.items[i] = try value.newList(a, &.{ .{ .str = k }, nv });
    } else _ = out.orderedRemove(i);
    return try value.wrapList(a, out.items);
}

fn keylKeys(it: *Interp, list: Value) Error!Value {
    const pairs = try it.list(list);
    const out = try it.alloc().alloc(Value, pairs.len);
    for (pairs, out) |p, *o| {
        const kv = try it.list(p);
        if (kv.len != 2) return it.fail("keyed list entry must be a two element list, found \"{s}\"", .{try it.str(p)});
        o.* = kv[0];
    }
    return value.wrapList(it.alloc(), out);
}

fn opKeylset(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 2 or x.rest.len % 2 != 0) return wrongArgs(it, x);
    const h = (try acquire(it, x.arr, true)).?;
    defer h.release();
    var cur: Value = if (h.arr.elems.get(x.key)) |s| try thread.unshare(it, s) else Value.empty;
    var k: usize = 0;
    while (k < x.rest.len) : (k += 2) cur = try keylSet(it, cur, try it.str(x.rest[k]), x.rest[k + 1], 0);
    try storeValue(it, h, x.key, cur);
    return Value.empty;
}

fn opKeylget(it: *Interp, x: Args) Error!Value {
    if (x.rest.len > 2) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const list = try element(it, h, x);
    if (x.rest.len == 0) return keylKeys(it, list);
    const key = try it.str(x.rest[0]);
    const v = try keylGet(it, list, key);
    if (x.rest.len == 2) {
        const name = try it.str(x.rest[1]);
        if (v) |found| {
            if (name.len > 0) try it.setVar(name, found);
            return .{ .int = 1 };
        }
        return .{ .int = 0 };
    }
    return v orelse it.fail("key \"{s}\" not found", .{key});
}

fn opKeylkeys(it: *Interp, x: Args) Error!Value {
    if (x.rest.len > 1) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    const list = try element(it, h, x);
    if (x.rest.len == 0) return keylKeys(it, list);
    const key = try it.str(x.rest[0]);
    const v = (try keylGet(it, list, key)) orelse return it.fail("key \"{s}\" not found", .{key});
    return keylKeys(it, v);
}

fn opKeyldel(it: *Interp, x: Args) Error!Value {
    if (x.rest.len < 1) return wrongArgs(it, x);
    const h = try need(it, x.arr);
    defer h.release();
    var v = try element(it, h, x);
    for (x.rest) |k| {
        const key = try it.str(k);
        v = (try keylDel(it, v, key, 0)) orelse return it.fail("key \"{s}\" not found", .{key});
    }
    try storeValue(it, h, x.key, v);
    return Value.empty;
}

// ---- The dispatch ----

const Op = struct { name: []const u8, f: *const fn (*Interp, Args) Error!Value, usage: []const u8 };

const ops = [_]Op{
    .{ .name = "set", .f = opSet, .usage = "?value?" },
    .{ .name = "get", .f = opGet, .usage = "?var?" },
    .{ .name = "exists", .f = opExists, .usage = "" },
    .{ .name = "pop", .f = opPop, .usage = "" },
    .{ .name = "move", .f = opMove, .usage = "newkey" },
    .{ .name = "incr", .f = opIncr, .usage = "?count?" },
    .{ .name = "append", .f = opAppend, .usage = "value ?value ...?" },
    .{ .name = "lappend", .f = opLappend, .usage = "value ?value ...?" },
    .{ .name = "llength", .f = opLlength, .usage = "" },
    .{ .name = "lindex", .f = opLindex, .usage = "index" },
    .{ .name = "lrange", .f = opLrange, .usage = "first last" },
    .{ .name = "lsearch", .f = opLsearch, .usage = "?mode? pattern" },
    .{ .name = "linsert", .f = opLinsert, .usage = "index element ?element ...?" },
    .{ .name = "lreplace", .f = opLreplace, .usage = "first last ?element ...?" },
    .{ .name = "lset", .f = opLset, .usage = "index ?index...? value" },
    .{ .name = "lpop", .f = opLpop, .usage = "?index?" },
    .{ .name = "lpush", .f = opLpush, .usage = "element ?index?" },
    .{ .name = "keylset", .f = opKeylset, .usage = "key value ?key value ...?" },
    .{ .name = "keylget", .f = opKeylget, .usage = "?key? ?var?" },
    .{ .name = "keylkeys", .f = opKeylkeys, .usage = "?lkey?" },
    .{ .name = "keyldel", .f = opKeyldel, .usage = "key ?key ...?" },
};

fn findOp(name: []const u8) ?Op {
    for (ops) |o| if (eql(o.name, name)) return o;
    return null;
}

/// The command of one op: `tsv::<op> array element ?arg ...?`.
fn opCmd(comptime o: Op) interp.NativeFn {
    return struct {
        fn f(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
            if (argv.len < 3) return wrong(it, "tsv::" ++ o.name ++ " array key ?args?");
            return o.f(it, .{ .arr = try it.str(argv[1]), .key = try it.str(argv[2]), .rest = argv[3..], .head = argv[0..3], .usage = o.usage });
        }
    }.f;
}

fn cmdUnset(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("tsv::unset array ?key ...?");
    const name = try it.str(argv[1]);
    if (argv.len == 2) {
        if (!try dropArray(it, name)) return notArray(it, name);
        return Value.empty;
    }
    const h = try need(it, name);
    defer h.release();
    for (argv[2..]) |k| {
        const key = try it.str(k);
        if (!remove(h, key)) return noKey(it, name, key);
    }
    return Value.empty;
}

fn cmdNames(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("tsv::names ?pattern?");
    const w = try self(it);
    const s = try store(it, w.group);
    const pat: ?[]const u8 = if (argv.len == 2) try it.str(argv[1]) else null;
    var out: std.ArrayList(Value) = .empty;
    s.lock.lock();
    defer s.lock.unlock();
    for (s.arrays.keys()) |k| {
        if (pat) |p| if (!cmds.globMatch(p, k, false)) continue;
        try out.append(it.alloc(), .{ .str = try it.alloc().dupe(u8, k) });
    }
    return value.wrapList(it.alloc(), out.items);
}

fn cmdArray(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("tsv::array option array");
    const sub = try it.str(argv[1]);
    const name = try it.str(argv[2]);
    if (eql(sub, "set") or eql(sub, "reset")) {
        if (argv.len != 4) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"tsv::array {s} array list\"", .{sub});
        const items = try it.list(argv[3]);
        if (items.len % 2 != 0) return it.fail("list must have an even number of elements", .{});
        const h = (try acquire(it, name, true)).?;
        defer h.release();
        if (eql(sub, "reset")) {
            while (h.arr.elems.count() > 0) _ = remove(h, h.arr.elems.keys()[0]);
        }
        var k: usize = 0;
        while (k < items.len) : (k += 2) try storeValue(it, h, try it.str(items[k]), items[k + 1]);
        return Value.empty;
    }
    if (eql(sub, "get") or eql(sub, "names")) {
        if (argv.len > 4) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"tsv::array {s} array ?pattern?\"", .{sub});
        const pat: ?[]const u8 = if (argv.len == 4) try it.str(argv[3]) else null;
        const h = (try acquire(it, name, false)) orelse return Value.empty;
        defer h.release();
        var out: std.ArrayList(Value) = .empty;
        for (h.arr.elems.keys(), h.arr.elems.values()) |k, v| {
            if (pat) |p| if (!cmds.globMatch(p, k, false)) continue;
            try out.append(it.alloc(), .{ .str = try it.alloc().dupe(u8, k) });
            if (eql(sub, "get")) try out.append(it.alloc(), try thread.unshare(it, v));
        }
        return value.wrapList(it.alloc(), out.items);
    }
    if (eql(sub, "size")) {
        if (argv.len != 3) return it.wrongArgs("tsv::array size array");
        const h = (try acquire(it, name, false)) orelse return .{ .int = 0 };
        defer h.release();
        return .{ .int = @intCast(h.arr.elems.count()) };
    }
    if (eql(sub, "isbound")) return .{ .int = 0 };
    return it.fail("bad option \"{s}\": must be set, reset, get, names, size, or isbound", .{sub});
}

fn cmdLock(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("tsv::lock array arg ?arg...?");
    const name = try it.str(argv[1]);
    const h = (try acquire(it, name, true)).?;
    defer h.release();
    const text = if (argv.len == 3) try it.str(argv[2]) else try cmds.concat(it, argv[2..]);
    const s = try it.compile(try it.alloc().dupe(u8, text));
    return it.evalScript(s);
}

fn cmdHandlers(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 1) return it.wrongArgs("tsv::handlers");
    return Value.empty;
}

/// The data of a command of `tsv::object`.
const ObjData = struct { arr: []const u8, key: []const u8 };

fn objCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const c = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    const d: *ObjData = @ptrCast(@alignCast(c.ctx.?));
    if (argv.len < 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} args\"", .{try it.str(argv[0])});
    const m = try it.str(argv[1]);
    var x: Args = .{ .arr = d.arr, .key = d.key, .rest = argv[2..], .head = argv[0..2], .usage = "" };
    if (eql(m, "unset")) {
        const h = try need(it, d.arr);
        defer h.release();
        if (!remove(h, d.key)) return noKey(it, d.arr, d.key);
        return Value.empty;
    }
    const o = findOp(m) orelse return it.fail("invalid command name \"{s}\"", .{m});
    x.usage = o.usage;
    return o.f(it, x);
}

fn cmdObject(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("tsv::object array key ?args?");
    const w = try self(it);
    const s = try store(it, w.group);
    s.lock.lock();
    const n = s.next_obj;
    s.next_obj += 1;
    s.lock.unlock();
    const a = it.alloc();
    const d = try a.create(ObjData);
    d.* = .{ .arr = try a.dupe(u8, try it.str(argv[1])), .key = try a.dupe(u8, try it.str(argv[2])) };
    const name = try std.fmt.allocPrint(a, "::tsv::obj0x{x}", .{n});
    const c = try a.create(interp.Command);
    c.* = .{ .name = name[2..], .impl = .{ .native = objCmd }, .ctx = d };
    try it.commands.put(a, name[2..], c);
    it.epoch += 1;
    return .{ .str = name };
}

/// Frees each array lock that the thread `id` holds at its end.
pub fn releaseOwned(g: *Group, id: u64) void {
    const s: *Store = @ptrCast(@alignCast(g.tsv orelse return));
    s.lock.lock();
    defer s.lock.unlock();
    for (s.arrays.values()) |arr| {
        arr.lock.lock();
        if (arr.owner == id) {
            arr.owner = 0;
            arr.depth = 0;
        }
        arr.lock.unlock();
        arr.ev.signal();
    }
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    inline for (ops) |o| {
        try it.register("tsv::" ++ o.name, opCmd(o));
        it.commands.get("tsv::" ++ o.name).?.tsv_op = true;
    }
    try it.register("tsv::unset", cmdUnset);
    try it.register("tsv::names", cmdNames);
    try it.register("tsv::array", cmdArray);
    try it.register("tsv::lock", cmdLock);
    try it.register("tsv::handlers", cmdHandlers);
    try it.register("tsv::object", cmdObject);
    _ = try it.internNs("tsv");
}
