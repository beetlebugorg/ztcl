//! The optional `exec` command, `pid`, and command pipelines on Windows
//! (capability `exec`). The plan is `docs/dev/exec-windows.md`. The
//! other platforms use `proc.zig`, and this file has the same public
//! names.
//!
//! WARNING: a process is outside the root folder of `file` and outside
//! each limit of the interpreter. A script with `exec` has the full
//! power of the user that runs the embedder. This capability is not
//! sandboxed.
//!
//! The words follow the rules of `proc.zig`: `|` and `|&` separate the
//! programs, the `<`, `<<`, `<@`, `>`, `>>`, `2>`, `>&`, `>@`, `2>@`,
//! and `2>@1` forms redirect, and a last word `&` runs the pipeline in
//! the background.
//!
//! `resolve` gives each program one full host path before any process
//! starts. A bare name goes through each folder of the `PATH` of
//! `exec_host.env` (or the system folder) with each extension of its
//! `PATHEXT` (or `.COM;.EXE`), and each folder must be a full path. The
//! path of an open of the file comes from `GetFinalPathNameByHandleW`,
//! so links and junctions are resolved. The allowlist compares that
//! path with no regard to case, and the child runs only that path. A
//! `.bat` or `.cmd` file is refused: `cmd.exe` runs it and reads its
//! arguments with its own rules, so an argument can hold a command. A
//! file below the root folder runs only when `allow_root` names it.
//!
//! The command line of each program follows the rules of the C runtime
//! of Microsoft: an argument with a space, a tab, or a quote goes in
//! quotes, a quote gets a backslash, and the backslashes before a quote
//! double. The environment block is `exec_host.env` in UTF-16, sorted
//! by name with no regard to case. `CreateProcessW` gets the attribute
//! `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, so a child inherits its three
//! standard handles and no other handle, and `CREATE_SUSPENDED`, so the
//! child joins the Job Object of its pipeline before it runs. With no
//! console in the parent, a child has `CREATE_NO_WINDOW`, so no console
//! window opens.
//!
//! Each pipeline is one Job Object with
//! `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Each process that a child
//! starts is in the job too. The kill of a tree is `TerminateJobObject`
//! with the code 137, and a process with that code after a kill is
//! `CHILDKILLED pid SIGKILL`. The error output and the text of `<<` use
//! a temporary file with `FILE_FLAG_DELETE_ON_CLOSE`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

/// Windows with the channels of `sys.zig`: x86-64.
pub const supported = builtin.os.tag == .windows and sys.supported;

const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;

const SECURITY_ATTRIBUTES = extern struct { nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES), lpSecurityDescriptor: ?*anyopaque = null, bInheritHandle: BOOL = 0 };
const STARTUPINFOW = extern struct {
    cb: DWORD = 0,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const STARTUPINFOEXW = extern struct { info: STARTUPINFOW, attrs: ?*anyopaque };
const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: DWORD, dwThreadId: DWORD };
const BASIC_LIMIT = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};
const EXTENDED_LIMIT = extern struct {
    basic: BASIC_LIMIT = .{},
    io: [6]u64 = @splat(0),
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};
const ACCOUNTING = extern struct {
    TotalUserTime: i64 = 0,
    TotalKernelTime: i64 = 0,
    ThisPeriodTotalUserTime: i64 = 0,
    ThisPeriodTotalKernelTime: i64 = 0,
    TotalPageFaultCount: DWORD = 0,
    TotalProcesses: DWORD = 0,
    ActiveProcesses: DWORD = 0,
    TotalTerminatedProcesses: DWORD = 0,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(STARTUPINFOW) == 104);
        std.debug.assert(@sizeOf(STARTUPINFOEXW) == 112);
        std.debug.assert(@sizeOf(EXTENDED_LIMIT) == 144);
        std.debug.assert(@sizeOf(ACCOUNTING) == 48);
    }
}

extern "kernel32" fn CreatePipe(r: *HANDLE, w: *HANDLE, sa: ?*SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOEXW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attr: usize, val: *const anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateJobObjectW(sa: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, len: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn QueryInformationJobObject(job: HANDLE, class: c_int, info: *anyopaque, len: DWORD, ret: ?*DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, proc: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(job: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(proc: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disp: DWORD, flags: DWORD, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]u16, len: DWORD, flags: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetTempPathW(len: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetTempFileNameW(dir: [*:0]const u16, prefix: [*:0]const u16, unique: u32, out: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

const invalid: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const HANDLE_FLAG_INHERIT = 0x1;
const CREATE_SUSPENDED = 0x4;
const CREATE_UNICODE_ENVIRONMENT = 0x400;
const EXTENDED_STARTUPINFO_PRESENT = 0x80000;
const CREATE_NO_WINDOW = 0x08000000;
const STARTF_USESTDHANDLES = 0x100;
const PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x20002;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
const generic_read = 0x80000000;
const generic_write = 0x40000000;
const share_all = 0x7;
const open_existing = 3;
const create_always = 2;
const file_flag_backup_semantics = 0x02000000;
const file_flag_delete_on_close = 0x04000000;
const file_attribute_temporary = 0x100;
const file_attribute_directory = 0x10;
const invalid_attributes = 0xffffffff;
/// The exit code of a process that the kill of its tree ended.
const kill_code: u32 = 137;

pub const Host = struct {
    /// The host programs that a script can run. An entry with no `/`,
    /// `\`, or `:` is a bare name: the word of the script must be that
    /// name, with no regard to case. Another entry is a full host path,
    /// and it matches each word that resolves to the same file. Null
    /// allows each host program. No entry matches a file below the root
    /// folder.
    allow: ?[]const []const u8 = null,
    /// The files below the root folder that a script can run, as full
    /// paths of the script, for example `/tool.exe`.
    allow_root: []const []const u8 = &.{},
    /// The longest run time of a pipeline in milliseconds. 0 is no limit.
    timeout_ms: u32 = 0,
    /// The environment of each program: `NAME=value` strings. A program
    /// of Windows often needs `SystemRoot`.
    env: []const [:0]const u8 = &.{},
};

pub const State = struct {
    /// The trees of the pipelines that can still have a process.
    groups: std.ArrayList(Group) = .empty,
};

const Group = struct { tree: Tree, pids: []const i32, start: i64 };

/// The process tree of one pipeline: its Job Object and the handle of
/// each program, in the order of `pids`.
pub const Tree = struct {
    job: ?HANDLE = null,
    procs: []const HANDLE = &.{},
    /// True after a kill, so the code 137 is a kill.
    killed: bool = false,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

pub fn sleepMs(ms: i32) void {
    Sleep(@intCast(@max(0, ms)));
}

pub fn posix(it: *Interp, e: sys.Errno, what: []const u8) Error {
    const f = sys.win.failOf(e);
    const code = try std.fmt.allocPrint(it.alloc(), "POSIX {s} {{{s}}}", .{ f.name, f.text });
    return it.failCode(code, "{s}{s}", .{ what, f.text });
}

fn lastErrno() sys.Errno {
    return @fromBackingInt(GetLastError());
}

fn denied(it: *Interp, word: []const u8, why: []const u8) Error {
    return it.failCode("ZTCL EXEC DENIED", "couldn't execute \"{s}\": {s}", .{ word, why });
}

pub fn cannotRun(it: *Interp, word: []const u8, e: sys.Errno) Error {
    return posix(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't execute \"{s}\": ", .{word}));
}

const One = struct {
    words: std.ArrayList([]const u8) = .empty,
    /// True when the error output goes to the next program too.
    err_too: bool = false,
};

const Target = union(enum) {
    none,
    /// A handle that the parent keeps.
    fd: i32,
    /// A handle that the parent closes after the start.
    owned: i32,
    /// The standard output of the same program (`2>@1`).
    to_out,
};

const Plan = struct {
    cmds: std.ArrayList(One) = .empty,
    in: Target = .none,
    out: Target = .none,
    err: Target = .none,
    background: bool = false,
    ignore_err: bool = false,
    keep_newline: bool = false,
};

fn closeTarget(t: Target) void {
    if (t == .owned) sys.close(t.owned);
}

fn closePlan(p: *Plan) void {
    closeTarget(p.in);
    closeTarget(p.out);
    if (p.err == .owned and !(p.out == .owned and p.out.owned == p.err.owned)) closeTarget(p.err);
    p.in = .none;
    p.out = .none;
    p.err = .none;
}

fn handleOf(fd: i32) HANDLE {
    return @ptrFromInt(@as(usize, @intCast(fd)));
}

fn fdOf(it: *Interp, h: HANDLE) Error!i32 {
    return sys.win.fdOfHandle(h) orelse {
        _ = CloseHandle(h);
        return it.fail("a handle of the system is out of the range of a channel", .{});
    };
}

fn wide(a: std.mem.Allocator, s: []const u8) Error![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return std.unicode.wtf8ToWtf16LeAllocZ(a, "") catch error.OutOfMemory,
    };
}

/// A temporary file that the system deletes at its last close, with
/// `text` in it and the offset at its start.
fn memFile(it: *Interp, text: []const u8) Error!i32 {
    var dir: [261]u16 = undefined;
    const n = GetTempPathW(dir.len, &dir);
    if (n == 0 or n >= dir.len) return posix(it, lastErrno(), "couldn't create a temporary file: ");
    dir[n] = 0;
    var name: [261]u16 = undefined;
    if (GetTempFileNameW(dir[0..n :0], std.unicode.utf8ToUtf16LeStringLiteral("ztc"), 0, &name) == 0) return posix(it, lastErrno(), "couldn't create a temporary file: ");
    const h = CreateFileW(@ptrCast(&name), generic_read | generic_write, share_all, null, create_always, file_attribute_temporary | file_flag_delete_on_close, null);
    if (h == invalid) return posix(it, lastErrno(), "couldn't create a temporary file: ");
    const fd = try fdOf(it, h);
    var at: usize = 0;
    while (at < text.len) {
        switch (sys.write(fd, text[at..])) {
            .n => |k| at += k,
            else => break,
        }
    }
    _ = sys.seek(fd, 0, 0);
    return fd;
}

/// A path of the form `~user` is an error: no user lookup exists.
pub fn noTilde(it: *Interp, path: []const u8) Error!void {
    if (path.len < 2 or path[0] != '~' or path[1] == '/') return;
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    return it.fail("user \"{s}\" doesn't exist", .{path[1..end]});
}

fn openFile(it: *Interp, path: []const u8, flags: sys.OpenFlags, what: []const u8) Error!i32 {
    const a = it.alloc();
    try noTilde(it, path);
    const rel: []const u8 = if (it.fs_ok())
        (try fsroot.normal(it, path)) orelse return it.failCode("POSIX EACCES {permission denied}", "couldn't {s} file \"{s}\": permission denied", .{ what, path })
    else
        path;
    const r = if (it.fs_ok()) try fsroot.openRel(it, rel, flags, 0o666) else try @import("fsroot_windows.zig").hostOpen(it, rel, flags, 0o666);
    return switch (r) {
        .fd => |x| x,
        .err => |e| posix(it, e, try std.fmt.allocPrint(a, "couldn't {s} file \"{s}\": ", .{ what, path })),
    };
}

fn chanFd(it: *Interp, name: []const u8, write: bool) Error!i32 {
    const c = chan.lookup(it, name) orelse return it.fail("can not find channel named \"{s}\"", .{name});
    if (write) {
        if (!c.writable) return it.fail("channel \"{s}\" wasn't opened for writing", .{name});
        try chan.flushChannel(it, c);
        return if (c.wfd >= 0) c.wfd else c.fd;
    }
    if (!c.readable) return it.fail("channel \"{s}\" wasn't opened for reading", .{name});
    return c.fd;
}

/// Reads the words of `exec` into a plan. Each redirection opens here.
fn parse(it: *Interp, words: []const []const u8, plan: *Plan) Error!void {
    const a = it.alloc();
    var cur: One = .{};
    var i: usize = 0;
    var n = words.len;
    if (n > 0 and eql(words[n - 1], "&")) {
        plan.background = true;
        n -= 1;
    }
    while (i < n) : (i += 1) {
        const w = words[i];
        if (eql(w, "|") or eql(w, "|&")) {
            if (cur.words.items.len == 0 or i + 1 >= n) return it.fail("illegal use of | or |& in command", .{});
            cur.err_too = w.len == 2;
            try plan.cmds.append(a, cur);
            cur = .{};
            continue;
        }
        // The redirection forms, longest first.
        const forms = [_][]const u8{ "2>@1", "<<", "<@", "<", ">>&", ">&@", "2>>", "2>@", ">>", ">&", ">@", "2>", ">" };
        var form: ?[]const u8 = null;
        for (forms) |f| {
            if (std.mem.startsWith(u8, w, f)) {
                form = f;
                break;
            }
        }
        const f = form orelse {
            try cur.words.append(a, w);
            continue;
        };
        if (eql(f, "2>@1")) {
            if (w.len != 4) return it.fail("must specify \"2>@1\" as last word in command", .{});
            closeTarget(plan.err);
            plan.err = .to_out;
            continue;
        }
        var arg = w[f.len..];
        if (arg.len == 0) {
            i += 1;
            if (i >= n) return it.fail("can't specify \"{s}\" as last word in command", .{w});
            arg = words[i];
        }
        const is_in = f[0] == '<';
        const to_err = f[0] == '2';
        const both = std.mem.indexOfScalar(u8, f, '&') != null;
        var t: Target = undefined;
        if (eql(f, "<<")) {
            t = .{ .owned = try memFile(it, arg) };
        } else if (f[f.len - 1] == '@') {
            t = .{ .fd = try chanFd(it, arg, !is_in) };
        } else if (is_in) {
            t = .{ .owned = try openFile(it, arg, .{}, "read") };
        } else {
            var flags: sys.OpenFlags = .{ .access = .write, .create = true };
            if (std.mem.indexOf(u8, f, ">>") != null) flags.append = true else flags.truncate = true;
            t = .{ .owned = try openFile(it, arg, flags, "write") };
        }
        if (is_in) {
            closeTarget(plan.in);
            plan.in = t;
        } else if (to_err) {
            closeTarget(plan.err);
            plan.err = t;
        } else {
            closeTarget(plan.out);
            plan.out = t;
            if (both) {
                closeTarget(plan.err);
                plan.err = .{ .fd = switch (t) {
                    .fd, .owned => |x| x,
                    else => unreachable,
                } };
            }
        }
    }
    if (cur.words.items.len == 0) return it.fail("illegal use of | or |& in command", .{});
    try plan.cmds.append(a, cur);
}

// ---- The paths of the programs ----

/// True for a full host path: a drive (`C:\`, `C:/`) or a share.
fn isFull(p: []const u8) bool {
    if (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')) return true;
    return p.len >= 2 and (p[0] == '\\' or p[0] == '/') and (p[1] == '\\' or p[1] == '/');
}

fn hasSep(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "/\\:") != null;
}

/// The final path of a file, with `\` between the parts, or null when
/// no file has the path.
fn canonical(a: std.mem.Allocator, path: []const u8) Error!?[]const u8 {
    const w = try wide(a, path);
    const h = CreateFileW(w, 0x80, share_all, null, open_existing, file_flag_backup_semantics, null);
    if (h == invalid) return null;
    defer _ = CloseHandle(h);
    return try finalOf(a, h);
}

fn finalOf(a: std.mem.Allocator, h: HANDLE) Error!?[]const u8 {
    const buf = try a.alloc(u16, 32768);
    const n = GetFinalPathNameByHandleW(h, buf.ptr, @intCast(buf.len), 0);
    if (n == 0 or n >= buf.len) return null;
    var u = buf[0..n];
    const unc = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
    const local = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    var lead: []const u8 = "";
    if (std.mem.startsWith(u16, u, unc)) {
        u = u[unc.len..];
        lead = "\\\\";
    } else if (std.mem.startsWith(u16, u, local)) {
        u = u[local.len..];
    }
    const text = std.unicode.wtf16LeToWtf8Alloc(a, u) catch return error.OutOfMemory;
    return try std.mem.concat(a, u8, &.{ lead, text });
}

fn isFile(a: std.mem.Allocator, path: []const u8) Error!bool {
    const attrs = GetFileAttributesW(try wide(a, path));
    return attrs != invalid_attributes and attrs & file_attribute_directory == 0;
}

fn startsWithFold(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The final path of the root folder, when the jail is on.
fn rootFinal(it: *Interp) Error!?[]const u8 {
    if (it.fs.host or it.fs.fd < 0) return null;
    return switch (try fsroot.openRel(it, "", .{ .directory = true }, 0)) {
        .fd => |fd| blk: {
            defer sys.close(fd);
            break :blk try finalOf(it.alloc(), handleOf(fd));
        },
        .err => null,
    };
}

fn belowRoot(it: *Interp, path: []const u8) Error!bool {
    const root = (try rootFinal(it)) orelse return false;
    return startsWithFold(path, root) and (path.len == root.len or path[root.len] == '\\');
}

/// A file of `allow_root` that the word names, as a full host path.
fn rootProgram(it: *Interp, word: []const u8) Error!?[]const u8 {
    if (it.exec_host.allow_root.len == 0 or it.fs.host or it.fs.fd < 0) return null;
    const rel = (try fsroot.normal(it, word)) orelse return null;
    for (it.exec_host.allow_root) |entry| {
        if (entry.len == 0 or entry[0] != '/') continue;
        const want = (try fsroot.normal(it, entry)) orelse continue;
        if (want.len == 0 or !eql(rel, want)) continue;
        return switch (try fsroot.openRel(it, rel, .{}, 0)) {
            .fd => |fd| blk: {
                defer sys.close(fd);
                break :blk try finalOf(it.alloc(), handleOf(fd));
            },
            .err => |e| cannotRun(it, word, e),
        };
    }
    return null;
}

fn isBatch(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".bat") or std.ascii.endsWithIgnoreCase(path, ".cmd");
}

/// Checks a resolved host program against the root folder, the type,
/// and the allowlist.
fn checked(it: *Interp, word: []const u8, path: []const u8) Error![]const u8 {
    if (try belowRoot(it, path)) return denied(it, word, "the program is in the root folder");
    if (isBatch(path)) return denied(it, word, "a .bat or .cmd file runs through cmd.exe with other rules for its arguments; run cmd.exe /c");
    const list = it.exec_host.allow orelse return path;
    for (list) |ok| {
        if (!hasSep(ok)) {
            if (std.ascii.eqlIgnoreCase(ok, word)) return path;
            continue;
        }
        if (!isFull(ok)) continue;
        if (try canonical(it.alloc(), ok)) |p| if (std.ascii.eqlIgnoreCase(p, path)) return path;
    }
    return denied(it, word, "the embedder does not allow this program");
}

fn envValue(it: *Interp, name: []const u8) ?[]const u8 {
    for (it.exec_host.env) |e| {
        if (e.len > name.len and e[name.len] == '=' and std.ascii.eqlIgnoreCase(e[0..name.len], name)) return e[name.len + 1 ..];
    }
    return null;
}

/// The one full host path that a program word runs. A word with `/`,
/// `\`, or `:` is a host path, or a file of `allow_root`. A bare name
/// goes through the `PATH` of the embedder.
pub fn resolve(it: *Interp, word: []const u8) Error![]const u8 {
    const a = it.alloc();
    if (hasSep(word)) {
        if (try rootProgram(it, word)) |p| return p;
        if (!isFull(word)) return denied(it, word, "a program path must be a full path or a bare name");
        const p = (try canonical(a, word)) orelse return cannotRun(it, word, .NOENT);
        if (!try isFile(a, p)) return cannotRun(it, word, .NOENT);
        return checked(it, word, p);
    }
    var sysdir: [261]u16 = undefined;
    const sn = GetSystemDirectoryW(&sysdir, sysdir.len);
    const path = envValue(it, "PATH") orelse (std.unicode.wtf16LeToWtf8Alloc(a, sysdir[0..@min(sn, sysdir.len)]) catch return error.OutOfMemory);
    const exts_text = envValue(it, "PATHEXT") orelse ".COM;.EXE";
    var exts: std.ArrayList([]const u8) = .empty;
    // A name with an extension of the list runs as it is first.
    var has_ext = false;
    var ex = std.mem.tokenizeScalar(u8, exts_text, ';');
    while (ex.next()) |e| {
        if (std.ascii.endsWithIgnoreCase(word, e)) has_ext = true;
    }
    if (has_ext or std.mem.indexOfScalar(u8, word, '.') != null) try exts.append(a, "");
    ex.reset();
    while (ex.next()) |e| try exts.append(a, e);
    var iter = std.mem.splitScalar(u8, path, ';');
    while (iter.next()) |dir| {
        // A relative entry depends on the working folder.
        if (dir.len > 0 and !isFull(dir)) return it.failCode("ZTCL EXEC PATH", "couldn't execute \"{s}\": the PATH entry \"{s}\" is not a full path", .{ word, dir });
    }
    iter.reset();
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const sep: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') "" else "\\";
        for (exts.items) |e| {
            const p = (try canonical(a, try std.mem.concat(a, u8, &.{ dir, sep, word, e }))) orelse continue;
            if (!try isFile(a, p)) continue;
            return checked(it, word, p);
        }
    }
    return cannotRun(it, word, .NOENT);
}

// ---- The start ----

/// The command line of a program: each argument with the quotes of the
/// C runtime of Microsoft.
pub fn commandLine(a: std.mem.Allocator, words: []const []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, k| {
        if (k > 0) try out.append(a, ' ');
        if (w.len > 0 and std.mem.indexOfAny(u8, w, " \t\n\x0b\"") == null) {
            try out.appendSlice(a, w);
            continue;
        }
        try out.append(a, '"');
        var i: usize = 0;
        while (true) {
            var slashes: usize = 0;
            while (i < w.len and w[i] == '\\') : (i += 1) slashes += 1;
            if (i == w.len) {
                try out.appendNTimes(a, '\\', slashes * 2);
                break;
            }
            if (w[i] == '"') {
                try out.appendNTimes(a, '\\', slashes * 2 + 1);
            } else try out.appendNTimes(a, '\\', slashes);
            try out.append(a, w[i]);
            i += 1;
        }
        try out.append(a, '"');
    }
    return out.items;
}

fn lessName(_: void, x: [:0]const u8, y: [:0]const u8) bool {
    const nx = std.mem.indexOfScalar(u8, x, '=') orelse x.len;
    const ny = std.mem.indexOfScalar(u8, y, '=') orelse y.len;
    return std.ascii.lessThanIgnoreCase(x[0..nx], y[0..ny]);
}

/// The environment block: the strings sorted by name, each with a 0,
/// and one more 0 at the end.
fn envBlock(a: std.mem.Allocator, env: []const [:0]const u8) Error![]u16 {
    const sorted = try a.dupe([:0]const u8, env);
    std.mem.sort([:0]const u8, sorted, {}, lessName);
    var out: std.ArrayList(u16) = .empty;
    for (sorted) |e| {
        try out.appendSlice(a, try wide(a, e));
        try out.append(a, 0);
    }
    if (sorted.len == 0) try out.append(a, 0);
    try out.append(a, 0);
    return out.items;
}

pub fn pipe(it: *Interp) Error![2]i32 {
    var r: HANDLE = undefined;
    var w: HANDLE = undefined;
    if (CreatePipe(&r, &w, null, 0) == 0) return posix(it, lastErrno(), "couldn't create pipe: ");
    const rf = sys.win.fdOfHandle(r) orelse {
        _ = CloseHandle(r);
        _ = CloseHandle(w);
        return it.fail("a handle of the system is out of the range of a channel", .{});
    };
    const wf = sys.win.fdOfHandle(w) orelse {
        _ = CloseHandle(r);
        _ = CloseHandle(w);
        return it.fail("a handle of the system is out of the range of a channel", .{});
    };
    return .{ rf, wf };
}

fn openNull(it: *Interp) Error!HANDLE {
    const h = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), generic_read | generic_write, share_all, null, open_existing, 0, null);
    if (h == invalid) return posix(it, lastErrno(), "couldn't open NUL: ");
    return h;
}

/// A standard handle of the parent, or the NUL device.
fn stdOr(which: DWORD, nul: HANDLE) HANDLE {
    const h = GetStdHandle(which) orelse return nul;
    return if (h == invalid) nul else h;
}

const Started = struct {
    pids: []i32,
    /// The read side of the output of the last program, or -1.
    out: i32 = -1,
    /// The write side of the input of the first program, or -1.
    in: i32 = -1,
    /// The temporary file of the error output, or -1.
    err: i32 = -1,
    start: i64,
    tree: Tree = .{},
    /// True when the time limit ended the pipeline.
    timed_out: bool = false,
};

/// Starts one program in the job with its three handles.
fn spawn(it: *Interp, job: HANDLE, prog: []const u8, words: []const []const u8, env: []u16, cwd: ?[:0]const u16, hin: HANDLE, hout: HANDLE, herr: HANDLE) Error!PROCESS_INFORMATION {
    const a = it.alloc();
    var argv = try a.dupe([]const u8, words);
    argv[0] = prog;
    const line = try wide(a, try commandLine(a, argv));
    // The handle list has no repeat.
    var list: [3]HANDLE = undefined;
    var n: usize = 0;
    for ([_]HANDLE{ hin, hout, herr }) |h| {
        if (std.mem.indexOfScalar(HANDLE, list[0..n], h) == null) {
            list[n] = h;
            n += 1;
        }
    }
    for (list[0..n]) |h| _ = SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    defer for (list[0..n]) |h| {
        _ = SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
    };
    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
    const attrs = try a.alignedAlloc(u8, .@"8", size);
    if (InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &size) == 0) return posix(it, lastErrno(), "couldn't start a process: ");
    defer DeleteProcThreadAttributeList(attrs.ptr);
    if (UpdateProcThreadAttribute(attrs.ptr, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, @ptrCast(&list), n * @sizeOf(HANDLE), null, null) == 0) return posix(it, lastErrno(), "couldn't start a process: ");
    var si: STARTUPINFOEXW = .{ .info = .{ .cb = @sizeOf(STARTUPINFOEXW), .dwFlags = STARTF_USESTDHANDLES, .hStdInput = hin, .hStdOutput = hout, .hStdError = herr }, .attrs = attrs.ptr };
    var pi: PROCESS_INFORMATION = undefined;
    var flags: DWORD = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;
    if (GetConsoleWindow() == null) flags |= CREATE_NO_WINDOW;
    const wprog = try wide(a, prog);
    if (CreateProcessW(wprog.ptr, line.ptr, null, null, 1, flags, env.ptr, if (cwd) |c| c.ptr else null, &si, &pi) == 0) return cannotRun(it, words[0], lastErrno());
    if (AssignProcessToJobObject(job, pi.hProcess) == 0) {
        const e = lastErrno();
        _ = TerminateProcess(pi.hProcess, kill_code);
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
        return posix(it, e, "couldn't put a process in its job: ");
    }
    _ = ResumeThread(pi.hThread);
    _ = CloseHandle(pi.hThread);
    return pi;
}

pub fn treeOpen() Tree {
    const job = CreateJobObjectW(null, null) orelse return .{};
    var info: EXTENDED_LIMIT = .{};
    info.basic.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // JobObjectExtendedLimitInformation
    _ = SetInformationJobObject(job, 9, &info, @sizeOf(EXTENDED_LIMIT));
    return .{ .job = job };
}

pub fn treeKill(t: *Tree, _: []const i32) void {
    t.killed = true;
    if (t.job) |j| _ = TerminateJobObject(j, kill_code);
}

fn treeLive(t: *const Tree) bool {
    const j = t.job orelse return false;
    var acc: ACCOUNTING = .{};
    // JobObjectBasicAccountingInformation
    if (QueryInformationJobObject(j, 1, &acc, @sizeOf(ACCOUNTING), null) == 0) return false;
    return acc.ActiveProcesses > 0;
}

pub fn treeClose(t: *Tree) void {
    for (t.procs) |h| _ = CloseHandle(h);
    t.procs = &.{};
    if (t.job) |j| _ = CloseHandle(j);
    t.job = null;
}

/// The exit code of a process, or null while it runs.
fn waitProc(h: HANDLE, ms: DWORD) ?u32 {
    if (WaitForSingleObject(h, ms) != 0) return null;
    var code: DWORD = 0;
    _ = GetExitCodeProcess(h, &code);
    return code;
}

/// Starts the programs of a plan. `want_out` and `want_in` ask for a
/// pipe to the parent when the plan has no redirection.
fn start(it: *Interp, plan: *Plan, want_out: bool, want_in: bool) Error!Started {
    const a = it.alloc();
    const count = plan.cmds.items.len;
    // The checks and the paths come before the first process.
    const progs = try a.alloc([]const u8, count);
    for (plan.cmds.items, 0..) |c, k| {
        const word = c.words.items[0];
        try noTilde(it, word);
        progs[k] = try resolve(it, word);
    }
    const env = try envBlock(a, it.exec_host.env);
    // The working folder: the current folder of `file`.
    var cwd: ?[:0]const u16 = null;
    if (it.fs_ok()) {
        switch (try fsroot.openRel(it, it.fs.cwd, .{ .directory = true }, 0)) {
            .fd => |fd| {
                defer sys.close(fd);
                if (try finalOf(a, handleOf(fd))) |p| cwd = try wide(a, p);
            },
            .err => |e| return posix(it, e, "couldn't open the working folder: "),
        }
    }
    const nul = try openNull(it);
    defer _ = CloseHandle(nul);

    var st: Started = .{ .pids = try a.alloc(i32, count), .start = nowMs() };
    const procs = try a.alloc(HANDLE, count);
    var made: usize = 0;
    var first_in: HANDLE = nul;
    switch (plan.in) {
        .fd, .owned => |x| first_in = handleOf(x),
        else => if (want_in) {
            const p = try pipe(it);
            first_in = handleOf(p[0]);
            st.in = p[1];
        },
    }
    var in_child: ?i32 = if (plan.in == .none and want_in) sys.win.fdOfHandle(first_in) else null;
    var last_out: HANDLE = stdOr(@bitCast(@as(i32, -11)), nul);
    var out_child: ?i32 = null;
    switch (plan.out) {
        .fd, .owned => |x| last_out = handleOf(x),
        else => if (want_out) {
            const p = try pipe(it);
            last_out = handleOf(p[1]);
            st.out = p[0];
            out_child = p[1];
        },
    }
    var err_h: ?HANDLE = stdOr(@bitCast(@as(i32, -12)), nul);
    switch (plan.err) {
        .fd, .owned => |x| err_h = handleOf(x),
        .to_out => err_h = null,
        .none => if (!plan.background) {
            st.err = try memFile(it, "");
            err_h = handleOf(st.err);
        },
    }
    st.tree = treeOpen();
    var failure: ?Error = null;
    if (st.tree.job == null) failure = posix(it, lastErrno(), "couldn't create a job object: ");
    var prev_read: ?i32 = null;
    var k: usize = 0;
    while (failure == null and k < count) : (k += 1) {
        var next: ?[2]i32 = null;
        if (k + 1 < count) next = pipe(it) catch |e| {
            failure = e;
            break;
        };
        const hin = if (k == 0) first_in else handleOf(prev_read.?);
        const hout = if (next) |p| handleOf(p[1]) else last_out;
        const one = plan.cmds.items[k];
        // `|&` sends the error output of a program to the next one too.
        const herr = if (one.err_too and next != null) hout else err_h orelse hout;
        const pi = spawn(it, st.tree.job.?, progs[k], one.words.items, env, cwd, hin, hout, herr) catch |e| {
            failure = e;
            if (next) |p| {
                sys.close(p[0]);
                sys.close(p[1]);
            }
            break;
        };
        procs[made] = pi.hProcess;
        st.pids[made] = @intCast(pi.dwProcessId);
        made += 1;
        if (prev_read) |r| sys.close(r);
        prev_read = null;
        if (next) |p| {
            sys.close(p[1]);
            prev_read = p[0];
        }
    }
    if (prev_read) |r| sys.close(r);
    if (in_child) |x| sys.close(x);
    in_child = null;
    if (out_child) |x| sys.close(x);
    closePlan(plan);
    st.pids = st.pids[0..made];
    st.tree.procs = procs[0..made];
    if (failure) |e| {
        const saved = it.result;
        const saved_code = it.error_code;
        treeKill(&st.tree, st.pids);
        for (st.tree.procs) |h| _ = waitProc(h, 0xffffffff);
        treeClose(&st.tree);
        if (st.out >= 0) sys.close(st.out);
        if (st.in >= 0) sys.close(st.in);
        if (st.err >= 0) sys.close(st.err);
        it.result = saved;
        it.error_code = saved_code;
        return e;
    }
    return st;
}

fn settle(it: *Interp, tree: Tree, pids: []const i32, start_ms: i64) Error!void {
    var t = tree;
    if (treeLive(&t)) return it.execs.groups.append(it.alloc(), .{ .tree = t, .pids = pids, .start = start_ms });
    treeClose(&t);
}

fn deadline(it: *Interp, start_ms: i64) ?i64 {
    if (it.exec_host.timeout_ms == 0) return null;
    return start_ms + it.exec_host.timeout_ms;
}

/// The signal of Tcl for an exception code of Windows, or null.
fn signalOf(code: u32) ?struct { []const u8, []const u8 } {
    return switch (code) {
        0xC0000005, 0xC00000FD => .{ "SIGSEGV", "segmentation violation" },
        0xC000001D => .{ "SIGILL", "illegal instruction" },
        0xC0000094, 0xC0000095 => .{ "SIGFPE", "floating-point exception" },
        0xC000013A => .{ "SIGINT", "interrupt" },
        else => null,
    };
}

/// Waits for the processes and builds the error text of Tcl. Gives
/// true when the pipeline failed. `text` gets the error output.
fn finish(it: *Interp, st: *Started, text: *std.ArrayList(u8), ignore_err: bool) Error!bool {
    const a = it.alloc();
    const limit = deadline(it, st.start);
    var failed = false;
    var any_info = false;
    var code: ?[]const u8 = null;
    for (st.tree.procs, st.pids) |h, pid| {
        var status: ?u32 = null;
        while (true) {
            if (limit) |l| {
                const left = l - nowMs();
                if (left <= 0) {
                    st.timed_out = true;
                    treeKill(&st.tree, st.pids);
                    status = waitProc(h, 0xffffffff);
                    break;
                }
                status = waitProc(h, @intCast(@min(left, 100)));
                if (status != null) break;
            } else {
                status = waitProc(h, 0xffffffff);
                break;
            }
        }
        const s = status orelse 0;
        if (st.tree.killed and s == kill_code) {
            failed = true;
            code = try std.fmt.allocPrint(a, "CHILDKILLED {d} SIGKILL {{kill signal}}", .{pid});
            if (st.timed_out) {
                try text.print(a, "child killed: the time limit of {d} ms ended\n", .{it.exec_host.timeout_ms});
            } else try text.appendSlice(a, "child killed: kill signal\n");
            any_info = true;
        } else if (signalOf(s)) |sig| {
            failed = true;
            code = try std.fmt.allocPrint(a, "CHILDKILLED {d} {s} {{{s}}}", .{ pid, sig[0], sig[1] });
            try text.print(a, "child killed: {s}\n", .{sig[1]});
            any_info = true;
        } else if (s != 0) {
            failed = true;
            code = try std.fmt.allocPrint(a, "CHILDSTATUS {d} {d}", .{ pid, s });
        }
    }
    if (st.err >= 0) {
        _ = sys.seek(st.err, 0, 0);
        var buf: [4096]u8 = undefined;
        const before = text.items.len;
        while (true) {
            switch (sys.read(st.err, &buf)) {
                .n => |n| if (n > 0) {
                    if (!ignore_err) try text.appendSlice(a, buf[0..n]);
                    continue;
                },
                else => {},
            }
            break;
        }
        sys.close(st.err);
        st.err = -1;
        if (text.items.len > before) {
            any_info = true;
            failed = true;
        }
    }
    if (failed and !any_info) try text.appendSlice(a, "child process exited abnormally\n");
    if (failed) it.error_code = .{ .str = code orelse "NONE" };
    return failed;
}

fn stripNewline(text: []const u8) []const u8 {
    return if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
}

/// Changes each CR LF of the output of a program to LF, as Tcl does for
/// the output of `exec` on Windows.
fn lines(a: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, text, "\r\n") == null) return text;
    const out = try a.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

fn cmdExec(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const a = it.alloc();
    sweep(it);
    var plan: Plan = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const o = try it.str(argv[i]);
        if (o.len == 0 or o[0] != '-') break;
        if (eql(o, "-ignorestderr")) {
            plan.ignore_err = true;
        } else if (eql(o, "-keepnewline")) {
            plan.keep_newline = true;
        } else if (eql(o, "--")) {
            i += 1;
            break;
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -ignorestderr, -keepnewline, or --", .{o});
    }
    if (i >= argv.len) return it.wrongArgs("exec ?-option ...? arg ?arg ...?");
    const words = try a.alloc([]const u8, argv.len - i);
    for (argv[i..], words) |v, *w| w.* = try it.str(v);
    parse(it, words, &plan) catch |e| {
        closePlan(&plan);
        return e;
    };
    errdefer closePlan(&plan);
    if (plan.background) {
        const st = try start(it, &plan, false, false);
        try it.execs.groups.append(a, .{ .tree = st.tree, .pids = st.pids, .start = st.start });
        var out: std.ArrayList(Value) = .empty;
        for (st.pids) |p| try out.append(a, .{ .int = p });
        return value.wrapList(a, out.items);
    }
    var st = try start(it, &plan, true, false);
    var text: std.ArrayList(u8) = .empty;
    if (st.out >= 0) {
        // The output of the last program, until its end or the limit.
        const limit = deadline(it, st.start);
        var buf: [16384]u8 = undefined;
        if (limit != null) sys.setBlocking(st.out, false);
        while (true) {
            if (limit) |l| {
                if (l - nowMs() <= 0) {
                    treeKill(&st.tree, st.pids);
                    st.timed_out = true;
                    break;
                }
            }
            switch (sys.read(st.out, &buf)) {
                .n => |n| if (n > 0) {
                    try text.appendSlice(a, buf[0..n]);
                    if (!it.overLimit()) continue;
                    treeKill(&st.tree, st.pids);
                },
                .again => {
                    Sleep(5);
                    continue;
                },
                else => {},
            }
            break;
        }
        sys.close(st.out);
    }
    const failed = finish(it, &st, &text, plan.ignore_err) catch |e| {
        try settle(it, st.tree, st.pids, st.start);
        return e;
    };
    try settle(it, st.tree, st.pids, st.start);
    const clean = try lines(a, text.items);
    const res = if (plan.keep_newline) clean else stripNewline(clean);
    if (failed) {
        it.result = .{ .str = res };
        return error.TclError;
    }
    return .{ .str = res };
}

/// `open "|command"`: a channel on a pipeline.
pub fn openPipeline(it: *Interp, command: []const u8, readable: bool, writable: bool) Error!Value {
    const a = it.alloc();
    sweep(it);
    const list = try it.list(.{ .str = command });
    if (list.len == 0) return it.fail("illegal use of | or |& in command", .{});
    const words = try a.alloc([]const u8, list.len);
    for (list, words) |v, *w| w.* = try it.str(v);
    var plan: Plan = .{};
    parse(it, words, &plan) catch |e| {
        closePlan(&plan);
        return e;
    };
    errdefer closePlan(&plan);
    if (plan.background) return it.fail("illegal use of & in a command pipeline", .{});
    if (readable and plan.out != .none) return it.fail("can't read output from command: standard output was redirected", .{});
    if (writable and plan.in != .none) return it.fail("can't write input to command: standard input was redirected", .{});
    const st = try start(it, &plan, readable, writable);
    const c = try chan.adopt(it, "file", if (readable) st.out else st.in, readable, writable);
    c.kind = .pipe;
    if (readable and writable) c.wfd = st.in;
    c.pids = st.pids;
    c.err_fd = st.err;
    c.started = st.start;
    c.tree = st.tree;
    return .{ .str = c.name };
}

/// Waits for the processes of a pipeline channel that closed.
pub fn reap(it: *Interp, c: *chan.Channel) Error!void {
    var text: std.ArrayList(u8) = .empty;
    var st: Started = .{ .pids = @constCast(c.pids), .err = c.err_fd, .start = c.started, .tree = c.tree };
    // A channel that does not block does not wait for its processes.
    if (!c.blocking) {
        try it.execs.groups.append(it.alloc(), .{ .tree = c.tree, .pids = c.pids, .start = c.started });
        if (c.err_fd >= 0) sys.close(c.err_fd);
        return;
    }
    const failed = finish(it, &st, &text, false) catch |e| {
        try settle(it, st.tree, st.pids, st.start);
        return e;
    };
    try settle(it, st.tree, st.pids, st.start);
    if (failed) {
        it.result = .{ .str = stripNewline(try lines(it.alloc(), text.items)) };
        return error.TclError;
    }
}

/// Ends the processes of a pipeline channel with no wait for output.
pub fn abandon(c: *chan.Channel) void {
    treeKill(&c.tree, c.pids);
    for (c.tree.procs) |h| _ = waitProc(h, 0xffffffff);
    treeClose(&c.tree);
    if (c.err_fd >= 0) sys.close(c.err_fd);
}

/// Collects the trees that ended, and kills each tree that is past the
/// time limit.
pub fn sweep(it: *Interp) void {
    var i: usize = 0;
    while (i < it.execs.groups.items.len) {
        const g = &it.execs.groups.items[i];
        const late = if (deadline(it, g.start)) |l| nowMs() >= l else false;
        if (late) treeKill(&g.tree, g.pids);
        var live = false;
        for (g.tree.procs) |h| {
            if (waitProc(h, if (late) 0xffffffff else 0) == null) live = true;
        }
        // A process below the programs keeps the tree live.
        if (!late and treeLive(&g.tree)) live = true;
        if (live) {
            i += 1;
        } else {
            treeClose(&g.tree);
            _ = it.execs.groups.orderedRemove(i);
        }
    }
}

/// Kills each tree when the interpreter ends.
pub fn abandonAll(it: *Interp) void {
    for (it.execs.groups.items) |*g| {
        treeKill(&g.tree, g.pids);
        for (g.tree.procs) |h| _ = waitProc(h, 0xffffffff);
        treeClose(&g.tree);
    }
    it.execs.groups = .empty;
}

fn cmdPid(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("pid ?channelId?");
    if (argv.len == 1) return .{ .int = GetCurrentProcessId() };
    const name = try it.str(argv[1]);
    const c = chan.lookup(it, name) orelse return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CHANNEL {s}", .{name}), "can not find channel named \"{s}\"", .{name});
    var out: std.ArrayList(Value) = .empty;
    for (c.pids) |p| try out.append(it.alloc(), .{ .int = p });
    return value.wrapList(it.alloc(), out.items);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("exec", cmdExec);
    try it.register("pid", cmdPid);
}
