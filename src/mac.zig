//! The direct APIs of macOS that need no window (ztcl#111), each behind
//! its own capability:
//!
//!   ztcl::mac::keychain get|set|delete service account ?secret?   (`keychain`)
//!   ztcl::mac::defaults get|set|delete domain key ?value?         (`defaults`)
//!
//! `keychain` reaches only the services of `Interp.keychain_allow`, and
//! `defaults` only the domains of `Interp.defaults_allow`. An empty list
//! reaches none. A keychain item is a generic password of the login
//! keychain. A secret is bytes: `set` stores the UTF-8 of its string,
//! and `get` gives the stored bytes as a string. A default is a
//! string, and `get` of a key with no value, or with a value of another
//! type, gives an empty string.
//!
//! The commands load CoreFoundation and Security with `dlopen` at the
//! first call, so a build of ztcl for macOS needs no SDK, as from Linux.
//! On another platform they give the error `ZTCL MAC UNAVAILABLE`.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const on_mac = builtin.os.tag == .macos;

pub fn registerKeychain(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::mac::keychain", cmdKeychain);
}

pub fn registerDefaults(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::mac::defaults", cmdDefaults);
}

fn unavailable(it: *Interp, name: []const u8) Error {
    return it.failCode("ZTCL MAC UNAVAILABLE", "{s} is only on macOS", .{name});
}

/// True when `name` is in `list`, with the same case.
pub fn allowed(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn cmdKeychain(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    const usage = "ztcl::mac::keychain get|set|delete service account ?secret?";
    if (args.len < 4) return it.wrongArgs(usage);
    const sub = try it.str(args[1]);
    const service = try it.str(args[2]);
    const account = try it.str(args[3]);
    const set = std.mem.eql(u8, sub, "set");
    if (!set and !std.mem.eql(u8, sub, "get") and !std.mem.eql(u8, sub, "delete"))
        return it.fail("bad option \"{s}\": must be delete, get, or set", .{sub});
    if (args.len != @as(usize, if (set) 5 else 4)) return it.wrongArgs(usage);
    if (!allowed(it.keychain_allow, service))
        return it.failCode("ZTCL MAC DENIED", "the keychain service \"{s}\" is not in the allow list", .{service});
    if (comptime !on_mac) return unavailable(it, "ztcl::mac::keychain");
    const fw = api.load() orelse return it.failCode("ZTCL MAC LOAD", "could not load the Security framework", .{});
    if (set) {
        const secret = try it.str(args[4]);
        const st = fw.keychainSet(service, account, secret);
        if (st != 0) return secError(it, st);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        const st = fw.keychainDelete(service, account);
        if (st != 0 and st != api.err_not_found) return secError(it, st);
        return .{ .str = "" };
    }
    var st: i32 = 0;
    const got = fw.keychainGet(it.alloc(), service, account, &st) catch return error.OutOfMemory;
    if (got) |s| return .{ .str = s };
    if (st == api.err_not_found) return it.failCode("ZTCL MAC NOTFOUND", "no keychain item for \"{s}\" and \"{s}\"", .{ service, account });
    return secError(it, st);
}

fn secError(it: *Interp, st: i32) Error {
    return it.failCode(try std.fmt.allocPrint(it.alloc(), "ZTCL MAC KEYCHAIN {d}", .{st}), "the keychain gave the error {d}", .{st});
}

fn cmdDefaults(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    const usage = "ztcl::mac::defaults get|set|delete domain key ?value?";
    if (args.len < 4) return it.wrongArgs(usage);
    const sub = try it.str(args[1]);
    const domain = try it.str(args[2]);
    const k = try it.str(args[3]);
    const set = std.mem.eql(u8, sub, "set");
    if (!set and !std.mem.eql(u8, sub, "get") and !std.mem.eql(u8, sub, "delete"))
        return it.fail("bad option \"{s}\": must be delete, get, or set", .{sub});
    if (args.len != @as(usize, if (set) 5 else 4)) return it.wrongArgs(usage);
    if (!allowed(it.defaults_allow, domain))
        return it.failCode("ZTCL MAC DENIED", "the defaults domain \"{s}\" is not in the allow list", .{domain});
    if (comptime !on_mac) return unavailable(it, "ztcl::mac::defaults");
    const fw = api.load() orelse return it.failCode("ZTCL MAC LOAD", "could not load CoreFoundation", .{});
    if (std.mem.eql(u8, sub, "get")) {
        const got = fw.defaultsGet(it.alloc(), domain, k) catch return error.OutOfMemory;
        return .{ .str = got orelse "" };
    }
    const v: ?[]const u8 = if (set) try it.str(args[4]) else null;
    if (!fw.defaultsSet(domain, k, v)) return it.failCode("ZTCL MAC DEFAULTS", "could not write the defaults of \"{s}\"", .{domain});
    return .{ .str = "" };
}

pub const api = if (on_mac) struct {
    const Ref = *anyopaque;
    const Bool = u8;
    /// errSecItemNotFound.
    pub const err_not_found: i32 = -25300;
    const utf8: u32 = 0x08000100;

    extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;

    const Fns = struct {
        CFRelease: *const fn (Ref) callconv(.c) void,
        CFStringCreateWithBytes: *const fn (?Ref, [*]const u8, isize, u32, Bool) callconv(.c) ?Ref,
        CFStringGetLength: *const fn (Ref) callconv(.c) isize,
        CFStringGetMaximumSizeForEncoding: *const fn (isize, u32) callconv(.c) isize,
        CFStringGetCString: *const fn (Ref, [*]u8, isize, u32) callconv(.c) Bool,
        CFStringGetTypeID: *const fn () callconv(.c) usize,
        CFGetTypeID: *const fn (Ref) callconv(.c) usize,
        CFDataCreate: *const fn (?Ref, [*]const u8, isize) callconv(.c) ?Ref,
        CFDataGetBytePtr: *const fn (Ref) callconv(.c) [*]const u8,
        CFDataGetLength: *const fn (Ref) callconv(.c) isize,
        CFDictionaryCreate: *const fn (?Ref, [*]const ?*const anyopaque, [*]const ?*const anyopaque, isize, *const anyopaque, *const anyopaque) callconv(.c) ?Ref,
        CFPreferencesCopyAppValue: *const fn (Ref, Ref) callconv(.c) ?Ref,
        CFPreferencesSetAppValue: *const fn (Ref, ?Ref, Ref) callconv(.c) void,
        CFPreferencesAppSynchronize: *const fn (Ref) callconv(.c) Bool,
        SecItemCopyMatching: *const fn (Ref, *?Ref) callconv(.c) i32,
        SecItemAdd: *const fn (Ref, ?*?Ref) callconv(.c) i32,
        SecItemUpdate: *const fn (Ref, Ref) callconv(.c) i32,
        SecItemDelete: *const fn (Ref) callconv(.c) i32,
        // The constants are pointers to the CFTypeRef of each name.
        kCFTypeDictionaryKeyCallBacks: *const anyopaque,
        kCFTypeDictionaryValueCallBacks: *const anyopaque,
        kCFBooleanTrue: *const Ref,
        kSecClass: *const Ref,
        kSecClassGenericPassword: *const Ref,
        kSecAttrService: *const Ref,
        kSecAttrAccount: *const Ref,
        kSecValueData: *const Ref,
        kSecReturnData: *const Ref,
        kSecMatchLimit: *const Ref,
        kSecMatchLimitOne: *const Ref,
    };

    var fns: Fns = undefined;
    var state: enum { unknown, loaded, failed } = .unknown;

    /// The functions, from the frameworks at the first call. Null when
    /// a framework or a name is missing.
    pub fn load() ?*const @This() {
        if (state == .unknown) {
            state = .failed;
            const cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", 1) orelse return null;
            const sec = dlopen("/System/Library/Frameworks/Security.framework/Security", 1) orelse return null;
            inline for (@typeInfo(Fns).@"struct".fields) |f| {
                const handle = if (f.name[0] == 'S' or std.mem.startsWith(u8, f.name, "kSec")) sec else cf;
                const p = dlsym(handle, f.name ++ "") orelse return null;
                @field(fns, f.name) = @ptrCast(@alignCast(p));
            }
            state = .loaded;
        }
        return if (state == .loaded) &@as(@This(), .{}) else null;
    }

    fn str(s: []const u8) ?Ref {
        return fns.CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8, 0);
    }

    fn query(service: Ref, account: Ref, extra: []const [2]?*const anyopaque) ?Ref {
        var keys: [8]?*const anyopaque = undefined;
        var vals: [8]?*const anyopaque = undefined;
        keys[0] = fns.kSecClass.*;
        vals[0] = fns.kSecClassGenericPassword.*;
        keys[1] = fns.kSecAttrService.*;
        vals[1] = service;
        keys[2] = fns.kSecAttrAccount.*;
        vals[2] = account;
        for (extra, 0..) |kv, i| {
            keys[3 + i] = kv[0];
            vals[3 + i] = kv[1];
        }
        return fns.CFDictionaryCreate(null, &keys, &vals, @intCast(3 + extra.len), fns.kCFTypeDictionaryKeyCallBacks, fns.kCFTypeDictionaryValueCallBacks);
    }

    pub fn keychainGet(_: *const @This(), a: std.mem.Allocator, service: []const u8, account: []const u8, st: *i32) !?[]u8 {
        const s = str(service) orelse return null;
        defer fns.CFRelease(s);
        const acc = str(account) orelse return null;
        defer fns.CFRelease(acc);
        const q = query(s, acc, &.{ .{ fns.kSecReturnData.*, fns.kCFBooleanTrue.* }, .{ fns.kSecMatchLimit.*, fns.kSecMatchLimitOne.* } }) orelse return null;
        defer fns.CFRelease(q);
        var out: ?Ref = null;
        st.* = fns.SecItemCopyMatching(q, &out);
        const data = out orelse return null;
        defer fns.CFRelease(data);
        const n: usize = @intCast(fns.CFDataGetLength(data));
        return try a.dupe(u8, fns.CFDataGetBytePtr(data)[0..n]);
    }

    pub fn keychainSet(_: *const @This(), service: []const u8, account: []const u8, secret: []const u8) i32 {
        const s = str(service) orelse return -1;
        defer fns.CFRelease(s);
        const acc = str(account) orelse return -1;
        defer fns.CFRelease(acc);
        const data = fns.CFDataCreate(null, secret.ptr, @intCast(secret.len)) orelse return -1;
        defer fns.CFRelease(data);
        const q = query(s, acc, &.{}) orelse return -1;
        defer fns.CFRelease(q);
        var k = [_]?*const anyopaque{fns.kSecValueData.*};
        var v = [_]?*const anyopaque{data};
        const change = fns.CFDictionaryCreate(null, &k, &v, 1, fns.kCFTypeDictionaryKeyCallBacks, fns.kCFTypeDictionaryValueCallBacks) orelse return -1;
        defer fns.CFRelease(change);
        const st = fns.SecItemUpdate(q, change);
        if (st != err_not_found) return st;
        const add = query(s, acc, &.{.{ fns.kSecValueData.*, data }}) orelse return -1;
        defer fns.CFRelease(add);
        return fns.SecItemAdd(add, null);
    }

    pub fn keychainDelete(_: *const @This(), service: []const u8, account: []const u8) i32 {
        const s = str(service) orelse return -1;
        defer fns.CFRelease(s);
        const acc = str(account) orelse return -1;
        defer fns.CFRelease(acc);
        const q = query(s, acc, &.{}) orelse return -1;
        defer fns.CFRelease(q);
        return fns.SecItemDelete(q);
    }

    pub fn defaultsGet(_: *const @This(), a: std.mem.Allocator, domain: []const u8, key: []const u8) !?[]u8 {
        const d = str(domain) orelse return null;
        defer fns.CFRelease(d);
        const k = str(key) orelse return null;
        defer fns.CFRelease(k);
        const v = fns.CFPreferencesCopyAppValue(k, d) orelse return null;
        defer fns.CFRelease(v);
        if (fns.CFGetTypeID(v) != fns.CFStringGetTypeID()) return null;
        const cap = fns.CFStringGetMaximumSizeForEncoding(fns.CFStringGetLength(v), utf8) + 1;
        const buf = try a.alloc(u8, @intCast(cap));
        if (fns.CFStringGetCString(v, buf.ptr, cap, utf8) == 0) return null;
        return buf[0..std.mem.indexOfScalar(u8, buf, 0).?];
    }

    /// Writes a string value, or removes the key for null.
    pub fn defaultsSet(_: *const @This(), domain: []const u8, key: []const u8, v: ?[]const u8) bool {
        const d = str(domain) orelse return false;
        defer fns.CFRelease(d);
        const k = str(key) orelse return false;
        defer fns.CFRelease(k);
        const sv: ?Ref = if (v) |x| str(x) orelse return false else null;
        defer if (sv) |x| fns.CFRelease(x);
        fns.CFPreferencesSetAppValue(k, sv, d);
        return fns.CFPreferencesAppSynchronize(d) != 0;
    }
} else struct {};
