//! The hash tables and the assoc data of the stubs table of Tcl 8.6. The
//! native path (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`)
//! use this one file.
//!
//! A `Tcl_HashTable` is in the memory of the package, in the layout of
//! tcl.h, because the macros `Tcl_FindHashEntry` and `Tcl_CreateHashEntry`
//! call `findProc` and `createProc` of the table, and C code reads
//! `numEntries`, `clientData`, and the key of an entry directly. The
//! table is an array of buckets, and each bucket is a chain of entries.
//! A new table has the 4 static buckets of the record. When the entry
//! count gets to 3 times the bucket count, the table gets 4 times the
//! buckets and moves each entry to its new bucket with the hash that the
//! entry stores. The bucket of a hash is the high bits of the hash times
//! a 32-bit odd constant, so keys with equal low bits go to different
//! buckets.
//!
//! Each key type is a `Tcl_HashKeyType`: the string keys, the one-word
//! keys, the keys of N words, the `Tcl_Obj` keys of
//! `Tcl_InitObjHashTable`, and the custom types of a package. The string
//! hash is FNV-1a. The order of a search is the order of the buckets, so
//! it is not the order of Tcl.
//!
//! The assoc data of an interp is a list in the record of the interp.
//! `dropAssoc` calls the delete proc of each entry when the interp goes.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const mem = @import("mem.zig").slots;

const Obj = obj.Obj;
const Interp = obj.Interp;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

// ---- The layouts of tcl.h ----

pub const KeyProc = *const fn (*Table, ?*anyopaque) callconv(.c) c_uint;
pub const CompareProc = *const fn (?*anyopaque, *Entry) callconv(.c) c_int;
pub const AllocProc = *const fn (*Table, ?*anyopaque) callconv(.c) ?*Entry;
pub const FreeProc = *const fn (*Entry) callconv(.c) void;

/// `Tcl_HashEntry` with `TCL_HASH_KEY_STORE_HASH`.
pub const Entry = extern struct {
    next: ?*Entry,
    table: *Table,
    hash: ?*anyopaque,
    client_data: ?*anyopaque,
    /// The first word of the key union. A string key and a key of N
    /// words go on past the end of the record.
    key: extern union { one_word: ?*anyopaque, words: [1]c_int, string: [1]u8 },
};

/// `Tcl_HashKeyType`.
pub const KeyType = extern struct {
    version: c_int,
    flags: c_int,
    hash_key: ?KeyProc,
    compare_keys: ?CompareProc,
    alloc_entry: ?AllocProc,
    free_entry: ?FreeProc,
};

pub const FindFn = *const fn (*Table, ?*const anyopaque) callconv(.c) ?*Entry;
pub const CreateFn = *const fn (*Table, ?*const anyopaque, ?*c_int) callconv(.c) ?*Entry;

/// `TCL_SMALL_HASH_TABLE`.
const small = 4;

/// `Tcl_HashTable`.
pub const Table = extern struct {
    buckets: [*]?*Entry,
    static_buckets: [small]?*Entry,
    num_buckets: c_int,
    num_entries: c_int,
    rebuild_size: c_int,
    down_shift: c_int,
    mask: c_int,
    key_type: c_int,
    find: FindFn,
    create: CreateFn,
    type: *const KeyType,
};

/// `Tcl_HashSearch`.
pub const Search = extern struct {
    table: *Table,
    next_index: c_int,
    next_entry: ?*Entry,
};

pub const string_keys: c_int = 0;
pub const one_word_keys: c_int = 1;
pub const custom_type_keys: c_int = -2;
pub const custom_ptr_keys: c_int = -1;

const key_offset = @offsetOf(Entry, "key");

// ---- The key types ----

fn fnv(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |b| h = (h ^ b) *% 16777619;
    return h;
}

fn cstr(p: ?*anyopaque) [*:0]const u8 {
    return @ptrCast(p.?);
}

fn hashString(_: *Table, key: ?*anyopaque) callconv(.c) c_uint {
    return fnv(std.mem.span(cstr(key)));
}

fn compareString(key: ?*anyopaque, e: *Entry) callconv(.c) c_int {
    const k: [*:0]const u8 = @ptrCast(&e.key.string);
    return @intFromBool(std.mem.orderZ(u8, cstr(key), k) == .eq);
}

fn allocString(t: *Table, key: ?*anyopaque) callconv(.c) ?*Entry {
    const s = std.mem.span(cstr(key));
    const e = newEntry(t, @max(@sizeOf(Entry), key_offset + s.len + 1));
    const dst: [*]u8 = @ptrCast(&e.key.string);
    @memcpy(dst[0 .. s.len + 1], s.ptr[0 .. s.len + 1]);
    return e;
}

fn words(t: *const Table, key: ?*anyopaque) []const c_int {
    const p: [*]const c_int = @ptrCast(@alignCast(key.?));
    return p[0..@intCast(t.key_type)];
}

fn hashWords(t: *Table, key: ?*anyopaque) callconv(.c) c_uint {
    return fnv(std.mem.sliceAsBytes(words(t, key)));
}

fn compareWords(key: ?*anyopaque, e: *Entry) callconv(.c) c_int {
    const w = words(e.table, key);
    const have: [*]const c_int = @ptrCast(&e.key.words);
    return @intFromBool(std.mem.eql(c_int, w, have[0..w.len]));
}

fn allocWords(t: *Table, key: ?*anyopaque) callconv(.c) ?*Entry {
    const w = words(t, key);
    const e = newEntry(t, @max(@sizeOf(Entry), key_offset + w.len * @sizeOf(c_int)));
    const dst: [*]c_int = @ptrCast(&e.key.words);
    @memcpy(dst[0..w.len], w);
    return e;
}

fn objText(key: ?*anyopaque) []const u8 {
    var n: c_int = 0;
    const s = obj.Tcl_GetStringFromObj(@ptrCast(@alignCast(key.?)), &n);
    return s[0..@intCast(n)];
}

fn hashObj(_: *Table, key: ?*anyopaque) callconv(.c) c_uint {
    return fnv(objText(key));
}

fn compareObj(key: ?*anyopaque, e: *Entry) callconv(.c) c_int {
    if (key == e.key.one_word) return 1;
    return @intFromBool(std.mem.eql(u8, objText(key), objText(e.key.one_word)));
}

fn allocObj(t: *Table, key: ?*anyopaque) callconv(.c) ?*Entry {
    const e = newEntry(t, @sizeOf(Entry));
    e.key = .{ .one_word = key };
    obj.incr(@ptrCast(@alignCast(key.?)));
    return e;
}

fn freeObj(e: *Entry) callconv(.c) void {
    obj.decr(@ptrCast(@alignCast(e.key.one_word.?)));
    std.c.free(e);
}

const string_type: KeyType = .{ .version = 1, .flags = 0, .hash_key = hashString, .compare_keys = compareString, .alloc_entry = allocString, .free_entry = null };
const one_word_type: KeyType = .{ .version = 1, .flags = 0, .hash_key = null, .compare_keys = null, .alloc_entry = null, .free_entry = null };
const words_type: KeyType = .{ .version = 1, .flags = 0, .hash_key = hashWords, .compare_keys = compareWords, .alloc_entry = allocWords, .free_entry = null };
const obj_type: KeyType = .{ .version = 1, .flags = 0, .hash_key = hashObj, .compare_keys = compareObj, .alloc_entry = allocObj, .free_entry = freeObj };

fn newEntry(_: *Table, size: usize) *Entry {
    const e: *Entry = @ptrCast(@alignCast(mem.Tcl_Alloc(@intCast(size))));
    e.client_data = null;
    return e;
}

// ---- The table ----

fn bucketOf(t: *const Table, hash: usize) usize {
    const h: u32 = @truncate(hash);
    const mixed = h *% 2654435761;
    return @as(usize, mixed >> @intCast(t.down_shift)) & @as(usize, @intCast(t.mask));
}

fn hashOf(t: *Table, key: ?*anyopaque) usize {
    if (t.type.hash_key) |f| return f(t, key);
    // A one-word key with no hash proc: the key is its own hash.
    return @intFromPtr(key);
}

fn match(t: *const Table, key: ?*anyopaque, hash: usize, e: *Entry) bool {
    if (@intFromPtr(e.hash) != hash) return false;
    if (t.type.compare_keys) |f| return f(key, e) != 0;
    return e.key.one_word == key;
}

fn findEntry(t: *Table, key_c: ?*const anyopaque) callconv(.c) ?*Entry {
    const key: ?*anyopaque = @constCast(key_c);
    const hash = hashOf(t, key);
    var e = t.buckets[bucketOf(t, hash)];
    while (e) |x| : (e = x.next) {
        if (match(t, key, hash, x)) return x;
    }
    return null;
}

fn createEntry(t: *Table, key_c: ?*const anyopaque, new: ?*c_int) callconv(.c) ?*Entry {
    const key: ?*anyopaque = @constCast(key_c);
    const hash = hashOf(t, key);
    const b = bucketOf(t, hash);
    var e = t.buckets[b];
    while (e) |x| : (e = x.next) {
        if (match(t, key, hash, x)) {
            if (new) |n| n.* = 0;
            return x;
        }
    }
    // With no flag pointer, the create proc only finds, as in Tcl 8.6:
    // a program can call it in place of the find proc.
    const n = new orelse return null;
    n.* = 1;
    const x: *Entry = if (t.type.alloc_entry) |f| f(t, key).? else blk: {
        const y = newEntry(t, @sizeOf(Entry));
        y.key = .{ .one_word = key };
        break :blk y;
    };
    x.table = t;
    x.hash = @ptrFromInt(hash);
    x.next = t.buckets[b];
    t.buckets[b] = x;
    t.num_entries += 1;
    if (t.num_entries >= t.rebuild_size) rebuild(t);
    return x;
}

fn deletedFind(_: *Table, _: ?*const anyopaque) callconv(.c) ?*Entry {
    mem.Tcl_Panic("called Tcl_FindHashEntry on deleted table");
}

fn deletedCreate(_: *Table, _: ?*const anyopaque, _: ?*c_int) callconv(.c) ?*Entry {
    mem.Tcl_Panic("called Tcl_CreateHashEntry on deleted table");
}

/// Gives the table 4 times the buckets.
fn rebuild(t: *Table) void {
    const old = t.buckets;
    const old_n: usize = @intCast(t.num_buckets);
    const n = old_n * 4;
    const raw = mem.Tcl_Alloc(@intCast(n * @sizeOf(?*Entry)));
    const nb: [*]?*Entry = @ptrCast(@alignCast(raw));
    @memset(nb[0..n], null);
    t.buckets = nb;
    t.num_buckets = @intCast(n);
    t.rebuild_size *= 4;
    t.down_shift -= 2;
    t.mask = (t.mask << 2) + 3;
    for (old[0..old_n]) |head| {
        var e = head;
        while (e) |x| {
            e = x.next;
            const b = bucketOf(t, @intFromPtr(x.hash));
            x.next = nb[b];
            nb[b] = x;
        }
    }
    if (old != &t.static_buckets) std.c.free(@ptrCast(old));
}

fn freeEntry(t: *const Table, e: *Entry) void {
    if (t.type.free_entry) |f| f(e) else std.c.free(e);
}

fn init(t: *Table, key_type: c_int, kt: *const KeyType) void {
    t.static_buckets = @splat(null);
    t.buckets = &t.static_buckets;
    t.num_buckets = small;
    t.num_entries = 0;
    t.rebuild_size = small * 3;
    t.down_shift = 30;
    t.mask = small - 1;
    t.key_type = key_type;
    t.find = findEntry;
    t.create = createEntry;
    t.type = kt;
}

pub fn Tcl_InitHashTable(t: *Table, key_type: c_int) callconv(.c) void {
    const kt: *const KeyType = switch (key_type) {
        string_keys => &string_type,
        one_word_keys => &one_word_type,
        else => if (key_type > 1) &words_type else mem.Tcl_Panic("Tcl_InitHashTable: the key type of a custom table needs Tcl_InitCustomHashTable"),
    };
    init(t, key_type, kt);
}

pub fn Tcl_InitCustomHashTable(t: *Table, key_type: c_int, kt: ?*const KeyType) callconv(.c) void {
    if (kt) |k| return init(t, key_type, k);
    Tcl_InitHashTable(t, key_type);
}

pub fn Tcl_InitObjHashTable(t: *Table) callconv(.c) void {
    init(t, custom_ptr_keys, &obj_type);
}

pub fn Tcl_FindHashEntry(t: *Table, key: ?*const anyopaque) callconv(.c) ?*Entry {
    return t.find(t, key);
}

pub fn Tcl_CreateHashEntry(t: *Table, key: ?*const anyopaque, new: ?*c_int) callconv(.c) ?*Entry {
    return t.create(t, key, new);
}

pub fn Tcl_DeleteHashEntry(e: *Entry) callconv(.c) void {
    const t = e.table;
    var link: *?*Entry = &t.buckets[bucketOf(t, @intFromPtr(e.hash))];
    while (link.*) |x| : (link = &x.next) {
        if (x == e) {
            link.* = e.next;
            break;
        }
    } else mem.Tcl_Panic("malformed bucket chain in Tcl_DeleteHashEntry");
    t.num_entries -= 1;
    freeEntry(t, e);
}

pub fn Tcl_DeleteHashTable(t: *Table) callconv(.c) void {
    for (t.buckets[0..@intCast(t.num_buckets)]) |head| {
        var e = head;
        while (e) |x| {
            e = x.next;
            freeEntry(t, x);
        }
    }
    if (t.buckets != &t.static_buckets) std.c.free(@ptrCast(t.buckets));
    t.buckets = &t.static_buckets;
    t.static_buckets = @splat(null);
    t.num_entries = 0;
    t.find = deletedFind;
    t.create = deletedCreate;
}

pub fn Tcl_FirstHashEntry(t: *Table, s: *Search) callconv(.c) ?*Entry {
    s.* = .{ .table = t, .next_index = 0, .next_entry = null };
    return Tcl_NextHashEntry(s);
}

/// The search moves to the next entry before it gives an entry, so the
/// caller can delete the entry that it got.
pub fn Tcl_NextHashEntry(s: *Search) callconv(.c) ?*Entry {
    const t = s.table;
    while (s.next_entry == null) {
        if (s.next_index >= t.num_buckets) return null;
        s.next_entry = t.buckets[@intCast(s.next_index)];
        s.next_index += 1;
    }
    const e = s.next_entry.?;
    s.next_entry = e.next;
    return e;
}

/// Gives the counts of the table as text in memory of `Tcl_Alloc`. The
/// caller frees it with `ckfree`.
pub fn Tcl_HashStats(t: *Table) callconv(.c) [*:0]u8 {
    var counts: [11]usize = @splat(0);
    var dist: f64 = 0;
    for (t.buckets[0..@intCast(t.num_buckets)]) |head| {
        var n: usize = 0;
        var e = head;
        while (e) |x| : (e = x.next) {
            n += 1;
            dist += @floatFromInt(n);
        }
        counts[@min(n, 10)] += 1;
    }
    if (t.num_entries > 0) dist /= @floatFromInt(t.num_entries);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d} entries in table, {d} buckets\n", .{ t.num_entries, t.num_buckets }) catch {};
    for (counts[0..10], 0..) |c, i| w.print("number of buckets with {d} entries: {d}\n", .{ i, c }) catch {};
    w.print("number of buckets with 10 or more entries: {d}\n", .{counts[10]}) catch {};
    w.print("average search distance for entry: {d:.1}", .{dist}) catch {};
    const text = w.buffered();
    const out = mem.Tcl_Alloc(@intCast(text.len + 1));
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out);
}

// ---- The assoc data ----

pub const InterpDeleteProc = *const fn (?*anyopaque, *Interp) callconv(.c) void;

/// One entry of the assoc data of an interp.
pub const Assoc = struct {
    next: ?*Assoc,
    name: [:0]u8,
    proc: ?InterpDeleteProc,
    data: ?*anyopaque,
};

const gpa = std.heap.c_allocator;

fn findAssoc(ip: *Interp, name: [*:0]const u8) ?*?*Assoc {
    var link: *?*Assoc = @ptrCast(@alignCast(&ip.assoc));
    while (link.*) |a| : (link = &a.next) {
        if (std.mem.orderZ(u8, a.name, name) == .eq) return link;
    }
    return null;
}

pub fn Tcl_SetAssocData(ip: *Interp, name: [*:0]const u8, proc: ?InterpDeleteProc, data: ?*anyopaque) callconv(.c) void {
    if (findAssoc(ip, name)) |link| {
        link.*.?.proc = proc;
        link.*.?.data = data;
        return;
    }
    const src = std.mem.span(name);
    const copy = gpa.allocSentinel(u8, src.len, 0) catch mem.Tcl_Panic("unable to alloc the assoc data");
    @memcpy(copy, src);
    const a = gpa.create(Assoc) catch mem.Tcl_Panic("unable to alloc the assoc data");
    a.* = .{ .next = @ptrCast(@alignCast(ip.assoc)), .name = copy, .proc = proc, .data = data };
    ip.assoc = a;
}

pub fn Tcl_GetAssocData(ip: *Interp, name: [*:0]const u8, proc: ?*?InterpDeleteProc) callconv(.c) ?*anyopaque {
    const link = findAssoc(ip, name) orelse return null;
    const a = link.*.?;
    if (proc) |p| p.* = a.proc;
    return a.data;
}

pub fn Tcl_DeleteAssocData(ip: *Interp, name: [*:0]const u8) callconv(.c) void {
    const link = findAssoc(ip, name) orelse return;
    const a = link.*.?;
    link.* = a.next;
    const proc = a.proc;
    const data = a.data;
    gpa.free(a.name);
    gpa.destroy(a);
    if (proc) |f| f(data, ip);
}

/// Calls the delete proc of each assoc data entry of `ip` and frees the
/// list. A proc can add an entry, so the loop runs until the list is
/// empty.
pub fn dropAssoc(ip: *Interp) void {
    while (ip.assoc) |p| {
        const a: *Assoc = @ptrCast(@alignCast(p));
        ip.assoc = a.next;
        const proc = a.proc;
        const data = a.data;
        gpa.free(a.name);
        gpa.destroy(a);
        if (proc) |f| f(data, ip);
    }
}

// ---- Tests ----

test "string keys, growth, search, and delete" {
    var t: Table = undefined;
    Tcl_InitHashTable(&t, string_keys);
    var buf: [16]u8 = undefined;
    var new: c_int = 0;
    for (0..100) |i| {
        const k = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        buf[k.len] = 0;
        const e = Tcl_CreateHashEntry(&t, &buf, &new).?;
        try std.testing.expectEqual(@as(c_int, 1), new);
        e.client_data = @ptrFromInt(i + 1);
    }
    try std.testing.expectEqual(@as(c_int, 100), t.num_entries);
    try std.testing.expectEqual(@as(c_int, 64), t.num_buckets);
    _ = Tcl_CreateHashEntry(&t, "k7", &new);
    try std.testing.expectEqual(@as(c_int, 0), new);
    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(t.find(&t, "k7").?.client_data));
    try std.testing.expect(t.find(&t, "nope") == null);
    var s: Search = undefined;
    var n: usize = 0;
    var e = Tcl_FirstHashEntry(&t, &s);
    while (e) |x| : (e = Tcl_NextHashEntry(&s)) {
        n += 1;
        if (@intFromPtr(x.client_data) % 2 == 0) Tcl_DeleteHashEntry(x);
    }
    try std.testing.expectEqual(@as(usize, 100), n);
    try std.testing.expectEqual(@as(c_int, 50), t.num_entries);
    try std.testing.expect(t.find(&t, "k1") == null);
    try std.testing.expect(t.find(&t, "k0") != null);
    const st = Tcl_HashStats(&t);
    defer std.c.free(st);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(st), "50 entries in table, 64 buckets\n"));
    Tcl_DeleteHashTable(&t);
}

test "one-word keys and keys of two words" {
    var t: Table = undefined;
    Tcl_InitHashTable(&t, one_word_keys);
    var x: u8 = 0;
    var is_new: c_int = 0;
    _ = Tcl_CreateHashEntry(&t, &x, &is_new);
    try std.testing.expect(t.find(&t, &x).?.key.one_word == @as(*anyopaque, &x));
    Tcl_DeleteHashTable(&t);
    Tcl_InitHashTable(&t, 2);
    const a = [2]c_int{ 1, 2 };
    const b = [2]c_int{ 1, 2 };
    _ = Tcl_CreateHashEntry(&t, &a, &is_new);
    try std.testing.expect(t.find(&t, &b) != null);
    try std.testing.expect(t.find(&t, &[2]c_int{ 2, 1 }) == null);
    Tcl_DeleteHashTable(&t);
}

test "assoc data" {
    var ip: Interp = .{};
    const S = struct {
        var calls: usize = 0;
        fn del(d: ?*anyopaque, _: *Interp) callconv(.c) void {
            calls += @intFromPtr(d);
        }
    };
    Tcl_SetAssocData(&ip, "a", S.del, @ptrFromInt(1));
    Tcl_SetAssocData(&ip, "b", S.del, @ptrFromInt(10));
    Tcl_SetAssocData(&ip, "a", S.del, @ptrFromInt(100));
    var p: ?InterpDeleteProc = null;
    try std.testing.expectEqual(@as(usize, 100), @intFromPtr(Tcl_GetAssocData(&ip, "a", &p)));
    try std.testing.expect(p != null);
    try std.testing.expect(Tcl_GetAssocData(&ip, "c", null) == null);
    Tcl_DeleteAssocData(&ip, "b");
    try std.testing.expectEqual(@as(usize, 10), S.calls);
    dropAssoc(&ip);
    try std.testing.expectEqual(@as(usize, 110), S.calls);
    try std.testing.expect(ip.assoc == null);
}
