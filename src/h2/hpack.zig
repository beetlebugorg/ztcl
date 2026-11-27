//! HPACK, the header compression of HTTP/2 (RFC 7541, task 28).
//!
//! - Integers with an N-bit prefix (section 5.1).
//! - Strings, plain or with the Huffman code of appendix B (5.2).
//! - The static table of appendix A and the dynamic table with its
//!   size limit and evictions (section 4).
//! - `Decoder` reads a header block and gives one field at a time.
//! - `Encoder` writes a header block.
//!
//! The decoder makes no copy of a plain string: the name and the value
//! of a field point into the header block, into the dynamic table, or
//! into the scratch buffer of the caller for a Huffman string. They stay
//! valid until the next call of `Block.next`. The decoder allocates
//! only the dynamic table, once, in `init`. A field past the limit of
//! the header list gives `error.HeaderListTooLarge`, so the caller
//! copies no field past the limit.
//!
//! The Huffman decoder reads 12 bits at a time from a 64-bit window: a
//! table of 4,096 entries gives up to 2 symbols for each lookup. A
//! longer code uses the canonical form of the code (appendix B is
//! canonical, and tools/hpack-tables.py checks it): for each length,
//! the first code and the place of its symbol in the list of symbols
//! sorted by length.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tables = @import("hpack_tables.zig");

pub const Field = tables.Field;

pub const Error = error{
    /// The block ends inside a representation.
    Truncated,
    IntegerOverflow,
    /// An index of 0 or past the end of the dynamic table.
    BadIndex,
    /// A bad Huffman string: EOS, padding of 8 bits or more, or padding
    /// that is not all ones.
    BadHuffman,
    /// A Huffman string longer than the scratch buffer of the caller.
    NoScratch,
    HeaderListTooLarge,
    /// A dynamic table size update past the limit of the settings, or
    /// after the first field of a block.
    BadTableSizeUpdate,
};

// Integers (section 5.1).

/// Reads an integer with a prefix of `n` bits at `pos`.
pub fn readInt(buf: []const u8, pos: *usize, comptime n: u4) Error!u32 {
    if (pos.* >= buf.len) return error.Truncated;
    const mask: u8 = (1 << n) - 1;
    var v: u64 = buf[pos.*] & mask;
    pos.* += 1;
    if (v < mask) return @intCast(v);
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= buf.len) return error.Truncated;
        const b = buf[pos.*];
        pos.* += 1;
        v += @as(u64, b & 0x7f) << shift;
        if (v > std.math.maxInt(u32)) return error.IntegerOverflow;
        if (b & 0x80 == 0) return @intCast(v);
        shift += 7;
        if (shift > 28) return error.IntegerOverflow;
    }
}

/// The length of an integer with a prefix of `n` bits.
pub fn intLen(v: u32, comptime n: u4) usize {
    const mask: u32 = (1 << n) - 1;
    if (v < mask) return 1;
    var r = v - mask;
    var len: usize = 2;
    while (r >= 0x80) : (r >>= 7) len += 1;
    return len;
}

/// Writes an integer with a prefix of `n` bits, with `flags` in the
/// high bits of the first byte. Gives the length.
pub fn writeInt(out: []u8, v: u32, comptime n: u4, flags: u8) usize {
    const mask: u32 = (1 << n) - 1;
    if (v < mask) {
        out[0] = flags | @as(u8, @intCast(v));
        return 1;
    }
    out[0] = flags | @as(u8, @intCast(mask));
    var r = v - mask;
    var i: usize = 1;
    while (r >= 0x80) : (r >>= 7) {
        out[i] = @as(u8, @truncate(r)) | 0x80;
        i += 1;
    }
    out[i] = @intCast(r);
    return i + 1;
}

// The Huffman code (section 5.2, appendix B).

const code = tables.huffman_code;
const code_len = tables.huffman_len;

/// The tables of the decoder, made at compile time.
const Dec = struct {
    /// For each length: the first code, the count of codes, and the
    /// place of the first symbol in `syms`.
    first: [31]u32,
    count: [31]u16,
    base: [31]u16,
    syms: [257]u16,
};

const dec: Dec = blk: {
    @setEvalBranchQuota(1_000_000);
    var d: Dec = .{ .first = @splat(0), .count = @splat(0), .base = @splat(0), .syms = undefined };
    var k: usize = 0;
    for (1..31) |l| {
        d.base[l] = k;
        var first_set = false;
        for (0..257) |s| {
            if (code_len[s] != l) continue;
            if (!first_set) {
                d.first[l] = code[s];
                first_set = true;
            }
            d.syms[k] = s;
            k += 1;
            d.count[l] += 1;
        }
    }
    break :blk d;
};

/// The length of the Huffman form of `s` in bytes.
pub fn huffmanLen(s: []const u8) usize {
    var bits: usize = 0;
    for (s) |b| bits += code_len[b];
    return (bits + 7) / 8;
}

/// Writes the Huffman form of `s` into `out`, which has room for
/// `huffmanLen(s)` bytes. Gives the length.
pub fn huffmanEncode(out: []u8, s: []const u8) usize {
    var acc: u64 = 0;
    var n: u6 = 0;
    var o: usize = 0;
    for (s) |b| {
        acc = (acc << @intCast(code_len[b])) | code[b];
        n += @intCast(code_len[b]);
        if (n >= 32) {
            n -= 32;
            std.mem.writeInt(u32, out[o..][0..4], @truncate(acc >> n), .big);
            o += 4;
        }
    }
    while (n >= 8) {
        n -= 8;
        out[o] = @truncate(acc >> n);
        o += 1;
    }
    if (n > 0) {
        // The padding: the high bits of EOS, all ones.
        out[o] = @truncate((acc << @intCast(8 - @as(u8, n))) | ((@as(u64, 1) << @intCast(8 - @as(u8, n))) - 1));
        o += 1;
    }
    return o;
}

/// For each 12-bit value: the symbols of the codes that it starts, at
/// most 2, and their bits. Bits 0 to 7 and 8 to 15 are the symbols, 16
/// and 17 the count, and 20 up the bits.
const multi: [4096]u32 = blk: {
    @setEvalBranchQuota(10_000_000);
    var t: [4096]u32 = undefined;
    for (0..4096) |v| {
        var bits: u32 = 0;
        var cnt: u32 = 0;
        var syms: [2]u32 = .{ 0, 0 };
        outer: while (cnt < 2) {
            for (1..13 - bits) |l| {
                const c: u32 = (v >> (12 - bits - l)) & ((1 << l) - 1);
                const off = c -% dec.first[l];
                if (dec.count[l] != 0 and off < dec.count[l]) {
                    const sym = dec.syms[dec.base[l] + off];
                    if (sym == 256) break :outer;
                    syms[cnt] = sym;
                    cnt += 1;
                    bits += l;
                    continue :outer;
                }
            }
            break;
        }
        t[v] = syms[0] | (syms[1] << 8) | (cnt << 16) | (bits << 20);
    }
    break :blk t;
};

/// Decodes the Huffman string `src` into `out`. Gives the decoded
/// bytes.
///
/// A 64-bit window holds the next bits, from the high end. With at
/// least 30 bits in the window (the longest code), a lookup of 12 bits
/// in `multi` gives up to 2 symbols. A code of more than 12 bits, the
/// end of the string, and a full `out` go to `one`.
pub fn huffmanDecode(out: []u8, src: []const u8) Error![]u8 {
    var acc: u64 = 0;
    var n: u7 = 0;
    var i: usize = 0;
    var o: usize = 0;
    while (true) {
        if (i + 8 <= src.len) {
            // Whole bytes of a load of 8, as many as fit.
            const w = std.mem.readInt(u64, src[i..][0..8], .big);
            const take: u7 = (63 - n) >> 3;
            acc |= (w >> @intCast(n)) & ~(@as(u64, std.math.maxInt(u64)) >> @intCast(n + take * 8));
            i += take;
            n += take * 8;
        } else {
            while (n <= 56 and i < src.len) {
                acc |= @as(u64, src[i]) << @intCast(56 - n);
                n += 8;
                i += 1;
            }
        }
        if (n == 0) break;
        const at_end = i == src.len;
        while (n >= 30 or (at_end and n > 0)) {
            const e = multi[@intCast(acc >> 52)];
            const bits: u7 = @intCast(e >> 20);
            const cnt = (e >> 16) & 3;
            if (cnt != 0 and bits <= n and o + cnt <= out.len) {
                out[o] = @truncate(e);
                if (cnt == 2) out[o + 1] = @truncate(e >> 8);
                o += cnt;
                acc <<= @intCast(bits);
                n -= bits;
                continue;
            }
            const len = try one(acc, n) orelse return out[0..o];
            if (o == out.len) return error.NoScratch;
            out[o] = len.sym;
            o += 1;
            acc <<= @intCast(len.len);
            n -= len.len;
        }
        if (at_end and n == 0) break;
    }
    return out[0..o];
}

/// One symbol from the window, or null for the padding at the end.
fn one(acc: u64, n: u7) Error!?struct { sym: u8, len: u7 } {
    var len: u7 = 5;
    while (len <= 30 and len <= n) : (len += 1) {
        const c: u32 = @intCast(acc >> @intCast(64 - @as(u8, len)));
        const off = c -% dec.first[len];
        if (off < dec.count[len]) {
            const sym = dec.syms[dec.base[len] + off];
            if (sym == 256) return error.BadHuffman;
            return .{ .sym = @intCast(sym), .len = len };
        }
    }
    // The rest is padding: fewer than 8 bits, all ones.
    if (n >= 8) return error.BadHuffman;
    const pad = acc >> @intCast(64 - @as(u8, n));
    if (pad != (@as(u64, 1) << @intCast(n)) - 1) return error.BadHuffman;
    return null;
}

// The tables (section 2.3).

/// The size of an entry: the name, the value, and 32 bytes.
pub fn entrySize(name_len: usize, value_len: usize) usize {
    return name_len + value_len + 32;
}

const static_count = tables.static.len;

/// The dynamic table: a FIFO of the bytes of the entries, the oldest
/// first, and a ring of the places of the entries. An add that does not
/// fit at the end moves the bytes to the start of the buffer first, so
/// each name and value is one slice.
pub const Table = struct {
    const Entry = struct { off: u32, name_len: u32, value_len: u32 };

    bytes: []u8,
    ring: []Entry,
    /// The place of the newest entry in `ring`, and the count.
    head: usize = 0,
    count: usize = 0,
    start: usize = 0,
    end: usize = 0,
    /// The size of the entries, and the limit now.
    size: usize = 0,
    max: usize,
    /// The limit of the settings: the largest `max`.
    cap: usize,

    pub fn init(gpa: std.mem.Allocator, cap: usize) !Table {
        const bytes = try gpa.alloc(u8, cap);
        errdefer gpa.free(bytes);
        const ring = try gpa.alloc(Entry, cap / 32 + 1);
        return .{ .bytes = bytes, .ring = ring, .max = cap, .cap = cap };
    }

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        gpa.free(t.bytes);
        gpa.free(t.ring);
    }

    fn entry(t: *const Table, i: usize) Field {
        const e = t.ring[(t.head + t.ring.len - i) % t.ring.len];
        const b = t.bytes[e.off..];
        return .{ .name = b[0..e.name_len], .value = b[e.name_len..][0..e.value_len] };
    }

    /// The entry at `index` of the address space: 1 to 61 is the static
    /// table, and 62 up is the dynamic table, newest first.
    pub fn get(t: *const Table, index: usize) Error!Field {
        if (index == 0) return error.BadIndex;
        if (index <= static_count) return tables.static[index - 1];
        const i = index - static_count - 1;
        if (i >= t.count) return error.BadIndex;
        return t.entry(i);
    }

    fn evictOldest(t: *Table) void {
        const e = t.ring[(t.head + t.ring.len - (t.count - 1)) % t.ring.len];
        t.size -= entrySize(e.name_len, e.value_len);
        t.start = e.off + e.name_len + e.value_len;
        t.count -= 1;
        if (t.count == 0) {
            t.start = 0;
            t.end = 0;
        }
    }

    /// Sets the limit, with evictions.
    pub fn setMax(t: *Table, max: usize) void {
        std.debug.assert(max <= t.cap);
        t.max = max;
        while (t.size > t.max) t.evictOldest();
    }

    /// Adds an entry, with evictions first. An entry larger than the
    /// limit empties the table (section 4.4) and gives false. `name` and
    /// `value` must not point into the table.
    pub fn add(t: *Table, name: []const u8, value: []const u8) bool {
        const sz = entrySize(name.len, value.len);
        while (t.count > 0 and t.size + sz > t.max) t.evictOldest();
        if (sz > t.max) return false;
        const len = name.len + value.len;
        if (t.end + len > t.bytes.len) {
            // Move the live bytes to the start.
            const live = t.end - t.start;
            std.mem.copyForwards(u8, t.bytes[0..live], t.bytes[t.start..t.end]);
            for (0..t.count) |i| {
                const e = &t.ring[(t.head + t.ring.len - i) % t.ring.len];
                e.off -= @intCast(t.start);
            }
            t.start = 0;
            t.end = live;
        }
        @memcpy(t.bytes[t.end..][0..name.len], name);
        @memcpy(t.bytes[t.end + name.len ..][0..value.len], value);
        t.head = (t.head + 1) % t.ring.len;
        t.ring[t.head] = .{ .off = @intCast(t.end), .name_len = @intCast(name.len), .value_len = @intCast(value.len) };
        t.end += len;
        t.count += 1;
        t.size += sz;
        return true;
    }

    /// True when `p` points into the bytes of the table.
    fn owns(t: *const Table, p: []const u8) bool {
        const a = @intFromPtr(p.ptr);
        const b = @intFromPtr(t.bytes.ptr);
        return a >= b and a < b + t.bytes.len;
    }
};

// The decoder (sections 3 and 6).

pub const Decoder = struct {
    table: Table,
    /// The limit of the header list: the sum of the entry sizes of the
    /// fields of a block (SETTINGS_MAX_HEADER_LIST_SIZE).
    max_list: usize,

    pub fn init(gpa: std.mem.Allocator, table_cap: usize, max_list: usize) !Decoder {
        return .{ .table = try .init(gpa, table_cap), .max_list = max_list };
    }

    pub fn deinit(d: *Decoder, gpa: std.mem.Allocator) void {
        d.table.deinit(gpa);
    }

    /// Starts the read of a header block. `scratch` holds the Huffman
    /// strings of one field at a time.
    pub fn block(d: *Decoder, data: []const u8, scratch: []u8) Block {
        return .{ .d = d, .data = data, .scratch = scratch };
    }
};

/// A decoded field. `never_index` is true for a literal never indexed
/// (section 6.2.3): a proxy keeps that form.
pub const Decoded = struct {
    name: []const u8,
    value: []const u8,
    never_index: bool = false,
};

pub const Block = struct {
    d: *Decoder,
    data: []const u8,
    scratch: []u8,
    pos: usize = 0,
    fields: usize = 0,
    list: usize = 0,

    /// A string at `pos`: a slice of the block, or of `out` for a
    /// Huffman string.
    fn string(b: *Block, out: []u8) Error![]const u8 {
        if (b.pos >= b.data.len) return error.Truncated;
        const huff = b.data[b.pos] & 0x80 != 0;
        const len = try readInt(b.data, &b.pos, 7);
        if (len > b.data.len - b.pos) return error.Truncated;
        const raw = b.data[b.pos..][0..len];
        b.pos += len;
        if (!huff) return raw;
        return huffmanDecode(out, raw);
    }

    fn account(b: *Block, name_len: usize, value_len: usize) Error!void {
        b.list += entrySize(name_len, value_len);
        if (b.list > b.d.max_list) return error.HeaderListTooLarge;
    }

    /// The next field of the block, or null at its end.
    pub fn next(b: *Block) Error!?Decoded {
        const t = &b.d.table;
        while (b.pos < b.data.len) {
            const first = b.data[b.pos];
            if (first & 0x80 != 0) {
                // Indexed field (6.1).
                const f = try t.get(try readInt(b.data, &b.pos, 7));
                try b.account(f.name.len, f.value.len);
                b.fields += 1;
                return .{ .name = f.name, .value = f.value };
            }
            if (first & 0xe0 == 0x20) {
                // Dynamic table size update (6.3): only before the first
                // field.
                const max = try readInt(b.data, &b.pos, 5);
                if (b.fields != 0 or max > t.cap) return error.BadTableSizeUpdate;
                t.setMax(max);
                continue;
            }
            // Literal: with incremental indexing (6.2.1, 01xxxxxx),
            // without indexing (0000xxxx), or never indexed (0001xxxx).
            const indexing = first & 0x40 != 0;
            const never = !indexing and first & 0x10 != 0;
            const index = if (indexing) try readInt(b.data, &b.pos, 6) else try readInt(b.data, &b.pos, 4);
            var name: []const u8 = undefined;
            var used: usize = 0;
            if (index == 0) {
                name = try b.string(b.scratch);
                if (b.owns(name)) used = name.len;
            } else {
                name = (try t.get(index)).name;
                if (indexing and t.owns(name)) {
                    // The add below can move or evict the bytes of the
                    // name: copy it to the scratch buffer first.
                    if (name.len > b.scratch.len) return error.NoScratch;
                    @memcpy(b.scratch[0..name.len], name);
                    name = b.scratch[0..name.len];
                    used = name.len;
                }
            }
            const value = try b.string(b.scratch[used..]);
            try b.account(name.len, value.len);
            b.fields += 1;
            if (indexing and t.add(name, value)) {
                const e = t.entry(0);
                return .{ .name = e.name, .value = e.value };
            }
            return .{ .name = name, .value = value, .never_index = never };
        }
        return null;
    }

    fn owns(b: *const Block, p: []const u8) bool {
        const a = @intFromPtr(p.ptr);
        const s = @intFromPtr(b.scratch.ptr);
        return a >= s and a < s + b.scratch.len;
    }
};

// The encoder (section 6).

pub const Huffman = enum { never, always, shorter };

/// The index of each name of the static table, and of each full field.
const static_names = blk: {
    @setEvalBranchQuota(100_000);
    var kvs: [static_count]struct { []const u8, u8 } = undefined;
    var n: usize = 0;
    for (tables.static, 1..) |f, i| {
        const seen = for (kvs[0..n]) |kv| {
            if (std.mem.eql(u8, kv[0], f.name)) break true;
        } else false;
        if (seen) continue;
        kvs[n] = .{ f.name, i };
        n += 1;
    }
    break :blk std.StaticStringMap(u8).initComptime(kvs[0..n]);
};

pub const Encoder = struct {
    table: Table,
    huffman: Huffman = .shorter,
    /// A size update to send at the start of the next block.
    update: ?usize = null,

    pub fn init(gpa: std.mem.Allocator, table_cap: usize) !Encoder {
        return .{ .table = try .init(gpa, table_cap) };
    }

    pub fn deinit(e: *Encoder, gpa: std.mem.Allocator) void {
        e.table.deinit(gpa);
    }

    /// Sets the limit of the table (at most the settings of the peer),
    /// and sends the update at the start of the next block.
    pub fn setMax(e: *Encoder, max: usize) void {
        e.table.setMax(max);
        e.update = max;
    }

    /// The index of the full field, or of the name only, or 0.
    fn find(e: *const Encoder, f: Field) struct { full: usize, name: usize } {
        var name: usize = 0;
        if (static_names.get(f.name)) |first| {
            name = first;
            var i: usize = first;
            while (i <= static_count and std.mem.eql(u8, tables.static[i - 1].name, f.name)) : (i += 1) {
                if (std.mem.eql(u8, tables.static[i - 1].value, f.value)) return .{ .full = i, .name = i };
            }
        }
        const t = &e.table;
        for (0..t.count) |i| {
            const d = t.entry(i);
            if (!std.mem.eql(u8, d.name, f.name)) continue;
            if (std.mem.eql(u8, d.value, f.value)) return .{ .full = static_count + 1 + i, .name = static_count + 1 + i };
            if (name == 0) name = static_count + 1 + i;
        }
        return .{ .full = 0, .name = name };
    }

    fn string(e: *const Encoder, out: []u8, s: []const u8) error{NoSpace}!usize {
        const hl = huffmanLen(s);
        const huff = switch (e.huffman) {
            .never => false,
            .always => true,
            .shorter => hl < s.len,
        };
        const len = if (huff) hl else s.len;
        if (out.len < intLen(@intCast(len), 7) + len) return error.NoSpace;
        const n = writeInt(out, @intCast(len), 7, if (huff) 0x80 else 0);
        if (huff) {
            _ = huffmanEncode(out[n..], s);
        } else {
            @memcpy(out[n..][0..len], s);
        }
        return n + len;
    }

    /// Writes the header block of `fields` into `out` and gives its
    /// length. Each field that is not in a table goes in as a literal
    /// with incremental indexing, as in the examples of appendix C.
    pub fn encode(e: *Encoder, out: []u8, fields: []const Field) error{NoSpace}!usize {
        var o: usize = 0;
        if (e.update) |max| {
            if (out.len < intLen(@intCast(max), 5)) return error.NoSpace;
            o += writeInt(out, @intCast(max), 5, 0x20);
            e.update = null;
        }
        for (fields) |f| {
            const m = e.find(f);
            if (m.full != 0) {
                if (out.len - o < intLen(@intCast(m.full), 7)) return error.NoSpace;
                o += writeInt(out[o..], @intCast(m.full), 7, 0x80);
                continue;
            }
            if (out.len - o < intLen(@intCast(m.name), 6)) return error.NoSpace;
            o += writeInt(out[o..], @intCast(m.name), 6, 0x40);
            if (m.name == 0) o += try e.string(out[o..], f.name);
            o += try e.string(out[o..], f.value);
            _ = e.table.add(f.name, f.value);
        }
        return o;
    }
};

test {
    _ = @import("hpack_test.zig");
}
