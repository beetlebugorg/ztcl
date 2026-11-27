//! The optional `ztcl::win::credential` command: the generic credentials
//! of the Credential Manager of Windows (capability `credential`, part of
//! ztcl#111), the peer of `ztcl::mac::keychain`.
//!
//!     ztcl::win::credential get service account
//!     ztcl::win::credential set service account secret
//!     ztcl::win::credential delete service account
//!
//! An item is a generic credential (`CRED_TYPE_GENERIC`) of the user,
//! with the target name `service/account` and the user name `account`,
//! kept on this computer (`CRED_PERSIST_LOCAL_MACHINE`). The secret is
//! the UTF-8 of the text, at most 2,560 bytes. `set` replaces an item
//! that exists, and `delete` of a missing item is no error. A service
//! has no `/`.
//!
//! The command reaches only the services of `Interp.credential_allow`,
//! with the same case. An empty list reaches no service. On another
//! platform the command checks its arguments and its list, then gives
//! `ZTCL WIN UNAVAILABLE`.
//!
//! The structure follows `wincred.h` of the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const on_win = builtin.os.tag == .windows;

/// CREDENTIALW: 80 bytes on x64.
pub const CREDENTIALW = extern struct {
    Flags: u32 = 0,
    Type: u32 = 1, // CRED_TYPE_GENERIC
    TargetName: [*:0]const u16,
    Comment: ?[*:0]const u16 = null,
    LastWritten: u64 = 0,
    CredentialBlobSize: u32 = 0,
    CredentialBlob: ?[*]const u8 = null,
    Persist: u32 = 2, // CRED_PERSIST_LOCAL_MACHINE
    AttributeCount: u32 = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?[*:0]const u16 = null,
    UserName: ?[*:0]const u16 = null,
};

/// CRED_MAX_CREDENTIAL_BLOB_SIZE.
pub const max_secret = 5 * 512;
const ERROR_NOT_FOUND: u32 = 1168;

extern "advapi32" fn CredReadW(target: [*:0]const u16, kind: u32, flags: u32, out: *?*CREDENTIALW) callconv(.winapi) i32;
extern "advapi32" fn CredWriteW(cred: *const CREDENTIALW, flags: u32) callconv(.winapi) i32;
extern "advapi32" fn CredDeleteW(target: [*:0]const u16, kind: u32, flags: u32) callconv(.winapi) i32;
extern "advapi32" fn CredFree(p: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::win::credential", cmdCredential);
}

/// The target name of an item: `service/account`.
pub fn targetName(a: std.mem.Allocator, service: []const u8, account: []const u8) ![:0]u16 {
    const t = try std.fmt.allocPrint(a, "{s}/{s}", .{ service, account });
    defer a.free(t);
    return std.unicode.utf8ToUtf16LeAllocZ(a, t);
}

/// The structure of `set` for an item, with its strings in memory of the
/// caller.
pub fn credentialOf(target: [*:0]const u16, user: [*:0]const u16, secret: []const u8) CREDENTIALW {
    return .{ .TargetName = target, .UserName = user, .CredentialBlobSize = @intCast(secret.len), .CredentialBlob = secret.ptr };
}

fn credError(it: *Interp, code: u32) Error {
    return it.failCode(try std.fmt.allocPrint(it.alloc(), "ZTCL WIN CREDENTIAL {d}", .{code}), "the credential store gave the error {d}", .{code});
}

fn cmdCredential(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    const usage = "ztcl::win::credential get|set|delete service account ?secret?";
    if (args.len < 4) return it.wrongArgs(usage);
    const sub = try it.str(args[1]);
    const service = try it.str(args[2]);
    const account = try it.str(args[3]);
    const set = std.mem.eql(u8, sub, "set");
    if (!set and !std.mem.eql(u8, sub, "get") and !std.mem.eql(u8, sub, "delete"))
        return it.fail("bad option \"{s}\": must be delete, get, or set", .{sub});
    if (args.len != @as(usize, if (set) 5 else 4)) return it.wrongArgs(usage);
    if (service.len == 0 or std.mem.indexOfScalar(u8, service, '/') != null)
        return it.fail("a service is a name with no \"/\"", .{});
    if (!@import("mac.zig").allowed(it.credential_allow, service))
        return it.failCode("ZTCL WIN DENIED", "the credential service \"{s}\" is not in the allow list", .{service});
    const secret = if (set) try it.str(args[4]) else "";
    if (secret.len > max_secret) return it.failCode("ZTCL WIN LENGTH", "a secret has at most {d} bytes", .{max_secret});
    if (comptime !on_win) return it.failCode("ZTCL WIN UNAVAILABLE", "ztcl::win::credential is only on Windows", .{});
    const a = it.alloc();
    const target = targetName(a, service, account) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return it.fail("a service and an account are UTF-8", .{}),
    };
    if (set) {
        const user = std.unicode.utf8ToUtf16LeAllocZ(a, account) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return it.fail("an account is UTF-8", .{}),
        };
        const c = credentialOf(target.ptr, user.ptr, secret);
        if (CredWriteW(&c, 0) == 0) return credError(it, GetLastError());
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        if (CredDeleteW(target.ptr, 1, 0) == 0) {
            const e = GetLastError();
            if (e != ERROR_NOT_FOUND) return credError(it, e);
        }
        return .{ .str = "" };
    }
    var got: ?*CREDENTIALW = null;
    if (CredReadW(target.ptr, 1, 0, &got) == 0) {
        const e = GetLastError();
        if (e == ERROR_NOT_FOUND) return it.failCode("ZTCL WIN NOTFOUND", "no credential for \"{s}\" and \"{s}\"", .{ service, account });
        return credError(it, e);
    }
    defer CredFree(got.?);
    const c = got.?;
    const bytes = if (c.CredentialBlob) |b| b[0..c.CredentialBlobSize] else "";
    return .{ .str = try a.dupe(u8, bytes) };
}
