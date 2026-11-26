//! The sandbox of the `process` level of ztcl threads on Windows
//! (ztcl#209). The protocol between the parent and the child is
//! `docs/dev/isolation.md`. This file starts the child and holds it in
//! its sandbox. The other platforms have the same `Spawn`, `Child`, and
//! `spawn` in their own file.
//!
//! The child is the ztcl runner, in an AppContainer of its own, in a
//! Job Object of its own:
//!
//! - Each child has an AppContainer profile of its own, from
//!   `CreateAppContainerProfile` on a name with the pid of the parent
//!   and a count, so two children never share a SID. `deinit` deletes
//!   the profile. A SID with no profile is not enough: `CreateProcessW`
//!   then gives `ERROR_FILE_NOT_FOUND`. A child reaches only what grants
//!   its SID, or all AppContainers, an access: the files of Windows, the
//!   copy of the runner, and the root folder of `Spawn`.
//! - The copy of the runner. An AppContainer cannot read a file under
//!   the folder of a user, so the first spawn copies the runner into
//!   `%TEMP%\ztcl-iso`, a folder with an ACE that lets each AppContainer
//!   read and run its files. The name of the copy has the size and the
//!   time of the runner, so a new build gets a new copy.
//! - The root folder. The child starts in it. `spawn` adds an
//!   inheritable ACE for the SID of the child on it, and `deinit` removes
//!   the ACE.
//! - The network. With `net`, the child has the capabilities
//!   `internetClient` and `privateNetworkClientServer`. Windows blocks
//!   the loopback for each AppContainer unless a system setting exempts
//!   it, and the sandbox does not change that setting.
//! - The transport is one duplex named pipe with a random name, one
//!   instance, `PIPE_REJECT_REMOTE_CLIENTS`, and a DACL for the user of
//!   the parent only. The parent opens the client end and the child
//!   inherits it. Its value is on the command line (`--iso-handle 0x...`).
//! - The child starts suspended, with only the client end of the pipe
//!   (and, for a test, one output handle) in `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`,
//!   goes into the job, and then resumes, so no code of it runs outside
//!   the job. Its environment has only the folders of the system and of
//!   the user (`SystemRoot`, `TEMP`, and the others of `env_names`):
//!   `CreateProcessW` gives `ERROR_ENVVAR_NOT_FOUND` for an AppContainer
//!   with no folder of the user, and gives the child the folders of its
//!   container in their place.
//! - The job ends the child when the parent closes it, limits the memory
//!   of the process, the user CPU time, and the count of processes (1,
//!   so the child cannot start one), ends the child at an unhandled
//!   exception with no dialog, and limits the UI. A completion port of
//!   the job reports the memory limit, and `wait` then ends the job.
//!   `kill` is `TerminateJobObject` with the code 137, the code of a
//!   killed `exec`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const procw = @import("proc_windows.zig");

pub const supported = builtin.os.tag == .windows and sys.supported;

pub const HANDLE = *anyopaque;
const BOOL = i32;
const DWORD = u32;
const HRESULT = i32;
const PSID = *anyopaque;
const INVALID: usize = std.math.maxInt(usize);

/// The exit code of a child that `kill` or a limit ended.
pub const killed_code: u32 = 137;

pub const Spawn = struct {
    /// The arguments of the runner after `--iso-handle 0x...`.
    args: []const []const u8,
    limits: struct { mem_bytes: u64 = 0, cpu_seconds: u64 = 0 } = .{},
    /// The root folder of the file jail, or null. The child can read and
    /// write only there, and in no other folder of the user.
    root: ?[]const u8 = null,
    /// Whether the child can use the network (the capability `socket`).
    net: bool = false,
    /// For a test: a handle that the child gets as its standard output
    /// and error. Null gives the child no standard handle.
    stdout: ?HANDLE = null,
};

pub const ExitStatus = struct {
    code: u32,
    /// True when `kill`, the memory limit, or the CPU limit ended it.
    killed: bool,
};

pub const Usage = struct { cpu_ns: u64, peak_bytes: u64 };

pub const Child = struct {
    a: std.mem.Allocator,
    /// The parent end of the transport: an overlapped duplex pipe.
    pipe: HANDLE,
    process: HANDLE,
    job: HANDLE,
    port: HANDLE,
    pid: u32,
    sid: PSID,
    /// The name of the AppContainer profile of the child.
    name: [:0]u16,
    /// The root folder with the ACE of `sid`, or null.
    root: ?[:0]u16,
    killed: bool = false,
    status: ?ExitStatus = null,

    /// The status of the end, or null while the child runs after
    /// `timeout_ms`.
    pub fn wait(c: *Child, timeout_ms: u32) ?ExitStatus {
        if (c.status) |s| return s;
        c.drainPort();
        if (WaitForSingleObject(c.process, timeout_ms) != 0) {
            c.drainPort();
            return null;
        }
        c.drainPort();
        var code: DWORD = 0;
        _ = GetExitCodeProcess(c.process, &code);
        c.status = .{ .code = code, .killed = c.killed };
        return c.status;
    }

    /// Ends the child at once.
    pub fn kill(c: *Child) void {
        if (c.status != null) return;
        c.killed = true;
        _ = TerminateJobObject(c.job, killed_code);
    }

    /// The counts of the system for the child, for `total_compute` and
    /// `total_mem`: they do not depend on what the child says.
    pub fn usage(c: *Child) Usage {
        var acc: ACCOUNTING = .{};
        var ext: EXTENDED_LIMIT = .{};
        _ = QueryInformationJobObject(c.job, job_basic_accounting, &acc, @sizeOf(ACCOUNTING), null);
        _ = QueryInformationJobObject(c.job, job_extended_limit, &ext, @sizeOf(EXTENDED_LIMIT), null);
        const ticks: u64 = @intCast(acc.TotalUserTime + acc.TotalKernelTime);
        return .{ .cpu_ns = ticks * 100, .peak_bytes = ext.PeakProcessMemoryUsed };
    }

    /// Ends the child if it runs, and frees each handle, the SID, and
    /// the ACE of the root folder.
    pub fn deinit(c: *Child) void {
        if (c.wait(0) == null) {
            c.kill();
            _ = c.wait(5000);
        }
        if (c.root) |r| {
            setAce(r, c.sid, 0, revoke_access, 0) catch {};
            c.a.free(r);
        }
        _ = CloseHandle(c.pipe);
        _ = CloseHandle(c.process);
        _ = CloseHandle(c.job);
        _ = CloseHandle(c.port);
        _ = FreeSid(c.sid);
        _ = DeleteAppContainerProfile(c.name.ptr);
        c.a.free(c.name);
        c.* = undefined;
    }

    /// Reads the messages of the job. A memory limit ends the job, since
    /// the limit only fails the allocation.
    fn drainPort(c: *Child) void {
        var msg: DWORD = 0;
        var key: usize = 0;
        var ov: ?*anyopaque = null;
        while (GetQueuedCompletionStatus(c.port, &msg, &key, &ov, 0) != 0) {
            switch (msg) {
                job_msg_process_memory_limit, job_msg_job_memory_limit => c.kill(),
                job_msg_end_of_job_time, job_msg_end_of_process_time => c.killed = true,
                else => {},
            }
        }
    }
};

pub const SpawnError = error{ OutOfMemory, Unsupported, SpawnFailed };

/// The error of Windows of the last `SpawnFailed` of this thread, for
/// the message of the caller.
pub threadlocal var last_error: u32 = 0;

fn failed() SpawnError {
    last_error = GetLastError();
    return error.SpawnFailed;
}

/// The count of the names of the AppContainers of this process.
var counter = std.atomic.Value(u32).init(0);

/// Starts `self_exe` (the ztcl runner) in a new sandbox with `s`.
pub fn spawn(a: std.mem.Allocator, self_exe: []const u8, s: Spawn) SpawnError!Child {
    if (comptime !supported) return error.Unsupported;
    const runner = try runnerCopy(a, self_exe);
    defer a.free(runner);

    // The AppContainer of this child.
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "ztcl.iso.{d}.{d}", .{ GetCurrentProcessId(), counter.fetchAdd(1, .monotonic) }) catch unreachable;
    const name_w = try wide(a, name);
    var name_owned = true;
    errdefer if (name_owned) a.free(name_w);
    // A profile from a parent with the same pid that ended before it
    // could delete it.
    _ = DeleteAppContainerProfile(name_w.ptr);
    var sid: PSID = undefined;
    const display = std.unicode.utf8ToUtf16LeStringLiteral("ztcl thread");
    const hr = CreateAppContainerProfile(name_w.ptr, display, display, null, 0, &sid);
    if (hr < 0) {
        last_error = @bitCast(hr);
        return error.SpawnFailed;
    }
    var sid_owned = true;
    errdefer if (sid_owned) {
        _ = FreeSid(sid);
        _ = DeleteAppContainerProfile(name_w.ptr);
    };

    var root_w: ?[:0]u16 = null;
    errdefer if (root_w) |r| {
        setAce(r, sid, 0, revoke_access, 0) catch {};
        a.free(r);
    };
    if (s.root) |r| {
        const rw = try wide(a, r);
        setAce(rw, sid, file_modify, grant_access, sub_containers_and_objects) catch {
            a.free(rw);
            return error.SpawnFailed;
        };
        root_w = rw;
    }

    // The transport.
    const ends = try pipePair(a);
    errdefer _ = CloseHandle(ends.parent);
    defer _ = CloseHandle(ends.child);

    // The job and its port.
    const job = CreateJobObjectW(null, null) orelse return failed();
    errdefer _ = CloseHandle(job);
    const port = CreateIoCompletionPort(@ptrFromInt(INVALID), null, 0, 1) orelse return failed();
    errdefer _ = CloseHandle(port);
    try setupJob(job, port, s);

    // The command line: the runner, the transport, and the arguments.
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(a);
    var hbuf: [32]u8 = undefined;
    const hval = std.fmt.bufPrint(&hbuf, "0x{x}", .{@intFromPtr(ends.child)}) catch unreachable;
    try words.appendSlice(a, &.{ runner, "--iso-handle", hval });
    try words.appendSlice(a, s.args);
    // `commandLine` gives the items of a list, so it gets an arena.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const line = procw.commandLine(arena.allocator(), words.items) catch return error.OutOfMemory;
    const line_w = try wide(a, line);
    defer a.free(line_w);
    const exe_w = try wide(a, runner);
    defer a.free(exe_w);

    // The environment: the folders of the system and of the user, in the
    // order of their names. Windows needs the folders of the user to
    // start an AppContainer, and gives the child the folders of its
    // container in their place.
    var env: std.ArrayList(u16) = .empty;
    defer env.deinit(a);
    for (env_names) |n| {
        var buf: [1024]u16 = undefined;
        const len = GetEnvironmentVariableW(n.ptr, &buf, buf.len);
        if (len == 0 or len >= buf.len) continue;
        try env.appendSlice(a, n);
        try env.append(a, '=');
        try env.appendSlice(a, buf[0..len]);
        try env.append(a, 0);
    }
    try env.append(a, 0);

    // The attributes: the handle list and the AppContainer.
    var caps: [2]SID_AND_ATTRIBUTES = undefined;
    var cap_sids: [2]?PSID = .{ null, null };
    defer for (cap_sids) |cs| if (cs) |p| {
        _ = LocalFree(p);
    };
    var ncaps: u32 = 0;
    if (s.net) {
        const names = [_][:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("S-1-15-3-1"), // internetClient
            std.unicode.utf8ToUtf16LeStringLiteral("S-1-15-3-3"), // privateNetworkClientServer
        };
        for (names, 0..) |n, i| {
            var p: PSID = undefined;
            if (ConvertStringSidToSidW(n.ptr, &p) == 0) return failed();
            cap_sids[i] = p;
            caps[i] = .{ .Sid = p, .Attributes = se_group_enabled };
            ncaps += 1;
        }
    }
    var sc: SECURITY_CAPABILITIES = .{ .AppContainerSid = sid, .Capabilities = if (ncaps > 0) &caps else null, .CapabilityCount = ncaps };
    var handles: [2]HANDLE = .{ ends.child, undefined };
    var nhandles: usize = 1;
    if (s.stdout) |h| {
        handles[1] = h;
        nhandles = 2;
    }
    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 2, 0, &size);
    const attrs = a.alignedAlloc(u8, .of(usize), size) catch return error.OutOfMemory;
    defer a.free(attrs);
    if (InitializeProcThreadAttributeList(attrs.ptr, 2, 0, &size) == 0) return failed();
    defer DeleteProcThreadAttributeList(attrs.ptr);
    if (UpdateProcThreadAttribute(attrs.ptr, 0, attr_handle_list, &handles, nhandles * @sizeOf(HANDLE), null, null) == 0) return failed();
    if (UpdateProcThreadAttribute(attrs.ptr, 0, attr_security_capabilities, &sc, @sizeOf(SECURITY_CAPABILITIES), null, null) == 0) return failed();

    var si: STARTUPINFOEXW = .{ .info = .{ .cb = @sizeOf(STARTUPINFOEXW) }, .attrs = attrs.ptr };
    if (s.stdout) |h| {
        si.info.dwFlags = startf_usestdhandles;
        si.info.hStdOutput = h;
        si.info.hStdError = h;
    } else {
        si.info.dwFlags = startf_usestdhandles;
    }
    var pi: PROCESS_INFORMATION = undefined;
    const flags: DWORD = extended_startupinfo_present | create_suspended | create_no_window | create_unicode_environment;
    if (CreateProcessW(exe_w.ptr, line_w.ptr, null, null, 1, flags, env.items.ptr, if (root_w) |r| r.ptr else null, &si, &pi) == 0) return failed();
    defer _ = CloseHandle(pi.hThread);
    if (AssignProcessToJobObject(job, pi.hProcess) == 0) {
        _ = TerminateProcess(pi.hProcess, killed_code);
        _ = CloseHandle(pi.hProcess);
        return error.SpawnFailed;
    }
    _ = ResumeThread(pi.hThread);
    sid_owned = false;
    name_owned = false;
    return .{
        .a = a,
        .pipe = ends.parent,
        .process = pi.hProcess,
        .job = job,
        .port = port,
        .pid = pi.dwProcessId,
        .sid = sid,
        .name = name_w,
        .root = root_w,
    };
}

/// The variables of the environment of a child, in order.
const env_names = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("APPDATA"),
    std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"),
    std.unicode.utf8ToUtf16LeStringLiteral("SystemDrive"),
    std.unicode.utf8ToUtf16LeStringLiteral("SystemRoot"),
    std.unicode.utf8ToUtf16LeStringLiteral("TEMP"),
    std.unicode.utf8ToUtf16LeStringLiteral("TMP"),
    std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"),
};

fn setupJob(job: HANDLE, port: HANDLE, s: Spawn) SpawnError!void {
    var assoc: ASSOCIATE_PORT = .{ .CompletionKey = null, .CompletionPort = port };
    if (SetInformationJobObject(job, job_associate_port, &assoc, @sizeOf(ASSOCIATE_PORT)) == 0) return failed();
    var ext: EXTENDED_LIMIT = .{};
    ext.basic.LimitFlags = limit_kill_on_job_close | limit_die_on_unhandled_exception | limit_active_process;
    ext.basic.ActiveProcessLimit = 1;
    if (s.limits.mem_bytes > 0) {
        ext.basic.LimitFlags |= limit_process_memory;
        ext.ProcessMemoryLimit = @intCast(s.limits.mem_bytes);
    }
    if (s.limits.cpu_seconds > 0) {
        ext.basic.LimitFlags |= limit_job_time;
        // In units of 100 ns.
        ext.basic.PerJobUserTimeLimit = @intCast(s.limits.cpu_seconds * 10_000_000);
    }
    if (SetInformationJobObject(job, job_extended_limit, &ext, @sizeOf(EXTENDED_LIMIT)) == 0) return failed();
    const ui: DWORD = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80;
    if (SetInformationJobObject(job, job_basic_ui, &ui, @sizeOf(DWORD)) == 0) return failed();
}

const Ends = struct { parent: HANDLE, child: HANDLE };

/// One duplex pipe: the parent end, and an inheritable client end.
fn pipePair(a: std.mem.Allocator) SpawnError!Ends {
    var rnd: [16]u8 = undefined;
    if (BCryptGenRandom(null, &rnd, rnd.len, 2) != 0) return failed();
    var name_buf: [80]u8 = undefined;
    const hex = std.fmt.bytesToHex(rnd, .lower);
    const name = std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\ztcl-iso-{s}", .{&hex}) catch unreachable;
    const name_w = try wide(a, name);
    defer a.free(name_w);

    // The DACL gives the user of the parent each right, and no one else
    // a right.
    const sddl = try userSddl(a);
    defer a.free(sddl);
    var sd: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.ptr, 1, &sd, null) == 0) return failed();
    defer _ = LocalFree(sd);
    var sa: SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = sd };

    const parent = CreateNamedPipeW(name_w.ptr, pipe_access_duplex | file_flag_overlapped | file_flag_first_pipe_instance, pipe_reject_remote_clients, 1, 64 << 10, 64 << 10, 0, &sa);
    if (@intFromPtr(parent) == INVALID) return failed();
    errdefer _ = CloseHandle(parent);
    var csa: SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = null, .bInheritHandle = 1 };
    const child = CreateFileW(name_w.ptr, generic_read | generic_write, 0, &csa, open_existing, file_flag_overlapped, null);
    if (@intFromPtr(child) == INVALID) return failed();
    return .{ .parent = parent, .child = child };
}

/// `D:P(A;;GA;;;<SID of the user>)`.
fn userSddl(a: std.mem.Allocator) SpawnError![:0]u16 {
    var token: HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), token_query, &token) == 0) return failed();
    defer _ = CloseHandle(token);
    var buf: [256]u8 align(8) = undefined;
    var len: DWORD = 0;
    if (GetTokenInformation(token, token_user, &buf, buf.len, &len) == 0) return failed();
    const user: *const SID_AND_ATTRIBUTES = @ptrCast(&buf);
    var str: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(user.Sid, &str) == 0) return failed();
    defer _ = LocalFree(str);
    const s = std.mem.span(str.?);
    const head = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;GA;;;");
    const out = try a.allocSentinel(u16, head.len + s.len + 1, 0);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..][0..s.len], s);
    out[head.len + s.len] = ')';
    return out;
}

/// The copy of the runner in `%TEMP%\ztcl-iso`, which each AppContainer
/// can read and run. Makes the folder and the copy when they are not
/// there.
fn runnerCopy(a: std.mem.Allocator, self_exe: []const u8) SpawnError![]u8 {
    const src_w = try wide(a, self_exe);
    defer a.free(src_w);
    var attr: FILE_ATTRIBUTE_DATA = undefined;
    if (GetFileAttributesExW(src_w.ptr, 0, &attr) == 0) return failed();
    var tmp: [261]u16 = undefined;
    const tn = GetTempPathW(tmp.len, &tmp);
    if (tn == 0 or tn >= tmp.len) return failed();
    const tmp8 = std.unicode.wtf16LeToWtf8Alloc(a, tmp[0..tn]) catch return error.OutOfMemory;
    defer a.free(tmp8);
    const dir = std.fmt.allocPrint(a, "{s}ztcl-iso", .{tmp8}) catch return error.OutOfMemory;
    defer a.free(dir);
    const dir_w = try wide(a, dir);
    defer a.free(dir_w);
    if (CreateDirectoryW(dir_w.ptr, null) != 0) {
        // A new folder: each AppContainer, and each one of the low
        // privilege form, can read and run its files.
        for ([_][:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("S-1-15-2-1"),
            std.unicode.utf8ToUtf16LeStringLiteral("S-1-15-2-2"),
        }) |n| {
            var p: PSID = undefined;
            if (ConvertStringSidToSidW(n.ptr, &p) == 0) return failed();
            defer _ = LocalFree(p);
            setAce(dir_w, p, file_read_execute, grant_access, sub_containers_and_objects) catch return error.SpawnFailed;
        }
    } else if (GetLastError() != error_already_exists) return failed();
    const size = (@as(u64, attr.nFileSizeHigh) << 32) | attr.nFileSizeLow;
    const time = (@as(u64, attr.ftLastWriteTime[1]) << 32) | attr.ftLastWriteTime[0];
    const dst = std.fmt.allocPrint(a, "{s}\\ztcl-{d}-{x}.exe", .{ dir, size, time }) catch return error.OutOfMemory;
    errdefer a.free(dst);
    const dst_w = try wide(a, dst);
    defer a.free(dst_w);
    if (CopyFileW(src_w.ptr, dst_w.ptr, 1) == 0 and GetLastError() != error_file_exists) return failed();
    return dst;
}

/// Adds or removes an ACE of `sid` on the DACL of the file or folder
/// `path`.
fn setAce(path: [:0]const u16, sid: PSID, access: DWORD, mode: c_int, inherit: DWORD) error{Failed}!void {
    var old: ?*anyopaque = null;
    var sd: ?*anyopaque = null;
    if (GetNamedSecurityInfoW(path.ptr, se_file_object, dacl_security_information, null, null, &old, null, &sd) != 0) return error.Failed;
    defer _ = LocalFree(sd);
    var ea: EXPLICIT_ACCESS_W = .{
        .grfAccessPermissions = access,
        .grfAccessMode = mode,
        .grfInheritance = inherit,
        .Trustee = .{ .TrusteeForm = trustee_is_sid, .TrusteeType = 0, .ptstrName = sid },
    };
    var new: ?*anyopaque = null;
    if (SetEntriesInAclW(1, @ptrCast(&ea), old, &new) != 0) return error.Failed;
    defer _ = LocalFree(new);
    if (SetNamedSecurityInfoW(path.ptr, se_file_object, dacl_security_information, null, null, new, null) != 0) return error.Failed;
}

fn wide(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch return error.OutOfMemory;
}

// ---- Win32 ----

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
    lpReserved2: ?*anyopaque = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const STARTUPINFOEXW = extern struct { info: STARTUPINFOW, attrs: ?*anyopaque };
const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: DWORD, dwThreadId: DWORD };
const SID_AND_ATTRIBUTES = extern struct { Sid: PSID, Attributes: DWORD };
const SECURITY_CAPABILITIES = extern struct {
    AppContainerSid: PSID,
    Capabilities: ?[*]SID_AND_ATTRIBUTES,
    CapabilityCount: DWORD,
    Reserved: DWORD = 0,
};
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
const ASSOCIATE_PORT = extern struct { CompletionKey: ?*anyopaque, CompletionPort: HANDLE };
const TRUSTEE_W = extern struct {
    pMultipleTrustee: ?*anyopaque = null,
    MultipleTrusteeOperation: c_int = 0,
    TrusteeForm: c_int,
    TrusteeType: c_int,
    ptstrName: ?*anyopaque,
};
const EXPLICIT_ACCESS_W = extern struct {
    grfAccessPermissions: DWORD,
    grfAccessMode: c_int,
    grfInheritance: DWORD,
    Trustee: TRUSTEE_W,
};
const FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: [2]DWORD,
    ftLastAccessTime: [2]DWORD,
    ftLastWriteTime: [2]DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(STARTUPINFOEXW) == 112);
        std.debug.assert(@sizeOf(EXTENDED_LIMIT) == 144);
        std.debug.assert(@sizeOf(ACCOUNTING) == 48);
        std.debug.assert(@sizeOf(SECURITY_CAPABILITIES) == 24);
        std.debug.assert(@sizeOf(EXPLICIT_ACCESS_W) == 48);
        std.debug.assert(@sizeOf(FILE_ATTRIBUTE_DATA) == 36);
    }
}

const extended_startupinfo_present: DWORD = 0x00080000;
const create_suspended: DWORD = 0x4;
const create_no_window: DWORD = 0x08000000;
const create_unicode_environment: DWORD = 0x400;
const startf_usestdhandles: DWORD = 0x100;
const attr_handle_list: usize = 0x00020002;
const attr_security_capabilities: usize = 0x00020009;
const se_group_enabled: DWORD = 0x4;
const pipe_access_duplex: DWORD = 0x3;
const file_flag_overlapped: DWORD = 0x40000000;
const file_flag_first_pipe_instance: DWORD = 0x00080000;
const pipe_reject_remote_clients: DWORD = 0x8;
const generic_read: DWORD = 0x80000000;
const generic_write: DWORD = 0x40000000;
const open_existing: DWORD = 3;
const token_query: DWORD = 0x8;
const token_user: c_int = 1;
const limit_job_time: DWORD = 0x4;
const limit_active_process: DWORD = 0x8;
const limit_process_memory: DWORD = 0x100;
const limit_die_on_unhandled_exception: DWORD = 0x400;
const limit_kill_on_job_close: DWORD = 0x2000;
const job_basic_accounting: c_int = 1;
const job_basic_ui: c_int = 4;
const job_associate_port: c_int = 7;
const job_extended_limit: c_int = 9;
const job_msg_end_of_job_time: DWORD = 1;
const job_msg_end_of_process_time: DWORD = 2;
const job_msg_process_memory_limit: DWORD = 9;
const job_msg_job_memory_limit: DWORD = 10;
const se_file_object: c_int = 1;
const dacl_security_information: DWORD = 0x4;
const grant_access: c_int = 1;
const revoke_access: c_int = 4;
const sub_containers_and_objects: DWORD = 0x3;
const trustee_is_sid: c_int = 0;
/// FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_GENERIC_EXECUTE, and DELETE.
const file_modify: DWORD = 0x1301BF;
/// FILE_GENERIC_READ and FILE_GENERIC_EXECUTE.
const file_read_execute: DWORD = 0x1200A9;
const error_already_exists: DWORD = 183;
const error_file_exists: DWORD = 80;

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
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateIoCompletionPort(file: HANDLE, existing: ?HANDLE, key: usize, threads: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetQueuedCompletionStatus(port: HANDLE, bytes: *DWORD, key: *usize, ov: *?*anyopaque, ms: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open: DWORD, mode: DWORD, max: DWORD, out_size: DWORD, in_size: DWORD, timeout: DWORD, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disp: DWORD, flags: DWORD, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, len: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetTempPathW(len: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CopyFileW(src: [*:0]const u16, dst: [*:0]const u16, fail_if_exists: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesExW(name: [*:0]const u16, level: c_int, info: *FILE_ATTRIBUTE_DATA) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(p: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(proc: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(token: HANDLE, class: c_int, info: *anyopaque, len: DWORD, ret: *DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn ConvertSidToStringSidW(sid: PSID, out: *?[*:0]u16) callconv(.winapi) BOOL;
extern "advapi32" fn ConvertStringSidToSidW(s: [*:0]const u16, out: *PSID) callconv(.winapi) BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(s: [*:0]const u16, rev: DWORD, sd: *?*anyopaque, len: ?*DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn GetNamedSecurityInfoW(name: [*:0]const u16, kind: c_int, info: DWORD, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: ?*?*anyopaque, sacl: ?*?*anyopaque, sd: *?*anyopaque) callconv(.winapi) DWORD;
extern "advapi32" fn SetNamedSecurityInfoW(name: [*:0]const u16, kind: c_int, info: DWORD, owner: ?*anyopaque, group: ?*anyopaque, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) DWORD;
extern "advapi32" fn SetEntriesInAclW(count: u32, list: [*]EXPLICIT_ACCESS_W, old: ?*anyopaque, new: *?*anyopaque) callconv(.winapi) DWORD;
extern "advapi32" fn FreeSid(sid: PSID) callconv(.winapi) ?*anyopaque;
extern "userenv" fn CreateAppContainerProfile(name: [*:0]const u16, display: [*:0]const u16, desc: [*:0]const u16, caps: ?[*]SID_AND_ATTRIBUTES, count: DWORD, sid: *PSID) callconv(.winapi) HRESULT;
extern "userenv" fn DeleteAppContainerProfile(name: [*:0]const u16) callconv(.winapi) HRESULT;
extern "bcrypt" fn BCryptGenRandom(alg: ?*anyopaque, buf: [*]u8, len: u32, flags: u32) callconv(.winapi) i32;
