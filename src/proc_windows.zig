//! The Windows form of `exec` (`proc.zig`).
//!
//! WARNING: a process is outside the root folder of `file` and outside
//! each limit of the interpreter. A script with `exec` has the full power
//! of the user that runs the embedder. This capability is not sandboxed.
//!
//! `CreateProcessW` gets the full path of the program, so no search runs,
//! and a command line that follows the CommandLineToArgvW rules, so the
//! program reads the words of the script. No shell reads them. A `.bat` or
//! `.cmd` file is an error, because Windows runs those through cmd.exe.
//!
//! Each pipeline is one Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
//! A process starts suspended and joins the job before its first
//! instruction, so each process that it makes is in the job too. The job
//! ends at the time limit, at a failed start, and when the last process of
//! the pipeline has been collected, so a process that a program leaves
//! behind ends then. If the embedder dies, the system closes the job.
//!
//! A handle list gives each process only its three standard handles.
//! Each handle of the interpreter stays out of the child.
//!
//! The error output and the text of `<<` use a temporary file that the
//! system deletes when its last handle closes.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const sys = @import("sys.zig");
const fsroot = @import("fsroot.zig");
const proc = @import("proc.zig");
const Interp = interp.Interp;
const Error = interp.Error;
const Fd = sys.Fd;

const HANDLE = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;

const invalid_handle: HANDLE = @ptrFromInt(~@as(usize, 0));
const infinite: DWORD = 0xFFFF_FFFF;
const wait_timeout: DWORD = 0x102;
const generic_read: DWORD = 0x8000_0000;
const generic_write: DWORD = 0x4000_0000;
const file_append_data: DWORD = 0x0004;
const synchronize: DWORD = 0x0010_0000;
const file_read_attributes: DWORD = 0x0080;
const share_all: DWORD = 7;
const create_new: DWORD = 1;
const create_always: DWORD = 2;
const open_existing: DWORD = 3;
const open_always: DWORD = 4;
const truncate_existing: DWORD = 5;
const attr_directory: DWORD = 0x10;
const attr_normal: DWORD = 0x80;
const attr_temporary: DWORD = 0x100;
const flag_delete_on_close: DWORD = 0x0400_0000;
const invalid_attributes: DWORD = 0xFFFF_FFFF;
const duplicate_same_access: DWORD = 2;
const startf_use_std_handles: DWORD = 0x100;
const create_suspended: DWORD = 0x0000_0004;
const create_unicode_environment: DWORD = 0x0000_0400;
const extended_startupinfo_present: DWORD = 0x0008_0000;
const create_no_window: DWORD = 0x0800_0000;
const attribute_handle_list: usize = 0x0002_0002;
const job_limit_kill_on_close: u32 = 0x2000;
const job_class_extended_limit: u32 = 9;

/// The exit code of a process that the job ended.
const kill_code: u32 = 0x2000_0009;
const access_violation: u32 = 0xC000_0005;
const error_file_not_found: u32 = 2;
const error_too_long: u32 = 206;
/// The longest command line of CreateProcessW, in UTF-16 units.
const command_cap = 32766;

const StartupInfo = extern struct {
    cb: u32,
    reserved: ?*anyopaque = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    fill: u32 = 0,
    flags: u32 = 0,
    show: u16 = 0,
    reserved2: u16 = 0,
    reserved3: ?*u8 = null,
    input: HANDLE = null,
    output: HANDLE = null,
    err: HANDLE = null,
};
const StartupInfoEx = extern struct { info: StartupInfo, attributes: ?*anyopaque };
const ProcessInfo = extern struct { process: HANDLE, thread: HANDLE, pid: u32, tid: u32 };

extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, command: ?[*:0]u16, process_security: ?*anyopaque, thread_security: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*const anyopaque, cwd: ?[*:0]const u16, startup: *StartupInfoEx, info: *ProcessInfo) callconv(.winapi) BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: ?*anyopaque, flags: DWORD, attribute: usize, value: *const anyopaque, size: usize, previous: ?*anyopaque, returned: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateJobObjectW(security: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: u32, info: *const anyopaque, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateJobObject(job: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, security: ?*anyopaque, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn DuplicateHandle(from: HANDLE, h: HANDLE, to: HANDLE, out: *HANDLE, access: DWORD, inherit: BOOL, options: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GetTempPathW(size: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]u16, size: DWORD, flags: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetConsoleWindow() callconv(.winapi) HANDLE;

// ---- the table of processes and jobs ----

const Job = struct { pgid: i32, job: HANDLE, left: usize };
const Entry = struct { pid: i32, process: HANDLE, pgid: i32 };

var busy = std.atomic.Value(bool).init(false);
var entries: std.ArrayList(Entry) = .empty;
var jobs: std.ArrayList(Job) = .empty;

fn lock() void {
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    busy.store(false, .release);
}

const table = std.heap.page_allocator;

pub fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

pub fn getPid() i64 {
    return GetCurrentProcessId();
}

/// The wait status in the form that `proc.finish` reads: a signal in the
/// low bits, or an exit code in the next byte.
fn statusOf(code: u32) u32 {
    if (code == kill_code) return 9;
    if (code == access_violation) return 11;
    if (code == 0) return 0;
    // An exit code with a low byte of 0 is still a failure.
    const low = code & 0xff;
    return (if (low == 0) @as(u32, 1) else low) << 8;
}

pub fn killGroup(pgid: i32) void {
    lock();
    defer unlock();
    for (jobs.items) |j| {
        if (j.pgid == pgid) _ = TerminateJobObject(j.job, kill_code);
    }
}

/// The wait status of a process, or null while it runs. A pid that was
/// collected before gives 0.
pub fn waitPid(pid: i32, block: bool) ?u32 {
    lock();
    var process: HANDLE = null;
    for (entries.items) |e| {
        if (e.pid == pid) process = e.process;
    }
    unlock();
    if (process == null) return 0;
    if (WaitForSingleObject(process, if (block) infinite else 0) == wait_timeout) return null;
    var code: u32 = 0;
    _ = GetExitCodeProcess(process, &code);
    var ended_job: HANDLE = null;
    lock();
    for (entries.items, 0..) |e, i| {
        if (e.pid != pid) continue;
        for (jobs.items, 0..) |*j, n| {
            if (j.pgid != e.pgid) continue;
            j.left -= 1;
            if (j.left == 0) {
                ended_job = j.job;
                _ = jobs.swapRemove(n);
            }
            break;
        }
        _ = entries.swapRemove(i);
        break;
    }
    unlock();
    _ = CloseHandle(process);
    // Closing the job ends what the pipeline left behind.
    if (ended_job != null) _ = CloseHandle(ended_job);
    return statusOf(code);
}

// ---- paths ----

/// True for a name that Windows runs through cmd.exe. Windows drops
/// trailing dots and spaces from a name, so `x.bat.` is the same file.
pub fn isBatch(path: []const u8) bool {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\");
    var name = if (cut) |c| path[c + 1 ..] else path;
    if (std.mem.indexOfScalar(u8, name, ':')) |c| name = name[0..c];
    name = std.mem.trimEnd(u8, name, ". ");
    if (name.len < 4) return false;
    const tail = name[name.len - 4..];
    return std.ascii.eqlIgnoreCase(tail, ".bat") or std.ascii.eqlIgnoreCase(tail, ".cmd");
}

fn isAbsolute(word: []const u8) bool {
    if (word.len > 0 and (word[0] == '/' or word[0] == '\\')) return true;
    return word.len > 2 and std.ascii.isAlphabetic(word[0]) and word[1] == ':' and (word[2] == '/' or word[2] == '\\');
}

/// The forms of a program name: a name with no extension is an `.exe`
/// or a `.com` first.
fn addForms(a: std.mem.Allocator, out: *std.ArrayList([:0]const u8), path: []const u8) Error!void {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\");
    const name = if (cut) |c| path[c + 1 ..] else path;
    if (std.mem.indexOfScalar(u8, name, '.') != null) {
        try out.append(a, try a.dupeZ(u8, path));
        try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}.exe", .{path}, 0));
        return;
    }
    try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}.exe", .{path}, 0));
    try out.append(a, try std.fmt.allocPrintSentinel(a, "{s}.com", .{path}, 0));
    try out.append(a, try a.dupeZ(u8, path));
}

/// The paths to try for a program word.
pub fn candidates(it: *Interp, word: []const u8) Error![]const [:0]const u8 {
    const a = it.alloc();
    var out: std.ArrayList([:0]const u8) = .empty;
    if (std.mem.indexOfAny(u8, word, "/\\") != null) {
        // A path names a file below the root first, as each path of a
        // script does. The host path is the second choice.
        if (it.fs_ok() and it.fs.path.len > 0) {
            if (try fsroot.normal(it, word)) |rel| try addForms(a, &out, try std.fmt.allocPrint(a, "{s}/{s}", .{ it.fs.path, rel }));
        }
        if (isAbsolute(word)) try addForms(a, &out, word);
        return out.items;
    }
    var path: []const u8 = "";
    for (it.exec_host.env) |e| {
        if (e.len >= 5 and std.ascii.eqlIgnoreCase(e[0..5], "PATH=")) path = e[5..];
    }
    var iter = std.mem.tokenizeScalar(u8, path, ';');
    while (iter.next()) |dir| try addForms(a, &out, try std.fmt.allocPrint(a, "{s}\\{s}", .{ std.mem.trimEnd(u8, dir, "/\\"), word }));
    return out.items;
}

pub fn runnable(p: [:0]const u8) bool {
    var buf: [1024]u16 = undefined;
    const n = std.unicode.calcUtf16LeLen(p) catch return false;
    if (n >= buf.len) return false;
    const got = std.unicode.utf8ToUtf16Le(&buf, p) catch return false;
    buf[got] = 0;
    const attributes = GetFileAttributesW(@ptrCast(&buf));
    return attributes != invalid_attributes and attributes & attr_directory == 0;
}

// ---- the command line and the environment ----

/// Adds one argument by the rules of CommandLineToArgvW: n backslashes
/// before a quote become 2n + 1, and n at the end of a quoted word become
/// 2n.
fn appendArg(a: std.mem.Allocator, out: *std.ArrayList(u16), arg: []const u16) std.mem.Allocator.Error!void {
    var plain = arg.len > 0;
    for (arg) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == '"') plain = false;
    }
    if (plain) {
        try out.appendSlice(a, arg);
        return;
    }
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            slashes += 1;
            continue;
        }
        const times = if (c == '"') 2 * slashes + 1 else slashes;
        try out.appendNTimes(a, '\\', times);
        slashes = 0;
        try out.append(a, c);
    }
    try out.appendNTimes(a, '\\', 2 * slashes);
    try out.append(a, '"');
}

/// The command line of a list of words, or null for a word that cannot
/// be one. The first word follows its own rule: it ends at the next
/// quote, so it has no quote in it.
pub fn commandLine(a: std.mem.Allocator, words: []const []const u8) std.mem.Allocator.Error!?[:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    for (words, 0..) |w, k| {
        if (std.mem.indexOfScalar(u8, w, 0) != null) return null;
        const wide = std.unicode.utf8ToUtf16LeAlloc(a, w) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        if (k == 0) {
            if (std.mem.indexOfScalar(u16, wide, '"') != null) return null;
            try out.append(a, '"');
            try out.appendSlice(a, wide);
            try out.append(a, '"');
        } else {
            try out.append(a, ' ');
            try appendArg(a, &out, wide);
        }
    }
    if (out.items.len > command_cap) return null;
    return try out.toOwnedSliceSentinel(a, 0);
}

fn nameLess(_: void, x: []const u8, y: []const u8) bool {
    const nx = x[0 .. std.mem.indexOfScalar(u8, x, '=') orelse x.len];
    const ny = y[0 .. std.mem.indexOfScalar(u8, y, '=') orelse y.len];
    return std.ascii.lessThanIgnoreCase(nx, ny);
}

/// The whole environment of a program, sorted by name, the order of a
/// Windows environment block.
fn envBlock(a: std.mem.Allocator, env: []const [:0]const u8) Error![]u16 {
    const sorted = try a.alloc([]const u8, env.len);
    for (env, sorted) |e, *s| s.* = e;
    std.mem.sort([]const u8, sorted, {}, nameLess);
    var out: std.ArrayList(u16) = .empty;
    for (sorted) |e| {
        const wide = std.unicode.utf8ToUtf16LeAlloc(a, e) catch |x| switch (x) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try out.appendSlice(a, wide);
        try out.append(a, 0);
    }
    try out.append(a, 0);
    if (out.items.len == 1) try out.append(a, 0);
    return out.items;
}

// ---- files ----

var temp_counter = std.atomic.Value(u32).init(0);

/// A new temporary file in a folder, with its text, or null.
fn tempIn(dir: []const u16, text: []const u8) ?Fd {
    var tries: usize = 0;
    while (tries < 64) : (tries += 1) {
        var name: [64]u8 = undefined;
        const text_name = std.fmt.bufPrint(&name, "ztcl-{d}-{d}-{d}.tmp", .{ GetCurrentProcessId(), GetTickCount64(), temp_counter.fetchAdd(1, .monotonic) }) catch return null;
        var path: [360]u16 = undefined;
        if (dir.len + text_name.len + 1 > path.len) return null;
        @memcpy(path[0..dir.len], dir);
        const m = std.unicode.utf8ToUtf16Le(path[dir.len..], text_name) catch return null;
        path[dir.len + m] = 0;
        const h = CreateFileW(@ptrCast(&path), generic_read | generic_write, share_all, null, create_new, attr_temporary | flag_delete_on_close, null);
        if (h == invalid_handle) {
            if (GetLastError() == 80) continue;
            return null;
        }
        const fd = sys.win.fdOfHandle(h) orelse {
            _ = CloseHandle(h);
            return null;
        };
        var at: usize = 0;
        while (at < text.len) {
            switch (sys.writeFile(fd, text[at..])) {
                .n => |w| at += w,
                .err => break,
            }
        }
        _ = sys.seek(fd, 0, 0);
        return fd;
    }
    return null;
}

/// A temporary file that the system deletes at its last close. A process
/// that `exec` started has only the environment of the embedder, so its
/// temp folder can be one that it cannot write. The root folder is then
/// the second choice.
pub fn memFile(it: *Interp, text: []const u8) Error!Fd {
    var dir: [280]u16 = undefined;
    const n = GetTempPathW(260, &dir);
    if (n > 0 and n < 260) {
        if (tempIn(dir[0..n], text)) |fd| return fd;
    }
    if (it.fs_ok() and it.fs.path.len > 0) {
        const len = std.unicode.calcUtf16LeLen(it.fs.path) catch 0;
        if (len > 0 and len + 1 < dir.len) {
            const got = std.unicode.utf8ToUtf16Le(&dir, it.fs.path) catch 0;
            if (got > 0) {
                dir[got] = '\\';
                if (tempIn(dir[0 .. got + 1], text)) |fd| return fd;
            }
        }
    }
    return proc.posix(it, .ACCES, "couldn't create a memory file: ");
}

/// Opens a host path for a redirection, when the embedder gave no root.
pub fn openHost(it: *Interp, path: []const u8, flags: sys.OpenFlags, what: []const u8) Error!Fd {
    const a = it.alloc();
    const message = try std.fmt.allocPrint(a, "couldn't {s} file \"{s}\": ", .{ what, path });
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return proc.posix(it, .INVAL, message),
    };
    var access: DWORD = switch (flags.access) {
        .read => generic_read,
        .write => generic_write,
        .read_write => generic_read | generic_write,
    };
    if (flags.append) access = (access & generic_read) | file_append_data | synchronize | file_read_attributes;
    var disposition: DWORD = open_existing;
    if (flags.create and flags.exclusive) {
        disposition = create_new;
    } else if (flags.create and flags.truncate) {
        disposition = create_always;
    } else if (flags.create) {
        disposition = open_always;
    } else if (flags.truncate) {
        disposition = truncate_existing;
    }
    const h = CreateFileW(wide.ptr, access, share_all, null, disposition, attr_normal, null);
    if (h == invalid_handle) return proc.posix(it, @enumFromInt(GetLastError()), message);
    return sys.win.fdOfHandle(h) orelse {
        _ = CloseHandle(h);
        return proc.posix(it, .ACCES, message);
    };
}

fn newPipe(it: *Interp) Error![2]Fd {
    var r: HANDLE = null;
    var w: HANDLE = null;
    if (CreatePipe(&r, &w, null, 65536) == 0) return proc.posix(it, @enumFromInt(GetLastError()), "couldn't create pipe: ");
    const rf = sys.win.fdOfHandle(r);
    const wf = sys.win.fdOfHandle(w);
    if (rf == null or wf == null) {
        _ = CloseHandle(r);
        _ = CloseHandle(w);
        return proc.posix(it, .ACCES, "couldn't create pipe: ");
    }
    return .{ rf.?, wf.? };
}

/// An inheritable copy of a descriptor for one child.
fn childHandle(fd: Fd, fallback: Fd) HANDLE {
    var source = sys.win.rawHandle(fd);
    if (source == null or source == invalid_handle) source = sys.win.rawHandle(fallback);
    var out: HANDLE = null;
    const me = GetCurrentProcess();
    if (DuplicateHandle(me, source, me, &out, 0, 1, duplicate_same_access) == 0) return null;
    return out;
}

/// The real path of the working folder, in the form of CreateProcessW.
fn folderOf(a: std.mem.Allocator, fd: Fd) Error!?[:0]const u16 {
    var buf: [4096]u16 = undefined;
    const n = GetFinalPathNameByHandleW(sys.win.rawHandle(fd), &buf, buf.len, 0);
    if (n == 0 or n >= buf.len) return null;
    var path: []const u16 = buf[0..n];
    const long = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    const unc = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
    if (std.mem.startsWith(u16, path, unc)) {
        const out = try a.allocSentinel(u16, path.len - unc.len + 2, 0);
        out[0] = '\\';
        out[1] = '\\';
        @memcpy(out[2..], path[unc.len..]);
        return out;
    }
    if (std.mem.startsWith(u16, path, long)) path = path[long.len..];
    return try a.dupeZ(u16, path);
}

fn newJob() ?HANDLE {
    const job = CreateJobObjectW(null, null);
    if (job == null) return null;
    // JOBOBJECT_EXTENDED_LIMIT_INFORMATION: LimitFlags is at offset 16.
    var info: [144]u8 align(8) = @splat(0);
    std.mem.writeInt(u32, info[16..20], job_limit_kill_on_close, .little);
    if (SetInformationJobObject(job, job_class_extended_limit, &info, info.len) == 0) {
        _ = CloseHandle(job);
        return null;
    }
    return job;
}

/// Starts one process, suspended, in the job, with three handles.
fn spawn(a: std.mem.Allocator, app: [:0]const u16, command: [:0]u16, env: []const u16, cwd: ?[:0]const u16, job: HANDLE, in: Fd, out: Fd, err: Fd, null_fd: Fd) std.mem.Allocator.Error!union(enum) { ok: ProcessInfo, err: u32 } {
    const h_in = childHandle(in, null_fd);
    const h_out = childHandle(out, null_fd);
    const h_err = childHandle(err, null_fd);
    defer {
        if (h_in != null) _ = CloseHandle(h_in);
        if (h_out != null) _ = CloseHandle(h_out);
        if (h_err != null) _ = CloseHandle(h_err);
    }
    if (h_in == null or h_out == null or h_err == null) return .{ .err = GetLastError() };
    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
    const list = try a.alignedAlloc(u8, .@"8", size);
    if (InitializeProcThreadAttributeList(list.ptr, 1, 0, &size) == 0) return .{ .err = GetLastError() };
    defer DeleteProcThreadAttributeList(list.ptr);
    const handles = [_]HANDLE{ h_in, h_out, h_err };
    if (UpdateProcThreadAttribute(list.ptr, 0, attribute_handle_list, &handles, @sizeOf(@TypeOf(handles)), null, null) == 0) return .{ .err = GetLastError() };
    var startup: StartupInfoEx = .{
        .info = .{ .cb = @sizeOf(StartupInfoEx), .flags = startf_use_std_handles, .input = h_in, .output = h_out, .err = h_err },
        .attributes = list.ptr,
    };
    var flags: DWORD = create_suspended | create_unicode_environment | extended_startupinfo_present;
    if (GetConsoleWindow() == null) flags |= create_no_window;
    var info: ProcessInfo = undefined;
    if (CreateProcessW(app.ptr, command.ptr, null, null, 1, flags, env.ptr, if (cwd) |c| c.ptr else null, &startup, &info) == 0) return .{ .err = GetLastError() };
    if (AssignProcessToJobObject(job, info.process) == 0) {
        const code = GetLastError();
        _ = TerminateProcess(info.process, kill_code);
        _ = CloseHandle(info.thread);
        _ = CloseHandle(info.process);
        return .{ .err = code };
    }
    _ = ResumeThread(info.thread);
    _ = CloseHandle(info.thread);
    return .{ .ok = info };
}

/// Starts the programs of a plan. Each check comes before the first
/// process.
pub fn start(it: *Interp, plan: *proc.Plan, want_out: bool, want_in: bool) Error!proc.Started {
    const a = it.alloc();
    const count = plan.cmds.items.len;
    const apps = try a.alloc([:0]const u16, count);
    const commands = try a.alloc([:0]u16, count);
    for (plan.cmds.items, 0..) |c, k| {
        const word = c.words.items[0];
        try proc.noTilde(it, word);
        const paths = try candidates(it, word);
        if (!proc.allowed(it, word, paths)) return it.failCode("ZTCL EXEC DENIED", "couldn't execute \"{s}\": the embedder does not allow this program", .{word});
        if (isBatch(word)) return batchError(it, word);
        var found: ?[:0]const u8 = null;
        for (paths) |p| {
            if (runnable(p)) {
                found = p;
                break;
            }
        }
        const path = found orelse return proc.posix(it, @enumFromInt(error_file_not_found), try std.fmt.allocPrint(a, "couldn't execute \"{s}\": ", .{word}));
        if (isBatch(path)) return batchError(it, word);
        apps[k] = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return proc.posix(it, .INVAL, try std.fmt.allocPrint(a, "couldn't execute \"{s}\": ", .{word})),
        };
        commands[k] = (try commandLine(a, c.words.items)) orelse return proc.posix(it, @enumFromInt(error_too_long), try std.fmt.allocPrint(a, "couldn't execute \"{s}\": ", .{word}));
    }
    const env = try envBlock(a, it.exec_host.env);
    // The working folder: the current folder below the root.
    var cwd: ?[:0]const u16 = null;
    if (it.fs_ok()) {
        const fd = switch (try fsroot.openRel(it, it.fs.cwd, .{ .directory = true }, 0)) {
            .fd => |x| x,
            .err => |e| return proc.posix(it, e, "couldn't open the working folder: "),
        };
        defer sys.close(fd);
        cwd = (try folderOf(a, fd)) orelse return proc.posix(it, .ACCES, "couldn't open the working folder: ");
    }
    const nul = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
    const null_handle = CreateFileW(nul, generic_read | generic_write, share_all, null, open_existing, 0, null);
    if (null_handle == invalid_handle) return proc.posix(it, @enumFromInt(GetLastError()), "couldn't open NUL: ");
    const null_fd = sys.win.fdOfHandle(null_handle) orelse {
        _ = CloseHandle(null_handle);
        return proc.posix(it, .ACCES, "couldn't open NUL: ");
    };
    defer sys.close(null_fd);
    const job = newJob() orelse return proc.posix(it, @enumFromInt(GetLastError()), "couldn't create a job object: ");
    var job_owned = true;
    defer if (job_owned) {
        _ = CloseHandle(job);
    };

    var st: proc.Started = .{ .pids = try a.alloc(i32, count), .start = nowMs() };
    var made: usize = 0;
    var first_in: Fd = null_fd;
    var in_pipe: ?[2]Fd = null;
    switch (plan.in) {
        .fd, .owned => |x| first_in = x,
        else => if (want_in) {
            in_pipe = try newPipe(it);
            first_in = in_pipe.?[0];
            st.in = in_pipe.?[1];
        },
    }
    var last_out: Fd = 1;
    var out_pipe: ?[2]Fd = null;
    switch (plan.out) {
        .fd, .owned => |x| last_out = x,
        else => if (want_out) {
            out_pipe = try newPipe(it);
            last_out = out_pipe.?[1];
            st.out = out_pipe.?[0];
        },
    }
    var err_fd: Fd = 2;
    switch (plan.err) {
        .fd, .owned => |x| err_fd = x,
        .to_out => {},
        .none => if (!plan.background) {
            st.err = try memFile(it, "");
            err_fd = st.err;
        },
    }
    var prev_read: Fd = -1;
    var failure: ?Error = null;
    var pgid: i32 = 0;
    for (0..count) |k| {
        var next: ?[2]Fd = null;
        if (k + 1 < count) next = newPipe(it) catch |e| {
            failure = e;
            break;
        };
        const in_fd = if (k == 0) first_in else prev_read;
        const out_fd = if (next) |p| p[1] else last_out;
        var this_err = err_fd;
        if (plan.err == .to_out and k + 1 == count) this_err = out_fd;
        if (plan.cmds.items[k].err_too) this_err = out_fd;
        const result = try spawn(a, apps[k], commands[k], env, cwd, job, in_fd, out_fd, this_err, null_fd);
        const info = switch (result) {
            .ok => |x| x,
            .err => |code| {
                failure = proc.posix(it, @enumFromInt(code), try std.fmt.allocPrint(a, "couldn't execute \"{s}\": ", .{plan.cmds.items[k].words.items[0]}));
                if (next) |p| {
                    sys.close(p[0]);
                    sys.close(p[1]);
                }
                break;
            },
        };
        const pid: i32 = @intCast(info.pid);
        if (pgid == 0) {
            pgid = pid;
            lock();
            jobs.append(table, .{ .pgid = pid, .job = job, .left = 0 }) catch {};
            unlock();
            job_owned = false;
        }
        lock();
        entries.append(table, .{ .pid = pid, .process = info.process, .pgid = pgid }) catch {};
        for (jobs.items) |*j| {
            if (j.pgid == pgid) j.left += 1;
        }
        unlock();
        st.pids[made] = pid;
        made += 1;
        if (prev_read >= 0) sys.close(prev_read);
        prev_read = -1;
        if (next) |p| {
            sys.close(p[1]);
            prev_read = p[0];
        }
    }
    if (prev_read >= 0) sys.close(prev_read);
    if (in_pipe) |p| sys.close(p[0]);
    if (out_pipe) |p| sys.close(p[1]);
    proc.closePlan(plan);
    st.pids = st.pids[0..made];
    if (failure) |e| {
        const saved = it.result;
        const saved_code = it.error_code;
        killGroup(pgid);
        for (st.pids) |p| _ = waitPid(p, true);
        if (st.out >= 0) sys.close(st.out);
        if (st.in >= 0) sys.close(st.in);
        if (st.err >= 0) sys.close(st.err);
        it.result = saved;
        it.error_code = saved_code;
        return e;
    }
    return st;
}

/// The output of a Windows program ends its lines with CR LF. `exec`
/// gives each line end as LF, so a script reads the same text on each
/// system.
pub fn dropCarriageReturns(text: *std.ArrayList(u8)) void {
    var out: usize = 0;
    for (text.items, 0..) |c, i| {
        if (c == '\r' and i + 1 < text.items.len and text.items[i + 1] == '\n') continue;
        text.items[out] = c;
        out += 1;
    }
    text.items.len = out;
}

fn batchError(it: *Interp, word: []const u8) Error {
    return it.failCode("ZTCL EXEC DENIED", "couldn't execute \"{s}\": a batch file runs through cmd.exe, and exec uses no shell", .{word});
}
