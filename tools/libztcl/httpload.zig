//! A small HTTP load generator for the page-load benchmark of libztcl
//! (docs/dev/libztcl.md). Each of C threads opens one keep-alive
//! connection to 127.0.0.1:PORT and sends GET requests for PATH, one at
//! a time, until the threads have sent N requests together. It prints
//! the requests per second, the latency at p50 and p99 in milliseconds,
//! and the count of responses with status 200.
//!
//!   zig run tools/libztcl/httpload.zig -lc -- PORT PATH N C
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const c = std.c;

var next: std.atomic.Value(u64) = .init(0);
var total: u64 = 0;
var port: u16 = 0;
var request: []const u8 = "";

const Worker = struct {
    lat: std.ArrayList(u64) = .empty,
    ok: u64 = 0,
    failed: u64 = 0,
};

fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn connectLocal() ?c.fd_t {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    var one: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO.TCP, std.posix.TCP.NODELAY, @ptrCast(&one), @sizeOf(c_int));
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// Reads one response. Gives its status, or null when the connection
/// ends. `buf` keeps the bytes after the response.
fn readResponse(fd: c.fd_t, buf: *std.ArrayList(u8)) ?u32 {
    while (true) {
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |end| {
            const head = buf.items[0..end];
            const status = std.fmt.parseInt(u32, if (head.len >= 12) head[9..12] else "0", 10) catch 0;
            var body: usize = 0;
            var lines = std.mem.splitSequence(u8, head, "\r\n");
            while (lines.next()) |l| {
                if (l.len > 15 and std.ascii.eqlIgnoreCase(l[0..15], "content-length:")) {
                    body = std.fmt.parseInt(usize, std.mem.trim(u8, l[15..], " "), 10) catch 0;
                }
            }
            const need = end + 4 + body;
            while (buf.items.len < need) if (!fill(fd, buf)) return null;
            const rest = buf.items.len - need;
            std.mem.copyForwards(u8, buf.items[0..rest], buf.items[need..]);
            buf.shrinkRetainingCapacity(rest);
            return status;
        }
        if (!fill(fd, buf)) return null;
    }
}

fn fill(fd: c.fd_t, buf: *std.ArrayList(u8)) bool {
    var tmp: [16384]u8 = undefined;
    const n = c.read(fd, &tmp, tmp.len);
    if (n <= 0) return false;
    buf.appendSlice(std.heap.c_allocator, tmp[0..@intCast(n)]) catch return false;
    return true;
}

fn work(w: *Worker) void {
    const a = std.heap.c_allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var fd = connectLocal() orelse {
        w.failed += 1;
        return;
    };
    while (next.fetchAdd(1, .monotonic) < total) {
        const t0 = now();
        var sent = c.write(fd, request.ptr, request.len) == @as(isize, @intCast(request.len));
        var status: ?u32 = if (sent) readResponse(fd, &buf) else null;
        if (status == null) {
            // The server closed the connection: open a new one once.
            _ = c.close(fd);
            buf.clearRetainingCapacity();
            fd = connectLocal() orelse {
                w.failed += 1;
                return;
            };
            sent = c.write(fd, request.ptr, request.len) == @as(isize, @intCast(request.len));
            status = if (sent) readResponse(fd, &buf) else null;
        }
        const s = status orelse {
            w.failed += 1;
            continue;
        };
        w.lat.append(a, now() - t0) catch return;
        if (s == 200) w.ok += 1 else w.failed += 1;
    }
    _ = c.close(fd);
}

pub fn main(init: std.process.Init) !void {
    const a = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) {
        std.debug.print("usage: httpload PORT PATH N C\n", .{});
        return error.Usage;
    }
    port = try std.fmt.parseInt(u16, args[1], 10);
    total = try std.fmt.parseInt(u64, args[3], 10);
    const conns = try std.fmt.parseInt(usize, args[4], 10);
    request = try std.fmt.allocPrint(a, "GET /{s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n", .{args[2]});
    const workers = try a.alloc(Worker, conns);
    for (workers) |*w| w.* = .{};
    const threads = try a.alloc(std.Thread, conns);
    const t0 = now();
    for (threads, workers) |*t, *w| t.* = try std.Thread.spawn(.{}, work, .{w});
    for (threads) |t| t.join();
    const elapsed = now() - t0;
    var all: std.ArrayList(u64) = .empty;
    var ok: u64 = 0;
    var failed: u64 = 0;
    for (workers) |w| {
        try all.appendSlice(a, w.lat.items);
        ok += w.ok;
        failed += w.failed;
    }
    std.mem.sort(u64, all.items, {}, std.sort.asc(u64));
    const n = all.items.len;
    const p50 = if (n > 0) all.items[n / 2] else 0;
    const p99 = if (n > 0) all.items[@min(n - 1, n * 99 / 100)] else 0;
    const secs = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    std.debug.print("rps={d:.0} p50={d:.2}ms p99={d:.2}ms ok={d} failed={d}\n", .{
        @as(f64, @floatFromInt(n)) / secs,
        @as(f64, @floatFromInt(p50)) / std.time.ns_per_ms,
        @as(f64, @floatFromInt(p99)) / std.time.ns_per_ms,
        ok,
        failed,
    });
}
