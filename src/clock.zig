//! The optional `clock` command and a small `msgcat` (capability `clock`).
//!
//! The time and the zone data come only from `Interp.clock_host`, a
//! callback of the embedder. The conversions are pure: a date is a
//! Julian day number plus seconds of the day, with the Julian calendar
//! before the change date of the locale. A zone is a fixed offset, a
//! POSIX TZ rule, or TZif data from the host.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

/// What the embedder gives to the `clock` capability.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    /// Microseconds since 1970-01-01 UTC.
    now: *const fn (ctx: ?*anyopaque) i64,
    /// The TZif bytes of a zone name, or null. The name has only
    /// letters, digits, and `_ + - /`, and no `..`.
    zone: ?*const fn (ctx: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 = null,
};

pub const State = struct {
    /// Locale name to (key to value).
    locales: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Value)) = .empty,
    current: []const u8 = "c",
    zones: std.StringHashMapUnmanaged(*Zone) = .empty,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- Calendar ----

const epoch_jd: i64 = 2440588;

const Date = struct {
    jd: i64,
    era_bce: bool = false,
    year: i64 = 0,
    month: i64 = 1,
    day: i64 = 1,
    yday: i64 = 1,
    /// 0 is Sunday.
    wday: i64 = 0,
    iso_year: i64 = 0,
    iso_week: i64 = 1,
};

fn gregorianToJd(y: i64, m: i64, d: i64) i64 {
    const a = @divFloor(14 - m, 12);
    const yy = y + 4800 - a;
    const mm = m + 12 * a - 3;
    return d + @divFloor(153 * mm + 2, 5) + 365 * yy + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400) - 32045;
}

fn julianToJd(y: i64, m: i64, d: i64) i64 {
    const a = @divFloor(14 - m, 12);
    const yy = y + 4800 - a;
    const mm = m + 12 * a - 3;
    return d + @divFloor(153 * mm + 2, 5) + 365 * yy + @divFloor(yy, 4) - 32083;
}

/// The Julian day of a date. The year is astronomical (1 BCE is 0).
fn toJd(y: i64, m: i64, d: i64, change: i64) i64 {
    // A month outside 1 to 12 carries into the year.
    const mz = m - 1;
    const yy = y + @divFloor(mz, 12);
    const mm = @mod(mz, 12) + 1;
    const g = gregorianToJd(yy, mm, 1) + d - 1;
    if (g >= change) return g;
    return julianToJd(yy, mm, 1) + d - 1;
}

fn isLeap(y: i64, gregorian: bool) bool {
    if (!gregorian) return @mod(y, 4) == 0;
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn fromJd(jd: i64, change: i64) Date {
    var y: i64 = undefined;
    var m: i64 = undefined;
    var d: i64 = undefined;
    if (jd >= change) {
        const a = jd + 32044;
        const b = @divFloor(4 * a + 3, 146097);
        const c = a - @divFloor(146097 * b, 4);
        const e = @divFloor(4 * c + 3, 1461);
        const f = c - @divFloor(1461 * e, 4);
        const g = @divFloor(5 * f + 2, 153);
        d = f - @divFloor(153 * g + 2, 5) + 1;
        m = g + 3 - 12 * @divFloor(g, 10);
        y = 100 * b + e - 4800 + @divFloor(g, 10);
    } else {
        const c = jd + 32082;
        const e = @divFloor(4 * c + 3, 1461);
        const f = c - @divFloor(1461 * e, 4);
        const g = @divFloor(5 * f + 2, 153);
        d = f - @divFloor(153 * g + 2, 5) + 1;
        m = g + 3 - 12 * @divFloor(g, 10);
        y = e - 4800 + @divFloor(g, 10);
    }
    var out: Date = .{ .jd = jd, .year = y, .month = m, .day = d };
    out.yday = jd - toJd(y, 1, 1, change) + 1;
    out.wday = @mod(jd + 1, 7);
    // The ISO week holds the Thursday of the week.
    const iso_dow = if (out.wday == 0) 7 else out.wday;
    const thursday = jd - iso_dow + 4;
    const t = fromJdPlain(thursday, change);
    out.iso_year = t;
    out.iso_week = @divFloor(thursday - toJd(t, 1, 1, change), 7) + 1;
    return out;
}

fn fromJdPlain(jd: i64, change: i64) i64 {
    if (jd >= change) {
        const a = jd + 32044;
        const b = @divFloor(4 * a + 3, 146097);
        const c = a - @divFloor(146097 * b, 4);
        const e = @divFloor(4 * c + 3, 1461);
        const f = c - @divFloor(1461 * e, 4);
        const g = @divFloor(5 * f + 2, 153);
        return 100 * b + e - 4800 + @divFloor(g, 10);
    }
    const c = jd + 32082;
    const e = @divFloor(4 * c + 3, 1461);
    const f = c - @divFloor(1461 * e, 4);
    const g = @divFloor(5 * f + 2, 153);
    return e - 4800 + @divFloor(g, 10);
}

// ---- Zones ----

const Rule = struct { month: i64, week: i64, dow: i64, time: i64 };

pub const Zone = struct {
    name: []const u8 = "UTC",
    offset: i64 = 0,
    /// A POSIX rule for times after the table.
    dst: ?Dst = null,
    /// The transitions of TZif data, sorted by time.
    times: []const i64 = &.{},
    kinds: []const u8 = &.{},
    types: []const Kind = &.{},
};

const Kind = struct { offset: i64, dst: bool, name: []const u8 };
const Dst = struct { name: []const u8, offset: i64, start: Rule, end: Rule };

const Here = struct { offset: i64, name: []const u8, dst: bool };

fn ruleTime(r: Rule, year: i64, offset: i64) i64 {
    // The day `dow` of week `week` of the month; week 5 is the last.
    const first = gregorianToJd(year, r.month, 1);
    const first_dow = @mod(first + 1, 7);
    var day = first + @mod(r.dow - first_dow, 7) + 7 * (r.week - 1);
    const next = if (r.month == 12) gregorianToJd(year + 1, 1, 1) else gregorianToJd(year, r.month + 1, 1);
    while (day >= next) day -= 7;
    return (day - epoch_jd) * 86400 + r.time - offset;
}

fn at(z: *const Zone, t: i64) Here {
    if (z.times.len > 0 and t < z.times[z.times.len - 1] or (z.times.len > 0 and z.dst == null)) {
        if (t < z.times[0]) {
            const k = z.types[0];
            return .{ .offset = k.offset, .name = k.name, .dst = k.dst };
        }
        var lo: usize = 0;
        var hi: usize = z.times.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (z.times[mid] <= t) lo = mid else hi = mid;
        }
        const k = z.types[z.kinds[lo]];
        return .{ .offset = k.offset, .name = k.name, .dst = k.dst };
    }
    if (z.dst) |d| {
        const year = fromJdPlain(@divFloor(t + z.offset, 86400) + epoch_jd, 0);
        const s = ruleTime(d.start, year, z.offset);
        const e = ruleTime(d.end, year, d.offset);
        const in = if (s < e) t >= s and t < e else t >= s or t < e;
        if (in) return .{ .offset = d.offset, .name = d.name, .dst = true };
    }
    return .{ .offset = z.offset, .name = z.name, .dst = false };
}

/// The UTC time of a local time. In a gap or overlap the earlier offset
/// that gives the same local time wins.
fn localToUtc(z: *const Zone, local: i64) i64 {
    const first = at(z, local - 86400).offset;
    const second = at(z, local + 86400).offset;
    const a = local - first;
    if (at(z, a).offset == first) return a;
    const b = local - second;
    if (at(z, b).offset == second) return b;
    return a;
}

fn parseOffset(s: []const u8, i: *usize) ?i64 {
    var sign: i64 = 1;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
        if (s[i.*] == '-') sign = -1;
        i.* += 1;
    }
    const start = i.*;
    var parts: [3]i64 = .{ 0, 0, 0 };
    var p: usize = 0;
    while (true) {
        var n: i64 = 0;
        const from = i.*;
        while (i.* < s.len and std.ascii.isDigit(s[i.*]) and i.* - from < 2) : (i.* += 1) n = n * 10 + (s[i.*] - '0');
        if (i.* == from) break;
        parts[p] = n;
        p += 1;
        if (p == 3) break;
        if (i.* < s.len and s[i.*] == ':') {
            i.* += 1;
        } else if (!(i.* < s.len and std.ascii.isDigit(s[i.*]))) break;
    }
    if (i.* == start) return null;
    return sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
}

fn parseRule(s: []const u8, i: *usize) ?Rule {
    if (i.* >= s.len or s[i.*] != 'M') return null;
    i.* += 1;
    var nums: [3]i64 = undefined;
    for (&nums, 0..) |*n, k| {
        var v: i64 = 0;
        const from = i.*;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
        if (i.* == from) return null;
        n.* = v;
        if (k < 2) {
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
        }
    }
    var time: i64 = 7200;
    if (i.* < s.len and s[i.*] == '/') {
        i.* += 1;
        time = parseOffset(s, i) orelse return null;
    }
    return .{ .month = nums[0], .week = nums[1], .dow = nums[2], .time = time };
}

fn parseName(s: []const u8, i: *usize) ?[]const u8 {
    const start = i.*;
    if (i.* < s.len and s[i.*] == '<') {
        const e = std.mem.indexOfScalarPos(u8, s, i.*, '>') orelse return null;
        i.* = e + 1;
        return s[start + 1 .. e];
    }
    while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    if (i.* - start < 3) return null;
    return s[start..i.*];
}

/// A POSIX TZ string such as `EST5EDT` or `EST05:00EDT04:00,M3.2.0,M11.1.0`.
fn parsePosix(a: std.mem.Allocator, s: []const u8) !?*Zone {
    var i: usize = 0;
    const name = parseName(s, &i) orelse return null;
    const std_west = parseOffset(s, &i) orelse return null;
    const z = try a.create(Zone);
    z.* = .{ .name = name, .offset = -std_west };
    if (i >= s.len) return z;
    const dname = parseName(s, &i) orelse return null;
    var doff = z.offset + 3600;
    if (i < s.len and s[i] != ',') doff = -(parseOffset(s, &i) orelse return null);
    var start: Rule = .{ .month = 3, .week = 2, .dow = 0, .time = 7200 };
    var end: Rule = .{ .month = 11, .week = 1, .dow = 0, .time = 7200 };
    if (i < s.len) {
        if (s[i] != ',') return null;
        i += 1;
        start = parseRule(s, &i) orelse return null;
        if (i >= s.len or s[i] != ',') return null;
        i += 1;
        end = parseRule(s, &i) orelse return null;
        if (i != s.len) return null;
    }
    z.dst = .{ .name = dname, .offset = doff, .start = start, .end = end };
    return z;
}

fn parseTzif(a: std.mem.Allocator, b: []const u8) !?*Zone {
    if (b.len < 44 or !eql(b[0..4], "TZif")) return null;
    const rd = struct {
        fn u(x: []const u8) usize {
            return std.mem.readInt(u32, x[0..4], .big);
        }
    }.u;
    var p: usize = 0;
    var wide = false;
    if (b[4] >= '2') {
        // Skip the 32-bit block.
        const skip = rd(b[32..]) * 5 + rd(b[36..]) * 6 + rd(b[40..]) + rd(b[28..]) * 8 + rd(b[24..]) + rd(b[20..]);
        p = 44 + skip;
        if (p + 44 > b.len or !eql(b[p .. p + 4], "TZif")) return null;
        wide = true;
    }
    const isut = rd(b[p + 20 ..]);
    const isstd = rd(b[p + 24 ..]);
    const leap = rd(b[p + 28 ..]);
    const count = rd(b[p + 32 ..]);
    const ntypes = rd(b[p + 36 ..]);
    const chars = rd(b[p + 40 ..]);
    const w: usize = if (wide) 8 else 4;
    var q = p + 44;
    const need = count * w + count + ntypes * 6 + chars + leap * (w + 4) + isstd + isut;
    if (q + need > b.len or ntypes == 0) return null;
    const times = try a.alloc(i64, count);
    for (times, 0..) |*t, k| {
        t.* = if (wide) std.mem.readInt(i64, b[q + k * 8 ..][0..8], .big) else std.mem.readInt(i32, b[q + k * 4 ..][0..4], .big);
    }
    q += count * w;
    const kinds = try a.dupe(u8, b[q .. q + count]);
    for (kinds) |k| if (k >= ntypes) return null;
    q += count;
    const text = b[q + ntypes * 6 .. q + ntypes * 6 + chars];
    const types = try a.alloc(Kind, ntypes);
    for (types, 0..) |*t, k| {
        const e = b[q + k * 6 ..];
        const nat = e[5];
        if (nat >= text.len) return null;
        const stop = std.mem.indexOfScalarPos(u8, text, nat, 0) orelse text.len;
        t.* = .{ .offset = std.mem.readInt(i32, e[0..4], .big), .dst = e[4] != 0, .name = try a.dupe(u8, text[nat..stop]) };
    }
    q += ntypes * 6 + chars + leap * (w + 4) + isstd + isut;
    const z = try a.create(Zone);
    z.* = .{ .times = times, .kinds = kinds, .types = types, .name = types[0].name, .offset = types[0].offset };
    // The footer has the POSIX rule for later times.
    if (wide and q < b.len and b[q] == '\n') {
        const end = std.mem.indexOfScalarPos(u8, b, q + 1, '\n') orelse b.len;
        if (try parsePosix(a, try a.dupe(u8, b[q + 1 .. end]))) |f| {
            z.name = f.name;
            z.offset = f.offset;
            z.dst = f.dst;
        }
    }
    return z;
}

const utc_zone: Zone = .{ .name = "UTC" };

fn safeZoneName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/' or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '-' or c == '/')) return false;
    }
    return true;
}

fn zoneOf(it: *Interp, spec: []const u8) Error!*const Zone {
    const a = it.alloc();
    if (spec.len == 0 or eql(spec, ":localtime") or eql(spec, ":UTC") or eql(spec, "UTC") or eql(spec, ":GMT") or eql(spec, "GMT") or eql(spec, ":Etc/UTC")) {
        if (eql(spec, ":GMT") or eql(spec, "GMT")) {
            const g = try a.create(Zone);
            g.* = .{ .name = "GMT" };
            return g;
        }
        return &utc_zone;
    }
    if (it.clock.zones.get(spec)) |z| return z;
    var made: ?*Zone = null;
    if (spec[0] == '+' or spec[0] == '-') {
        var i: usize = 0;
        if (parseOffset(spec, &i)) |off| {
            if (i == spec.len) {
                const z = try a.create(Zone);
                z.* = .{ .offset = off, .name = try a.dupe(u8, spec) };
                made = z;
            }
        }
    } else if (spec[0] == ':') {
        const name = spec[1..];
        if (safeZoneName(name)) {
            if (it.clock_host) |h| if (h.zone) |f| {
                if (f(h.ctx, name, a)) |bytes| made = try parseTzif(a, bytes);
            };
        }
    } else {
        made = try parsePosix(a, try a.dupe(u8, spec));
    }
    const z = made orelse return it.failCode(try std.fmt.allocPrint(a, "CLOCK badTimeZone {s}", .{spec}), "time zone \"{s}\" not found", .{spec});
    try it.clock.zones.put(a, try a.dupe(u8, spec), z);
    return z;
}

// ---- msgcat and locales ----

/// The commands of msgcat in Tcl: mcload, mcpreferences, mcmax, and the
/// export list for `namespace import`.
const msgcat_script = @embedFile("msgcat.tcl");

const root_keys = [_]struct { []const u8, []const u8 }{
    .{ "DAYS_OF_WEEK_ABBREV", "Sun Mon Tue Wed Thu Fri Sat" },
    .{ "DAYS_OF_WEEK_FULL", "Sunday Monday Tuesday Wednesday Thursday Friday Saturday" },
    .{ "MONTHS_ABBREV", "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec" },
    .{ "MONTHS_FULL", "January February March April May June July August September October November December" },
    .{ "AM", "am" },
    .{ "PM", "pm" },
    .{ "BCE", "B.C.E." },
    .{ "CE", "C.E." },
    .{ "DATE_FORMAT", "%m/%d/%Y" },
    .{ "TIME_FORMAT", "%H:%M:%S" },
    .{ "TIME_FORMAT_12", "%I:%M:%S %P" },
    .{ "DATE_TIME_FORMAT", "%a %b %e %H:%M:%S %Y" },
    .{ "LOCALE_YEAR_FORMAT", "%EC%Ey" },
    .{ "GREGORIAN_CHANGE_DATE", "2299161" },
};

fn lookupIn(it: *Interp, locale: []const u8, key: []const u8) ?Value {
    var name = locale;
    while (true) {
        if (it.clock.locales.get(name)) |m| {
            if (m.get(key)) |v| return v;
        }
        if (name.len == 0) break;
        name = if (std.mem.lastIndexOfScalar(u8, name, '_')) |k| name[0..k] else "";
    }
    return null;
}

fn msg(it: *Interp, locale: []const u8, key: []const u8) Value {
    if (lookupIn(it, locale, key)) |v| return v;
    // English differs from the root in these keys.
    if (std.mem.startsWith(u8, locale, "en")) {
        if (eql(key, "AM")) return .{ .str = "AM" };
        if (eql(key, "PM")) return .{ .str = "PM" };
        if (eql(key, "BCE")) return .{ .str = "BC" };
        if (eql(key, "CE")) return .{ .str = "AD" };
        if (eql(key, "GREGORIAN_CHANGE_DATE")) return .{ .str = "2361222" };
    }
    if (eql(key, "AM") or eql(key, "PM")) return .{ .str = if (eql(key, "AM")) "AM" else "PM" };
    for (root_keys) |k| if (eql(k[0], key)) return .{ .str = k[1] };
    if (eql(key, "LOCALE_DATE_FORMAT")) return msg(it, locale, "DATE_FORMAT");
    if (eql(key, "LOCALE_TIME_FORMAT")) return msg(it, locale, "TIME_FORMAT");
    if (eql(key, "LOCALE_DATE_TIME_FORMAT")) return msg(it, locale, "DATE_TIME_FORMAT");
    return Value.empty;
}

fn changeDate(it: *Interp, locale: []const u8) i64 {
    return msg(it, locale, "GREGORIAN_CHANGE_DATE").asInt() orelse 2299161;
}

fn setMsg(it: *Interp, locale: []const u8, key: Value, v: Value) Error!void {
    const a = it.alloc();
    const lo = try std.ascii.allocLowerString(a, locale);
    const gop = try it.clock.locales.getOrPut(a, lo);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.put(a, try a.dupe(u8, try it.str(key)), v);
}

fn cmdMcset(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3 and argv.len != 4) return it.wrongArgs("::msgcat::mcset locale src ?translation?");
    const v = if (argv.len == 4) argv[3] else argv[2];
    try setMsg(it, try it.str(argv[1]), argv[2], v);
    return v;
}

fn cmdMcmset(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len != 3) return it.wrongArgs("::msgcat::mcmset locale pairs");
    const l = try it.list(argv[2]);
    if (l.len % 2 != 0) return it.fail("bad translation list: should be \"locale {{src dest ...}}\"", .{});
    var k: usize = 0;
    while (k < l.len) : (k += 2) try setMsg(it, try it.str(argv[1]), l[k], l[k + 1]);
    return .{ .int = @intCast(l.len / 2) };
}

/// `::msgcat::mc src ?arg ...?`: the translation of src in the locale
/// and its parents. With no translation, `::msgcat::mcunknown` gives
/// the text when it exists. With args, the text goes through `format`.
fn cmdMc(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("::msgcat::mc src ?arg ...?");
    const a = it.alloc();
    const text = lookupIn(it, it.clock.current, try it.str(argv[1])) orelse {
        if (it.findCommand("::msgcat::mcunknown") != null) {
            var words = try a.alloc(Value, argv.len + 1);
            words[0] = .{ .str = "::msgcat::mcunknown" };
            words[1] = .{ .str = it.clock.current };
            @memcpy(words[2..], argv[1..]);
            return it.eval(try it.str(try value.newList(a, words)));
        }
        if (argv.len == 2) return argv[1];
        return formatWith(it, argv[1], argv[2..]);
    };
    if (argv.len == 2) return text;
    return formatWith(it, text, argv[2..]);
}

fn formatWith(it: *Interp, fmt: Value, args: []const Value) Error!Value {
    const a = it.alloc();
    var words = try a.alloc(Value, args.len + 2);
    words[0] = .{ .str = "::format" };
    words[1] = fmt;
    @memcpy(words[2..], args);
    return it.eval(try it.str(try value.newList(a, words)));
}

/// `::msgcat::mcexists src`: 1 when the locale or a parent has src.
fn cmdMcexists(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("::msgcat::mcexists ?-exactnamespace? ?-exactlocale? src");
    const src = try it.str(argv[argv.len - 1]);
    return .{ .int = @intFromBool(lookupIn(it, it.clock.current, src) != null) };
}

fn cmdMclocale(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("::msgcat::mclocale ?newLocale?");
    if (argv.len == 2) it.clock.current = try std.ascii.allocLowerString(it.alloc(), try it.str(argv[1]));
    return .{ .str = it.clock.current };
}

// ---- format ----

fn pad(a: std.mem.Allocator, out: *std.ArrayList(u8), n: i64, width: usize, fill: u8) !void {
    var buf: [32]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}) catch unreachable;
    if (n < 0) try out.append(a, '-');
    if (t.len < width) try out.appendNTimes(a, fill, width - t.len);
    try out.appendSlice(a, t);
}

fn numeral(it: *Interp, locale: []const u8, n: i64) Error!Value {
    const l = try it.list(msg(it, locale, "LOCALE_NUMERALS"));
    if (n >= 0 and n < l.len) return l[@intCast(n)];
    return .{ .int = n };
}

const Era = struct { name: []const u8, offset: i64 };

fn eraOf(it: *Interp, locale: []const u8, local: i64) Error!?Era {
    const l = try it.list(msg(it, locale, "LOCALE_ERAS"));
    var best: ?Era = null;
    for (l) |e| {
        const f = try it.list(e);
        if (f.len < 3) continue;
        if ((f[0].asInt() orelse continue) > local) break;
        best = .{ .name = try it.str(f[1]), .offset = f[2].asInt() orelse 0 };
    }
    return best;
}

const Ctx = struct { d: Date, secs: i64, local: i64, here: Here, locale: []const u8 };

fn listItem(it: *Interp, v: Value, k: i64) Error![]const u8 {
    const l = try it.list(v);
    if (k < 0 or k >= l.len) return "";
    return it.str(l[@intCast(k)]);
}

fn formatInto(it: *Interp, out: *std.ArrayList(u8), f: []const u8, c: *const Ctx, depth: u32) Error!void {
    const a = it.alloc();
    if (depth > 8) return;
    const d = c.d;
    const tod = @mod(c.local, 86400);
    const hour = @divFloor(tod, 3600);
    const minute = @divFloor(@mod(tod, 3600), 60);
    const sec = @mod(tod, 60);
    const h12 = if (@mod(hour, 12) == 0) 12 else @mod(hour, 12);
    // A year before 1 CE prints as a positive year of the BCE era.
    const yr = if (d.year <= 0) 1 - d.year else d.year;
    const iso_yr = if (d.iso_year <= 0) 1 - d.iso_year else d.iso_year;
    const L = c.locale;
    var i: usize = 0;
    while (i < f.len) : (i += 1) {
        if (f[i] != '%' or i + 1 >= f.len) {
            try out.append(a, f[i]);
            continue;
        }
        i += 1;
        var conv = f[i];
        var mod: u8 = 0;
        if ((conv == 'E' or conv == 'O') and i + 1 < f.len) {
            mod = conv;
            i += 1;
            conv = f[i];
        }
        if (mod == 'O') {
            const n: ?i64 = switch (conv) {
                'd', 'e' => d.day,
                'H', 'k' => hour,
                'I', 'l' => h12,
                'm' => d.month,
                'M' => minute,
                'S' => sec,
                'u' => if (d.wday == 0) 7 else d.wday,
                'w' => d.wday,
                'y' => @mod(yr, 100),
                else => null,
            };
            if (n) |x| {
                try out.appendSlice(a, try it.str(try numeral(it, L, x)));
                continue;
            }
            try out.appendSlice(a, f[i - 2 .. i + 1]);
            continue;
        }
        if (mod == 'E') {
            switch (conv) {
                'c' => try formatInto(it, out, try it.str(msg(it, L, "LOCALE_DATE_TIME_FORMAT")), c, depth + 1),
                'x' => try formatInto(it, out, try it.str(msg(it, L, "LOCALE_DATE_FORMAT")), c, depth + 1),
                'X' => try formatInto(it, out, try it.str(msg(it, L, "LOCALE_TIME_FORMAT")), c, depth + 1),
                'E' => try out.appendSlice(a, try it.str(msg(it, L, if (d.year <= 0) "BCE" else "CE"))),
                'C' => {
                    if (try eraOf(it, L, c.local)) |e| {
                        try out.appendSlice(a, e.name);
                    } else try pad(a, out, @divFloor(yr, 100), 2, '0');
                },
                'y' => {
                    if (try eraOf(it, L, c.local)) |e| {
                        try out.appendSlice(a, try it.str(try numeral(it, L, yr - e.offset)));
                    } else try pad(a, out, @mod(yr, 100), 2, '0');
                },
                'Y' => {
                    if (try eraOf(it, L, c.local) != null) {
                        try formatInto(it, out, try it.str(msg(it, L, "LOCALE_YEAR_FORMAT")), c, depth + 1);
                    } else try pad(a, out, yr, 4, '0');
                },
                else => try out.appendSlice(a, f[i - 2 .. i + 1]),
            }
            continue;
        }
        switch (conv) {
            '%' => try out.append(a, '%'),
            'a' => try out.appendSlice(a, try listItem(it, msg(it, L, "DAYS_OF_WEEK_ABBREV"), d.wday)),
            'A' => try out.appendSlice(a, try listItem(it, msg(it, L, "DAYS_OF_WEEK_FULL"), d.wday)),
            'b', 'h' => try out.appendSlice(a, try listItem(it, msg(it, L, "MONTHS_ABBREV"), d.month - 1)),
            'B' => try out.appendSlice(a, try listItem(it, msg(it, L, "MONTHS_FULL"), d.month - 1)),
            'c' => try formatInto(it, out, try it.str(msg(it, L, "DATE_TIME_FORMAT")), c, depth + 1),
            'C' => try pad(a, out, @divFloor(yr, 100), 2, '0'),
            'd' => try pad(a, out, d.day, 2, '0'),
            'D' => try formatInto(it, out, "%m/%d/%Y", c, depth + 1),
            'e' => try pad(a, out, d.day, 2, ' '),
            'g' => try pad(a, out, @mod(iso_yr, 100), 2, '0'),
            'G' => try pad(a, out, iso_yr, 4, '0'),
            'H' => try pad(a, out, hour, 2, '0'),
            'I' => try pad(a, out, h12, 2, '0'),
            'j' => try pad(a, out, d.yday, 3, '0'),
            'J' => try pad(a, out, d.jd, 1, '0'),
            'k' => try pad(a, out, hour, 2, ' '),
            'l' => try pad(a, out, h12, 2, ' '),
            'm' => try pad(a, out, d.month, 2, '0'),
            'M' => try pad(a, out, minute, 2, '0'),
            'n' => try out.append(a, '\n'),
            'N' => try pad(a, out, d.month, 2, ' '),
            'p' => try out.appendSlice(a, try it.str(msg(it, L, if (hour < 12) "AM" else "PM"))),
            'P' => {
                const s = try it.str(msg(it, L, if (hour < 12) "AM" else "PM"));
                try out.appendSlice(a, try std.ascii.allocLowerString(a, s));
            },
            'r' => try formatInto(it, out, try it.str(msg(it, L, "TIME_FORMAT_12")), c, depth + 1),
            'R' => try formatInto(it, out, "%H:%M", c, depth + 1),
            's' => try pad(a, out, c.secs, 1, '0'),
            'S' => try pad(a, out, sec, 2, '0'),
            't' => try out.append(a, '\t'),
            'T' => try formatInto(it, out, "%H:%M:%S", c, depth + 1),
            'u' => try pad(a, out, if (d.wday == 0) 7 else d.wday, 1, '0'),
            'U' => try pad(a, out, @divFloor(d.yday + 6 - d.wday, 7), 2, '0'),
            'V' => try pad(a, out, d.iso_week, 2, '0'),
            'w' => try pad(a, out, d.wday, 1, '0'),
            'W' => try pad(a, out, @divFloor(d.yday + 6 - @mod(d.wday + 6, 7), 7), 2, '0'),
            'x' => try formatInto(it, out, try it.str(msg(it, L, "DATE_FORMAT")), c, depth + 1),
            'X' => try formatInto(it, out, try it.str(msg(it, L, "TIME_FORMAT")), c, depth + 1),
            'y' => try pad(a, out, @mod(yr, 100), 2, '0'),
            'Y' => try pad(a, out, yr, 4, '0'),
            'z' => {
                const o = c.here.offset;
                try out.append(a, if (o < 0) '-' else '+');
                const m = @abs(o);
                try pad(a, out, @intCast(m / 3600), 2, '0');
                try pad(a, out, @intCast(m % 3600 / 60), 2, '0');
                if (m % 60 != 0) try pad(a, out, @intCast(m % 60), 2, '0');
            },
            'Z' => try out.appendSlice(a, c.here.name),
            '+' => try formatInto(it, out, "%a %b %e %H:%M:%S %Z %Y", c, depth + 1),
            else => try out.appendSlice(a, f[i - 1 .. i + 1]),
        }
    }
}

const Opts = struct {
    format: ?[]const u8 = null,
    zone: []const u8 = ":localtime",
    locale: []const u8 = "c",
    base: ?i64 = null,
};

fn seconds(it: *Interp, v: Value) Error!i64 {
    return v.asInt() orelse it.failCode("TCL VALUE INTEGER", "expected integer but got \"{s}\"", .{try it.str(v)});
}

fn parseOpts(it: *Interp, args: []const Value, usage: []const u8, allow_format: bool, allow_base: bool) Error!Opts {
    var o: Opts = .{};
    var gmt = false;
    var zone_given = false;
    if (args.len % 2 != 0) return it.failCode("CLOCK wrongNumArgs", "wrong # args: should be \"{s}\"", .{usage});
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const w = try it.str(args[i]);
        const v = args[i + 1];
        if (allow_format and w.len > 1 and std.mem.startsWith(u8, "-format", w)) {
            o.format = try it.str(v);
        } else if (w.len > 1 and std.mem.startsWith(u8, "-gmt", w)) {
            gmt = try @import("expr.zig").truthy(it, v);
        } else if (w.len > 1 and std.mem.startsWith(u8, "-locale", w)) {
            o.locale = try std.ascii.allocLowerString(it.alloc(), try it.str(v));
        } else if (w.len > 1 and std.mem.startsWith(u8, "-timezone", w)) {
            o.zone = try it.str(v);
            zone_given = true;
        } else if (allow_base and w.len > 1 and std.mem.startsWith(u8, "-base", w)) {
            o.base = try seconds(it, v);
        } else {
            return it.failCode("CLOCK badOption", "bad option \"{s}\": must be {s}", .{ w, if (allow_base) "-base, -format, -gmt, -locale or -timezone" else if (allow_format) "-format, -gmt, -locale or -timezone" else "-gmt, -locale or -timezone" });
        }
    }
    if (gmt and zone_given) return it.failCode("CLOCK gmtWithTimezone", "cannot use -gmt and -timezone in same call", .{});
    if (gmt) o.zone = ":GMT";
    return o;
}

fn ctxAt(it: *Interp, secs: i64, z: *const Zone, locale: []const u8) Ctx {
    const here = at(z, secs);
    const local = secs + here.offset;
    const d = fromJd(@divFloor(local, 86400) + epoch_jd, changeDate(it, locale));
    return .{ .d = d, .secs = secs, .local = local, .here = here, .locale = locale };
}

fn subFormat(it: *Interp, args: []const Value) Error!Value {
    const usage = "clock format clockval ?-format string? ?-gmt boolean? ?-locale LOCALE? ?-timezone ZONE?";
    if (args.len < 1) return it.failCode("CLOCK wrongNumArgs", "wrong # args: should be \"{s}\"", .{usage});
    const secs = try seconds(it, args[0]);
    const o = try parseOpts(it, args[1..], usage, true, false);
    const z = try zoneOf(it, o.zone);
    const c = ctxAt(it, secs, z, o.locale);
    var out: std.ArrayList(u8) = .empty;
    try formatInto(it, &out, o.format orelse "%a %b %d %H:%M:%S %Z %Y", &c, 0);
    return .{ .str = out.items };
}

// ---- scan ----

const Fields = struct {
    year: ?i64 = null,
    century: ?i64 = null,
    yy: ?i64 = null,
    month: ?i64 = null,
    day: ?i64 = null,
    yday: ?i64 = null,
    jd: ?i64 = null,
    iso_year: ?i64 = null,
    iso_yy: ?i64 = null,
    iso_week: ?i64 = null,
    dow: ?i64 = null,
    hour: ?i64 = null,
    hour12: ?i64 = null,
    pm: ?bool = null,
    minute: ?i64 = null,
    second: ?i64 = null,
    secs: ?i64 = null,
    bce: bool = false,
    offset: ?i64 = null,
    // The positions of the groups in the format; the rightmost wins.
    pos_jd: usize = 0,
    pos_md: usize = 0,
    pos_yd: usize = 0,
    pos_wk: usize = 0,
};

const Scan = struct {
    it: *Interp,
    s: []const u8,
    i: usize = 0,
    locale: []const u8,
    f: Fields = .{},
    seq: usize = 0,

    fn ws(p: *Scan) void {
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
    }

    fn num(p: *Scan, maxw: usize) ?i64 {
        const start = p.i;
        var n: i64 = 0;
        while (p.i < p.s.len and p.i - start < maxw and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) n = n *| 10 +| (p.s[p.i] - '0');
        return if (p.i == start) null else n;
    }

    /// The longest item of a list that starts here, in any case.
    fn word(p: *Scan, list: Value) Error!?i64 {
        const l = try p.it.list(list);
        var best: ?i64 = null;
        var best_len: usize = 0;
        for (l, 0..) |v, k| {
            const t = try p.it.str(v);
            if (t.len == 0 or t.len <= best_len or p.i + t.len > p.s.len) continue;
            if (std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + t.len], t)) {
                best = @intCast(k);
                best_len = t.len;
            }
        }
        p.i += best_len;
        return best;
    }

    fn numeral(p: *Scan) Error!?i64 {
        return p.word(msg(p.it, p.locale, "LOCALE_NUMERALS"));
    }

    fn apply(p: *Scan, fmt: []const u8, depth: u32) Error!bool {
        if (depth > 8) return false;
        const L = p.locale;
        var k: usize = 0;
        while (k < fmt.len) : (k += 1) {
            const ch = fmt[k];
            if (std.ascii.isWhitespace(ch)) {
                p.ws();
                continue;
            }
            if (ch != '%' or k + 1 >= fmt.len) {
                if (p.i >= p.s.len or std.ascii.toLower(p.s[p.i]) != std.ascii.toLower(ch)) return false;
                p.i += 1;
                continue;
            }
            k += 1;
            var c = fmt[k];
            var mod: u8 = 0;
            if ((c == 'E' or c == 'O') and k + 1 < fmt.len) {
                mod = c;
                k += 1;
                c = fmt[k];
            }
            p.seq += 1;
            const seq = p.seq;
            if (c != 'n' and c != 't' and c != '%') p.ws();
            const f = &p.f;
            var n: ?i64 = null;
            if (mod == 'O') {
                n = try p.numeral();
                if (n == null) return false;
            }
            switch (c) {
                '%' => {
                    if (p.i >= p.s.len or p.s[p.i] != '%') return false;
                    p.i += 1;
                },
                'n', 't' => p.ws(),
                'a', 'A' => {
                    var w = try p.word(msg(p.it, L, "DAYS_OF_WEEK_FULL"));
                    if (w == null) w = try p.word(msg(p.it, L, "DAYS_OF_WEEK_ABBREV"));
                    f.dow = w orelse return false;
                    f.pos_wk = seq;
                },
                'b', 'B', 'h' => {
                    var w = try p.word(msg(p.it, L, "MONTHS_FULL"));
                    if (w == null) w = try p.word(msg(p.it, L, "MONTHS_ABBREV"));
                    f.month = (w orelse return false) + 1;
                    f.pos_md = seq;
                },
                'C' => {
                    if (mod == 'E') {
                        if (!try p.eraName()) return false;
                    } else f.century = p.num(2) orelse return false;
                },
                'd', 'e' => {
                    f.day = n orelse (p.num(2) orelse return false);
                    f.pos_md = seq;
                },
                'g' => {
                    f.iso_yy = p.num(2) orelse return false;
                    f.pos_wk = seq;
                },
                'G' => {
                    f.iso_year = p.num(4) orelse return false;
                    f.pos_wk = seq;
                },
                'H', 'k' => f.hour = n orelse (p.num(2) orelse return false),
                'I', 'l' => f.hour12 = n orelse (p.num(2) orelse return false),
                'j' => {
                    f.yday = p.num(3) orelse return false;
                    f.pos_yd = seq;
                },
                'J' => {
                    f.jd = p.num(18) orelse return false;
                    f.pos_jd = seq;
                },
                'm', 'N' => {
                    f.month = n orelse (p.num(2) orelse return false);
                    f.pos_md = seq;
                },
                'M' => f.minute = n orelse (p.num(2) orelse return false),
                'p', 'P' => {
                    const am = try p.it.str(msg(p.it, L, "AM"));
                    const pm = try p.it.str(msg(p.it, L, "PM"));
                    if (p.i + pm.len <= p.s.len and std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + pm.len], pm)) {
                        f.pm = true;
                        p.i += pm.len;
                    } else if (p.i + am.len <= p.s.len and std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + am.len], am)) {
                        f.pm = false;
                        p.i += am.len;
                    } else return false;
                },
                's' => {
                    var neg = false;
                    if (p.i < p.s.len and (p.s[p.i] == '-' or p.s[p.i] == '+')) {
                        neg = p.s[p.i] == '-';
                        p.i += 1;
                    }
                    const v = p.num(19) orelse return false;
                    f.secs = if (neg) -v else v;
                },
                'S' => f.second = n orelse (p.num(2) orelse return false),
                'u', 'w' => {
                    const v = n orelse (p.num(1) orelse return false);
                    f.dow = @mod(v, 7);
                    f.pos_wk = seq;
                },
                'V' => {
                    f.iso_week = p.num(2) orelse return false;
                    f.pos_wk = seq;
                },
                'U', 'W' => _ = p.num(2) orelse return false,
                'y' => {
                    if (mod == 'E') {
                        const v = (try p.numeral()) orelse (p.num(4) orelse return false);
                        f.yy = v;
                    } else f.yy = n orelse (p.num(2) orelse return false);
                },
                'Y' => {
                    if (mod == 'E') {
                        if (!try p.apply(try p.it.str(msg(p.it, L, "LOCALE_YEAR_FORMAT")), depth + 1)) return false;
                    } else f.year = p.num(4) orelse return false;
                },
                'x' => if (!try p.apply(try p.it.str(msg(p.it, L, if (mod == 'E') "LOCALE_DATE_FORMAT" else "DATE_FORMAT")), depth + 1)) return false,
                'X' => if (!try p.apply(try p.it.str(msg(p.it, L, if (mod == 'E') "LOCALE_TIME_FORMAT" else "TIME_FORMAT")), depth + 1)) return false,
                'c' => if (!try p.apply(try p.it.str(msg(p.it, L, if (mod == 'E') "LOCALE_DATE_TIME_FORMAT" else "DATE_TIME_FORMAT")), depth + 1)) return false,
                'D' => if (!try p.apply("%m/%d/%Y", depth + 1)) return false,
                'r' => if (!try p.apply(try p.it.str(msg(p.it, L, "TIME_FORMAT_12")), depth + 1)) return false,
                'R' => if (!try p.apply("%H:%M", depth + 1)) return false,
                'T' => if (!try p.apply("%H:%M:%S", depth + 1)) return false,
                'z', 'Z' => {
                    const st = p.i;
                    if (p.i < p.s.len and (p.s[p.i] == '+' or p.s[p.i] == '-')) {
                        var j = p.i;
                        if (parseOffset(p.s, &j)) |o| {
                            f.offset = o;
                            p.i = j;
                        } else return false;
                    } else {
                        while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
                        if (p.i == st) return false;
                        const nm = p.s[st..p.i];
                        if (std.ascii.eqlIgnoreCase(nm, "gmt") or std.ascii.eqlIgnoreCase(nm, "utc")) f.offset = 0;
                    }
                },
                'E' => {
                    if (mod != 'E') return false;
                    const bce = try p.it.str(msg(p.it, L, "BCE"));
                    const ce = try p.it.str(msg(p.it, L, "CE"));
                    if (p.i + bce.len <= p.s.len and std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + bce.len], bce)) {
                        f.bce = true;
                        p.i += bce.len;
                    } else if (p.i + ce.len <= p.s.len and std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + ce.len], ce)) {
                        p.i += ce.len;
                    } else return false;
                },
                else => return p.it.failCode("CLOCK badFormat", "bad format field %{c}", .{c}),
            }
        }
        return true;
    }

    /// An era name of the locale. It sets the century from the era.
    fn eraName(p: *Scan) Error!bool {
        const l = try p.it.list(msg(p.it, p.locale, "LOCALE_ERAS"));
        var best: ?i64 = null;
        var best_len: usize = 0;
        for (l) |e| {
            const x = try p.it.list(e);
            if (x.len < 3) continue;
            const t = try p.it.str(x[1]);
            if (t.len < best_len or p.i + t.len > p.s.len) continue;
            if (std.ascii.eqlIgnoreCase(p.s[p.i .. p.i + t.len], t)) {
                best = x[2].asInt() orelse 0;
                best_len = t.len;
            }
        }
        const b = best orelse return false;
        p.i += best_len;
        p.f.century = @divFloor(b, 100);
        return true;
    }
};

fn baseFields(it: *Interp, base: i64, z: *const Zone, locale: []const u8) Date {
    return ctxAt(it, base, z, locale).d;
}

fn resolveYear(f: *const Fields, base_year: i64) i64 {
    var y: i64 = base_year;
    if (f.year) |v| {
        y = v;
    } else if (f.yy) |v| {
        if (f.century) |c| {
            y = c * 100 + v;
        } else y = if (v >= 38) 1900 + v else 2000 + v;
    } else if (f.century) |c| {
        y = c * 100 + @mod(base_year, 100);
    }
    if (f.bce) y = 1 - y;
    return y;
}

fn subScan(it: *Interp, args: []const Value) Error!Value {
    const usage = "clock scan string ?-base seconds? ?-format string? ?-gmt boolean? ?-locale LOCALE? ?-timezone ZONE?";
    if (args.len < 1) return it.failCode("CLOCK wrongNumArgs", "wrong # args: should be \"{s}\"", .{usage});
    const text = try it.str(args[0]);
    const o = try parseOpts(it, args[1..], usage, true, true);
    const z = try zoneOf(it, o.zone);
    const base = o.base orelse @divFloor(try nowMicros(it), 1000000);
    const change = changeDate(it, o.locale);
    // Relative items of the free form: "+1 month -1 day", "2 weeks ago",
    // "tomorrow". They move the date of the rest of the text, or the base.
    if (o.format == null) if (try relative(it, text)) |rel| {
        var t: i64 = base;
        if (rel.rest.len > 0) {
            const again = try it.alloc().dupe(Value, args);
            again[0] = .{ .str = rel.rest };
            t = (try subScan(it, again)).asInt() orelse base;
        }
        var add: std.ArrayList(Value) = .empty;
        try add.append(it.alloc(), .{ .int = t });
        try add.appendSlice(it.alloc(), rel.items);
        var k: usize = 1;
        while (k + 1 < args.len) : (k += 2) {
            const name = try it.str(args[k]);
            if (eql(name, "-base") or eql(name, "-format")) continue;
            try add.appendSlice(it.alloc(), args[k .. k + 2]);
        }
        return subAdd(it, add.items);
    };
    var f: Fields = .{};
    if (o.format) |fmt| {
        var p: Scan = .{ .it = it, .s = text, .locale = o.locale };
        const ok = try p.apply(fmt, 0);
        p.ws();
        if (!ok or p.i != text.len) return it.failCode("CLOCK badInputString", "input string does not match supplied format", .{});
        f = p.f;
    } else f = try freeForm(it, text);
    if (f.secs) |s| return .{ .int = s };
    const b = baseFields(it, base, z, o.locale);
    const has_date = f.jd != null or f.year != null or f.yy != null or f.century != null or f.month != null or f.day != null or f.yday != null or f.iso_year != null or f.iso_yy != null or f.iso_week != null or f.dow != null;
    var jd = b.jd;
    if (has_date) {
        // The rightmost group of fields selects the calendar.
        const best = @max(f.pos_jd, @max(f.pos_md, @max(f.pos_yd, f.pos_wk)));
        if (f.jd != null and f.pos_jd == best) {
            jd = f.jd.?;
        } else if ((f.yday != null) and f.pos_yd == best) {
            jd = toJd(resolveYear(&f, b.year), 1, 1, change) + f.yday.? - 1;
        } else if ((f.iso_week != null or f.iso_year != null or f.iso_yy != null or f.dow != null) and f.pos_wk == best and f.pos_wk != 0) {
            var iy = b.iso_year;
            if (f.iso_year) |v| {
                iy = v;
            } else if (f.iso_yy) |v| {
                iy = if (f.century) |c| c * 100 + v else (if (v >= 38) 1900 + v else 2000 + v);
            }
            const week = f.iso_week orelse b.iso_week;
            const dow = f.dow orelse (if (f.iso_week != null) @as(i64, 1) else b.wday);
            const iso_dow = if (dow == 0) 7 else dow;
            // January 4 is always in week 1.
            const jan4 = toJd(iy, 1, 4, change);
            const jan4_dow = @mod(jan4 + 1, 7);
            const monday = jan4 - (if (jan4_dow == 0) @as(i64, 6) else jan4_dow - 1);
            jd = monday + (week - 1) * 7 + iso_dow - 1;
        } else {
            const has_year = f.year != null or f.yy != null or f.century != null;
            const y = resolveYear(&f, b.year);
            const m = f.month orelse (if (has_year) @as(i64, 1) else b.month);
            const d = f.day orelse (if (has_year or f.month != null) @as(i64, 1) else b.day);
            jd = toJd(y, m, d, change);
        }
    }
    var tod: i64 = 0;
    const has_time = f.hour != null or f.hour12 != null or f.minute != null or f.second != null or f.pm != null;
    if (has_time or has_date) {
        var h = f.hour orelse 0;
        if (f.hour12) |x| h = @mod(x, 12);
        if (f.pm) |pm| {
            if (f.hour == null and f.hour12 == null) h = 0;
            h = @mod(h, 12) + (if (pm) @as(i64, 12) else 0);
        }
        tod = h * 3600 + (f.minute orelse 0) * 60 + (f.second orelse 0);
    } else tod = @mod(base + at(z, base).offset, 86400);
    const local = (jd - epoch_jd) * 86400 + tod;
    if (f.offset) |off| return .{ .int = local - off };
    return .{ .int = localToUtc(z, local) };
}

/// The common forms with no format: an ISO date, a US date, a time.
const Relative = struct { rest: []const u8, items: []const Value };

/// Splits the relative items off a free-form text: a signed count and a
/// unit, with "ago" after it to go back, and the words tomorrow,
/// yesterday, today, and now. Gives null when the text has none.
fn relative(it: *Interp, text: []const u8) Error!?Relative {
    const a = it.alloc();
    var words: std.ArrayList([]const u8) = .empty;
    var tok = std.mem.tokenizeAny(u8, text, " \t\n");
    while (tok.next()) |w| try words.append(a, w);
    const units = [_][2][]const u8{
        .{ "year", "years" },     .{ "month", "months" }, .{ "fortnight", "fortnight" }, .{ "week", "weeks" },
        .{ "day", "days" },       .{ "hour", "hours" },   .{ "minute", "minutes" },      .{ "min", "minutes" },
        .{ "second", "seconds" }, .{ "sec", "seconds" },
    };
    var items: std.ArrayList(Value) = .empty;
    var rest: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < words.items.len) : (i += 1) {
        const w = try std.ascii.allocLowerString(a, words.items[i]);
        if (eql(w, "tomorrow") or eql(w, "yesterday")) {
            try items.appendSlice(a, &.{ .{ .int = if (w[0] == 't') 1 else -1 }, .{ .str = "days" } });
            continue;
        }
        if (eql(w, "today") or eql(w, "now")) {
            try items.appendSlice(a, &.{ .{ .int = 0 }, .{ .str = "days" } });
            continue;
        }
        // A count with a sign or a plain count, then a unit.
        var count: ?i64 = null;
        var unit_at = i + 1;
        if (std.fmt.parseInt(i64, w, 10)) |n| {
            count = n;
        } else |_| {
            if ((w[0] == '+' or w[0] == '-') and w.len == 1 and i + 1 < words.items.len) {
                if (std.fmt.parseInt(i64, words.items[i + 1], 10)) |n| {
                    count = if (w[0] == '-') -n else n;
                    unit_at = i + 2;
                } else |_| {}
            }
        }
        if (count != null and unit_at < words.items.len) {
            const u = try std.ascii.allocLowerString(a, words.items[unit_at]);
            const found: ?[]const u8 = for (units) |pair| {
                if (eql(u, pair[0]) or (u.len > pair[0].len and std.mem.startsWith(u8, u, pair[0]) and u[u.len - 1] == 's')) break pair[1];
            } else null;
            if (found) |unit| {
                var n = count.?;
                var next = unit_at + 1;
                if (next < words.items.len and std.ascii.eqlIgnoreCase(words.items[next], "ago")) {
                    n = -n;
                    next += 1;
                }
                if (eql(unit, "fortnight")) {
                    try items.appendSlice(a, &.{ .{ .int = n * 14 }, .{ .str = "days" } });
                } else try items.appendSlice(a, &.{ .{ .int = n }, .{ .str = unit } });
                i = next - 1;
                continue;
            }
        }
        if (rest.items.len > 0) try rest.append(a, ' ');
        try rest.appendSlice(a, words.items[i]);
    }
    if (items.items.len == 0) return null;
    return .{ .rest = rest.items, .items = items.items };
}

fn freeForm(it: *Interp, text: []const u8) Error!Fields {
    var f: Fields = .{};
    const t = std.mem.trim(u8, text, " \t\n");
    var p: Scan = .{ .it = it, .s = t, .locale = "c" };
    // The common forms of the free-form scan of Tcl: ISO dates, US
    // dates, a day and a month name ("1 january 2004", "Jan 1, 2004"),
    // each with an optional time, and a time alone.
    const forms = [_][]const u8{
        "%Y-%m-%d %H:%M:%S",    "%Y-%m-%d %H:%M",    "%Y-%m-%d",           "%Y-%m-%dT%H:%M:%S",
        "%m/%d/%Y %H:%M:%S",    "%m/%d/%Y %H:%M",    "%m/%d/%Y",           "%d %b %Y %H:%M:%S",
        "%d %b %Y %H:%M",       "%d %b %Y",          "%b %d, %Y %H:%M:%S", "%b %d, %Y %H:%M",
        "%b %d, %Y",            "%b %d %Y %H:%M:%S", "%b %d %Y %H:%M",     "%b %d %Y",
        "%a %b %d %H:%M:%S %Y", "%H:%M:%S",          "%H:%M",
    };
    for (forms) |fm| {
        p = .{ .it = it, .s = t, .locale = "c" };
        if (try p.apply(fm, 0)) {
            if (p.i == t.len) {
                f = p.f;
                return f;
            }
        }
    }
    return it.failCode("CLOCK badInputString", "unable to convert date-time string \"{s}\": syntax error", .{text});
}

// ---- add ----

fn subAdd(it: *Interp, args: []const Value) Error!Value {
    const usage = "clock add clockval ?number units?... ?-gmt boolean? ?-locale LOCALE? ?-timezone ZONE?";
    if (args.len < 1 or args.len % 2 != 1) return it.failCode("CLOCK wrongNumArgs", "wrong # args: should be \"{s}\"", .{usage});
    var t = try seconds(it, args[0]);
    var opt_words: std.ArrayList(Value) = .empty;
    var steps: std.ArrayList([2]Value) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const w = try it.str(args[i]);
        if (w.len > 1 and w[0] == '-' and !std.ascii.isDigit(w[1])) {
            try opt_words.appendSlice(it.alloc(), args[i .. i + 2]);
        } else try steps.append(it.alloc(), .{ args[i], args[i + 1] });
    }
    const o = try parseOpts(it, opt_words.items, usage, false, false);
    const z = try zoneOf(it, o.zone);
    const change = changeDate(it, o.locale);
    for (steps.items) |st| {
        const n = st[0].asInt() orelse return it.failCode("CLOCK badInt", "expected integer but got \"{s}\"", .{try it.str(st[0])});
        const unit = try it.str(st[1]);
        const u = try std.ascii.allocLowerString(it.alloc(), unit);
        const has = struct {
            fn f(word: []const u8, full: []const u8) bool {
                return word.len > 0 and (std.mem.startsWith(u8, full, word) or eql(word, full[0 .. full.len - 1]));
            }
        }.f;
        if (has(u, "seconds")) {
            t += n;
        } else if (has(u, "minutes")) {
            t += n * 60;
        } else if (has(u, "hours")) {
            t += n * 3600;
        } else if (has(u, "days") or has(u, "weeks")) {
            const days = if (has(u, "weeks")) n * 7 else n;
            const here = at(z, t);
            t = localToUtc(z, t + here.offset + days * 86400);
        } else if (has(u, "months") or has(u, "years")) {
            const here = at(z, t);
            const local = t + here.offset;
            const d = fromJd(@divFloor(local, 86400) + epoch_jd, change);
            const months = if (has(u, "years")) n * 12 else n;
            const mz = d.month - 1 + months;
            const y = d.year + @divFloor(mz, 12);
            const m = @mod(mz, 12) + 1;
            const greg = toJd(y, m, 1, change) >= change;
            const lens = [_]i64{ 31, if (isLeap(y, greg)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            const day = @min(d.day, lens[@intCast(m - 1)]);
            t = localToUtc(z, (toJd(y, m, day, change) - epoch_jd) * 86400 + @mod(local, 86400));
        } else return it.failCode("CLOCK badUnit", "unknown unit \"{s}\": must be seconds, minutes, hours, days, weeks, months, or years", .{unit});
    }
    return .{ .int = t };
}

// ---- The command ----

fn nowMicros(it: *Interp) Error!i64 {
    const h = it.clock_host orelse return it.fail("the embedder gave no clock", .{});
    return @import("tape.zig").time(it, .clock, h.ctx, h.now);
}

pub fn cmdClock(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("clock subcommand ?arg ...?");
    const word = try it.str(argv[1]);
    const names = [_][]const u8{ "add", "clicks", "format", "microseconds", "milliseconds", "scan", "seconds" };
    var sub: ?[]const u8 = null;
    var hits: usize = 0;
    for (names) |n| {
        if (eql(n, word)) {
            sub = n;
            hits = 1;
            break;
        }
        if (word.len > 0 and std.mem.startsWith(u8, n, word)) {
            sub = n;
            hits += 1;
        }
    }
    if (hits != 1) return it.failCode("TCL LOOKUP INDEX subcommand", "unknown or ambiguous subcommand \"{s}\": must be add, clicks, format, microseconds, milliseconds, scan, or seconds", .{word});
    const s = sub.?;
    const args = argv[2..];
    if (eql(s, "format")) return subFormat(it, args);
    if (eql(s, "scan")) return subScan(it, args);
    if (eql(s, "add")) return subAdd(it, args);
    if (eql(s, "clicks")) {
        if (args.len > 1) return it.wrongArgs("clock clicks ?-switch?");
        var div: i64 = 1;
        if (args.len == 1) {
            const o = try it.str(args[0]);
            if (o.len > 1 and std.mem.startsWith(u8, "-milliseconds", o)) {
                div = 1000;
            } else if (!(o.len > 1 and std.mem.startsWith(u8, "-microseconds", o))) {
                return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -milliseconds or -microseconds", .{o});
            }
        }
        return .{ .int = @divFloor(try nowMicros(it), div) };
    }
    if (args.len != 0) return it.fail("wrong # args: should be \"clock {s}\"", .{s});
    const us = try nowMicros(it);
    if (eql(s, "seconds")) return .{ .int = @divFloor(us, 1000000) };
    if (eql(s, "milliseconds")) return .{ .int = @divFloor(us, 1000) };
    return .{ .int = us };
}

/// `time script ?count?`: the mean time of a script in microseconds.
fn cmdTime(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    if (argv.len != 2 and argv.len != 3) return it.wrongArgs("time command ?count?");
    const count: i64 = if (argv.len == 3) try it.int(argv[2]) else 1;
    const script = try it.scriptOf(argv, 1, cmd);
    const start = try nowMicros(it);
    var i: i64 = 0;
    while (i < count) : (i += 1) _ = try it.evalScript(script);
    const total = (try nowMicros(it)) - start;
    const a = it.alloc();
    if (count <= 0) return .{ .str = "0 microseconds per iteration" };
    if (@rem(total, count) == 0) return .{ .str = try std.fmt.allocPrint(a, "{d} microseconds per iteration", .{@divTrunc(total, count)}) };
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
    return .{ .str = try std.fmt.allocPrint(a, "{d:.2} microseconds per iteration", .{mean}) };
}

/// `timerate ?-direct? ?-calibrate? ?-overhead double? command ?time
/// ?max-count??`: runs a script until a time in milliseconds ends, and
/// gives the mean time, the count, the rate, and the net time.
fn cmdTimerate(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    const usage = "timerate ?-direct? ?-calibrate? ?-overhead double? command ?time ?max-count??";
    const a = it.alloc();
    var i: usize = 1;
    var overhead: f64 = 0;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (eql(o, "-direct") or eql(o, "-calibrate")) continue;
        if (eql(o, "-overhead")) {
            i += 1;
            if (i >= argv.len) return it.wrongArgs(usage);
            const n = argv[i].asNumber() orelse return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(argv[i])});
            overhead = if (n == .int) @floatFromInt(n.int) else n.double;
            continue;
        }
        if (eql(o, "--")) i += 1;
        break;
    }
    const rest = argv[i..];
    if (rest.len < 1 or rest.len > 3) return it.wrongArgs(usage);
    var limit_ms: i64 = 1000;
    var max_count: i64 = std.math.maxInt(i64);
    if (rest.len >= 2) limit_ms = try it.int(rest[1]);
    if (rest.len == 3) max_count = try it.int(rest[2]);
    const script = try it.scriptOf(argv, i, cmd);
    const start = try nowMicros(it);
    var count: i64 = 0;
    while (count < max_count) {
        count += 1;
        _ = it.evalScript(script) catch |e| switch (e) {
            error.TclBreak => break,
            error.TclContinue => {},
            else => return e,
        };
        if ((try nowMicros(it)) - start >= limit_ms * 1000) break;
    }
    if (count == 0) return .{ .str = "0 \u{b5}s/# 0 # 0 #/sec 0 net-ms" };
    const total: f64 = @floatFromInt((try nowMicros(it)) - start);
    const n: f64 = @floatFromInt(count);
    const net = @max(total - overhead * n, 0);
    const each = net / n;
    const rate: f64 = if (net > 0) n * 1e6 / net else 1e6;
    return .{ .str = try std.fmt.allocPrint(a, "{d:.6} \u{b5}s/# {d} # {d:.3} #/sec {d:.3} net-ms", .{ each, count, rate, net / 1000 }) };
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("clock", cmdClock);
    try it.register("time", cmdTime);
    try it.register("timerate", cmdTimerate);
    try it.register("msgcat::mcset", cmdMcset);
    try it.register("msgcat::mcmset", cmdMcmset);
    try it.register("msgcat::mc", cmdMc);
    try it.register("msgcat::mclocale", cmdMclocale);
    try it.register("msgcat::mcexists", cmdMcexists);
    _ = try it.internNs("msgcat");
    _ = it.eval(msgcat_script) catch {};
    if (it.capabilities & @backingInt(interp.Capability.package) != 0) {
        _ = it.eval("package provide msgcat 1.6.1") catch {};
    }
}
