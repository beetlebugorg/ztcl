//! The guest of `thread::create -isolation vm` (ztcl#471): the ztcl
//! unikernel (`src/unikernel.zig`) on the KVM monitor of `kvm.zig`.
//!
//! `start` reads the image once for each process, makes a guest of one
//! CPU with twice the memory limit of the thread plus `runtime_mb`, gives
//! it a new bootstrap secret, the rate of the time stamp counter, and the
//! time of the host at one count of the counter on its command line
//! (`ztcl.secret=`, `ztcl.tsc_khz=`, `ztcl.epoch=`), and connects to vsock port 1024 of the guest. The
//! bridge of `isothread.zig` then runs the protocol on that socket, with
//! the secret as the salt of the handshake.
//!
//! The console of the guest is one end of a socket pair. The guest
//! writes to it only on a panic or an exception, and `consoleText`
//! reads that text for the error of a failed start.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const kvm = @import("kvm.zig");
const iso = @import("isoproto.zig");
const linux = std.os.linux;

pub const supported = kvm.supported;

/// The memory of the guest past the memory limit of the thread: the
/// image (its stack is 8 MiB), the page tables, the vsock rings, and the
/// pieces of the heap. The guest also gets the memory limit twice, as a
/// growth of a block can copy it.
pub const runtime_mb: u32 = 32;
/// The most memory of one guest: the guest maps the first 4 GB, and the
/// devices are at 0xd0000000 and above.
pub const max_mb: u32 = 3072;
pub const port: u32 = 1024;

pub const Guest = struct {
    m: *kvm,
    con: [2]i32,
    secret: [32]u8,
    cmdline: [224]u8 = undefined,
    fd: i32 = -1,

    /// Stops the guest and frees it. The vsock socket stays with the
    /// transport.
    pub fn stop(g: *Guest, a: std.mem.Allocator) void {
        g.m.deinit();
        for (g.con) |f| _ = linux.close(f);
        a.destroy(g);
    }

    /// The text that the guest wrote to its console, for an error.
    pub fn consoleText(g: *Guest, buf: []u8) []const u8 {
        const n = linux.recvfrom(g.con[1], buf.ptr, buf.len, linux.MSG.DONTWAIT, null, null);
        return if (linux.errno(n) == .SUCCESS) std.mem.trimEnd(u8, buf[0..n], "\r\n") else "";
    }
};

var image_lock: std.atomic.Mutex = .unlocked;
var image: ?[]const u8 = null;
var tsc_khz: u64 = 0;

/// The error text of the last failed `start`.
pub threadlocal var why: []const u8 = "";

fn readImage(path: []const u8) ?[]const u8 {
    while (!image_lock.tryLock()) std.atomic.spinLoopHint();
    defer image_lock.unlock();
    if (image) |i| return i;
    var p: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= p.len) return null;
    @memcpy(p[0..path.len], path);
    p[path.len] = 0;
    const rc = linux.open(&p, .{ .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) != .SUCCESS) return null;
    const len: usize = @intCast(st.size);
    const buf = std.heap.page_allocator.alloc(u8, len) catch return null;
    var off: usize = 0;
    while (off < len) {
        const n = linux.read(fd, buf[off..].ptr, len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) {
            std.heap.page_allocator.free(buf);
            return null;
        }
        off += n;
    }
    image = buf;
    tsc_khz = measureTsc();
    return buf;
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// The rate of the time stamp counter, over 5 ms of the monotonic clock.
/// KVM gives the guest the counter of the host, with no scale.
fn measureTsc() u64 {
    const t0 = kvm.nowNs();
    const c0 = rdtsc();
    var ts: linux.timespec = .{ .sec = 0, .nsec = 5_000_000 };
    _ = linux.nanosleep(&ts, null);
    const t1 = kvm.nowNs();
    const c1 = rdtsc();
    if (t1 <= t0) return 0;
    return (c1 - c0) * std.time.ns_per_ms / (t1 - t0);
}

/// Boots a guest for a thread with the memory limit `mem` and connects
/// to it. Gives the guest and its socket.
pub fn start(a: std.mem.Allocator, path: []const u8, mem: u64) ?*Guest {
    const img = readImage(path) orelse {
        why = "no ztcl unikernel image next to the runner: build it with zig build unikernel";
        return null;
    };
    const want_mb: u64 = (if (mem >= @as(u64, max_mb) << 19) max_mb else 2 * @as(u32, @intCast((mem + (1 << 20) - 1) >> 20))) + runtime_mb;
    const g = a.create(Guest) catch return null;
    g.* = .{ .m = undefined, .con = .{ -1, -1 }, .secret = undefined };
    iso.entropy(&g.secret);
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) {
        a.destroy(g);
        return null;
    }
    g.con = fds;
    const hex = std.fmt.bytesToHex(g.secret, .lower);
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const epoch_us = @as(i64, ts.sec) * std.time.us_per_s + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_us);
    const cl = std.fmt.bufPrint(&g.cmdline, "ztcl.secret={s} ztcl.tsc_khz={d} ztcl.epoch={d}@{d}", .{ &hex, tsc_khz, epoch_us, rdtsc() }) catch unreachable;
    g.m = kvm.init(a, .{ .cpus = 1, .memory_mb = @intCast(@min(want_mb, max_mb)), .kernel = img, .cmdline = cl, .console = fds[0] }) catch {
        why = kvm.why;
        for (g.con) |f| _ = linux.close(f);
        a.destroy(g);
        return null;
    };
    g.m.start() catch {
        why = kvm.why;
        g.stop(a);
        return null;
    };
    g.fd = connect(g.m, port, 5000) orelse {
        var buf: [256]u8 = undefined;
        const t = g.consoleText(&buf);
        why = if (t.len > 0) "the guest stopped before it answered" else "the guest did not answer on vsock";
        g.stop(a);
        return null;
    };
    return g;
}

const AF_VSOCK = 40;

/// Connects to a port of the guest, again after each refused
/// connection, until `timeout_ms` pass. Gives a blocking socket.
fn connect(m: *kvm, p: u32, timeout_ms: u32) ?i32 {
    const end = kvm.nowNs() + @as(u64, timeout_ms) * std.time.ns_per_ms;
    while (m.getState() == .running) {
        const rc = linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        var addr: extern struct { family: u16 = AF_VSOCK, reserved1: u16 = 0, port: u32, cid: u32, flags: u8 = 0, zero: [3]u8 = @splat(0) } = .{ .port = p, .cid = @intCast(m.cid) };
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)))) == .SUCCESS) return fd;
        _ = linux.close(fd);
        if (kvm.nowNs() >= end) return null;
        var ts: linux.timespec = .{ .sec = 0, .nsec = 20_000 };
        _ = linux.nanosleep(&ts, null);
    }
    return null;
}
