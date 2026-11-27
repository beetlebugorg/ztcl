//! A TCP bench for `-net nat` (docs/dev/vm-net.md, Measurements). The
//! same static binary runs on the host (the servers) and in the guest
//! (the clients).
//!
//!   netbench serve PORT          sink on PORT, source on PORT+1, echo on PORT+2
//!   netbench send HOST PORT MB N    N streams send MB each to the sink
//!   netbench recv HOST PORT MB N    N streams read MB each from the source
//!   netbench rr HOST PORT COUNT     request and answer of 1 byte, COUNT times
//!   netbench crr HOST PORT COUNT    connect, 1 byte each way, close; COUNT times
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const linux = std.os.linux;

const buf_len = 1 << 20;

fn die(msg: []const u8) noreturn {
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
    linux.exit_group(1);
}

fn out(comptime f: []const u8, args: anytype) void {
    var b: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&b, f, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

fn nodelay(fd: i32) void {
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), 4);
}

fn parseIp(s: []const u8) [4]u8 {
    var a: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&a) |*x| x.* = std.fmt.parseInt(u8, it.next() orelse die("bad address"), 10) catch die("bad address");
    return a;
}

fn connectTo(ip: [4]u8, port: u16) i32 {
    const fd: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast(ip) };
    if (!ok(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)))) die("connect");
    nodelay(fd);
    return fd;
}

fn listenOn(port: u16) i32 {
    const fd: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    const one: c_int = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var sa: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    if (!ok(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)))) die("bind");
    _ = linux.listen(fd, 128);
    return fd;
}

fn writeAll(fd: i32, b: []const u8) bool {
    var i: usize = 0;
    while (i < b.len) {
        const r = linux.write(fd, b[i..].ptr, b.len - i);
        if (!ok(r) or r == 0) return false;
        i += r;
    }
    return true;
}

fn readSome(fd: i32, b: []u8) usize {
    const r = linux.read(fd, b.ptr, b.len);
    return if (ok(r)) r else 0;
}

var big: [buf_len]u8 = @splat('x');

fn sinkConn(fd: i32) void {
    var b: [buf_len]u8 = undefined;
    while (readSome(fd, &b) > 0) {}
    _ = linux.close(fd);
}

fn sourceConn(fd: i32) void {
    // The client sends the count of MB as 4 bytes.
    var m: [4]u8 = undefined;
    if (readSome(fd, &m) != 4) return;
    const mb = std.mem.readInt(u32, &m, .little);
    for (0..mb) |_| if (!writeAll(fd, &big)) break;
    _ = linux.close(fd);
}

fn echoConn(fd: i32) void {
    nodelay(fd);
    var b: [64]u8 = undefined;
    while (true) {
        const k = readSome(fd, &b);
        if (k == 0) break;
        if (!writeAll(fd, b[0..k])) break;
    }
    _ = linux.close(fd);
}

fn acceptLoop(lfd: i32, comptime f: fn (i32) void) void {
    while (true) {
        const r = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
        if (!ok(r)) continue;
        const t = std.Thread.spawn(.{ .stack_size = 4 << 20 }, f, .{@as(i32, @intCast(r))}) catch continue;
        t.detach();
    }
}

fn serve(port: u16) void {
    const a = listenOn(port);
    const b = listenOn(port + 1);
    const c = listenOn(port + 2);
    _ = std.Thread.spawn(.{}, acceptLoop, .{ b, sourceConn }) catch die("thread");
    _ = std.Thread.spawn(.{}, acceptLoop, .{ c, echoConn }) catch die("thread");
    acceptLoop(a, sinkConn);
}

const Job = struct { ip: [4]u8, port: u16, mb: u32, recv: bool };

fn stream(j: Job) void {
    const fd = connectTo(j.ip, j.port);
    if (j.recv) {
        var m: [4]u8 = undefined;
        std.mem.writeInt(u32, &m, j.mb, .little);
        _ = writeAll(fd, &m);
        var b: [buf_len]u8 = undefined;
        var got: u64 = 0;
        while (true) {
            const k = readSome(fd, &b);
            if (k == 0) break;
            got += k;
        }
        if (got != @as(u64, j.mb) << 20) die("short read");
    } else {
        for (0..j.mb) |_| if (!writeAll(fd, &big)) die("write");
        _ = linux.shutdown(fd, linux.SHUT.WR);
        var b: [16]u8 = undefined;
        _ = readSome(fd, &b);
    }
    _ = linux.close(fd);
}

fn bulk(ip: [4]u8, port: u16, mb: u32, n: usize, recv: bool) void {
    var ts: [64]std.Thread = undefined;
    const t0 = now();
    for (ts[0..n]) |*t| t.* = std.Thread.spawn(.{ .stack_size = 4 << 20 }, stream, .{Job{ .ip = ip, .port = port, .mb = mb, .recv = recv }}) catch die("thread");
    for (ts[0..n]) |t| t.join();
    const ns = now() - t0;
    const bits = @as(f64, @floatFromInt(@as(u64, mb) * n * 8 << 20));
    out("{s} {d} x {d} MB: {d:.1} ms, {d:.2} Gbit/s\n", .{ if (recv) "recv" else "send", n, mb, @as(f64, @floatFromInt(ns)) / 1e6, bits / @as(f64, @floatFromInt(ns)) });
}

fn rr(ip: [4]u8, port: u16, count: usize) void {
    const fd = connectTo(ip, port);
    var b: [1]u8 = .{'x'};
    var best: u64 = std.math.maxInt(u64);
    const t0 = now();
    for (0..count) |_| {
        const t = now();
        _ = writeAll(fd, &b);
        if (readSome(fd, &b) != 1) die("rr");
        best = @min(best, now() - t);
    }
    const ns = now() - t0;
    out("rr {d}: mean {d:.1} us, best {d:.1} us\n", .{ count, @as(f64, @floatFromInt(ns / count)) / 1e3, @as(f64, @floatFromInt(best)) / 1e3 });
    _ = linux.close(fd);
}

fn crr(ip: [4]u8, port: u16, count: usize) void {
    const t0 = now();
    for (0..count) |_| {
        const fd = connectTo(ip, port);
        var b: [1]u8 = .{'x'};
        _ = writeAll(fd, &b);
        if (readSome(fd, &b) != 1) die("crr");
        _ = linux.close(fd);
    }
    const ns = now() - t0;
    out("crr {d}: {d:.0} connections/s\n", .{ count, @as(f64, @floatFromInt(count)) * 1e9 / @as(f64, @floatFromInt(ns)) });
}

pub fn main(init: std.process.Init.Minimal) void {
    var it = init.args.iterate();
    _ = it.next();
    const cmd = it.next() orelse die("usage: netbench serve|send|recv|rr|crr ...");
    if (std.mem.eql(u8, cmd, "serve")) return serve(std.fmt.parseInt(u16, it.next() orelse die("port"), 10) catch die("port"));
    const ip = parseIp(it.next() orelse die("host"));
    const port = std.fmt.parseInt(u16, it.next() orelse die("port"), 10) catch die("port");
    const a = std.fmt.parseInt(u32, it.next() orelse "100", 10) catch die("count");
    const n = std.fmt.parseInt(usize, it.next() orelse "1", 10) catch die("streams");
    if (std.mem.eql(u8, cmd, "send")) return bulk(ip, port, a, n, false);
    if (std.mem.eql(u8, cmd, "recv")) return bulk(ip, port + 1, a, n, true);
    if (std.mem.eql(u8, cmd, "rr")) return rr(ip, port + 2, a);
    if (std.mem.eql(u8, cmd, "crr")) return crr(ip, port + 2, a);
    die("bad command");
}
