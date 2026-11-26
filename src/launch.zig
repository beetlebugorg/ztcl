//! The optional `ztcl::open` command (capability `launch`): a URL or a
//! file in the default app of the host.
//!
//! WARNING: the app runs outside the root folder and outside each limit
//! of the interpreter, with the power of the user. It is not sandboxed.
//!
//! A URL needs the scheme `http`, `https`, or `mailto`, and has no
//! control character. A file also needs `file`: the path goes through
//! `fsroot`, so the jail and host mode apply. On Windows the command
//! opens the file and asks the system for the final path of the handle
//! (`GetFinalPathNameByHandleW`), so the app gets the file that the
//! check saw. A file of a type that Windows runs as code (`.exe`,
//! `.bat`, `.lnk`, and the others of `blocked`) is an error, and so is
//! a path to a named stream (`a.txt:s`).
//!
//! Windows opens the target with `ShellExecuteExW` and the verb `open`,
//! with COM on the thread as the shell asks. An embedder can give
//! `Interp.launch_host`, which gets each target in place of the system,
//! as the tests do.
//!
//! macOS runs `/usr/bin/open`, the program of LaunchServices, with the
//! URL or the full path, and waits for its exit status. The full path of
//! a file in the jail comes from `F_GETPATH` on a descriptor of the file,
//! so the app gets the file that the check saw. An app bundle, a file
//! that macOS runs as code (`.command`, `.pkg`, and the others of
//! `blocked_mac`), and a file with an execute bit are errors. Linux has
//! no backend yet: with no `launch_host`, the command gives the error
//! `ZTCL OPEN UNAVAILABLE`.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const on_win = builtin.os.tag == .windows;
const on_mac = builtin.os.tag == .macos;

/// The callback of an embedder. It opens the target (a URL, or the full
/// host path of a file) and gives false on a failure.
pub const Host = struct {
    ctx: ?*anyopaque = null,
    open: *const fn (ctx: ?*anyopaque, target: []const u8) bool,
};

const schemes = [_][]const u8{ "http", "https", "mailto" };

/// The extensions of the file types that Windows runs as code, or that
/// point at another program.
const blocked = [_][]const u8{
    "exe",               "com",       "bat",                "cmd",         "scr",           "pif",
    "lnk",               "url",       "msi",                "msp",         "mst",           "msc",
    "cpl",               "hta",       "js",                 "jse",         "vbs",           "vbe",
    "vb",                "wsf",       "wsh",                "ws",          "wsc",           "sct",
    "ps1",               "psm1",      "psd1",               "ps1xml",      "psc1",          "reg",
    "inf",               "jar",       "appref-ms",          "application", "gadget",        "scf",
    "settingcontent-ms", "chm",       "appx",               "appxbundle",  "msix",          "msixbundle",
    "library-ms",        "search-ms", "searchconnector-ms", "diagcab",     "xll",           "xbap",
    "website",           "shb",       "shs",                "job",         "mof",           "dll",
    "ocx",               "sys",       "drv",                "cab",         "py",            "pyw",
    "pl",                "rb",        "theme",              "themepack",   "deskthemepack", "iso",
    "img",               "vhd",       "vhdx",
};

/// The extensions of the files and the bundles that macOS runs as code,
/// or that point at another program or place.
const blocked_mac = [_][]const u8{
    "app",  "command", "tool",        "terminal",  "workflow", "action",       "pkg",     "mpkg",
    "scpt", "scptd",   "applescript", "jar",       "webloc",   "inetloc",      "fileloc", "prefpane",
    "kext", "plugin",  "bundle",      "framework", "sh",       "zsh",          "bash",    "csh",
    "py",   "pl",      "rb",          "osax",      "saver",    "mobileconfig", "dylib",   "xpc",
};

fn blockedMac(full: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, full, "/");
    const base = trimmed[(std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return false) + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    for (blocked_mac) |b| if (std.ascii.eqlIgnoreCase(base[dot + 1 ..], b)) return true;
    return false;
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::open", cmdOpen);
}

fn cmdOpen(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    if (args.len != 2) return it.wrongArgs("ztcl::open url-or-path");
    const t = try it.str(args[1]);
    const target = if (schemeOf(t)) |s| blk: {
        if (!known(s)) return it.failCode("ZTCL OPEN SCHEME", "ztcl::open does not open URLs with the scheme \"{s}\"", .{s});
        for (t) |c| if (c < 0x20 or c == 0x7f) return it.failCode("ZTCL OPEN URL", "a URL with a control character", .{});
        break :blk t;
    } else try filePath(it, t);
    if (it.launch_host) |h| {
        if (!h.open(h.ctx, target)) return failed(it, t);
        return .{ .str = "" };
    }
    if (comptime on_mac) {
        if (!mac.open(it.alloc(), target)) return failed(it, t);
        return .{ .str = "" };
    }
    if (comptime !on_win) return unavailable(it);
    if (!(try win.shellOpen(it.alloc(), target))) return failed(it, t);
    return .{ .str = "" };
}

fn failed(it: *Interp, t: []const u8) Error {
    return it.failCode("ZTCL OPEN FAILED", "could not open \"{s}\" in its default app", .{t});
}

fn unavailable(it: *Interp) Error {
    const name = switch (builtin.os.tag) {
        .macos => "macOS",
        .linux => "Linux",
        else => "this platform",
    };
    return it.failCode("ZTCL OPEN UNAVAILABLE", "ztcl::open is not available on {s} yet", .{name});
}

/// The scheme of a URL, or null for a path. A scheme has two or more
/// characters, so `C:` is a drive.
pub fn schemeOf(t: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
    if (colon < 2 or !std.ascii.isAlphabetic(t[0])) return null;
    for (t[1..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return t[0..colon];
}

fn known(s: []const u8) bool {
    for (schemes) |k| if (std.ascii.eqlIgnoreCase(s, k)) return true;
    return false;
}

/// True when the name ends in an extension of `blocked`.
pub fn isBlocked(name: []const u8) bool {
    const base = name[(std.mem.lastIndexOfAny(u8, name, "/\\") orelse return blockedExt(name)) + 1 ..];
    return blockedExt(base);
}

fn blockedExt(base: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot + 1 ..];
    for (blocked) |b| if (std.ascii.eqlIgnoreCase(ext, b)) return true;
    return false;
}

/// The full host path of a file for the app.
fn filePath(it: *Interp, path: []const u8) Error![]const u8 {
    if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok())
        return it.failCode("ZTCL OPEN NOFILE", "ztcl::open of a file needs the file capability", .{});
    const rel = try fsroot.need(it, path);
    const full = if (comptime on_win) try win.finalPath(it, rel, path) else if (comptime on_mac) try mac.finalPath(it, rel, path) else if (it.fs.host) rel else return unavailable(it);
    if (comptime on_win) {
        // A named stream: a colon after the drive.
        const start: usize = if (full.len >= 2 and full[1] == ':') 2 else 0;
        if (std.mem.indexOfScalar(u8, full[start..], ':') != null) return it.failCode("ZTCL OPEN BLOCKED", "ztcl::open does not open the file \"{s}\"", .{path});
        if (isBlocked(full)) return it.failCode("ZTCL OPEN BLOCKED", "ztcl::open does not open the file \"{s}\": the system runs it as a program", .{path});
    }
    return full;
}

pub const mac = if (on_mac) struct {
    const c = std.c;
    /// F_GETPATH of fcntl on macOS, and MAXPATHLEN.
    const f_getpath = 50;
    const max_path = 1024;

    /// Runs `/usr/bin/open target` and gives true for an exit status of 0.
    pub fn open(a: std.mem.Allocator, target: []const u8) bool {
        const arg = a.dupeSentinel(u8, target, 0) catch return false;
        defer a.free(arg);
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/open", arg.ptr };
        const envp = [_:null]?[*:0]const u8{};
        // The messages of `open` go to /dev/null: the exit status has the answer.
        var actions: c.posix_spawn_file_actions_t = undefined;
        if (c.posix_spawn_file_actions_init(&actions) != 0) return false;
        defer _ = c.posix_spawn_file_actions_destroy(&actions);
        const null_flags: c_int = @bitCast(c.O{ .ACCMODE = .WRONLY });
        if (c.posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", null_flags, 0) != 0) return false;
        if (c.posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", null_flags, 0) != 0) return false;
        var pid: c.pid_t = 0;
        if (c.posix_spawn(&pid, "/usr/bin/open", &actions, null, @ptrCast(&argv), @ptrCast(&envp)) != 0) return false;
        var status: c_int = 0;
        while (c.waitpid(pid, &status, 0) < 0) {
            if (@as(c.E, @fromBackingInt(@intCast(c._errno().*))) != .INTR) return false;
        }
        return status == 0;
    }

    /// The full host path of a file that the jail allows, from its
    /// descriptor. A bundle or a file that macOS runs is an error.
    pub fn finalPath(it: *Interp, rel: []const u8, shown: []const u8) Error![]const u8 {
        var r = try fsroot.openRel(it, rel, .{}, 0);
        if (r == .err and r.err == .ISDIR) r = try fsroot.openRel(it, rel, .{ .directory = true }, 0);
        const fd = switch (r) {
            .fd => |fd| fd,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't open \"{s}\": ", .{shown})),
        };
        defer sys.close(fd);
        var buf: [max_path]u8 = @splat(0);
        if (c.fcntl(fd, f_getpath, &buf) < 0) return it.failCode("ZTCL OPEN PATH", "ztcl::open has no host path for \"{s}\"", .{shown});
        const full = std.mem.sliceTo(&buf, 0);
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return it.failCode("ZTCL OPEN PATH", "ztcl::open has no host path for \"{s}\"", .{shown});
        const is_file = st.mode & c.S.IFMT == c.S.IFREG;
        if (blockedMac(full) or (is_file and st.mode & 0o111 != 0))
            return it.failCode("ZTCL OPEN BLOCKED", "ztcl::open does not open the file \"{s}\": the system runs it as a program", .{shown});
        return try it.alloc().dupe(u8, full);
    }
} else struct {};

pub const win = if (on_win) struct {
    const HANDLE = *anyopaque;
    const SHELLEXECUTEINFOW = extern struct {
        cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
        fMask: u32 = 0,
        hwnd: ?*anyopaque = null,
        lpVerb: ?[*:0]const u16 = null,
        lpFile: ?[*:0]const u16 = null,
        lpParameters: ?[*:0]const u16 = null,
        lpDirectory: ?[*:0]const u16 = null,
        nShow: i32 = 1,
        hInstApp: ?*anyopaque = null,
        lpIDList: ?*anyopaque = null,
        lpClass: ?[*:0]const u16 = null,
        hkeyClass: ?*anyopaque = null,
        dwHotKey: u32 = 0,
        hIcon: ?*anyopaque = null,
        hProcess: ?*anyopaque = null,
    };
    const SEE_MASK_NOASYNC = 0x100;
    const SEE_MASK_FLAG_NO_UI = 0x400;
    extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) i32;
    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]u16, len: u32, flags: u32) callconv(.winapi) u32;

    comptime {
        if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(SHELLEXECUTEINFOW) == 112);
    }

    /// Opens a URL or a full path with the verb `open`. Gives false when
    /// the shell fails.
    pub fn shellOpen(a: std.mem.Allocator, target: []const u8) !bool {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(a, target) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer a.free(wide);
        if (target.len > 2 and target[1] == ':') {
            for (wide) |*c| if (c.* == '/') {
                c.* = '\\';
            };
        }
        // COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE. S_OK and
        // S_FALSE need an uninit; a thread in another mode keeps it.
        const hr = CoInitializeEx(null, 0x2 | 0x4);
        defer if (hr == 0 or hr == 1) CoUninitialize();
        var info: SHELLEXECUTEINFOW = .{
            .fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
            .lpVerb = std.unicode.utf8ToUtf16LeStringLiteral("open"),
            .lpFile = wide.ptr,
        };
        return ShellExecuteExW(&info) != 0;
    }

    /// The final host path of a normal path, with `/` between the parts:
    /// `C:/a/b` or `//server/share/a`.
    pub fn finalPath(it: *Interp, rel: []const u8, shown: []const u8) Error![]const u8 {
        var r = try fsroot.openRel(it, rel, .{}, 0);
        if (r == .err and r.err == .ISDIR) r = try fsroot.openRel(it, rel, .{ .directory = true }, 0);
        const fd = switch (r) {
            .fd => |fd| fd,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't open \"{s}\": ", .{shown})),
        };
        defer sys.close(fd);
        const h: HANDLE = @ptrFromInt(@as(usize, @intCast(fd)));
        const a = it.alloc();
        const buf = try a.alloc(u16, 32768);
        defer a.free(buf);
        const n = GetFinalPathNameByHandleW(h, buf.ptr, @intCast(buf.len), 0);
        if (n == 0 or n >= buf.len) return it.failCode("ZTCL OPEN PATH", "ztcl::open has no host path for \"{s}\"", .{shown});
        var w = buf[0..n];
        const unc = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
        const local = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
        var lead: []const u8 = "";
        if (std.mem.startsWith(u16, w, unc)) {
            w = w[unc.len..];
            lead = "//";
        } else if (std.mem.startsWith(u16, w, local)) {
            w = w[local.len..];
        }
        const text = std.unicode.utf16LeToUtf8Alloc(a, w) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return it.failCode("ZTCL OPEN PATH", "ztcl::open has no host path for \"{s}\"", .{shown}),
        };
        const out = try std.mem.concat(a, u8, &.{ lead, text });
        for (out) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        return out;
    }
} else struct {};
