//! The `dict` command.
//!
//! A dict is a list of keys and values in the order of the first insert,
//! as in Tcl. A dict with fewer than 16 keys uses a linear search. A
//! larger dict has a hash table with open addressing and linear probing.
//! The table maps the hash of the string form of a key to the position
//! of the key in the buffer.
//!
//! A new key goes after the end of the view when the view ends at the
//! used part of the buffer. An older view keeps its length, so it stays
//! the same value, and a lookup for it ignores positions past its end.
//! The buffer doubles when it is full, so a new key is amortized O(1).
//! A write to an existing key of a shared dict copies the buffer.
//!
//! Subcommands: create, get, exists, set, unset, keys, values, size,
//! for, merge, incr, lappend, and append.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const expr = @import("expr.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Error = interp.Error;

/// The item count where a dict starts to use a hash table.
const index_min = 32;

fn intText(b: *[24]u8, i: i64) []const u8 {
    return std.fmt.bufPrint(b, "{d}", .{i}) catch unreachable;
}

fn hashText(s: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0x7a74636c, s));
}

/// The hash of the string form of a key. An integer uses no arena.
fn hashKey(it: *Interp, key: Value) Error!u32 {
    if (key == .int) {
        var b: [24]u8 = undefined;
        return hashText(intText(&b, key.int));
    }
    return hashText(try it.str(key));
}

/// True when two keys have the same string form.
fn sameKey(it: *Interp, x: Value, y: Value) Error!bool {
    if (x == .int and y == .int) return x.int == y.int;
    var bx: [24]u8 = undefined;
    var by: [24]u8 = undefined;
    const sx = if (x == .int) intText(&bx, x.int) else try it.str(x);
    const sy = if (y == .int) intText(&by, y.int) else try it.str(y);
    return std.mem.eql(u8, sx, sy);
}

/// The place of a key in a table, or the empty place where it can go.
/// A long probe uses fuel, so keys with equal hashes cannot run without
/// a limit.
fn probe(it: *Interp, slots: []const value.DictSlot, items: []const Value, key: Value, h: u32) Error!usize {
    const mask = slots.len - 1;
    var at: usize = h & mask;
    var n: u32 = 0;
    while (true) : (at = (at + 1) & mask) {
        const s = slots[at];
        if (s.pos == value.DictSlot.empty_pos) return at;
        if (s.hash == h and try sameKey(it, items[s.pos], key)) return at;
        n +%= 1;
        if (n & 63 == 0) try step(it);
    }
}

fn newSlots(it: *Interp, want: usize) Error![]value.DictSlot {
    const cap = std.math.ceilPowerOfTwo(usize, @max(64, want)) catch return error.OutOfMemory;
    const slots = try it.alloc().alloc(value.DictSlot, cap);
    @memset(slots, .{ .hash = 0, .pos = value.DictSlot.empty_pos });
    return slots;
}

fn checkPos(it: *Interp, n: usize) Error!void {
    if (n >= value.DictSlot.empty_pos) return it.fail("dictionary is too large", .{});
}

/// Makes the table of all keys of the marked part of the buffer.
fn buildIndex(it: *Interp, obj: *value.ListObj) Error!*value.DictIndex {
    try checkPos(it, obj.dict_len);
    const items = obj.buf[0..obj.dict_len];
    const slots = try newSlots(it, items.len);
    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const h = try hashKey(it, items[i]);
        slots[try probe(it, slots, items, items[i], h)] = .{ .hash = h, .pos = @intCast(i) };
    }
    const idx = try it.alloc().create(value.DictIndex);
    idx.* = .{ .slots = slots, .count = items.len / 2 };
    obj.index = idx;
    return idx;
}

/// Adds a new key to a table. The table doubles at a load of 3/4.
fn indexAdd(it: *Interp, idx: *value.DictIndex, h: u32, pos: usize) Error!void {
    try checkPos(it, pos);
    if ((idx.count + 1) * 4 > idx.slots.len * 3) {
        const slots = try newSlots(it, idx.slots.len * 2);
        const mask = slots.len - 1;
        for (idx.slots) |s| {
            if (s.pos == value.DictSlot.empty_pos) continue;
            var at: usize = s.hash & mask;
            while (slots[at].pos != value.DictSlot.empty_pos) at = (at + 1) & mask;
            slots[at] = s;
        }
        idx.slots = slots;
    }
    const mask = idx.slots.len - 1;
    var at: usize = h & mask;
    while (idx.slots[at].pos != value.DictSlot.empty_pos) at = (at + 1) & mask;
    idx.slots[at] = .{ .hash = h, .pos = @intCast(pos) };
    idx.count += 1;
}

/// A copy of the table of `from` for a new buffer with the same keys at
/// the same positions. A table with keys past the view is left out, and
/// the next lookup makes a new one.
fn copyIndex(it: *Interp, from: Value, to: *value.ListObj) Error!void {
    if (!isChecked(from)) return;
    const obj = from.list.obj;
    const idx = obj.index orelse return;
    if (from.list.len != obj.dict_len) return;
    const copy = try it.alloc().create(value.DictIndex);
    copy.* = .{ .slots = try it.alloc().dupe(value.DictSlot, idx.slots), .count = idx.count };
    to.index = copy;
}

/// The position of a key in a dict. `items` are the pairs of `d`.
fn lookup(it: *Interp, d: Value, items: []const Value, key: Value) Error!?usize {
    if (items.len < index_min or !isChecked(d)) return find(it, items, key);
    const obj = d.list.obj;
    const idx = obj.index orelse try buildIndex(it, obj);
    const h = try hashKey(it, key);
    const s = idx.slots[try probe(it, idx.slots, obj.buf[0..obj.dict_len], key, h)];
    if (s.pos == value.DictSlot.empty_pos or s.pos >= items.len) return null;
    return s.pos;
}

/// The pairs of a dict value, each key one time. A key that comes twice
/// keeps its first place and its last value.
fn pairs(it: *Interp, v: Value) Error![]Value {
    if (isChecked(v)) {
        const out = try it.alloc().alloc(Value, v.list.len + 2);
        @memcpy(out[0..v.list.len], v.list.items());
        return out[0..v.list.len];
    }
    const items = try it.list(v);
    if (items.len % 2 != 0) return it.fail("missing value to go with key", .{});
    if (items.len >= index_min) return pairsLarge(it, items);
    var out: std.ArrayList(Value) = .empty;
    try out.ensureTotalCapacity(it.alloc(), items.len + 2);
    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        if (try find(it, out.items, items[i])) |at| {
            out.items[at + 1] = items[i + 1];
        } else {
            out.appendAssumeCapacity(items[i]);
            out.appendAssumeCapacity(items[i + 1]);
        }
    }
    return out.allocatedSlice()[0..out.items.len];
}

/// The same result as `pairs` for a long list, with a temporary table.
fn pairsLarge(it: *Interp, items: []const Value) Error![]Value {
    try checkPos(it, items.len);
    const out = try it.alloc().alloc(Value, items.len + 2);
    const slots = try newSlots(it, items.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        const h = try hashKey(it, items[i]);
        const at = try probe(it, slots, out[0..n], items[i], h);
        if (slots[at].pos == value.DictSlot.empty_pos) {
            slots[at] = .{ .hash = h, .pos = @intCast(n) };
            out[n] = items[i];
            out[n + 1] = items[i + 1];
            n += 2;
        } else {
            out[slots[at].pos + 1] = items[i + 1];
        }
    }
    return out[0..n];
}

/// True when the value has the mark of a valid dict.
fn isChecked(v: Value) bool {
    return v == .list and v.list.len > 0 and v.list.len % 2 == 0 and v.list.len <= v.list.obj.dict_len;
}

/// The pairs for a read. A marked dict gives its items with no copy.
/// The caller must not write to the result.
fn readPairs(it: *Interp, v: Value) Error![]const Value {
    if (isChecked(v)) return v.list.items();
    return pairs(it, v);
}

/// A list value of pairs with unique keys, with the mark of a dict.
fn wrapDict(it: *Interp, items: []Value) Error!Value {
    const out = try value.wrapList(it.alloc(), items);
    out.list.obj.dict_len = items.len;
    return out;
}

/// Updates an owned dict in place: `by` adds to an integer value, or
/// `new` replaces the value. Returns false when the key is not there,
/// or when the value is not an integer for an add.
pub fn updateOwned(it: *Interp, d: Value, key: Value, by: i64, new: ?Value) Error!bool {
    const items = @constCast(d.list.items());
    const at = try lookup(it, d, items, key) orelse return false;
    if (new) |v| {
        items[at + 1] = v;
        return true;
    }
    if (items[at + 1] != .int) return false;
    items[at + 1] = .{ .int = items[at + 1].int +% by };
    return true;
}

/// True when the value is a dict with the mark of a valid dict.
pub fn isMarked(v: Value) bool {
    return isChecked(v);
}

/// The index of a key in the pairs, or null.
fn find(it: *Interp, items: []const Value, key: Value) Error!?usize {
    var i: usize = 0;
    // Two integers compare with no string: each has one string form.
    if (key == .int) {
        var all_int = true;
        while (i < items.len) : (i += 2) {
            if (items[i] != .int) {
                all_int = false;
                break;
            }
            if (items[i].int == key.int) return i;
        }
        if (all_int) return null;
        i = 0;
    }
    const k = try it.str(key);
    while (i < items.len) : (i += 2) {
        if (items[i] == .int and key == .int) {
            if (items[i].int == key.int) return i;
            continue;
        }
        if (std.mem.eql(u8, k, try it.str(items[i]))) return i;
    }
    return null;
}

/// The dict `d` with one more pair. The pair goes after the view when
/// the view ends at the used part of the buffer. Other views stay the
/// same values. In the other case the pairs go to a new buffer with
/// twice the room.
fn appendPair(it: *Interp, d: Value, items: []const Value, key: Value, v: Value) Error!Value {
    if (isChecked(d)) {
        const l = d.list;
        const o = l.obj;
        if (o.used == l.len and o.dict_len == l.len and l.len + 2 <= o.buf.len) {
            if (o.index) |idx| try indexAdd(it, idx, try hashKey(it, key), l.len);
            o.buf[l.len] = key;
            o.buf[l.len + 1] = v;
            o.used += 2;
            o.dict_len += 2;
            return .{ .list = .{ .obj = o, .len = l.len + 2 } };
        }
    }
    const a = it.alloc();
    const n = items.len;
    const buf = try a.alloc(Value, @max(4, n * 2));
    @memcpy(buf[0..n], items);
    buf[n] = key;
    buf[n + 1] = v;
    const obj = try a.create(value.ListObj);
    obj.* = .{ .buf = buf, .used = n + 2, .dict_len = n + 2 };
    try copyIndex(it, d, obj);
    if (obj.index) |idx| try indexAdd(it, idx, try hashKey(it, key), n);
    return .{ .list = .{ .obj = obj, .len = n + 2 } };
}

/// The dict with a value at a path of keys.
fn setIn(it: *Interp, d: Value, keys: []const Value, v: Value) Error!Value {
    const items = try readPairs(it, d);
    const at = try lookup(it, d, items, keys[0]);
    const inner = if (keys.len == 1) v else try setIn(it, if (at) |i| items[i + 1] else Value.empty, keys[1..], v);
    if (at) |i| {
        const out = try it.alloc().dupe(Value, items);
        out[i + 1] = inner;
        const r = try wrapDict(it, out);
        try copyIndex(it, d, r.list.obj);
        return r;
    }
    return appendPair(it, d, items, keys[0], inner);
}

/// The dict with no value at a path of keys.
fn unsetIn(it: *Interp, d: Value, keys: []const Value) Error!Value {
    const items = try pairs(it, d);
    const at = try lookup(it, d, items, keys[0]) orelse {
        if (keys.len == 1) return wrapDict(it, items);
        return it.fail("key \"{s}\" not known in dictionary", .{try it.str(keys[0])});
    };
    if (keys.len > 1) {
        items[at + 1] = try unsetIn(it, items[at + 1], keys[1..]);
        return wrapDict(it, items);
    }
    std.mem.copyForwards(Value, items[at..], items[at + 2 ..]);
    return wrapDict(it, items[0 .. items.len - 2]);
}

fn getIn(it: *Interp, d: Value, keys: []const Value) Error!Value {
    var cur = d;
    for (keys) |k| {
        const items = try readPairs(it, cur);
        const at = try lookup(it, cur, items, k) orelse
            return it.fail("key \"{s}\" not known in dictionary", .{try it.str(k)});
        cur = items[at + 1];
    }
    return cur;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn step(it: *Interp) Error!void {
    if (it.fuel == 0) return it.fail("the script ran out of fuel", .{});
    it.fuel -= 1;
}

/// The subcommands remove, replace, map, filter, update, and with.
/// Returns null for all other names.
fn dictMore(it: *Interp, name: []const u8, argv: []const Value, cmd: ?*interp.Cmd) Error!?Value {
    const a = it.alloc();
    const args = argv[2..];
    if (eql(name, "remove")) {
        if (args.len < 1) return it.wrongArgs("dict remove dictionary ?key ...?");
        var d = try value.wrapList(a, try pairs(it, args[0]));
        for (args[1..]) |k| d = try unsetIn(it, d, &.{k});
        return d;
    }
    if (eql(name, "replace")) {
        if (args.len < 1 or args.len % 2 != 1) return it.wrongArgs("dict replace dictionary ?key value ...?");
        var d = try value.wrapList(a, try pairs(it, args[0]));
        var i: usize = 1;
        while (i < args.len) : (i += 2) d = try setIn(it, d, args[i .. i + 1], args[i + 1]);
        return d;
    }
    if (eql(name, "map")) {
        if (args.len != 3) return it.wrongArgs("dict map {{keyVarName valueVarName}} dictionary script");
        const names = try it.list(args[0]);
        if (names.len != 2) return it.fail("must have exactly two variable names", .{});
        const items = try pairs(it, args[1]);
        const body = try it.scriptOf(argv, 4, cmd);
        var out: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (i < items.len) : (i += 2) {
            try step(it);
            try it.setVar(try it.str(names[0]), items[i]);
            try it.setVar(try it.str(names[1]), items[i + 1]);
            const v = it.evalScript(body) catch |e| switch (e) {
                error.TclBreak => return Value.empty,
                error.TclContinue => continue,
                else => return e,
            };
            try out.append(a, items[i]);
            try out.append(a, v);
        }
        return try value.wrapList(a, try pairs(it, try value.wrapList(a, out.items)));
    }
    if (eql(name, "filter")) {
        if (args.len < 2) return it.wrongArgs("dict filter dictionary filterType ?arg ...?");
        const items = try pairs(it, args[0]);
        const kind = try it.str(args[1]);
        var out: std.ArrayList(Value) = .empty;
        if (kind.len > 0 and (std.mem.startsWith(u8, "key", kind) or std.mem.startsWith(u8, "value", kind))) {
            const off: usize = if (kind[0] == 'k') 0 else 1;
            var i: usize = 0;
            while (i < items.len) : (i += 2) {
                for (args[2..]) |pat| {
                    if (try cmds.globFuel(it, try it.str(pat), try it.str(items[i + off]), false)) {
                        try out.appendSlice(a, items[i .. i + 2]);
                        break;
                    }
                }
            }
            return try value.wrapList(a, out.items);
        }
        if (kind.len == 0 or !std.mem.startsWith(u8, "script", kind)) return it.fail("bad filterType \"{s}\": must be key, script, or value", .{kind});
        if (args.len != 4) return it.wrongArgs("dict filter dictionary script {{keyVarName valueVarName}} filterScript");
        const names = try it.list(args[2]);
        if (names.len != 2) return it.fail("must have exactly two variable names", .{});
        const body = try it.scriptOf(argv, 5, cmd);
        var i: usize = 0;
        while (i < items.len) : (i += 2) {
            try step(it);
            try it.setVar(try it.str(names[0]), items[i]);
            try it.setVar(try it.str(names[1]), items[i + 1]);
            const v = it.evalScript(body) catch |e| switch (e) {
                error.TclBreak => break,
                error.TclContinue => continue,
                else => return e,
            };
            if (try expr.truthy(it, v)) try out.appendSlice(a, items[i .. i + 2]);
        }
        return try value.wrapList(a, out.items);
    }
    if (eql(name, "update")) {
        if (args.len < 4 or args.len % 2 != 0) return it.wrongArgs("dict update dictVarName key varName ?key varName ...? script");
        const var_name = try it.str(args[0]);
        const items = try pairs(it, try it.getVar(var_name));
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            if (try find(it, items, args[i])) |at| try it.setVar(try it.str(args[i + 1]), items[at + 1]);
        }
        const res = it.evalScript(try it.scriptOf(argv, argv.len - 1, cmd));
        // Write the variables back, also after an error of the script.
        const saved = it.result;
        if (try it.getVarOpt(var_name)) |now| {
            var d = try value.wrapList(a, try pairs(it, now));
            i = 1;
            while (i + 1 < args.len) : (i += 2) {
                if (try it.getVarOpt(try it.str(args[i + 1]))) |v| {
                    d = try setIn(it, d, args[i .. i + 1], v);
                } else d = try unsetIn(it, d, args[i .. i + 1]);
            }
            try it.setVar(var_name, d);
        }
        it.result = saved;
        return try res;
    }
    if (eql(name, "with")) {
        if (args.len < 2) return it.wrongArgs("dict with dictVarName ?key ...? script");
        const var_name = try it.str(args[0]);
        const path = args[1 .. args.len - 1];
        const inner = try pairs(it, try getIn(it, try it.getVar(var_name), path));
        var i: usize = 0;
        while (i < inner.len) : (i += 2) try it.setVar(try it.str(inner[i]), inner[i + 1]);
        const res = it.evalScript(try it.scriptOf(argv, argv.len - 1, cmd));
        const saved = it.result;
        if (try it.getVarOpt(var_name)) |now| {
            var d = try value.wrapList(a, try pairs(it, try getIn(it, now, path)));
            i = 0;
            while (i < inner.len) : (i += 2) {
                if (try it.getVarOpt(try it.str(inner[i]))) |v| {
                    d = try setIn(it, d, inner[i .. i + 1], v);
                } else d = try unsetIn(it, d, inner[i .. i + 1]);
            }
            try it.setVar(var_name, if (path.len == 0) d else try setIn(it, now, path, d));
        }
        it.result = saved;
        return try res;
    }
    return null;
}

pub fn cmdDict(it: *Interp, argv: []const Value, cmd: ?*interp.Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("dict subcommand ?arg ...?");
    const a = it.alloc();
    const Sub = enum { create, get, exists, set, unset, keys, values, size, @"for", merge, incr, lappend, append };
    const name = try it.str(argv[1]);
    if (try dictMore(it, name, argv, cmd)) |v| return v;
    const sub = std.meta.stringToEnum(Sub, name) orelse
        return it.fail("unknown or ambiguous subcommand \"{s}\": must be append, create, exists, filter, for, get, incr, info, keys, lappend, map, merge, remove, replace, set, size, unset, update, values, or with", .{name});
    const args = argv[2..];
    switch (sub) {
        .create => {
            if (args.len % 2 != 0) return it.wrongArgs("dict create ?key value ...?");
            return wrapDict(it, try pairs(it, try value.newList(a, args)));
        },
        .get => {
            if (args.len < 1) return it.wrongArgs("dict get dictionary ?key ...?");
            if (args.len == 1) {
                if (isChecked(args[0])) return args[0];
                return wrapDict(it, try pairs(it, args[0]));
            }
            return getIn(it, args[0], args[1..]);
        },
        .exists => {
            if (args.len < 2) return it.wrongArgs("dict exists dictionary key ?key ...?");
            var cur = args[0];
            for (args[1..]) |k| {
                const items = readPairs(it, cur) catch |e| {
                    if (e != error.TclError) return e;
                    return .{ .int = 0 };
                };
                const at = try lookup(it, cur, items, k) orelse return .{ .int = 0 };
                cur = items[at + 1];
            }
            return .{ .int = 1 };
        },
        .set => {
            if (args.len < 3) return it.wrongArgs("dict set dictVarName key ?key ...? value");
            const var_name = try it.str(args[0]);
            const cur = try it.getVarOpt(var_name) orelse Value.empty;
            const out = try setIn(it, cur, args[1 .. args.len - 1], args[args.len - 1]);
            try it.setVar(var_name, out);
            return out;
        },
        .unset => {
            if (args.len < 2) return it.wrongArgs("dict unset dictVarName key ?key ...?");
            const var_name = try it.str(args[0]);
            const cur = try it.getVarOpt(var_name) orelse Value.empty;
            const out = try unsetIn(it, cur, args[1..]);
            try it.setVar(var_name, out);
            return out;
        },
        .keys, .values => {
            if (args.len < 1 or args.len > 2) return it.fail("wrong # args: should be \"dict {s} dictionary ?pattern?\"", .{name});
            const items = try pairs(it, args[0]);
            const pattern: ?[]const u8 = if (args.len == 2) try it.str(args[1]) else null;
            var out: std.ArrayList(Value) = .empty;
            var i: usize = 0;
            while (i < items.len) : (i += 2) {
                const item = items[i + @intFromBool(sub == .values)];
                if (pattern) |p| if (!cmds.globMatch(p, try it.str(item), false)) continue;
                try out.append(a, item);
            }
            return value.wrapList(a, out.items);
        },
        .size => {
            if (args.len != 1) return it.wrongArgs("dict size dictionary");
            return .{ .int = @intCast((try readPairs(it, args[0])).len / 2) };
        },
        .@"for" => {
            if (args.len != 3) return it.wrongArgs("dict for {{keyVarName valueVarName}} dictionary script");
            const names = try it.list(args[0]);
            if (names.len != 2) return it.fail("must have exactly two variable names", .{});
            const items = try pairs(it, args[1]);
            const body = try it.scriptOf(argv, 4, cmd);
            var i: usize = 0;
            while (i < items.len) : (i += 2) {
                if (it.fuel == 0) return it.fail("the script ran out of fuel", .{});
                it.fuel -= 1;
                try it.setVar(try it.str(names[0]), items[i]);
                try it.setVar(try it.str(names[1]), items[i + 1]);
                _ = it.evalScript(body) catch |e| switch (e) {
                    error.TclBreak => break,
                    error.TclContinue => continue,
                    else => return e,
                };
            }
            return Value.empty;
        },
        .merge => {
            var out: std.ArrayList(Value) = .empty;
            for (args) |d| try out.appendSlice(a, try pairs(it, d));
            return wrapDict(it, try pairs(it, try value.wrapList(a, out.items)));
        },
        .incr, .lappend, .append => {
            if (args.len < 2 or (sub == .incr and args.len > 3)) return it.fail("wrong # args: should be \"dict {s} dictVarName key ?value ...?\"", .{name});
            const var_name = try it.str(args[0]);
            const cur = try it.getVarOpt(var_name) orelse Value.empty;
            const items = try readPairs(it, cur);
            const at = try lookup(it, cur, items, args[1]);
            const old: Value = if (at) |i| items[i + 1] else Value.empty;
            var new: Value = undefined;
            switch (sub) {
                .incr => {
                    const by: i64 = if (args.len == 3) try it.int(args[2]) else 1;
                    new = .{ .int = (if (at != null) try it.int(old) else 0) +% by };
                },
                .lappend => {
                    var l = old.toList(a) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BadList => return it.fail("unmatched open brace or quote in list", .{}),
                    };
                    for (args[2..]) |v| l = try l.append(a, v);
                    new = .{ .list = l };
                },
                else => {
                    var text: std.ArrayList(u8) = .empty;
                    try text.appendSlice(a, try it.str(old));
                    for (args[2..]) |v| try text.appendSlice(a, try it.str(v));
                    new = .{ .str = text.items };
                },
            }
            const out = try setIn(it, cur, args[1..2], new);
            try it.setVar(var_name, out);
            return out;
        },
    }
}
