//! The macOS spike of ztcl::vm (ztcl#203).
//!
//!   spike check GUESTDIR
//!       Boots Image and initramfs.cpio.gz (BusyBox and init), waits for
//!       "ztvm: ready" on the console, echoes a line over vsock port 1024,
//!       and checks the file that the guest writes in GUESTDIR/share.
//!   spike bench GUESTDIR N INITRD MEMORY_MB CMDLINE
//!       Boots N times and prints the time of each phase, and the best.
//!   spike warm GUESTDIR N INITRD MEMORY_MB CMDLINE
//!       Boots one time and pauses, then times N resumes to the answer of
//!       the agent.
//!   spike dmesg GUESTDIR 1 INITRD MEMORY_MB CMDLINE
//!       Boots one time and prints the kernel log of the guest.
//!   spike snap GUESTDIR N INITRD MEMORY_MB CMDLINE
//!       Boots one time, saves the state of the booted guest, then
//!       restores it N times and prints the time of each phase.
//!
//! The tools/vm-guest/spike.sh script builds, signs, and runs it.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const vz = @import("vz");
const c = std.c;
extern "c" fn usleep(us: c_uint) c_int;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("spike: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn writeFile(path: [:0]const u8, text: []const u8) void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) fail("cannot write {s}", .{path});
    _ = c.write(fd, text.ptr, text.len);
    _ = c.close(fd);
}

fn exists(path: [:0]const u8) bool {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

var timebase: c.mach_timebase_info_data = undefined;

fn now() u64 {
    return c.mach_absolute_time() * timebase.numer / timebase.denom;
}

fn readAll(fd: c_int, buf: []u8) error{Closed}!void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) return error.Closed;
        got += @intCast(n);
    }
}

/// The 16-byte header of the agent, then a line and its echo. Gives the
/// two times of the guest.
fn talk(conn: vz.Machine.Conn) error{Closed}![2]u64 {
    var times: [2]u64 = undefined;
    try readAll(conn.fd, std.mem.asBytes(&times));
    const line = "hello over vsock\n";
    if (c.write(conn.fd, line.ptr, line.len) != line.len) fail("vsock write", .{});
    var back: [line.len]u8 = undefined;
    try readAll(conn.fd, &back);
    if (!std.mem.eql(u8, &back, line)) fail("vsock echo gave {s}", .{&back});
    return times;
}

/// Connects to the agent as soon as it listens: a failed connection
/// comes back at once, so the loop tries again with no sleep.
fn connectSoon(m: *vz.Machine, seconds: u64) vz.Machine.Conn {
    var why: []const u8 = "";
    const end = now() + seconds * std.time.ns_per_s;
    while (true) {
        return m.connect(1024, &why) catch {
            if (now() > end) fail("vsock: {s}", .{why});
            continue;
        };
    }
}

/// Connects and talks until the agent answers. Gives the times of the
/// guest, the time of the last connection, and the number of tries.
fn answer(m: *vz.Machine, t_conn: *u64, tries: *usize) [2]u64 {
    tries.* = 0;
    while (true) {
        tries.* += 1;
        const conn = connectSoon(m, 10);
        t_conn.* = now();
        defer conn.close();
        return talk(conn) catch {
            if (tries.* == 20) fail("vsock: the agent closes each connection", .{});
            continue;
        };
    }
}

const Guest = struct {
    dir: []const u8,
    initrd: []const u8,
    memory_mb: u64,
    cmdline: []const u8,
    share: ?[]const u8 = null,
    machine_id: ?vz.Id = null,
    console: ?[2]c.fd_t = null,

    fn config(g: Guest, arena: std.mem.Allocator) !vz.Id {
        var why: []const u8 = "";
        return vz.configure(.{
            .kernel = try std.fmt.allocPrint(arena, "{s}/Image", .{g.dir}),
            .initrd = try std.fmt.allocPrint(arena, "{s}/{s}", .{ g.dir, g.initrd }),
            .cmdline = g.cmdline,
            .cpus = 1,
            .memory_mb = g.memory_mb,
            .console = if (g.console) |p| .{ .in = p[0], .out = p[1] } else null,
            .share = if (g.share) |s| .{ .path = s, .tag = "share" } else null,
            .machine_id = g.machine_id,
            .entropy = c.getenv("ZTVM_NO_RNG") == null,
        }, &why) catch fail("configuration: {s}", .{why});
    }
};

const Phase = enum { configure, create, start, listen, answer, total, guest_init, guest_listen };
const phase_names = [_][]const u8{ "configure", "create", "start (VZ)", "start to connect", "connect to answer", "start to answer", "guest: boot to agent", "guest: agent to listen" };

const Row = [@typeInfo(Phase).@"enum".field_names.len]u64;

fn printRow(label: []const u8, r: Row) void {
    std.debug.print("{s:>6}", .{label});
    for (r) |v| std.debug.print(" {d:>8.2}", .{@as(f64, @floatFromInt(v)) / 1e6});
    std.debug.print("\n", .{});
}

fn printHead() void {
    std.debug.print("phases in ms:\n", .{});
    for (phase_names, 0..) |n, i| std.debug.print("  {d}: {s}\n", .{ i + 1, n });
    std.debug.print("{s:>6}", .{"run"});
    for (0..phase_names.len) |i| std.debug.print(" {d:>8}", .{i + 1});
    std.debug.print("\n", .{});
}

fn printBest(rows: []const Row) void {
    var best: Row = rows[0];
    for (rows[1..]) |r| for (&best, r) |*b, v| {
        b.* = @min(b.*, v);
    };
    printRow("best", best);
}

fn bench(arena: std.mem.Allocator, g: Guest, n: usize) !void {
    const rows = try arena.alloc(Row, n);
    printHead();
    for (rows, 0..) |*r, i| {
        const pool = try vz.new("NSAutoreleasePool");
        defer vz.release(pool);
        const t0 = now();
        const vc = try g.config(arena);
        const t1 = now();
        var m = try vz.Machine.init(vc);
        const t2 = now();
        var why: []const u8 = "";
        m.start(&why) catch fail("start: {s}", .{why});
        const t3 = now();
        var t4: u64 = 0;
        var tries: usize = 0;
        const gt = answer(&m, &t4, &tries);
        const t5 = now();
        if (tries > 1) std.debug.print("  ({d} connections)\n", .{tries});
        m.stop();
        m.deinit();
        vz.release(vc);
        r.* = .{ t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4, t5 - t2, gt[0], gt[1] - gt[0] };
        printRow(try std.fmt.allocPrint(arena, "{d}", .{i + 1}), r.*);
    }
    printBest(rows);
}

fn snap(arena: std.mem.Allocator, g0: Guest, n: usize) !void {
    var g = g0;
    g.machine_id = try vz.new("VZGenericMachineIdentifier");
    const state = try std.fmt.allocPrintSentinel(arena, "{s}/state.vzvmsave", .{g.dir}, 0);
    _ = c.unlink(state);
    var why: []const u8 = "";
    {
        const pool = try vz.new("NSAutoreleasePool");
        defer vz.release(pool);
        const vc = try g.config(arena);
        if (!vz.checkSaveRestore(vc, &why)) fail("no save and restore: {s}", .{why});
        var m = try vz.Machine.init(vc);
        m.start(&why) catch fail("start: {s}", .{why});
        var t: u64 = 0;
        var tries: usize = 0;
        _ = answer(&m, &t, &tries);
        m.pause(&why) catch fail("pause: {s}", .{why});
        const t0 = now();
        m.save(state, &why) catch fail("save: {s}", .{why});
        std.debug.print("saved {s} in {d:.1} ms\n", .{ state, @as(f64, @floatFromInt(now() - t0)) / 1e6 });
        m.stop();
        m.deinit();
    }
    const rows = try arena.alloc(Row, n);
    printHead();
    for (rows, 0..) |*r, i| {
        const pool = try vz.new("NSAutoreleasePool");
        defer vz.release(pool);
        const t0 = now();
        const vc = try g.config(arena);
        const t1 = now();
        var m = try vz.Machine.init(vc);
        const t2 = now();
        m.restore(state, &why) catch fail("restore: {s}", .{why});
        const tr = now();
        m.@"resume"(&why) catch fail("resume: {s}", .{why});
        std.debug.print("  (restore {d:.2} ms, resume {d:.2} ms)\n", .{ @as(f64, @floatFromInt(tr - t2)) / 1e6, @as(f64, @floatFromInt(now() - tr)) / 1e6 });
        const t3 = now();
        var t4: u64 = 0;
        var tries: usize = 0;
        const gt = answer(&m, &t4, &tries);
        const t5 = now();
        if (tries > 1) std.debug.print("  ({d} connections)\n", .{tries});
        m.stop();
        m.deinit();
        vz.release(vc);
        r.* = .{ t1 - t0, t2 - t1, t3 - t2, t4 - t3, t5 - t4, t5 - t2, gt[0], gt[1] - gt[0] };
        printRow(try std.fmt.allocPrint(arena, "{d}", .{i + 1}), r.*);
    }
    printBest(rows);
}

/// Boots one guest, pauses it when the agent answers, and then times N
/// resumes to the answer of the agent, with a pause after each.
fn warm(arena: std.mem.Allocator, g: Guest, n: usize) !void {
    var why: []const u8 = "";
    const vc = try g.config(arena);
    var m = try vz.Machine.init(vc);
    m.start(&why) catch fail("start: {s}", .{why});
    var t: u64 = 0;
    var tries: usize = 0;
    _ = answer(&m, &t, &tries);
    m.pause(&why) catch fail("pause: {s}", .{why});
    const rows = try arena.alloc(u64, n);
    std.debug.print("resume to answer, in ms:", .{});
    for (rows) |*r| {
        const t0 = now();
        m.@"resume"(&why) catch fail("resume: {s}", .{why});
        _ = answer(&m, &t, &tries);
        r.* = now() - t0;
        std.debug.print(" {d:.2}", .{@as(f64, @floatFromInt(r.*)) / 1e6});
        m.pause(&why) catch fail("pause: {s}", .{why});
    }
    std.debug.print("\nbest {d:.2}\n", .{@as(f64, @floatFromInt(std.mem.min(u64, rows))) / 1e6});
    m.stop();
}

/// Boots one guest and prints its kernel log.
fn dmesg(arena: std.mem.Allocator, g: Guest) !void {
    var why: []const u8 = "";
    const vc = try g.config(arena);
    var m = try vz.Machine.init(vc);
    m.start(&why) catch fail("start: {s}", .{why});
    var t: u64 = 0;
    var tries: usize = 0;
    _ = answer(&m, &t, &tries);
    const conn = connectSoon(&m, 10);
    var times: [2]u64 = undefined;
    readAll(conn.fd, std.mem.asBytes(&times)) catch fail("vsock read", .{});
    _ = c.write(conn.fd, "\x01", 1);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(conn.fd, &buf, buf.len);
        if (n <= 0) break;
        _ = c.write(1, &buf, @intCast(n));
    }
    conn.close();
    m.stop();
}

fn check(arena: std.mem.Allocator, dir: []const u8) !void {
    const share = try std.fmt.allocPrintSentinel(arena, "{s}/share", .{dir}, 0);
    _ = c.mkdir(share, 0o755);
    writeFile(try std.fmt.allocPrintSentinel(arena, "{s}/hello.txt", .{share}, 0), "hello from the host\n");
    const from_guest = try std.fmt.allocPrintSentinel(arena, "{s}/from-guest.txt", .{share}, 0);
    _ = c.unlink(from_guest);

    // The guest reads `to_guest[0]` and writes `out[1]`.
    var to_guest: [2]c.fd_t = undefined;
    var out: [2]c.fd_t = undefined;
    if (c.pipe(&to_guest) != 0 or c.pipe(&out) != 0) fail("no pipe", .{});
    const g: Guest = .{ .dir = dir, .initrd = "initramfs.cpio.gz", .memory_mb = 256, .cmdline = "console=hvc0 rdinit=/init quiet", .share = share, .console = .{ to_guest[0], out[1] } };
    const vc = try g.config(arena);
    var m = try vz.Machine.init(vc);
    var why: []const u8 = "";
    m.start(&why) catch fail("start: {s}", .{why});

    var seen: std.ArrayList(u8) = .empty;
    while (std.mem.indexOf(u8, seen.items, "ztvm: ready") == null) {
        var buf: [1024]u8 = undefined;
        const n = c.read(out[0], &buf, buf.len);
        if (n <= 0) fail("the console closed", .{});
        std.debug.print("{s}", .{buf[0..@intCast(n)]});
        try seen.appendSlice(arena, buf[0..@intCast(n)]);
    }
    var t: u64 = 0;
    var tries: usize = 0;
    _ = answer(&m, &t, &tries);
    std.debug.print("\nspike: vsock echo ok\n", .{});
    if (!exists(from_guest)) fail("the guest wrote no file in the share", .{});
    std.debug.print("spike: virtio-fs ok\n", .{});
    m.stop();
    std.debug.print("spike: stopped\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    _ = c.mach_timebase_info(&timebase);
    vz.load() catch fail("no Virtualization.framework", .{});
    const pool = try vz.new("NSAutoreleasePool");
    defer vz.release(pool);

    if (args.len == 3 and std.mem.eql(u8, args[1], "check")) return check(arena, args[2]);
    if (args.len == 7) {
        var p: [2]c.fd_t = undefined;
        const show = c.getenv("ZTVM_CONSOLE") != null;
        if (show and c.pipe(&p) != 0) fail("no pipe", .{});
        const g: Guest = .{
            .console = if (show) .{ p[0], 2 } else null,
            .dir = args[2],
            .initrd = args[4],
            .memory_mb = try std.fmt.parseInt(u64, args[5], 10),
            .cmdline = args[6],
        };
        const n = try std.fmt.parseInt(usize, args[3], 10);
        if (std.mem.eql(u8, args[1], "bench")) return bench(arena, g, n);
        if (std.mem.eql(u8, args[1], "snap")) return snap(arena, g, n);
        if (std.mem.eql(u8, args[1], "warm")) return warm(arena, g, n);
        if (std.mem.eql(u8, args[1], "dmesg")) return dmesg(arena, g);
    }
    fail("usage: spike check DIR | spike bench|warm|snap|dmesg DIR N INITRD MEMORY_MB CMDLINE", .{});
}
