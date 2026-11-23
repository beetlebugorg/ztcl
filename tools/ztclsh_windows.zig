//! The `ztclsh` of `tools/suite.sh` on Windows.
//!
//! The Tcl tests run their interpreter as a child process. On other
//! systems `ztclsh` is a shell script that runs the suite runner with its
//! options. Windows runs no `#!` script, so this small program does that
//! work. It reads the runner and its options from `ztclsh.args`, one word
//! on each line, beside this program. It adds the current folder and the
//! words of its own command line, runs the runner, and gives its exit code.
//!
//! Only `zig build suite-runner` builds this file.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const HANDLE = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;

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
const ProcessInfo = extern struct { process: HANDLE, thread: HANDLE, pid: u32, tid: u32 };

extern "kernel32" fn GetModuleFileNameW(module: HANDLE, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetCurrentDirectoryW(size: DWORD, buf: [*]u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetStdHandle(n: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, got: *DWORD, over: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, command: ?[*:0]u16, process_security: ?*anyopaque, thread_security: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*const anyopaque, cwd: ?[*:0]const u16, startup: *StartupInfo, info: *ProcessInfo) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

fn appendWord(a: std.mem.Allocator, out: *std.ArrayList(u16), word: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(a, word);
    const quote = std.mem.indexOfScalar(u8, word, ' ') != null;
    if (out.items.len > 0) try out.append(a, ' ');
    if (quote) try out.append(a, '"');
    try out.appendSlice(a, wide);
    if (quote) try out.append(a, '"');
}

/// The command line after its first word, as the parent wrote it.
fn restOfLine(line: []const u16) []const u16 {
    var at: usize = 0;
    if (line.len > 0 and line[0] == '"') {
        at = 1;
        while (at < line.len and line[at] != '"') at += 1;
        if (at < line.len) at += 1;
    } else {
        while (at < line.len and line[at] != ' ' and line[at] != '\t') at += 1;
    }
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    return line[at..];
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    var self: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &self, self.len - 8);
    if (n == 0 or n < 4) ExitProcess(126);
    // `ztclsh.exe` becomes `ztclsh.args`.
    const tail = std.unicode.utf8ToUtf16LeStringLiteral(".args");
    @memcpy(self[n - 4 ..][0..tail.len], tail);
    self[n - 4 + tail.len] = 0;
    const file = CreateFileW(@ptrCast(&self), 0x8000_0000, 1, null, 3, 0, null);
    if (file == @as(HANDLE, @ptrFromInt(~@as(usize, 0)))) ExitProcess(126);
    var text: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        var got: DWORD = 0;
        if (ReadFile(file, &buf, buf.len, &got, null) == 0 or got == 0) break;
        try text.appendSlice(a, buf[0..got]);
    }
    _ = CloseHandle(file);

    var words = std.mem.tokenizeAny(u8, text.items, "\r\n");
    const runner = words.next() orelse ExitProcess(126);
    const app = try std.unicode.utf8ToUtf16LeAllocZ(a, runner);
    var line: std.ArrayList(u16) = .empty;
    try appendWord(a, &line, runner);
    while (words.next()) |w| try appendWord(a, &line, w);

    var folder: [1024]u16 = undefined;
    const f = GetCurrentDirectoryW(folder.len, &folder);
    if (f == 0 or f >= folder.len) ExitProcess(126);
    for (folder[0..f]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    const here = try std.unicode.utf16LeToUtf8Alloc(a, folder[0..f]);
    try appendWord(a, &line, "--cwd");
    try appendWord(a, &line, here);
    try appendWord(a, &line, "--tclsh");
    const rest = restOfLine(std.mem.span(GetCommandLineW()));
    if (rest.len > 0) {
        try line.append(a, ' ');
        try line.appendSlice(a, rest);
    }
    const command = try line.toOwnedSliceSentinel(a, 0);
    var startup: StartupInfo = .{
        .cb = @sizeOf(StartupInfo),
        .flags = 0x100,
        .input = GetStdHandle(@bitCast(@as(i32, -10))),
        .output = GetStdHandle(@bitCast(@as(i32, -11))),
        .err = GetStdHandle(@bitCast(@as(i32, -12))),
    };
    var info: ProcessInfo = undefined;
    if (CreateProcessW(app.ptr, command.ptr, null, null, 1, 0, null, null, &startup, &info) == 0) ExitProcess(127);
    _ = CloseHandle(info.thread);
    _ = WaitForSingleObject(info.process, 0xFFFF_FFFF);
    var code: u32 = 1;
    _ = GetExitCodeProcess(info.process, &code);
    ExitProcess(code);
}
