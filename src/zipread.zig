//! A reader of zip archives in memory, for the mounts of `vfs.zig`.
//!
//! `Archive.parse` finds the end of central directory record in the
//! last 65,557 bytes, follows the zip64 locator when a field is full,
//! and reads each central header. The offsets of an archive can be
//! relative to an earlier start, as in a zip after a program binary.
//! The start is the position of the central directory minus its
//! recorded offset. Each entry gets its data range from its local
//! header. The parse checks each range against the archive, sorts the
//! ranges, and refuses two that overlap, so one byte belongs to at most
//! one entry. Names are checked: no leading `/`, no `\`, no NUL, no
//! `.` or `..` part, and no name twice.
//!
//! Entries are stored (method 0) or deflate (method 8). A stored entry
//! is a slice of the archive. `extract` decompresses a deflate entry
//! with `inflate.zig` into a buffer of the size in the central header,
//! gives an error for more or less output, and checks the CRC-32.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ NotZip, BadArchive, Encrypted, BadMethod, BadName, Duplicate, BadData } || Allocator.Error;

pub const Method = enum(u16) { stored = 0, deflate = 8, _ };

pub const Entry = struct {
    /// The name with no trailing `/`.
    name: []const u8,
    dir: bool,
    method: Method,
    size: u64,
    csize: u64,
    crc: u32,
    /// Seconds since 1970 (UTC).
    mtime: i64,
    /// The offset of the data in the archive.
    data: u64,
    /// The offset of the local header in the archive.
    header: u64,
};

pub const Archive = struct {
    bytes: []const u8,
    /// Sorted by name.
    entries: []Entry,

    pub fn deinit(z: *Archive, a: Allocator) void {
        a.free(z.entries);
        z.* = undefined;
    }

    /// The entry of `name`, or null.
    pub fn find(z: *const Archive, name: []const u8) ?*const Entry {
        var lo: usize = 0;
        var hi: usize = z.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, z.entries[mid].name, name)) {
                .eq => return &z.entries[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// The index of the first entry with a name at or after `name`.
    pub fn lowerBound(z: *const Archive, name: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = z.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.lessThan(u8, z.entries[mid].name, name)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// True when `name` is a folder: a folder entry, or a prefix
    /// `name/` of an entry. The empty name is the root.
    pub fn isDir(z: *const Archive, name: []const u8) bool {
        if (name.len == 0) return true;
        if (z.find(name)) |e| return e.dir;
        var buf: [1024]u8 = undefined;
        if (name.len + 1 > buf.len) return false;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = '/';
        const p = buf[0 .. name.len + 1];
        const i = z.lowerBound(p);
        return i < z.entries.len and std.mem.startsWith(u8, z.entries[i].name, p);
    }

    /// The data of a file entry. A stored entry is a slice of the
    /// archive. A deflate entry goes in a new buffer from `a`.
    pub fn extract(z: *const Archive, a: Allocator, e: *const Entry) Error![]const u8 {
        const raw = z.bytes[@intCast(e.data)..@intCast(e.data + e.csize)];
        switch (e.method) {
            .stored => {
                if (e.size != e.csize) return error.BadData;
                if (std.hash.Crc32.hash(raw) != e.crc) return error.BadData;
                return raw;
            },
            .deflate => {
                const n = std.math.cast(usize, e.size) orelse return error.OutOfMemory;
                const out = try a.alloc(u8, n);
                errdefer a.free(out);
                const got = @import("inflate.zig").inflate(out, raw) catch return error.BadData;
                if (got != n) return error.BadData;
                if (std.hash.Crc32.hash(out) != e.crc) return error.BadData;
                return out;
            },
            _ => return error.BadMethod,
        }
    }

    pub fn parse(a: Allocator, bytes: []const u8) Error!Archive {
        if (bytes.len < 22) return error.NotZip;
        const eocd = findEnd(bytes) orelse return error.NotZip;
        var count: u64 = rd16(bytes, eocd + 10);
        var cd_size: u64 = rd32(bytes, eocd + 12);
        var cd_off: u64 = rd32(bytes, eocd + 16);
        if (rd16(bytes, eocd + 4) != 0 or rd16(bytes, eocd + 6) != 0) return error.BadArchive;
        // The record of the central directory ends here.
        var cd_end: u64 = eocd;
        if (count == 0xffff or cd_size == 0xffffffff or cd_off == 0xffffffff) {
            if (eocd < 20 or rd32(bytes, eocd - 20) != 0x07064b50) return error.BadArchive;
            // A zip64 record is 56 bytes before its locator, with no
            // extensible data.
            if (eocd < 20 + 56) return error.BadArchive;
            const rec: u64 = eocd - 20 - 56;
            if (rd32(bytes, @intCast(rec)) != 0x06064b50) return error.BadArchive;
            count = rd64(bytes, @intCast(rec + 32));
            cd_size = rd64(bytes, @intCast(rec + 40));
            cd_off = rd64(bytes, @intCast(rec + 48));
            cd_end = rec;
        }
        if (cd_size > cd_end) return error.BadArchive;
        const cd_start = cd_end - cd_size;
        if (cd_off > cd_start) return error.BadArchive;
        const base = cd_start - cd_off;
        // Each central header is at least 46 bytes.
        if (count > cd_size / 46) return error.BadArchive;

        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(a);
        try list.ensureTotalCapacity(a, @intCast(count));
        var p: u64 = cd_start;
        var k: u64 = 0;
        while (k < count) : (k += 1) {
            if (p + 46 > cd_end) return error.BadArchive;
            const h: usize = @intCast(p);
            if (rd32(bytes, h) != 0x02014b50) return error.BadArchive;
            const flags = rd16(bytes, h + 8);
            const method: Method = @enumFromInt(rd16(bytes, h + 10));
            const time = rd16(bytes, h + 12);
            const date = rd16(bytes, h + 14);
            const crc = rd32(bytes, h + 16);
            var csize: u64 = rd32(bytes, h + 20);
            var size: u64 = rd32(bytes, h + 24);
            const nlen = rd16(bytes, h + 28);
            const xlen = rd16(bytes, h + 30);
            const clen = rd16(bytes, h + 32);
            var lho: u64 = rd32(bytes, h + 42);
            const next = p + 46 + nlen + xlen + clen;
            if (next > cd_end) return error.BadArchive;
            var name = bytes[h + 46 .. h + 46 + nlen];
            const extra = bytes[h + 46 + nlen .. h + 46 + nlen + xlen];
            if (flags & 1 != 0) return error.Encrypted;
            if (method != .stored and method != .deflate) return error.BadMethod;
            var mtime = dosTime(date, time);
            // The extra fields: zip64 sizes (0x0001) and the Unix time (0x5455).
            var x: usize = 0;
            while (x + 4 <= extra.len) {
                const id = rd16(extra, x);
                const len = rd16(extra, x + 2);
                if (x + 4 + len > extra.len) return error.BadArchive;
                const f = extra[x + 4 .. x + 4 + len];
                if (id == 0x0001) {
                    var q: usize = 0;
                    if (size == 0xffffffff) {
                        if (q + 8 > f.len) return error.BadArchive;
                        size = rd64(f, q);
                        q += 8;
                    }
                    if (csize == 0xffffffff) {
                        if (q + 8 > f.len) return error.BadArchive;
                        csize = rd64(f, q);
                        q += 8;
                    }
                    if (lho == 0xffffffff) {
                        if (q + 8 > f.len) return error.BadArchive;
                        lho = rd64(f, q);
                    }
                } else if (id == 0x5455 and len >= 5 and f[0] & 1 != 0) {
                    mtime = @as(i32, @bitCast(rd32(f, 1)));
                }
                x += 4 + len;
            }
            const dir = name.len > 0 and name[name.len - 1] == '/';
            if (dir) name = name[0 .. name.len - 1];
            if (!goodName(name)) return error.BadName;
            // The data range from the local header.
            const lh = base + lho;
            if (lh > bytes.len or bytes.len - lh < 30) return error.BadArchive;
            const l: usize = @intCast(lh);
            if (rd32(bytes, l) != 0x04034b50) return error.BadArchive;
            const data = lh + 30 + rd16(bytes, l + 26) + rd16(bytes, l + 28);
            if (data > bytes.len or bytes.len - data < csize) return error.BadArchive;
            if (method == .stored and csize != size) return error.BadData;
            list.appendAssumeCapacity(.{ .name = name, .dir = dir, .method = method, .size = size, .csize = csize, .crc = crc, .mtime = mtime, .data = data, .header = lh });
            p = next;
        }
        const entries = try list.toOwnedSlice(a);
        errdefer a.free(entries);
        // No two data ranges overlap.
        std.mem.sort(Entry, entries, {}, byHeader);
        var i: usize = 1;
        while (i < entries.len) : (i += 1) {
            const prev = entries[i - 1];
            if (prev.data + prev.csize > entries[i].header) return error.BadArchive;
        }
        std.mem.sort(Entry, entries, {}, byName);
        i = 1;
        while (i < entries.len) : (i += 1) {
            if (std.mem.eql(u8, entries[i - 1].name, entries[i].name)) return error.Duplicate;
        }
        return .{ .bytes = bytes, .entries = entries };
    }
};

fn byHeader(_: void, x: Entry, y: Entry) bool {
    return x.header < y.header;
}

fn byName(_: void, x: Entry, y: Entry) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// True for a relative name with no empty, `.`, or `..` part.
pub fn goodName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfAny(u8, name, "\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |w| {
        if (w.len == 0 or std.mem.eql(u8, w, ".") or std.mem.eql(u8, w, "..")) return false;
    }
    return true;
}

fn findEnd(bytes: []const u8) ?usize {
    const lowest = bytes.len -| (22 + 0xffff);
    var i = bytes.len - 22;
    while (true) : (i -= 1) {
        if (rd32(bytes, i) == 0x06054b50 and i + 22 + rd16(bytes, i + 20) == bytes.len) return i;
        if (i == lowest) return null;
    }
}

/// A DOS date and time as seconds since 1970, read as UTC.
fn dosTime(date: u16, time: u16) i64 {
    const year: i64 = 1980 + @as(i64, date >> 9);
    const month: i64 = @max(1, @min(12, (date >> 5) & 15));
    const day: i64 = @max(1, date & 31);
    // Days from 1970-01-01 to the date, by the days_from_civil algorithm
    // of Howard Hinnant (docs/references/static-build.md).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, time >> 11) * 3600 + @as(i64, (time >> 5) & 63) * 60 + @as(i64, time & 31) * 2;
}

fn rd16(b: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, b[i..][0..2], .little);
}

fn rd32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

fn rd64(b: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, b[i..][0..8], .little);
}

const fixtures = [_][]const u8{
    @embedFile("testdata/zip/python-stored.zip"),
    @embedFile("testdata/zip/python-deflate.zip"),
    @embedFile("testdata/zip/python-zip64.zip"),
    @embedFile("testdata/zip/infozip.zip"),
    @embedFile("testdata/zip/7zip.zip"),
};

test "zipread: the archives of Python, Info-ZIP, and 7-Zip" {
    const a = std.testing.allocator;
    for (fixtures) |bytes| {
        var z = try Archive.parse(a, bytes);
        defer z.deinit(a);
        const u = z.find("lib/util.tcl").?;
        try std.testing.expect(!u.dir);
        const text = try z.extract(a, u);
        defer if (u.method == .deflate) a.free(text);
        try std.testing.expectEqualStrings("proc hello {} {return \"hello from zip\"}\n", text);
        const b = z.find("data/big.txt").?;
        const big = try z.extract(a, b);
        defer if (b.method == .deflate) a.free(big);
        try std.testing.expectEqual(@as(usize, 10390), big.len);
        try std.testing.expect(std.mem.startsWith(u8, big, "line 0 of the text\nline 1"));
        try std.testing.expect(z.isDir("lib"));
        try std.testing.expect(z.isDir("data"));
        try std.testing.expect(!z.isDir("lib/util.tcl"));
        try std.testing.expect(z.find("nope") == null);
        try std.testing.expectEqual(@as(u64, 0), z.find("empty.txt").?.size);
        // 2024-05-06 07:08:10 UTC, or the same time in the local zone
        // of the tool, within a day.
        try std.testing.expect(@abs(u.mtime - 1714979290) <= 86400);
    }
}

test "zipread: an archive after other bytes" {
    const a = std.testing.allocator;
    const zip = fixtures[1];
    const buf = try a.alloc(u8, zip.len + 1000);
    defer a.free(buf);
    @memset(buf[0..1000], 0x7f);
    @memcpy(buf[1000..], zip);
    var z = try Archive.parse(a, buf);
    defer z.deinit(a);
    const text = try z.extract(a, z.find("lib/util.tcl").?);
    a.free(text);
}

test "zipread: malformed archives are errors" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotZip, Archive.parse(a, "short"));
    try std.testing.expectError(error.NotZip, Archive.parse(a, &([_]u8{0} ** 100)));
    const zip = fixtures[1];
    // Each truncation of the archive is an error or a smaller archive.
    var n: usize = 0;
    while (n < zip.len) : (n += 1) {
        if (Archive.parse(a, zip[0..n])) |z0| {
            var z = z0;
            z.deinit(a);
        } else |_| {}
    }
    // A flip of each byte gives an error or an archive with data
    // that extract checks.
    const buf = try a.dupe(u8, zip);
    defer a.free(buf);
    for (0..buf.len) |i| {
        for ([_]u8{ 0x01, 0x80, 0xff }) |m| {
            buf[i] ^= m;
            defer buf[i] ^= m;
            var z = Archive.parse(a, buf) catch continue;
            defer z.deinit(a);
            for (z.entries) |*e| {
                if (e.dir) continue;
                if (e.size > 1 << 20) continue;
                const d = z.extract(a, e) catch continue;
                if (e.method == .deflate) a.free(d);
            }
        }
    }
}

test "zipread: bad names, encryption, and a size past the memory" {
    const a = std.testing.allocator;
    try std.testing.expect(!goodName("/etc/passwd"));
    try std.testing.expect(!goodName("a/../b"));
    try std.testing.expect(!goodName("a\\b"));
    try std.testing.expect(!goodName("a//b"));
    try std.testing.expect(goodName("a/b.tcl"));
    const zip = fixtures[1];
    const buf = try a.dupe(u8, zip);
    defer a.free(buf);
    const cd = blk: {
        var z = try Archive.parse(a, zip);
        defer z.deinit(a);
        break :blk std.mem.indexOf(u8, zip, "PK\x01\x02").?;
    };
    // Encryption.
    buf[cd + 8] |= 1;
    try std.testing.expectError(error.Encrypted, Archive.parse(a, buf));
    buf[cd + 8] &= 0xfe;
    // A size of 4 GiB for the first deflate entry: the allocation
    // fails at the limit of the allocator.
    var z = try Archive.parse(a, buf);
    defer z.deinit(a);
    var bomb = z.entries[0];
    for (z.entries) |e| if (e.method == .deflate and e.size > 100) {
        bomb = e;
    };
    bomb.size = 0xfffffff0;
    var lim = std.heap.FixedBufferAllocator.init(&.{});
    try std.testing.expectError(error.OutOfMemory, z.extract(lim.allocator(), &bomb));
}
