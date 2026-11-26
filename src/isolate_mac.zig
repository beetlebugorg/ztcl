//! The sandbox of the `process` level of isolated threads on macOS
//! (ztcl#209, `docs/dev/isolation.md`).
//!
//! macOS starts no process in a sandbox profile, so the child enters
//! its sandbox itself with `sandbox_init`, after the handshake and the
//! start frame and before the first script runs. A descriptor that is
//! open before the call stays usable, so the socket pair to the parent
//! works, and each new open, connect, and start of a program goes
//! through the profile:
//!
//! - files: the root folder of the jail (its real path), or every file
//!   in host mode, or none without the `file` capability. The zone data
//!   for `clock`, and `/dev/null` and `/dev/urandom`, for reading.
//! - the network: only with the `socket` capability. The policy of
//!   `socket` (`Interp.net`) still applies inside the child.
//! - no `fork`, no `exec`, and no Mach service.
//!
//! The parent watches the memory of the child: macOS does not reliably
//! enforce `RLIMIT_AS`, so `footprint` reads the physical footprint of
//! the child (`proc_pid_rusage`), and the parent ends a child past its
//! limit. The child sets `RLIMIT_CORE` to 0.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const c = std.c;

extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn sandbox_free_error(errorbuf: [*:0]u8) void;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;

pub const Options = struct {
    /// The real path of the root folder, or null.
    root: ?[]const u8 = null,
    /// Host mode: every file of the user.
    host_files: bool = false,
    /// The `socket` capability.
    net: bool = false,
    /// The `clock` capability: the zone data.
    zones: bool = false,
};

/// Writes the profile of `o` in SBPL, the profile language of the
/// sandbox of macOS. A path goes in a string with its quotes and
/// backslashes escaped.
pub fn profile(a: std.mem.Allocator, o: Options) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a,
        \\(version 1)
        \\(deny default)
        \\(allow sysctl-read)
        \\(allow signal (target self))
        \\(allow file-read* (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
        \\(allow file-write-data (literal "/dev/null"))
        \\
    );
    if (o.host_files) {
        try out.appendSlice(a, "(allow file-read* file-write*)\n");
    } else if (o.root) |r| {
        try out.appendSlice(a, "(allow file-read* file-write* (subpath ");
        try quoted(a, &out, r);
        try out.appendSlice(a, "))\n");
    }
    if (o.zones) {
        try out.appendSlice(a,
            \\(allow file-read* (subpath "/usr/share/zoneinfo") (subpath "/private/var/db/timezone"))
            \\(allow file-read-metadata (literal "/usr") (literal "/usr/share") (literal "/var") (literal "/private") (literal "/private/var") (literal "/private/var/db"))
            \\
        );
    }
    if (o.net) try out.appendSlice(a, "(allow network*)\n");
    return out.toOwnedSliceSentinel(a, 0);
}

fn quoted(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try out.append(a, '\\');
        try out.append(a, ch);
    }
    try out.append(a, '"');
}

/// Enters the sandbox of `o`. It cannot be left.
pub fn enter(a: std.mem.Allocator, o: Options) !void {
    const p = try profile(a, o);
    defer a.free(p);
    var err: ?[*:0]u8 = null;
    if (sandbox_init(p.ptr, 0, &err) != 0) {
        if (err) |e| sandbox_free_error(e);
        return error.Sandbox;
    }
    const zero: c.rlimit = .{ .cur = 0, .max = 0 };
    _ = c.setrlimit(.CORE, &zero);
}

/// The real path of an open folder (`F_GETPATH`), or null.
pub fn realPath(a: std.mem.Allocator, fd: i32) ?[]u8 {
    var buf: [1024]u8 = @splat(0);
    if (c.fcntl(fd, 50, &buf) < 0) return null;
    return a.dupe(u8, std.mem.sliceTo(&buf, 0)) catch null;
}

/// The physical footprint of the process `pid` in bytes, or null.
pub fn footprint(pid: i32) ?u64 {
    // RUSAGE_INFO_V2: the uuid (16 bytes) and seven 8-byte counts come
    // before `ri_phys_footprint`.
    var buf: [512]u8 align(8) = undefined;
    if (proc_pid_rusage(pid, 2, &buf) != 0) return null;
    return std.mem.readInt(u64, buf[72..80], .little);
}

test "isolate_mac: the profile of a root folder, the zones, and the network" {
    const a = std.testing.allocator;
    const p = try profile(a, .{ .root = "/tmp/a \"b\"", .zones = true });
    defer a.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "(subpath \"/tmp/a \\\"b\\\"\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "zoneinfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "network") == null);
    try std.testing.expect(std.mem.indexOf(u8, p, "process-exec") == null);
    const q = try profile(a, .{ .net = true });
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "(allow network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "subpath") == null);
}

test "isolate_mac: the footprint of this process" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const f = footprint(c.getpid()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(f > 1 << 20);
}

test "isolate_mac: the sandbox denies files outside the root and new programs" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [1024]u8 = @splat(0);
    if (c.fcntl(tmp.dir.handle, 50, &path_buf) < 0) return error.TestUnexpectedResult;
    const root = std.mem.sliceTo(&path_buf, 0);
    const inside = try std.fmt.allocPrintSentinel(a, "{s}/in.txt", .{root}, 0);
    defer a.free(inside);
    const pid = c.fork();
    if (pid == 0) {
        // The child: each failed check exits with its own code.
        enter(std.heap.c_allocator, .{ .root = root }) catch c._exit(10);
        const fd = c.open(inside.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
        if (fd < 0) c._exit(11);
        if (c.open("/etc/hosts", .{ .ACCMODE = .RDONLY }) >= 0) c._exit(12);
        var child: c.pid_t = 0;
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/true", null };
        const env = [_:null]?[*:0]const u8{null};
        if (posix_spawn(&child, "/usr/bin/true", null, null, &argv, &env) == 0) c._exit(13);
        c._exit(0);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    try std.testing.expectEqual(@as(c_int, 0), status);
}

extern "c" fn posix_spawn(pid: *c.pid_t, path: [*:0]const u8, actions: ?*const anyopaque, attrs: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
