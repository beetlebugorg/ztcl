//! The DAX window of a virtio-fs share on the Windows Hypervisor Platform
//! (`whp.zig`, the plan in `docs/dev/virtiofs.md`). The window is a range
//! of guest addresses above the RAM and the devices, with no memory of
//! the host until the guest asks for a mapping.
//!
//! FUSE_SETUPMAPPING gives a range of a file and an offset in the window.
//! The window keeps a handle of the file for the mapping, and maps a view:
//! a section of the file (`CreateFileMappingW`), a view of the range in the
//! address space of the host (`MapViewOfFile`), and that view at the guest
//! address of the window plus the offset (`WHvMapGpaRange`), read-only or
//! read-write, with the advice of `WHvAdviseGpaRange` to fill the map of
//! the hypervisor at once. A view and the reads and writes of the host
//! share the pages of the file cache of Windows, so a write on either side
//! shows on the other at once. FUSE_REMOVEMAPPING undoes each step.
//!
//! A view ends at the end of the file when the mapping is made. Windows
//! refuses to truncate a file with a section, and a view does not grow
//! with the file. So a mapping can lose its view and keep its range: the
//! server drops the views of a file before it changes the size of the file
//! and when the guest releases the file, and a file that the guest has no
//! open handle for is free on the host. A load or a store of the guest in
//! a range with no view comes to `fault` as a memory exit: the window maps
//! a view again at the size of the file now, and does that one access on
//! it. A place past the end of the file reads zeros.
//!
//! The FUSE server and `fault` run on the threads of the vCPUs under the
//! lock of the device, so the calls of one window never run at the same
//! time.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const fuse = @import("virtio/fuse.zig");
const share_windows = @import("share_windows.zig");
const E = @import("virtio/ninep.zig").E;
const Lock = @import("virtio/mmio.zig").Lock;

const HANDLE = *anyopaque;
const Partition = *anyopaque;
const HRESULT = i32;
const BOOL = i32;

extern "kernel32" fn CreateFileMappingW(h: HANDLE, sa: ?*anyopaque, protect: u32, size_high: u32, size_low: u32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn MapViewOfFile(section: HANDLE, access: u32, off_high: u32, off_low: u32, size: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(addr: *const anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn ReOpenFile(h: HANDLE, access: u32, share: u32, flags: u32) callconv(.winapi) isize;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetModuleHandleA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(lib: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "winhvplatform" fn WHvMapGpaRange(p: Partition, host: *anyopaque, gpa: u64, size: u64, flags: u32) callconv(.winapi) HRESULT;
extern "winhvplatform" fn WHvUnmapGpaRange(p: Partition, gpa: u64, size: u64) callconv(.winapi) HRESULT;

const page_readonly: u32 = 0x02;
const page_readwrite: u32 = 0x04;
const file_map_write: u32 = 0x02;
const file_map_read: u32 = 0x04;
const generic_read: u32 = 0x80000000;
const generic_write: u32 = 0x40000000;
const share_all: u32 = 0x7;
const gpa_read: u32 = 1;
const gpa_write: u32 = 2;
const gpa_execute: u32 = 4;

/// The guest address of the first window, at 4 GiB: the RAM of a WHP
/// guest is below the devices at 0xd0000000.
pub const base: u64 = 4 << 30;
/// The size of each window.
pub const window_size: u64 = 1 << 30;
/// A view of a file starts at a multiple of the allocation granularity
/// of Windows, 64 KiB.
pub const align_log2: u16 = 16;

var advise_fn: ?*const anyopaque = null;

const Map = struct {
    moffset: u64,
    /// The length of the range that the guest asked for.
    len: u64,
    foffset: u64,
    write: bool,
    node: u64,
    /// The handle of the file that the window keeps, with the access of
    /// the mapping.
    file: HANDLE,
    /// The view, when the mapping has one: its section, and the bytes of
    /// its guest map, a multiple of the page.
    section: ?HANDLE = null,
    view: ?[*]u8 = null,
    size: u64 = 0,
    /// The tick (ms) when the guest closed its last handle of the node, or
    /// 0 while it has one.
    idle_at: u64 = 0,
};

pub const Window = struct {
    alloc: std.mem.Allocator,
    part: Partition,
    gpa: u64,
    maps: std.ArrayList(Map) = .empty,
    /// Each new view gets the advice of `advise`.
    prefault: bool = true,
    /// The lock of the device, which the sweep of idle views takes.
    lock: *Lock,
    sweeper: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Counts of the calls, for the tests and a trace.
    setups: u64 = 0,
    faults: u64 = 0,

    pub fn dax(w: *Window) fuse.Dax {
        return .{ .ctx = w, .size = window_size, .align_log2 = align_log2, .setup = setup, .remove = remove, .drop = drop, .idle = idle, .clear = clear };
    }

    pub fn deinit(w: *Window) void {
        if (w.sweeper) |t| {
            w.stop.store(true, .release);
            t.join();
            w.sweeper = null;
        }
        clear(w);
        w.maps.deinit(w.alloc);
    }

    fn setup(ctx: *anyopaque, node: u64, fh: u64, foffset: u64, len: u64, write: bool, moffset: u64) u32 {
        const w: *Window = @ptrCast(@alignCast(ctx));
        w.setups += 1;
        // A new mapping replaces each old one in its range.
        _ = remove(ctx, moffset, len);
        const access = generic_read | (if (write) generic_write else 0);
        const again = ReOpenFile(share_windows.fileOf(fh), access, share_all, 0);
        if (again == -1 or again == 0) return E.IO;
        const file: HANDLE = @ptrFromInt(@as(usize, @bitCast(again)));
        w.maps.append(w.alloc, .{ .moffset = moffset, .len = len, .foffset = foffset, .write = write, .node = node, .file = file }) catch {
            _ = CloseHandle(file);
            return E.NOMEM;
        };
        return w.mapView(&w.maps.items[w.maps.items.len - 1]);
    }

    /// Maps a view of `m` at the size of its file now. No view for a
    /// range past the end of the file.
    fn mapView(w: *Window, m: *Map) u32 {
        w.unmapView(m);
        var size: i64 = 0;
        if (GetFileSizeEx(m.file, &size) == 0) return E.IO;
        const end: u64 = @intCast(size);
        if (m.foffset >= end) return 0;
        const view_len = @min(m.len, end - m.foffset);
        const section = CreateFileMappingW(m.file, null, if (m.write) page_readwrite else page_readonly, 0, 0, null) orelse return E.IO;
        const view = MapViewOfFile(section, if (m.write) file_map_write else file_map_read, @truncate(m.foffset >> 32), @truncate(m.foffset), @intCast(view_len)) orelse {
            _ = CloseHandle(section);
            return E.IO;
        };
        const pages = std.mem.alignForward(u64, view_len, 4096);
        const flags = gpa_read | gpa_execute | (if (m.write) gpa_write else 0);
        if (WHvMapGpaRange(w.part, view, w.gpa + m.moffset, pages, flags) < 0) {
            _ = UnmapViewOfFile(view);
            _ = CloseHandle(section);
            return E.IO;
        }
        m.section = section;
        m.view = @ptrCast(view);
        m.size = pages;
        if (w.prefault) advise(w.part, w.gpa + m.moffset, pages, m.write);
        return 0;
    }

    fn unmapView(w: *Window, m: *Map) void {
        const view = m.view orelse return;
        _ = WHvUnmapGpaRange(w.part, w.gpa + m.moffset, m.size);
        _ = UnmapViewOfFile(view);
        _ = CloseHandle(m.section.?);
        m.section = null;
        m.view = null;
        m.size = 0;
    }

    fn remove(ctx: *anyopaque, moffset: u64, len: u64) u32 {
        const w: *Window = @ptrCast(@alignCast(ctx));
        var i: usize = 0;
        while (i < w.maps.items.len) {
            const m = &w.maps.items[i];
            if (m.moffset < moffset + len and moffset < m.moffset + m.len) {
                w.unmapView(m);
                _ = CloseHandle(m.file);
                _ = w.maps.swapRemove(i);
            } else i += 1;
        }
        return 0;
    }

    /// Drops the views of the mappings of `node`, and keeps their ranges.
    fn drop(ctx: *anyopaque, node: u64) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        for (w.maps.items) |*m| if (m.node == node) w.unmapView(m);
    }

    fn idle(ctx: *anyopaque, node: u64, on: bool) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        const now = if (on) @max(1, GetTickCount64()) else 0;
        for (w.maps.items) |*m| if (m.node == node) {
            m.idle_at = now;
        };
        if (on and w.sweeper == null) {
            w.sweeper = std.Thread.spawn(.{}, sweep, .{w}) catch null;
        }
    }

    /// The time after the last close of a file by the guest when its views
    /// go, so the host can truncate it, rename over it, or delete it: the
    /// same bound as the times of the cache of the server.
    pub const idle_ms = 1000;

    /// Each 250 ms, drops the views of the mappings idle for `idle_ms`.
    fn sweep(w: *Window) void {
        while (!w.stop.load(.acquire)) {
            Sleep(250);
            w.lock.lock();
            defer w.lock.unlock();
            const now = GetTickCount64();
            for (w.maps.items) |*m| {
                if (m.idle_at == 0 or m.view == null or now - m.idle_at < idle_ms) continue;
                w.unmapView(m);
            }
        }
    }

    fn clear(ctx: *anyopaque) void {
        const w: *Window = @ptrCast(@alignCast(ctx));
        _ = remove(ctx, 0, window_size);
        w.maps.clearRetainingCapacity();
    }

    /// Maps the view of the mapping at `offset` of the window again, for a
    /// memory exit there. True when the place now has a view that takes
    /// the access, so the guest can run its instruction again.
    pub fn remap(w: *Window, offset: u64, write: bool) bool {
        for (w.maps.items) |*m| {
            if (offset < m.moffset or offset >= m.moffset + m.len) continue;
            if (write and !m.write) return false;
            // A view that covers the place already: the exit has another
            // cause, and the emulator handles it.
            if (m.view != null and offset < m.moffset + m.size) return false;
            w.faults += 1;
            if (w.mapView(m) != 0) return false;
            return m.view != null and offset < m.moffset + m.size;
        }
        return false;
    }

    /// A load or a store of `data` by the guest at `offset` of the window,
    /// where the hypervisor has no map: a mapping that lost its view, or
    /// a place past its view. The window maps the view again and does the
    /// access on it, so the next ones go to the memory with no exit. A
    /// place in no mapping, or past the end of its file, reads zeros.
    pub fn fault(w: *Window, offset: u64, write: bool, data: []u8) void {
        w.faults += 1;
        for (w.maps.items) |*m| {
            if (offset < m.moffset or offset >= m.moffset + m.len) continue;
            if (m.view == null or offset + data.len > m.moffset + m.size) _ = w.mapView(m);
            const at = offset - m.moffset;
            const view = m.view orelse break;
            if (at + data.len > m.size) break;
            if (write) {
                if (m.write) @memcpy(view[at..][0..data.len], data);
            } else @memcpy(data, view[at..][0..data.len]);
            return;
        }
        if (!write) @memset(data, 0);
    }

    /// Fills the map of the hypervisor for the pages of a new view, as
    /// `whp.populate` does for the RAM. With no advice, each first touch
    /// of a page of the guest faults in the hypervisor and in the view of
    /// the host, one page at a time. A host without `WHvAdviseGpaRange`
    /// (before Windows 10 2004) leaves the pages to the first touch.
    fn advise(p: Partition, gpa: u64, size: u64, write: bool) void {
        const Range = extern struct { gpa: u64, size: u64 };
        const Advice = extern struct { flags: u32, access: u32 };
        const Fn = *const fn (Partition, [*]const Range, u32, u32, *const Advice, u32) callconv(.winapi) HRESULT;
        const f: Fn = if (advise_fn) |p0| @ptrCast(p0) else blk: {
            const lib = GetModuleHandleA("winhvplatform.dll") orelse return;
            const got: Fn = @ptrCast(GetProcAddress(lib, "WHvAdviseGpaRange") orelse return);
            advise_fn = got;
            break :blk got;
        };
        const range = [1]Range{.{ .gpa = gpa, .size = size }};
        // WHV_ADVISE_GPA_RANGE_POPULATE: the flag Prefetch, and the access
        // WHvMemoryAccessRead (0) or WHvMemoryAccessWrite (1).
        const advice: Advice = .{ .flags = 1, .access = @intFromBool(write) };
        // WHvAdviseGpaRangeCodePopulate.
        _ = f(p, &range, 1, 0, &advice, @sizeOf(Advice));
    }
};
