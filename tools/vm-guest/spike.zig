//! The macOS spike of ztcl::vm (ztcl#203): boots the guest of
//! tools/vm-guest, waits for its init to say "ztvm: ready", sends a line
//! to the echo agent on vsock port 1024 and reads it back, and checks the
//! file that the guest writes in the shared directory.
//!
//!   tools/vm-guest/spike.sh GUESTDIR
//!
//! GUESTDIR has Image and initramfs.cpio.gz. The shared directory is
//! GUESTDIR/share.
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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) fail("usage: vm-spike GUESTDIR", .{});
    const dir = args[1];

    vz.load() catch fail("no Virtualization.framework", .{});
    const pool = try vz.new("NSAutoreleasePool");
    defer vz.release(pool);

    const share = try std.fmt.allocPrintSentinel(arena, "{s}/share", .{dir}, 0);
    _ = c.mkdir(share, 0o755);
    writeFile(try std.fmt.allocPrintSentinel(arena, "{s}/hello.txt", .{share}, 0), "hello from the host\n");
    const from_guest = try std.fmt.allocPrintSentinel(arena, "{s}/from-guest.txt", .{share}, 0);
    _ = c.unlink(from_guest);

    // Two pipes for the console: the guest reads `to_guest[0]` and writes
    // `from_guest[1]`.
    var to_guest: [2]c.fd_t = undefined;
    var out: [2]c.fd_t = undefined;
    if (c.pipe(&to_guest) != 0 or c.pipe(&out) != 0) fail("no pipe", .{});

    var why: []const u8 = "";
    const vc = vz.configure(.{
        .kernel = try std.fmt.allocPrint(arena, "{s}/Image", .{dir}),
        .initrd = try std.fmt.allocPrint(arena, "{s}/initramfs.cpio.gz", .{dir}),
        .cmdline = "console=hvc0 rdinit=/init quiet",
        .cpus = 2,
        .memory_mb = 256,
        .console_in = to_guest[0],
        .console_out = out[1],
        .share = .{ .path = share, .tag = "share" },
    }, &why) catch fail("configuration: {s}", .{why});

    const t0 = std.c.mach_absolute_time();
    var m = try vz.Machine.init(vc);
    m.start(&why) catch fail("start: {s}", .{why});
    std.debug.print("spike: the guest runs\n", .{});

    // The console, to "ztvm: ready".
    var seen: std.ArrayList(u8) = .empty;
    while (std.mem.indexOf(u8, seen.items, "ztvm: ready") == null) {
        var buf: [1024]u8 = undefined;
        const n = c.read(out[0], &buf, buf.len);
        if (n <= 0) fail("the console closed", .{});
        const got = buf[0..@intCast(n)];
        std.debug.print("{s}", .{got});
        try seen.appendSlice(arena, got);
    }
    var tb: std.c.mach_timebase_info_data = undefined;
    _ = std.c.mach_timebase_info(&tb);
    const ms = (std.c.mach_absolute_time() - t0) * tb.numer / tb.denom / 1_000_000;
    std.debug.print("\nspike: ready {d} ms after the start\n", .{ms});

    // The agent starts in the background: try for a few seconds.
    var conn: vz.Machine.Conn = undefined;
    var tries: usize = 0;
    while (true) : (tries += 1) {
        conn = m.connect(1024, &why) catch {
            if (tries == 50) fail("vsock: {s}", .{why});
            _ = usleep(100_000);
            continue;
        };
        break;
    }
    const line = "hello over vsock\n";
    if (c.write(conn.fd, line.ptr, line.len) != line.len) fail("vsock write", .{});
    var back: [64]u8 = undefined;
    var got: usize = 0;
    while (got < line.len) {
        const n = c.read(conn.fd, back[got..].ptr, back.len - got);
        if (n <= 0) fail("vsock read", .{});
        got += @intCast(n);
    }
    if (!std.mem.eql(u8, back[0..got], line)) fail("vsock echo gave {s}", .{back[0..got]});
    std.debug.print("spike: vsock echo ok\n", .{});
    conn.close();

    if (!exists(from_guest)) fail("the guest wrote no file in the share", .{});
    std.debug.print("spike: virtio-fs ok\n", .{});

    m.stop();
    std.debug.print("spike: stopped\n", .{});
}
