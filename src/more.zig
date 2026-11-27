//! More commands: `lset`, `lsort`, and `binary`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- lset ----

fn lsetRec(it: *Interp, list: Value, idxs: []const Value, v: Value) Error!Value {
    if (idxs.len == 0) return v;
    const items = try it.list(list);
    const n = try cmds.index(it, idxs[0], items.len);
    if (n < 0 or n > items.len) return it.fail("list index out of range", .{});
    const at: usize = @intCast(n);
    if (at == items.len and idxs.len > 1) return it.fail("list index out of range", .{});
    const copy = try it.alloc().alloc(Value, @max(items.len, at + 1));
    @memcpy(copy[0..items.len], items);
    copy[at] = try lsetRec(it, if (at < items.len) items[at] else Value.empty, idxs[1..], v);
    return value.wrapList(it.alloc(), copy);
}

/// Writes `v` at `index` of the list in a plain cell. The cell keeps the
/// list as its own: a later call writes in place. Returns false for a
/// case that needs the general path: a cell that is not plain, an index
/// outside the list, or an index that is not valid.
pub fn lsetOwned(it: *Interp, cell: *interp.Var, index: Value, v: Value) Error!bool {
    const c = cell.target();
    if (c.v != .val and c.v != .owned) return false;
    const len = (try it.list(if (c.v == .val) c.v.val else c.v.owned)).len;
    const at = cmds.index(it, index, len) catch return false;
    if (at < 0 or at >= len) return false;
    const items = (try it.ownList(c)).?;
    items[@intCast(at)] = v;
    // The write changes the keys of a dict, so its marks go.
    const obj = c.v.owned.list.obj;
    obj.dict_len = 0;
    obj.index = null;
    return true;
}

/// Writes `v` at the path `idxs` (two or more indexes) of the list in a
/// plain cell. The cell owns the outer list, as in `lsetOwned`. An inner
/// list goes in place when it and each list above it on the path have
/// the stamp of the outer list. Each other inner list on the path gets a
/// copy with that stamp, and each list below a copy gets a copy too: a
/// copied list can share its items with another holder. Returns false
/// before any write for a case that needs the general path.
pub fn lsetOwnedPath(it: *Interp, cell: *interp.Var, idxs: []const Value, v: Value) Error!bool {
    const c = cell.target();
    if (c.v != .val and c.v != .owned) return false;
    // Each check comes before the first write.
    var cur = if (c.v == .val) c.v.val else c.v.owned;
    for (idxs, 0..) |ix, k| {
        const items = it.list(cur) catch return false;
        const at = cmds.index(it, ix, items.len) catch return false;
        if (at < 0 or at >= items.len) return false;
        if (k + 1 < idxs.len) cur = items[@intCast(at)];
    }
    var items = (try it.ownList(c)).?;
    var obj = c.v.owned.list.obj;
    const stamp = obj.own_stamp;
    var copied = stamp == 0;
    for (idxs, 0..) |ix, k| {
        // The write changes the keys of a dict, so its marks go.
        obj.dict_len = 0;
        obj.index = null;
        const at: usize = @intCast(try cmds.index(it, ix, items.len));
        if (k + 1 == idxs.len) {
            items[at] = v;
            break;
        }
        const child = items[at];
        if (!copied and child == .list and child.list.obj.own_stamp == stamp) {
            obj = child.list.obj;
            items = @constCast(child.list.items());
            continue;
        }
        const from = try it.list(child);
        const l = try value.allocList(it.alloc(), from.len);
        @memcpy(l.obj.buf, from);
        l.obj.own_stamp = stamp;
        items[at] = .{ .list = l };
        copied = true;
        obj = l.obj;
        items = l.obj.buf;
    }
    return true;
}

/// `lset` on a plain variable: the general command writes through
/// `lsetOwned` or `lsetOwnedPath`. It then ends the ownership, because it
/// returns the list, unless the bytecode drops the result (`dropped`).
/// The result is then an empty string, and the cell keeps the list.
fn lsetPlain(it: *Interp, name: []const u8, idxs: []const Value, v: Value, dropped: bool) Error!?Value {
    if (std.mem.indexOfScalar(u8, name, '(') != null) return null;
    const cell = (if (dropped) try it.findOwnedVar(it.frame, name) else try it.findVar(it.frame, name, false)) orelse return null;
    const done = if (idxs.len == 1) try lsetOwned(it, cell, idxs[0], v) else try lsetOwnedPath(it, cell, idxs, v);
    if (!done) return null;
    if (dropped) return Value.empty;
    const c = cell.target();
    const out = c.v.owned;
    c.v = .{ .val = out };
    return out;
}

pub fn cmdLset(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("lset listVar ?index? ?index ...? value");
    const name = try it.str(argv[1]);
    const dropped = it.takeDropped(argv);
    // One index word is a list of indexes.
    var idxs = argv[2 .. argv.len - 1];
    if (idxs.len == 1) idxs = try it.list(idxs[0]);
    if (idxs.len >= 1) {
        if (try lsetPlain(it, name, idxs, argv[argv.len - 1], dropped)) |out| return out;
    }
    const old = try it.getVar(name);
    const out = try lsetRec(it, old, idxs, argv[argv.len - 1]);
    try it.setVar(name, out);
    return out;
}

// ---- lsort ----

const Mode = enum { ascii, integer, real, nocase, dictionary, command };

const Key = struct { pos: usize, v: Value, s: []const u8 = "", i: i64 = 0, f: f64 = 0 };

const SortCtx = struct {
    it: *Interp,
    mode: Mode = .ascii,
    desc: bool = false,
    command: []const Value = &.{},
    /// The first error of the compare command.
    err: ?Error = null,

    fn order(c: *SortCtx, x: Key, y: Key) std.math.Order {
        const o: std.math.Order = switch (c.mode) {
            .ascii => std.mem.order(u8, x.s, y.s),
            .nocase => std.ascii.orderIgnoreCase(x.s, y.s),
            .dictionary => dictOrder(x.s, y.s),
            .integer => std.math.order(x.i, y.i),
            .real => std.math.order(x.f, y.f),
            .command => c.callOrder(x.v, y.v),
        };
        return if (c.desc) o.invert() else o;
    }

    fn callOrder(c: *SortCtx, x: Value, y: Value) std.math.Order {
        if (c.err != null) return .eq;
        const it = c.it;
        const words = it.alloc().alloc(Value, c.command.len + 2) catch {
            c.err = error.OutOfMemory;
            return .eq;
        };
        @memcpy(words[0..c.command.len], c.command);
        words[c.command.len] = x;
        words[c.command.len + 1] = y;
        const r = it.callWords(words) catch |e| {
            c.err = e;
            return .eq;
        };
        const n = r.asInt() orelse {
            c.err = it.fail("-compare command returned non-integer result", .{});
            return .eq;
        };
        return std.math.order(n, 0);
    }

    fn less(c: *SortCtx, x: Key, y: Key) bool {
        return c.order(x, y) == .lt;
    }
};

/// The order of `lsort -dictionary`: case does not count except as a
/// tie-break, and a run of digits compares as a number.
pub fn dictOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    var tie: std.math.Order = .eq;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var zi = i;
            while (zi < a.len and a[zi] == '0') zi += 1;
            var zj = j;
            while (zj < b.len and b[zj] == '0') zj += 1;
            var ei = zi;
            while (ei < a.len and std.ascii.isDigit(a[ei])) ei += 1;
            var ej = zj;
            while (ej < b.len and std.ascii.isDigit(b[ej])) ej += 1;
            if (ei - zi != ej - zj) return std.math.order(ei - zi, ej - zj);
            const o = std.mem.order(u8, a[zi..ei], b[zj..ej]);
            if (o != .eq) return o;
            if (tie == .eq) tie = std.math.order(zi - i, zj - j);
            i = ei;
            j = ej;
            continue;
        }
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[j]);
        if (x != y) return std.math.order(x, y);
        // An upper case letter sorts before the same lower case letter.
        if (tie == .eq and a[i] != b[j]) tie = std.math.order(a[i], b[j]);
        i += 1;
        j += 1;
    }
    if (i < a.len) return .gt;
    if (j < b.len) return .lt;
    return tie;
}

fn mergeSort(keys: []Key, tmp: []Key, ctx: *SortCtx) void {
    if (keys.len < 2) return;
    const mid = keys.len / 2;
    mergeSort(keys[0..mid], tmp[0..mid], ctx);
    mergeSort(keys[mid..], tmp[mid..], ctx);
    @memcpy(tmp[0..keys.len], keys);
    var i: usize = 0;
    var j: usize = mid;
    for (keys) |*k| {
        // The right element goes first only when it is less.
        if (j < keys.len and (i >= mid or ctx.less(tmp[j], tmp[i]))) {
            k.* = tmp[j];
            j += 1;
        } else {
            k.* = tmp[i];
            i += 1;
        }
    }
}

pub fn cmdLsort(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("lsort ?-option value ...? list");
    var ctx: SortCtx = .{ .it = it };
    var unique = false;
    var indices = false;
    var idx: []const Value = &.{};
    var stride: usize = 1;
    var has_stride = false;
    var oi: usize = 1;
    const last = argv.len - 1;
    while (oi < last) : (oi += 1) {
        const s = try it.str(argv[oi]);
        if (eql(s, "-ascii")) {
            ctx.mode = .ascii;
        } else if (eql(s, "-integer")) {
            ctx.mode = .integer;
        } else if (eql(s, "-real")) {
            ctx.mode = .real;
        } else if (eql(s, "-nocase")) {
            if (ctx.mode == .ascii) ctx.mode = .nocase;
        } else if (eql(s, "-dictionary")) {
            ctx.mode = .dictionary;
        } else if (eql(s, "-increasing")) {
            ctx.desc = false;
        } else if (eql(s, "-decreasing")) {
            ctx.desc = true;
        } else if (eql(s, "-unique")) {
            unique = true;
        } else if (eql(s, "-indices")) {
            indices = true;
        } else if (eql(s, "-index")) {
            if (oi + 1 >= last) return it.fail("\"-index\" option must be followed by list index", .{});
            oi += 1;
            idx = try it.list(argv[oi]);
            try cmds.checkSelect(it, idx);
        } else if (eql(s, "-command")) {
            if (oi + 1 >= last) return it.fail("\"-command\" option must be followed by comparison command", .{});
            oi += 1;
            ctx.mode = .command;
            ctx.command = try it.list(argv[oi]);
        } else if (eql(s, "-stride")) {
            if (oi + 1 >= last) return it.fail("\"-stride\" option must be followed by stride length", .{});
            oi += 1;
            const n = try it.int(argv[oi]);
            if (n < 2) return it.fail("stride length must be at least 2", .{});
            stride = @intCast(n);
            has_stride = true;
        } else return it.fail("bad option \"{s}\": must be -ascii, -command, -decreasing, -dictionary, -increasing, -index, -indices, -integer, -nocase, -real, -stride, or -unique", .{s});
    }
    const items = try it.list(argv[last]);
    if (has_stride) {
        if (items.len % stride != 0) return it.fail("list size must be a multiple of the stride length", .{});
        // The first index selects the element of the group.
        if (idx.len > 0) {
            const n = try cmds.index(it, idx[0], stride);
            if (n < 0 or n >= stride) return it.fail("when used with \"-stride\", the leading \"-index\" value must be within the group", .{});
        }
    }
    const count = items.len / stride;
    // A merge sort of n keys does at most n * ceil(log2(n)) compares.
    try cmds.chargeEntries(it, count *| std.math.log2_int_ceil(usize, @max(count, 1)));
    const keys = try it.alloc().alloc(Key, count);
    for (keys, 0..) |*k, g| {
        var kv = items[g * stride];
        var path = idx;
        if (has_stride and path.len > 0) {
            kv = items[g * stride + @as(usize, @intCast(try cmds.index(it, path[0], stride)))];
            path = path[1..];
        }
        for (path) |ix| {
            const sub = try it.list(kv);
            const n = try cmds.index(it, ix, sub.len);
            if (n < 0 or n >= sub.len) return it.fail("element {d} missing from sublist \"{s}\"", .{ n, try it.str(kv) });
            kv = sub[@intCast(n)];
        }
        k.* = .{ .pos = g, .v = kv };
        switch (ctx.mode) {
            .ascii, .nocase, .dictionary => k.s = try it.str(kv),
            .integer => k.i = try it.int(kv),
            .real => k.f = switch (kv.asNumber() orelse return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(kv)})) {
                .int => |n| @floatFromInt(n),
                .double => |d| d,
                else => unreachable,
            },
            .command => {},
        }
    }
    // A merge sort with its buffer in the arena: it is stable, as the
    // sort of Tcl is, and a compare command that sorts again uses
    // little native stack.
    mergeSort(keys, try it.alloc().alloc(Key, keys.len), &ctx);
    if (ctx.err) |e| return e;
    var out: std.ArrayList(Value) = .empty;
    for (keys, 0..) |k, i| {
        if (unique and i + 1 < keys.len and ctx.order(k, keys[i + 1]) == .eq) continue;
        if (indices) {
            try out.append(it.alloc(), .{ .int = @intCast(k.pos * stride) });
        } else try out.appendSlice(it.alloc(), items[k.pos * stride ..][0..stride]);
    }
    if (ctx.err) |e| return e;
    return value.wrapList(it.alloc(), out.items);
}

// ---- binary ----

/// True when no byte has the top bit. The scan reads 8 bytes at a time.
fn isAscii(s: []const u8) bool {
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 8) {
        if (std.mem.readInt(u64, s[i..][0..8], .little) & 0x8080808080808080 != 0) return false;
    }
    while (i < s.len) : (i += 1) if (s[i] >= 0x80) return false;
    return true;
}

/// The bytes of a string: each character below 256 is one byte.
fn toBytes(it: *Interp, s: []const u8) Error![]const u8 {
    if (isAscii(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (n == 1 or i + n > s.len) {
            try out.append(it.alloc(), s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch {
            try out.append(it.alloc(), s[i]);
            i += 1;
            continue;
        };
        try out.append(it.alloc(), @truncate(cp));
        i += n;
    }
    return out.items;
}

/// The string of bytes: a byte above 127 becomes the character with
/// that number.
fn fromBytes(it: *Interp, b: []const u8) Error![]const u8 {
    if (isAscii(b)) return b;
    var out: std.ArrayList(u8) = .empty;
    for (b) |c| {
        if (c < 0x80) {
            try out.append(it.alloc(), c);
        } else {
            try out.append(it.alloc(), 0xC0 | (c >> 6));
            try out.append(it.alloc(), 0x80 | (c & 0x3F));
        }
    }
    return out.items;
}

const Field = struct { type: u8, unsigned: bool, count: ?usize, star: bool };

fn nextField(it: *Interp, fmt: []const u8, pos: *usize) Error!?Field {
    while (pos.* < fmt.len and fmt[pos.*] == ' ') pos.* += 1;
    if (pos.* >= fmt.len) return null;
    var f: Field = .{ .type = fmt[pos.*], .unsigned = false, .count = null, .star = false };
    pos.* += 1;
    if (pos.* < fmt.len and fmt[pos.*] == 'u') {
        f.unsigned = true;
        pos.* += 1;
    }
    if (pos.* < fmt.len and fmt[pos.*] == '*') {
        f.star = true;
        pos.* += 1;
    } else if (pos.* < fmt.len and std.ascii.isDigit(fmt[pos.*])) {
        var n: usize = 0;
        while (pos.* < fmt.len and std.ascii.isDigit(fmt[pos.*])) : (pos.* += 1) {
            n = n *| 10 +| (fmt[pos.*] - '0');
        }
        if (n > 1 << 24) return it.fail("the count of a binary field is too large", .{});
        f.count = n;
    }
    return f;
}

/// The size and the byte order of a number field, or null.
fn numSpec(t: u8) ?struct { size: usize, big: bool, float: bool } {
    return switch (t) {
        'c' => .{ .size = 1, .big = false, .float = false },
        's', 't' => .{ .size = 2, .big = false, .float = false },
        'S' => .{ .size = 2, .big = true, .float = false },
        'i', 'n' => .{ .size = 4, .big = false, .float = false },
        'I' => .{ .size = 4, .big = true, .float = false },
        'w', 'm' => .{ .size = 8, .big = false, .float = false },
        'W' => .{ .size = 8, .big = true, .float = false },
        'f', 'r' => .{ .size = 4, .big = false, .float = true },
        'R' => .{ .size = 4, .big = true, .float = true },
        'd', 'q' => .{ .size = 8, .big = false, .float = true },
        'Q' => .{ .size = 8, .big = true, .float = true },
        else => null,
    };
}

fn toDouble(it: *Interp, v: Value) Error!f64 {
    const n = v.asNumber() orelse return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(v)});
    return if (n == .int) @floatFromInt(n.int) else n.double;
}

fn binaryFormat(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len < 3) return it.wrongArgs("binary format formatString ?arg ...?");
    const a = it.alloc();
    const fmt = try it.str(argv[2]);
    var out: std.ArrayList(u8) = .empty;
    var arg: usize = 3;
    var pos: usize = 0;
    while (try nextField(it, fmt, &pos)) |f| {
        if (f.type == 'x') {
            try out.appendNTimes(a, 0, f.count orelse 1);
            continue;
        }
        if (f.type == 'X') {
            const n = @min(f.count orelse 1, out.items.len);
            out.items.len = if (f.star) 0 else out.items.len - n;
            continue;
        }
        if (f.type == '@') {
            const n = f.count orelse return it.fail("missing count for \"@\" field specifier", .{});
            if (n > out.items.len) try out.appendNTimes(a, 0, n - out.items.len) else out.items.len = n;
            continue;
        }
        if (arg >= argv.len) return it.fail("not enough arguments for all format specifiers", .{});
        const v = argv[arg];
        arg += 1;
        if (f.type == 'a' or f.type == 'A') {
            const bytes = try toBytes(it, try it.str(v));
            const n = if (f.star) bytes.len else f.count orelse 1;
            try out.appendSlice(a, bytes[0..@min(n, bytes.len)]);
            if (n > bytes.len) try out.appendNTimes(a, if (f.type == 'a') 0 else ' ', n - bytes.len);
            continue;
        }
        if (f.type == 'h' or f.type == 'H' or f.type == 'b' or f.type == 'B') {
            const digits = try it.str(v);
            const bits: usize = if (f.type == 'h' or f.type == 'H') 4 else 1;
            const n = if (f.star) digits.len else f.count orelse 1;
            const per = 8 / bits;
            const start = out.items.len;
            try out.appendNTimes(a, 0, (n + per - 1) / per);
            for (0..@min(n, digits.len)) |k| {
                const d = std.fmt.charToDigit(digits[k], if (bits == 4) 16 else 2) catch
                    return it.fail("expected {s} string but got \"{s}\" instead", .{ if (bits == 4) "hexadecimal" else "binary", digits });
                const in_byte = k % per;
                const high_first = f.type == 'H' or f.type == 'B';
                const shift: u3 = @intCast(if (high_first) (per - 1 - in_byte) * bits else in_byte * bits);
                out.items[start + k / per] |= @as(u8, d) << shift;
            }
            continue;
        }
        const spec = numSpec(f.type) orelse return it.fail("bad field specifier \"{c}\"", .{f.type});
        var vals: []const Value = &.{v};
        if (f.count != null or f.star) {
            vals = try it.list(v);
            if (f.count) |n| {
                if (n > vals.len) return it.fail("number of elements in list does not match count", .{});
                vals = vals[0..n];
            }
        }
        for (vals) |x| {
            var bits: u64 = 0;
            if (spec.float) {
                const d = try toDouble(it, x);
                bits = if (spec.size == 8) @bitCast(d) else @as(u32, @bitCast(@as(f32, @floatCast(d))));
            } else bits = @bitCast(try it.int(x));
            for (0..spec.size) |k| {
                const sh: u6 = @intCast(8 * (if (spec.big) spec.size - 1 - k else k));
                try out.append(a, @truncate(bits >> sh));
            }
        }
    }
    return .{ .str = try fromBytes(it, out.items) };
}

fn binaryScan(it: *Interp, argv: []const Value) Error!Value {
    if (argv.len < 4) return it.wrongArgs("binary scan value formatString ?varName ...?");
    const a = it.alloc();
    const data = try toBytes(it, try it.str(argv[2]));
    const fmt = try it.str(argv[3]);
    var arg: usize = 4;
    var pos: usize = 0;
    var at: usize = 0;
    var done: i64 = 0;
    while (try nextField(it, fmt, &pos)) |f| {
        if (f.type == 'x') {
            at = if (f.star) data.len else @min(data.len, at + (f.count orelse 1));
            continue;
        }
        if (f.type == 'X') {
            at = if (f.star) 0 else at - @min(at, f.count orelse 1);
            continue;
        }
        if (f.type == '@') {
            at = if (f.star) data.len else @min(data.len, f.count orelse return it.fail("missing count for \"@\" field specifier", .{}));
            continue;
        }
        if (arg >= argv.len) return it.fail("not enough arguments for all format specifiers", .{});
        const name = try it.str(argv[arg]);
        arg += 1;
        const rest = data.len - at;
        if (f.type == 'a' or f.type == 'A') {
            const n = if (f.star) rest else f.count orelse 1;
            if (n > rest) break;
            var bytes = data[at .. at + n];
            if (f.type == 'A') bytes = std.mem.trimEnd(u8, bytes, " \x00");
            try it.setVar(name, .{ .str = try fromBytes(it, bytes) });
            at += n;
            done += 1;
            continue;
        }
        if (f.type == 'h' or f.type == 'H' or f.type == 'b' or f.type == 'B') {
            const bits: usize = if (f.type == 'h' or f.type == 'H') 4 else 1;
            const per = 8 / bits;
            const n = if (f.star) rest * per else f.count orelse 1;
            if ((n + per - 1) / per > rest) break;
            const text = try a.alloc(u8, n);
            for (text, 0..) |*ch, k| {
                const in_byte = k % per;
                const high_first = f.type == 'H' or f.type == 'B';
                const shift: u3 = @intCast(if (high_first) (per - 1 - in_byte) * bits else in_byte * bits);
                const d = (data[at + k / per] >> shift) & (if (bits == 4) @as(u8, 15) else 1);
                ch.* = "0123456789abcdef"[d];
            }
            try it.setVar(name, .{ .str = text });
            at += (n + per - 1) / per;
            done += 1;
            continue;
        }
        const spec = numSpec(f.type) orelse return it.fail("bad field specifier \"{c}\"", .{f.type});
        const n = if (f.star) rest / spec.size else f.count orelse 1;
        if (n * spec.size > rest) break;
        const vals = try a.alloc(Value, n);
        for (vals) |*x| {
            var bits: u64 = 0;
            for (0..spec.size) |k| {
                const sh: u6 = @intCast(8 * (if (spec.big) spec.size - 1 - k else k));
                bits |= @as(u64, data[at + k]) << sh;
            }
            at += spec.size;
            if (spec.float) {
                x.* = .{ .double = if (spec.size == 8) @bitCast(bits) else @as(f32, @bitCast(@as(u32, @truncate(bits)))) };
            } else if (f.unsigned or spec.size == 8) {
                x.* = .{ .int = @bitCast(bits) };
            } else {
                const sh: u6 = @intCast(64 - 8 * spec.size);
                x.* = .{ .int = @as(i64, @bitCast(bits << sh)) >> sh };
            }
        }
        const single = f.count == null and !f.star;
        try it.setVar(name, if (single) vals[0] else try value.wrapList(a, vals));
        done += 1;
    }
    return .{ .int = done };
}

pub fn cmdBinary(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("binary subcommand ?arg ...?");
    const sub = try it.str(argv[1]);
    if (eql(sub, "format")) return binaryFormat(it, argv);
    if (eql(sub, "scan")) return binaryScan(it, argv);
    if (eql(sub, "encode") or eql(sub, "decode")) return binaryCode(it, argv, eql(sub, "encode"));
    return it.fail("unknown or ambiguous subcommand \"{s}\": must be decode, encode, format, or scan", .{sub});
}

fn uuChar(v: u32) u8 {
    return if (v == 0) '`' else @intCast(v + 32);
}

/// `binary encode uuencode` and `binary decode uuencode`.
fn uuCode(it: *Interp, argv: []const Value, encode: bool) Error!Value {
    const a = it.alloc();
    if (argv.len < 4) {
        if (encode) return it.wrongArgs("binary encode uuencode ?-maxlen len? ?-wrapchar char? data");
        return it.wrongArgs("binary decode uuencode ?options? data");
    }
    var strict = false;
    var maxlen: i64 = 61;
    var wrap: []const u8 = "\n";
    var i: usize = 3;
    while (i < argv.len - 1) : (i += 1) {
        const o = try it.str(argv[i]);
        if (!encode and eql(o, "-strict")) {
            strict = true;
        } else if (encode and eql(o, "-maxlen") and i + 1 < argv.len - 1) {
            i += 1;
            maxlen = try it.int(argv[i]);
            if (maxlen < 5 or maxlen > 85) return it.fail("line length out of range", .{});
        } else if (encode and eql(o, "-wrapchar") and i + 1 < argv.len - 1) {
            i += 1;
            wrap = try it.str(argv[i]);
        } else if (encode) {
            return it.fail("bad option \"{s}\": must be -maxlen or -wrapchar", .{o});
        } else return it.fail("bad option \"{s}\": must be -strict", .{o});
    }
    const data = try it.str(argv[argv.len - 1]);
    var out: std.ArrayList(u8) = .empty;
    if (encode) {
        const bytes = try toBytes(it, data);
        const per_line: usize = @intCast(@divFloor(maxlen - 1, 4) * 3);
        var k: usize = 0;
        while (k < bytes.len) {
            const n = @min(per_line, bytes.len - k);
            try out.append(a, uuChar(@intCast(n)));
            var g: usize = 0;
            while (g < n) : (g += 3) {
                const left = n - g;
                const b0: u32 = bytes[k + g];
                const b1: u32 = if (left > 1) bytes[k + g + 1] else 0;
                const b2: u32 = if (left > 2) bytes[k + g + 2] else 0;
                try out.append(a, uuChar(b0 >> 2));
                try out.append(a, uuChar((b0 & 3) << 4 | b1 >> 4));
                if (left > 1) try out.append(a, uuChar((b1 & 15) << 2 | b2 >> 6));
                if (left > 2) try out.append(a, uuChar(b2 & 63));
            }
            try out.appendSlice(a, wrap);
            k += n;
        }
        return .{ .str = out.items };
    }
    var pos: usize = 0;
    while (pos < data.len) {
        const c = data[pos];
        if (c == '\n' or c == '\r' or (!strict and (c <= ' ' or c > '`'))) {
            pos += 1;
            continue;
        }
        if (c < ' ' or c > '`') return it.fail("invalid uuencode character \"{c}\" at position {d}", .{ c, pos });
        const want: usize = (c - 32) & 63;
        pos += 1;
        var vals: [4]u32 = undefined;
        var have: usize = 0;
        var made: usize = 0;
        while (pos < data.len and data[pos] != '\n' and made < want) {
            const d = data[pos];
            if (d < ' ' or d > '`') {
                if (strict) return it.fail("invalid uuencode character \"{c}\" at position {d}", .{ d, pos });
                pos += 1;
                continue;
            }
            vals[have] = (d - 32) & 63;
            have += 1;
            pos += 1;
            if (have == 4) {
                const v = vals[0] << 18 | vals[1] << 12 | vals[2] << 6 | vals[3];
                for ([3]u8{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) }) |b| {
                    if (made < want) try out.append(a, b);
                    made += 1;
                }
                have = 0;
            }
        }
        if (have > 1 and made < want) {
            for (vals[have..4]) |*x| x.* = 0;
            const v = vals[0] << 18 | vals[1] << 12 | vals[2] << 6 | vals[3];
            for ([3]u8{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) }, 0..) |b, t| {
                if (t + 1 < have and made < want) {
                    try out.append(a, b);
                    made += 1;
                }
            }
        }
        while (pos < data.len and data[pos] != '\n') : (pos += 1) {
            if (strict and (data[pos] < ' ' or data[pos] > '`')) return it.fail("invalid uuencode character \"{c}\" at position {d}", .{ data[pos], pos });
        }
    }
    return .{ .str = try fromBytes(it, out.items) };
}

const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// `binary encode` and `binary decode` for hex and base64.
fn binaryCode(it: *Interp, argv: []const Value, encode: bool) Error!Value {
    const a = it.alloc();
    if (argv.len < 3) return it.wrongArgs("binary encode|decode format ?-option value ...? data");
    const form = try it.str(argv[2]);
    const is_hex = eql(form, "hex");
    if (eql(form, "uuencode")) return uuCode(it, argv, encode);
    if (!is_hex and !eql(form, "base64")) return it.fail("unknown or ambiguous subcommand \"{s}\": must be base64, hex, or uuencode", .{form});
    if (argv.len < 4) {
        if (encode) return it.fail("wrong # args: should be \"binary encode {s} {s}\"", .{ form, if (is_hex) "data" else "?-maxlen len? ?-wrapchar char? data" });
        return it.fail("wrong # args: should be \"binary decode {s} ?options? data\"", .{form});
    }
    var strict = false;
    var maxlen: usize = 0;
    var wrap: []const u8 = "\n";
    var i: usize = 3;
    while (i < argv.len - 1) : (i += 1) {
        const o = try it.str(argv[i]);
        if (!encode and eql(o, "-strict")) {
            strict = true;
        } else if (encode and !is_hex and eql(o, "-maxlen") and i + 1 < argv.len - 1) {
            i += 1;
            const n = try it.int(argv[i]);
            if (n < 0) return it.fail("line length out of range", .{});
            maxlen = @intCast(n);
        } else if (encode and !is_hex and eql(o, "-wrapchar") and i + 1 < argv.len - 1) {
            i += 1;
            wrap = try it.str(argv[i]);
        } else if (encode) {
            if (is_hex) return it.fail("wrong # args: should be \"binary encode hex data\"", .{});
            return it.fail("bad option \"{s}\": must be -maxlen or -wrapchar", .{o});
        } else return it.fail("bad option \"{s}\": must be -strict", .{o});
    }
    const data = try it.str(argv[argv.len - 1]);
    var out: std.ArrayList(u8) = .empty;
    if (encode) {
        const bytes = try toBytes(it, data);
        if (is_hex) {
            for (bytes) |b| {
                try out.append(a, "0123456789abcdef"[b >> 4]);
                try out.append(a, "0123456789abcdef"[b & 15]);
            }
            return .{ .str = out.items };
        }
        if (maxlen == 0) return .{ .str = try encode64(a, bytes) };
        var col: usize = 0;
        var k: usize = 0;
        while (k < bytes.len) : (k += 3) {
            const n = @min(3, bytes.len - k);
            const b0: u32 = bytes[k];
            const b1: u32 = if (n > 1) bytes[k + 1] else 0;
            const b2: u32 = if (n > 2) bytes[k + 2] else 0;
            const v = b0 << 16 | b1 << 8 | b2;
            const quad = [4]u8{ b64[v >> 18], b64[(v >> 12) & 63], if (n > 1) b64[(v >> 6) & 63] else '=', if (n > 2) b64[v & 63] else '=' };
            for (quad) |ch| {
                if (maxlen > 0 and col == maxlen) {
                    try out.appendSlice(a, wrap);
                    col = 0;
                }
                try out.append(a, ch);
                col += 1;
            }
        }
        return .{ .str = out.items };
    }
    if (is_hex) {
        var half: ?u8 = null;
        for (data, 0..) |ch, pos| {
            const d = std.fmt.charToDigit(ch, 16) catch {
                if (!strict and std.ascii.isWhitespace(ch)) continue;
                return it.fail("invalid hexadecimal digit \"{c}\" at position {d}", .{ ch, pos });
            };
            if (half) |h| {
                try out.append(a, h << 4 | d);
                half = null;
            } else half = d;
        }
        if (half != null and strict) return it.fail("invalid hexadecimal digit \"\" at position {d}", .{data.len});
        return .{ .str = try fromBytes(it, out.items) };
    }
    var acc: u32 = 0;
    var have: u32 = 0;
    var pad: usize = 0;
    // Each four characters give three bytes at most.
    const buf = try a.alloc(u8, data.len / 4 * 3 + 3);
    var made: usize = 0;
    // Groups of four valid characters give three bytes each. The first
    // other character ends this loop, and the loop below goes on from it.
    var start: usize = 0;
    while (start + 4 <= data.len) : (start += 4) {
        const d0 = b64_value[data[start]];
        const d1 = b64_value[data[start + 1]];
        const d2 = b64_value[data[start + 2]];
        const d3 = b64_value[data[start + 3]];
        if ((d0 | d1 | d2 | d3) >= 64) break;
        const v = @as(u32, d0) << 18 | @as(u32, d1) << 12 | @as(u32, d2) << 6 | d3;
        buf[made] = @truncate(v >> 16);
        buf[made + 1] = @truncate(v >> 8);
        buf[made + 2] = @truncate(v);
        made += 3;
    }
    for (data[start..], start..) |ch, pos| {
        const d = b64_value[ch];
        if (d < 64 and pad == 0) {
            acc = acc << 6 | d;
            have += 6;
            if (have >= 8) {
                have -= 8;
                buf[made] = @truncate(acc >> @intCast(have));
                made += 1;
            }
            continue;
        }
        if (ch == '=') {
            pad += 1;
            if (pad > 2) return it.fail("invalid base64 character \"=\" at position {d}", .{pos});
            continue;
        }
        if (d >= 64 and !strict and std.ascii.isWhitespace(ch)) continue;
        return it.fail("invalid base64 character \"{c}\" at position {d}", .{ ch, pos });
    }
    return .{ .str = try fromBytes(it, buf[0..made]) };
}

/// The value of each base64 character, and 255 for any other byte.
const b64_value: [256]u8 = blk: {
    var t: [256]u8 = @splat(255);
    for (b64, 0..) |c, i| t[c] = @intCast(i);
    break :blk t;
};

/// The two base64 characters of each 12-bit value.
const b64_pairs: [4096][2]u8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [4096][2]u8 = undefined;
    for (0..4096) |v| t[v] = .{ b64[v >> 6], b64[v & 63] };
    break :blk t;
};

/// The base64 text of `bytes` with no line breaks. One allocation.
fn encode64(a: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    const out = try a.alloc(u8, (bytes.len + 2) / 3 * 4);
    var o: usize = 0;
    var k: usize = 0;
    // Two characters for each 12 bits, from one table.
    while (k + 3 <= bytes.len) : (k += 3) {
        const v = @as(u32, bytes[k]) << 16 | @as(u32, bytes[k + 1]) << 8 | bytes[k + 2];
        out[o..][0..2].* = b64_pairs[v >> 12];
        out[o + 2 ..][0..2].* = b64_pairs[v & 0xfff];
        o += 4;
    }
    const rest = bytes.len - k;
    if (rest > 0) {
        const v = @as(u32, bytes[k]) << 16 | (if (rest > 1) @as(u32, bytes[k + 1]) << 8 else 0);
        out[o] = b64[v >> 18];
        out[o + 1] = b64[(v >> 12) & 63];
        out[o + 2] = if (rest > 1) b64[(v >> 6) & 63] else '=';
        out[o + 3] = '=';
    }
    return out;
}

// ---- scan ----

fn isWs(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

/// `scan string format ?varName ...?`. With no variables, the result
/// is the list of the values.
/// Marks a position of `%n$` that received no value.
const unset_mark: Value = .{ .str = "\x00unset" };

fn isMark(v: Value) bool {
    return v == .str and v.str.ptr == unset_mark.str.ptr;
}

/// Stores a scanned value: in order, or at the index of `%n$`.
fn place(a: std.mem.Allocator, out: *std.ArrayList(Value), target: ?usize, v: Value) !void {
    const k = target orelse return out.append(a, v);
    while (out.items.len <= k) try out.append(a, unset_mark);
    out.items[k] = v;
}

pub fn cmdScan(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("scan string format ?varName ...?");
    const a = it.alloc();
    const s = try it.str(argv[1]);
    const f = try it.str(argv[2]);
    const vars = argv[3..];
    var out: std.ArrayList(Value) = .empty;
    var si: usize = 0;
    var fi: usize = 0;
    var wanted: usize = 0;
    var under = false;
    var stopped = false;
    var saw_xpg = false;
    var saw_seq = false;
    var used: std.ArrayList(usize) = .empty;
    // With no variables, an index of `%n$` is at most this count.
    var conversions: usize = 0;
    for (f, 0..) |x, k| {
        if (x == '%' and (k + 1 >= f.len or f[k + 1] != '%')) conversions += 1;
    }
    while (fi < f.len) {
        const c = f[fi];
        if (isWs(c)) {
            if (!stopped) while (si < s.len and isWs(s[si])) : (si += 1) {};
            fi += 1;
            continue;
        }
        if (c != '%' or (fi + 1 < f.len and f[fi + 1] == '%')) {
            if (c == '%') fi += 1;
            if (!stopped) {
                if (si < s.len and s[si] == c) si += 1 else stopped = true;
            }
            fi += 1;
            continue;
        }
        fi += 1;
        var suppress = false;
        if (fi < f.len and f[fi] == '*') {
            suppress = true;
            fi += 1;
        }
        var width: usize = 0;
        while (fi < f.len and std.ascii.isDigit(f[fi])) : (fi += 1) width = width *| 10 +| (f[fi] - '0');
        var target: ?usize = null;
        if (fi < f.len and f[fi] == '$') {
            if (suppress) return it.fail("bad scan conversion character \"$\"", .{});
            if (saw_seq) return it.fail("cannot mix \"%\" and \"%n$\" conversion specifiers", .{});
            saw_xpg = true;
            if (width == 0 or width > (if (vars.len > 0) vars.len else conversions)) return it.fail("\"%n$\" argument index out of range", .{});
            target = width - 1;
            fi += 1;
            width = 0;
            while (fi < f.len and std.ascii.isDigit(f[fi])) : (fi += 1) width = width *| 10 +| (f[fi] - '0');
            for (used.items) |u| if (u == target.?) return it.fail("variable is assigned by multiple \"%n$\" conversion specifiers", .{});
            try used.append(a, target.?);
        } else if (!suppress) {
            if (saw_xpg) return it.fail("cannot mix \"%\" and \"%n$\" conversion specifiers", .{});
            saw_seq = true;
        }
        while (fi < f.len and (f[fi] == 'h' or f[fi] == 'l' or f[fi] == 'L')) fi += 1;
        if (fi >= f.len) return it.fail("format string ended in middle of field specifier", .{});
        var conv = f[fi];
        fi += 1;
        if (conv == 'E' or conv == 'G') conv = 'e';
        if (conv == 'X') conv = 'x';
        if (conv == 'c' and width != 0) return it.fail("field width may not be specified in %c conversion", .{});
        // The set of `%[...]`.
        var set: [32]u8 = @splat(0);
        if (conv == '[') {
            var negate = false;
            if (fi < f.len and f[fi] == '^') {
                negate = true;
                fi += 1;
            }
            var first = true;
            while (true) : (first = false) {
                if (fi >= f.len) return it.fail("unmatched [ in format string", .{});
                const ch = f[fi];
                if (ch == ']' and !first) break;
                var hi = ch;
                if (fi + 2 < f.len and f[fi + 1] == '-' and f[fi + 2] != ']') {
                    hi = f[fi + 2];
                    fi += 2;
                }
                var x: usize = @min(ch, hi);
                while (x <= @max(ch, hi)) : (x += 1) set[x >> 3] |= @as(u8, 1) << @intCast(x & 7);
                fi += 1;
            }
            fi += 1;
            if (negate) for (&set) |*b| {
                b.* = ~b.*;
            };
        } else if (std.mem.indexOfScalar(u8, "dioxbucsefgn", conv) == null) {
            return it.fail("bad scan conversion character \"{c}\"", .{conv});
        }
        if (!suppress) wanted += 1;
        if (stopped) continue;
        if (conv == 'n') {
            if (!suppress) try place(a, &out, target, .{ .int = @intCast(cmds.charCount(s[0..si])) });
            continue;
        }
        if (conv != 'c' and conv != '[') while (si < s.len and isWs(s[si])) : (si += 1) {};
        if (si >= s.len) {
            if (out.items.len == 0) under = true;
            stopped = true;
            continue;
        }
        const limit = if (width == 0) s.len else @min(s.len, si + width);
        var v: Value = undefined;
        switch (conv) {
            'c' => {
                const n = std.unicode.utf8ByteSequenceLength(s[si]) catch 1;
                const cp: u32 = if (si + n <= s.len) (std.unicode.wtf8Decode(s[si .. si + n]) catch s[si]) else s[si];
                si += if (si + n <= s.len) n else 1;
                v = .{ .int = cp };
            },
            's' => {
                const start = si;
                while (si < limit and !isWs(s[si])) si += 1;
                v = .{ .str = s[start..si] };
            },
            '[' => {
                const start = si;
                while (si < limit and set[s[si] >> 3] & (@as(u8, 1) << @intCast(s[si] & 7)) != 0) si += 1;
                if (si == start) {
                    stopped = true;
                    continue;
                }
                v = .{ .str = s[start..si] };
            },
            'f', 'e', 'g' => {
                const start = si;
                if (si < limit and (s[si] == '-' or s[si] == '+')) si += 1;
                while (si < limit and std.ascii.isDigit(s[si])) si += 1;
                if (si < limit and s[si] == '.') {
                    si += 1;
                    while (si < limit and std.ascii.isDigit(s[si])) si += 1;
                }
                if (si < limit and (s[si] == 'e' or s[si] == 'E')) {
                    var e = si + 1;
                    if (e < limit and (s[e] == '-' or s[e] == '+')) e += 1;
                    if (e < limit and std.ascii.isDigit(s[e])) {
                        while (e < limit and std.ascii.isDigit(s[e])) e += 1;
                        si = e;
                    }
                }
                const d = std.fmt.parseFloat(f64, s[start..si]) catch {
                    si = start;
                    stopped = true;
                    continue;
                };
                v = .{ .double = d };
            },
            else => {
                const start = si;
                var neg = false;
                if (si < limit and (s[si] == '-' or s[si] == '+')) {
                    neg = s[si] == '-';
                    si += 1;
                }
                var base: u8 = switch (conv) {
                    'x' => 16,
                    'o' => 8,
                    'b' => 2,
                    else => 10,
                };
                if (conv == 'i' and si < limit and s[si] == '0') {
                    base = 8;
                    if (si + 1 < limit and (s[si + 1] == 'x' or s[si + 1] == 'X')) {
                        base = 16;
                        si += 2;
                    } else if (si + 1 < limit and (s[si + 1] == 'b' or s[si + 1] == 'B')) {
                        base = 2;
                        si += 2;
                    }
                } else if (conv == 'x' and si + 1 < limit and s[si] == '0' and (s[si + 1] == 'x' or s[si + 1] == 'X')) {
                    si += 2;
                }
                const digits = si;
                var n: u64 = 0;
                while (si < limit) : (si += 1) {
                    const d = std.fmt.charToDigit(s[si], base) catch break;
                    n = n *% base +% d;
                }
                if (si == digits and !(conv == 'i' and base != 10)) {
                    si = start;
                    stopped = true;
                    continue;
                }
                const signed: i64 = @bitCast(n);
                v = .{ .int = if (neg) 0 -% signed else signed };
            },
        }
        if (!suppress) try place(a, &out, target, v);
    }
    if (saw_xpg) {
        const size = if (vars.len > 0) vars.len else blk: {
            var top: usize = 0;
            for (used.items) |u| top = @max(top, u + 1);
            break :blk top;
        };
        while (out.items.len < size) try out.append(a, unset_mark);
        if (vars.len == 0) {
            for (out.items) |*v| if (isMark(v.*)) {
                v.* = Value.empty;
            };
            if (under) return Value.empty;
            return value.wrapList(a, out.items);
        }
        if (used.items.len < vars.len) return it.fail("variable is not assigned by any conversion specifiers", .{});
        var n: i64 = 0;
        for (out.items, 0..) |v, i| {
            if (isMark(v)) continue;
            try it.setVar(try it.str(vars[i]), v);
            n += 1;
        }
        return .{ .int = if (under) -1 else n };
    }
    if (vars.len == 0) {
        if (under) return Value.empty;
        while (out.items.len < wanted) try out.append(a, Value.empty);
        return value.wrapList(a, out.items);
    }
    if (wanted > vars.len) return it.fail("different numbers of variable names and field specifiers", .{});
    if (wanted < vars.len) return it.fail("variable is not assigned by any conversion specifiers", .{});
    for (out.items, 0..) |v, i| try it.setVar(try it.str(vars[i]), v);
    return .{ .int = if (under) -1 else @intCast(out.items.len) };
}
