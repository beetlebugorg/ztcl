//! The Windows form of `ztcl::watch` (`watch.zig`): one folder handle
//! for each watcher, with `ReadDirectoryChangesW` in overlapped mode on
//! an I/O completion port of its own.
//!
//! `open` opens the folder through the jail of `fsroot.zig`, so the
//! checks of the root and of reparse points apply, and opens that handle
//! again by its final path with `FILE_FLAG_OVERLAPPED`, which the jail
//! does not give. Both handles must name one folder. `-recursive` is the
//! `bWatchSubtree` of the read, so a new folder needs no watch of its
//! own. A read waits at each moment, so the file system keeps the
//! changes between two reads in its own buffer.
//!
//! `drain` reads the completions of the port with no wait and turns each
//! `FILE_NOTIFY_INFORMATION` record into an event: added and the new
//! name of a rename are `created`, removed is `deleted`, the old name of
//! a rename is `moved`, and the rest is `modified`. A change of the time
//! of a folder, which Windows gives for each change in the folder, is
//! no event. A read of 0 bytes or `ERROR_NOTIFY_ENUM_DIR` is a lost
//! buffer: `overflow`.
//!
//! The event of the read (`event`) is signaled when a completion waits,
//! so an embedder can wait on it in the place of a descriptor.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const fsroot = @import("fsroot.zig");
const Interp = interp.Interp;
const Error = interp.Error;

const HANDLE = *anyopaque;
const DWORD = u32;
const BOOL = i32;

pub const Kind = enum { created, modified, deleted, moved, overflow };

/// A change: its kind and the path below the folder of the watch, with
/// `/` between the names.
pub const Event = struct { kind: Kind, name: []u8 };

const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?HANDLE = null,
};

/// The size of the buffer of a read. A larger read fails on a folder of
/// the network.
const buf_size = 64 << 10;

pub const Win = struct {
    dir: HANDLE,
    port: HANDLE,
    event: HANDLE,
    ov: OVERLAPPED = .{},
    buf: []align(4) u8,
    recursive: bool,
    /// True while a read waits on the folder.
    pending: bool = false,

    /// The handle that an embedder waits on.
    pub fn waitHandle(w: *const Win) usize {
        return @intFromPtr(w.event);
    }
};

const notify_filter: DWORD = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40; // file name, folder name, attributes, size, last write, creation
const file_list_directory: DWORD = 0x1;
const share_all: DWORD = 0x7;
const flag_backup_semantics: DWORD = 0x02000000;
const flag_overlapped: DWORD = 0x40000000;
const open_existing: DWORD = 3;
const error_notify_enum_dir: DWORD = 1022;
const error_operation_aborted: DWORD = 995;
const invalid: usize = std.math.maxInt(usize);

/// Opens the watch of the folder `rel` (a normal path of `fsroot`) in
/// `w`, which must not move until `close`.
pub fn open(it: *Interp, w: *Win, rel: []const u8, recursive: bool) Error!void {
    const fd = switch (try fsroot.openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |x| x,
        .err => |e| return fsroot.posixError(it, e, "couldn't watch the folder: "),
    };
    const jailed: HANDLE = @ptrFromInt(@as(usize, @intCast(fd)));
    defer _ = CloseHandle(jailed);
    const dir = try reopen(it, jailed);
    errdefer _ = CloseHandle(dir);
    const port = CreateIoCompletionPort(dir, null, 0, 1) orelse return it.fail("couldn't start a watch: Windows error {d}", .{GetLastError()});
    errdefer _ = CloseHandle(port);
    const event = CreateEventW(null, 1, 0, null) orelse return it.fail("couldn't start a watch: Windows error {d}", .{GetLastError()});
    errdefer _ = CloseHandle(event);
    const buf = try it.alloc().alignedAlloc(u8, .@"4", buf_size);
    errdefer it.alloc().free(buf);
    w.* = .{ .dir = dir, .port = port, .event = event, .buf = buf, .recursive = recursive };
    if (!start(w)) return it.fail("couldn't start a watch: Windows error {d}", .{GetLastError()});
}

/// Opens the folder of `jailed` again for overlapped reads: by its final
/// path, and then a check that both handles name one file (the serial
/// number of the volume and the index of the file), so a folder that a
/// rename puts in its place in the meantime is an error.
fn reopen(it: *Interp, jailed: HANDLE) Error!HANDLE {
    var path: [32768]u16 = undefined;
    const n = GetFinalPathNameByHandleW(jailed, &path, path.len - 1, 0);
    if (n == 0 or n >= path.len - 1) return denied(it);
    path[n] = 0;
    const dir = CreateFileW(path[0..n :0].ptr, file_list_directory, share_all, null, open_existing, flag_backup_semantics | flag_overlapped, null);
    if (@intFromPtr(dir) == invalid) return denied(it);
    var a: FileInfo = undefined;
    var b: FileInfo = undefined;
    if (GetFileInformationByHandle(jailed, &a) == 0 or GetFileInformationByHandle(dir, &b) == 0 or
        a.volume != b.volume or a.index_high != b.index_high or a.index_low != b.index_low)
    {
        _ = CloseHandle(dir);
        return denied(it);
    }
    return dir;
}

fn denied(it: *Interp) Error {
    return it.failCode("POSIX EACCES {permission denied}", "couldn't watch the folder: permission denied", .{});
}

const FileInfo = extern struct {
    attributes: DWORD,
    created: u64 align(4),
    accessed: u64 align(4),
    written: u64 align(4),
    volume: DWORD,
    size_high: DWORD,
    size_low: DWORD,
    links: DWORD,
    index_high: DWORD,
    index_low: DWORD,
};

/// Starts the next read.
fn start(w: *Win) bool {
    w.ov = .{ .event = w.event };
    if (ReadDirectoryChangesW(w.dir, w.buf.ptr, @intCast(w.buf.len), @intFromBool(w.recursive), notify_filter, null, &w.ov, null) == 0) return false;
    w.pending = true;
    return true;
}

/// Adds the changes that wait to `out`, with no wait.
pub fn drain(it: *Interp, w: *Win, out: *std.ArrayList(Event)) Error!void {
    const a = it.alloc();
    while (w.pending) {
        var n: DWORD = 0;
        var key: usize = 0;
        var ov: ?*OVERLAPPED = null;
        const ok = GetQueuedCompletionStatus(w.port, &n, &key, &ov, 0);
        if (ov == null) return; // No completion waits.
        w.pending = false;
        if (ok == 0) {
            const e = GetLastError();
            if (e == error_operation_aborted) return;
            if (e != error_notify_enum_dir) return it.fail("couldn't read the changes: Windows error {d}", .{e});
            try out.append(a, .{ .kind = .overflow, .name = &.{} });
        } else if (n == 0) {
            try out.append(a, .{ .kind = .overflow, .name = &.{} });
        } else try records(it, w.buf[0..n], out);
        if (!start(w)) return it.fail("couldn't read the changes: Windows error {d}", .{GetLastError()});
    }
}

fn records(it: *Interp, data: []align(4) const u8, out: *std.ArrayList(Event)) Error!void {
    const a = it.alloc();
    var off: usize = 0;
    while (off + 12 <= data.len) {
        const next = std.mem.readInt(u32, data[off..][0..4], .little);
        const action = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const len = std.mem.readInt(u32, data[off + 8 ..][0..4], .little);
        if (off + 12 + len > data.len) return;
        const wide: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, data[off + 12 ..][0..len]));
        const name = try std.unicode.wtf16LeToWtf8Alloc(a, wide);
        for (name) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        const kind: Kind = switch (action) {
            1, 5 => .created, // added, the new name of a rename
            2 => .deleted,
            4 => .moved, // the old name of a rename
            else => .modified,
        };
        try out.append(a, .{ .kind = kind, .name = name });
        if (next == 0) return;
        off += next;
    }
}

/// Ends the read and closes the handles.
pub fn close(it: *Interp, w: *Win) void {
    if (w.pending) {
        _ = CancelIoEx(w.dir, &w.ov);
        var n: DWORD = 0;
        _ = GetOverlappedResult(w.dir, &w.ov, &n, 1);
    }
    _ = CloseHandle(w.dir);
    _ = CloseHandle(w.port);
    _ = CloseHandle(w.event);
    it.alloc().free(w.buf);
    w.* = undefined;
}

extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]u16, len: DWORD, flags: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *FileInfo) callconv(.winapi) BOOL;
extern "kernel32" fn CreateIoCompletionPort(file: HANDLE, port: ?HANDLE, key: usize, threads: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateEventW(sa: ?*anyopaque, manual: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ReadDirectoryChangesW(dir: HANDLE, buf: [*]u8, len: DWORD, subtree: BOOL, filter: DWORD, got: ?*DWORD, ov: *OVERLAPPED, done: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetQueuedCompletionStatus(port: HANDLE, bytes: *DWORD, key: *usize, ov: *?*OVERLAPPED, ms: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(h: HANDLE, ov: *OVERLAPPED, n: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
