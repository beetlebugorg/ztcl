//! `ztcl::vm`: small Linux guests on the hypervisor of the host
//! (capability `vm`, ztcl#203). The plan is `docs/dev/vm.md`.
//!
//!   ztcl::vm create ?-cpus N? ?-memory MB? -kernel F ?-initrd F? ?-cmdline TEXT?
//!                   ?-disk {F ?rw?}? ... ?-share {HOST GUEST ?rw?}? ... ?-entropy 0|1? ?-warm 0|1?
//!   ztcl::vm start|stop ?-force?|status|delete VM
//!   ztcl::vm vsock VM PORT ?-timeout MS?
//!   ztcl::vm console VM
//!
//! macOS has the part of this file: Virtualization.framework through
//! `vz.zig`. On another platform each command gives the error
//! `ZTCL VM UNAVAILABLE`, until the KVM and HCS parts of the plan.
//!
//! The paths of `-kernel`, `-initrd`, `-disk`, and `-share` also need
//! the `file` capability, and each is a path below the root folder of
//! the file jail. The framework gets the final path of the open
//! descriptor (`F_GETPATH`), so a link in the root folder cannot point
//! the guest outside it.
//!
//! A share is the virtio-fs tag `share0`, `share1`, ..., in the order of
//! the options, and a disk is `/dev/vda`, `/dev/vdb`, .... A share or a
//! disk is read-only unless its list ends in `rw`.
//!
//! WARNING: a share with `rw` lets the guest change the files of that
//! folder of the host, and a disk with `rw` lets it change the file of
//! the disk.
//!
//! The process needs the entitlement `com.apple.security.virtualization`
//! in its signature (an ad hoc one too). Without it, `create` gives the
//! error `ZTCL VM ENTITLEMENT`.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const chan = @import("chan.zig");
const fsroot = @import("fsroot.zig");
const sys = @import("sys.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const on_mac = builtin.os.tag == .macos;
const vz = if (on_mac) @import("vz.zig") else struct {};

/// The limits of the embedder for the guests of one interpreter.
pub const Host = struct {
    max_cpus: u32 = 4,
    max_memory_mb: u32 = 2048,
    max_guests: u32 = 4,
};

/// The port of the guest agent. A warm guest pauses when a program of
/// the guest accepts a connection on it.
pub const agent_port: u32 = 1024;

const usage = "ztcl::vm create|start|stop|status|vsock|console|delete ?arg ...?";

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::vm", cmdVm);
}

fn unavailable(it: *Interp) Error {
    const name = switch (builtin.os.tag) {
        .linux => "Linux",
        .windows => "Windows",
        else => "this platform",
    };
    return it.failCode("ZTCL VM UNAVAILABLE", "ztcl::vm is not available on {s} yet", .{name});
}

fn cmdVm(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    if (args.len < 2) return it.wrongArgs(usage);
    if (comptime !on_mac) return unavailable(it);
    return mac.run(it, args);
}

/// Stops and frees each guest of the interpreter, at its end.
pub fn closeAll(it: *Interp) void {
    if (comptime on_mac) mac.closeAll(it);
}

const mac = if (on_mac) struct {
    const c = std.c;
    const f_getpath = 50;
    const max_path = 1024;

    const Guest = struct {
        name: []const u8,
        config: vz.Id,
        machine: vz.Machine,
        /// The end of the console socket that the framework has, and the
        /// end of the script, until `console` gives it as a channel.
        console_vm: c_int,
        console_host: c_int,
        warm: bool,
        started: bool = false,
    };

    const State = struct {
        guests: std.ArrayList(*Guest) = .empty,
        next: u32 = 1,
    };

    fn state(it: *Interp) Error!*State {
        if (it.vm_state) |p| return @ptrCast(@alignCast(p));
        const s = try it.heap.backing.create(State);
        s.* = .{};
        it.vm_state = s;
        return s;
    }

    fn find(it: *Interp, v: Value) Error!*Guest {
        const name = try it.str(v);
        const s = try state(it);
        for (s.guests.items) |g| if (std.mem.eql(u8, g.name, name)) return g;
        return it.failCode("ZTCL VM NAME", "no guest named \"{s}\"", .{name});
    }

    fn framework(it: *Interp, what: []const u8, why: []const u8) Error {
        if (std.mem.indexOf(u8, why, "com.apple.security.virtualization") != null)
            return it.failCode("ZTCL VM ENTITLEMENT", "ztcl::vm needs the entitlement com.apple.security.virtualization in the signature of this program", .{});
        return it.failCode("ZTCL VM FRAMEWORK", "{s}: {s}", .{ what, why });
    }

    pub fn run(it: *Interp, args: []const Value) Error!Value {
        vz.load() catch return it.failCode("ZTCL VM UNAVAILABLE", "this macOS has no Virtualization.framework", .{});
        const pool = vz.new("NSAutoreleasePool") catch return it.failCode("ZTCL VM UNAVAILABLE", "no Foundation", .{});
        defer vz.release(pool);
        const sub = try it.str(args[1]);
        if (std.mem.eql(u8, sub, "create")) return create(it, args[2..]);
        if (args.len < 3) return it.wrongArgs(usage);
        const g = try find(it, args[2]);
        if (std.mem.eql(u8, sub, "start")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm start vm");
            try start(it, g);
            return .{ .str = "" };
        }
        if (std.mem.eql(u8, sub, "stop")) {
            const force = args.len == 4 and std.mem.eql(u8, try it.str(args[3]), "-force");
            if (args.len != 3 and !force) return it.wrongArgs("ztcl::vm stop vm ?-force?");
            stop(g, force);
            return .{ .str = "" };
        }
        if (std.mem.eql(u8, sub, "status")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm status vm");
            return .{ .str = status(g) };
        }
        if (std.mem.eql(u8, sub, "vsock")) return vsock(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "console")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm console vm");
            return console(it, g);
        }
        if (std.mem.eql(u8, sub, "delete")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm delete vm");
            const s = try state(it);
            for (s.guests.items, 0..) |x, i| if (x == g) {
                _ = s.guests.orderedRemove(i);
                break;
            };
            destroy(it, g);
            return .{ .str = "" };
        }
        return it.fail("bad option \"{s}\": must be console, create, delete, start, status, stop, or vsock", .{sub});
    }

    /// The host path of a path of the script, below the root folder.
    fn hostPath(it: *Interp, path: []const u8, dir: bool) Error![]const u8 {
        if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok())
            return it.failCode("ZTCL VM NOFILE", "a path of ztcl::vm needs the file capability", .{});
        const rel = try fsroot.need(it, path);
        const r = try fsroot.openRel(it, rel, .{ .directory = dir }, 0);
        const fd = switch (r) {
            .fd => |fd| fd,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't open \"{s}\": ", .{path})),
        };
        defer sys.close(fd);
        var buf: [max_path]u8 = @splat(0);
        if (c.fcntl(fd, f_getpath, &buf) < 0) return it.failCode("ZTCL VM PATH", "no host path for \"{s}\"", .{path});
        return try it.alloc().dupe(u8, std.mem.sliceTo(&buf, 0));
    }

    fn isRw(it: *Interp, v: Value) Error!bool {
        const w = try it.str(v);
        if (std.mem.eql(u8, w, "rw")) return true;
        if (std.mem.eql(u8, w, "ro")) return false;
        return it.fail("bad mode \"{s}\": must be ro or rw", .{w});
    }

    fn limit(it: *Interp, v: Value, what: []const u8, max: u32) Error!u32 {
        const n = try it.int(v);
        if (n < 1) return it.failCode("ZTCL VM LIMIT", "the {s} of a guest must be 1 or more", .{what});
        if (n > max) return it.failCode("ZTCL VM LIMIT", "the {s} of a guest is more than the limit of {d}", .{ what, max });
        return @intCast(n);
    }

    fn create(it: *Interp, args: []const Value) Error!Value {
        const a = it.alloc();
        const host = it.vm_host;
        const s = try state(it);
        if (s.guests.items.len >= host.max_guests)
            return it.failCode("ZTCL VM LIMIT", "the interpreter has {d} guests, the limit", .{s.guests.items.len});
        if (args.len % 2 != 0) return it.wrongArgs("ztcl::vm create ?-option value ...?");
        var cfg: vz.Config = .{ .kernel = "", .cmdline = "console=hvc0 quiet", .memory_mb = 256, .entropy = false };
        var shares: std.ArrayList(vz.Share) = .empty;
        var disks: std.ArrayList(vz.Disk) = .empty;
        var warm = false;
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            const opt = try it.str(args[i]);
            const v = args[i + 1];
            if (std.mem.eql(u8, opt, "-cpus")) {
                cfg.cpus = try limit(it, v, "CPU count", host.max_cpus);
            } else if (std.mem.eql(u8, opt, "-memory")) {
                cfg.memory_mb = try limit(it, v, "memory in MB", host.max_memory_mb);
            } else if (std.mem.eql(u8, opt, "-kernel")) {
                cfg.kernel = try hostPath(it, try it.str(v), false);
            } else if (std.mem.eql(u8, opt, "-initrd")) {
                cfg.initrd = try hostPath(it, try it.str(v), false);
            } else if (std.mem.eql(u8, opt, "-cmdline")) {
                cfg.cmdline = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-entropy")) {
                cfg.entropy = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-warm")) {
                warm = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-disk")) {
                const l = try it.readList(v);
                if (l.len < 1 or l.len > 2) return it.fail("a disk is {{file ?rw?}}", .{});
                try disks.append(a, .{ .path = try hostPath(it, try it.str(l[0]), false), .read_only = !(l.len == 2 and try isRw(it, l[1])) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                const l = try it.readList(v);
                if (l.len < 2 or l.len > 3) return it.fail("a share is {{host guest ?rw?}}", .{});
                const tag = try std.fmt.allocPrint(a, "share{d}", .{shares.items.len});
                try shares.append(a, .{ .path = try hostPath(it, try it.str(l[0]), true), .tag = tag, .read_only = !(l.len == 3 and try isRw(it, l[2])) });
            } else return it.fail("bad option \"{s}\": must be -cmdline, -cpus, -disk, -entropy, -initrd, -kernel, -memory, -share, or -warm", .{opt});
        }
        if (cfg.kernel.len == 0) return it.failCode("ZTCL VM KERNEL", "a guest needs -kernel until the base image of the plan", .{});
        cfg.shares = shares.items;
        cfg.disks = disks.items;

        var pair: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair) != 0) return it.failCode("ZTCL VM FRAMEWORK", "no socket for the console", .{});
        var keep = false;
        defer if (!keep) {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
        };
        cfg.console = .{ .in = pair[0], .out = pair[0] };
        var why: []const u8 = "";
        const vc = vz.configure(cfg, &why) catch return framework(it, "the configuration of the guest", why);
        const g = try it.heap.backing.create(Guest);
        g.* = .{
            .name = try std.fmt.allocPrint(it.heap.backing, "vm{d}", .{s.next}),
            .config = vc,
            .machine = vz.Machine.init(vc) catch return framework(it, "the guest", "no machine"),
            .console_vm = pair[0],
            .console_host = pair[1],
            .warm = warm,
        };
        s.next += 1;
        try s.guests.append(it.heap.backing, g);
        keep = true;
        if (warm) {
            g.machine.start(&why) catch return framework(it, "the start of the guest", why);
            g.started = true;
            const conn = connect(&g.machine, agent_port, 10_000) orelse
                return it.failCode("ZTCL VM AGENT", "no program of the guest accepted a connection on port {d}", .{agent_port});
            conn.close();
            g.machine.pause(&why) catch return framework(it, "the pause of the guest", why);
        }
        return .{ .str = g.name };
    }

    fn start(it: *Interp, g: *Guest) Error!void {
        var why: []const u8 = "";
        switch (g.machine.state()) {
            .paused => g.machine.@"resume"(&why) catch return framework(it, "the resume of the guest", why),
            .stopped, .@"error" => {
                if (g.started) {
                    // A machine of the framework starts one time: a new
                    // one of the same configuration starts again.
                    g.machine.deinit();
                    g.machine = vz.Machine.init(g.config) catch return framework(it, "the guest", "no machine");
                }
                g.machine.start(&why) catch return framework(it, "the start of the guest", why);
                g.started = true;
            },
            else => return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) }),
        }
    }

    /// Asks the guest to power off and waits up to 5 seconds, then
    /// stops it at once. `force` stops it at once.
    fn stop(g: *Guest, force: bool) void {
        const st = g.machine.state();
        if (st == .stopped or st == .@"error") return;
        if (!force and st == .running and g.machine.requestStop()) {
            var waited: u32 = 0;
            while (waited < 5000) : (waited += 10) {
                if (g.machine.state() == .stopped) return;
                sleepMs(10);
            }
        }
        g.machine.stop();
    }

    fn status(g: *Guest) []const u8 {
        return switch (g.machine.state()) {
            .stopped => if (g.started) "stopped" else "created",
            .running => "running",
            .paused => "paused",
            .@"error" => "error",
            .starting, .resuming, .restoring => "starting",
            .pausing, .saving => "pausing",
            .stopping => "stopping",
            _ => "unknown",
        };
    }

    fn sleepMs(ms: u32) void {
        var ts: c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }

    fn nowMs() i64 {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
    }

    /// Connects to a port of the guest, again at once after each refused
    /// connection, until `timeout_ms` pass.
    fn connect(m: *vz.Machine, port: u32, timeout_ms: u32) ?vz.Machine.Conn {
        var why: []const u8 = "";
        const end = nowMs() + timeout_ms;
        while (true) {
            return m.connect(port, &why) catch {
                if (nowMs() >= end) return null;
                continue;
            };
        }
    }

    fn binaryChannel(it: *Interp, prefix: []const u8, fd: c_int) Error!Value {
        const ch = try chan.adopt(it, prefix, fd, true, true);
        ch.kind = .pipe;
        ch.input = .binary;
        ch.output = .binary;
        ch.binary = true;
        ch.buffering = "none";
        return .{ .str = ch.name };
    }

    fn vsock(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const use = "ztcl::vm vsock vm port ?-timeout ms?";
        if (args.len != 1 and args.len != 3) return it.wrongArgs(use);
        const port = try it.int(args[0]);
        if (port < 0 or port > std.math.maxInt(u32)) return it.fail("bad port \"{d}\"", .{port});
        var timeout: u32 = 5000;
        if (args.len == 3) {
            if (!std.mem.eql(u8, try it.str(args[1]), "-timeout")) return it.wrongArgs(use);
            const t = try it.int(args[2]);
            if (t < 0) return it.fail("bad timeout \"{d}\"", .{t});
            timeout = @intCast(@min(t, std.math.maxInt(u32)));
        }
        if (g.machine.state() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const conn = connect(&g.machine, @intCast(port), timeout) orelse
            return it.failCode("ZTCL VM CONNECT", "no program of the guest {s} accepted a connection on port {d}", .{ g.name, port });
        // The connection object owns its descriptor: the channel gets a
        // copy, and the object goes.
        const fd = c.dup(conn.fd);
        conn.close();
        if (fd < 0) return it.failCode("ZTCL VM CONNECT", "no descriptor for the connection", .{});
        return binaryChannel(it, "vsock", fd);
    }

    fn console(it: *Interp, g: *Guest) Error!Value {
        if (g.console_host < 0) return it.failCode("ZTCL VM CONSOLE", "the console of the guest {s} is a channel already", .{g.name});
        const v = try binaryChannel(it, "vmcon", g.console_host);
        g.console_host = -1;
        return v;
    }

    fn destroy(it: *Interp, g: *Guest) void {
        stop(g, true);
        g.machine.deinit();
        vz.release(g.config);
        _ = c.close(g.console_vm);
        if (g.console_host >= 0) _ = c.close(g.console_host);
        it.heap.backing.free(g.name);
        it.heap.backing.destroy(g);
    }

    pub fn closeAll(it: *Interp) void {
        const s: *State = @ptrCast(@alignCast(it.vm_state orelse return));
        vz.load() catch {};
        for (s.guests.items) |g| destroy(it, g);
        s.guests.deinit(it.heap.backing);
        it.heap.backing.destroy(s);
        it.vm_state = null;
    }
} else struct {};
