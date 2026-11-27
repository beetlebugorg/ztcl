//! `ztcl::vm`: small Linux guests on the hypervisor of the host
//! (capability `vm`, ztcl#203). The plan is `docs/dev/vm.md`.
//!
//!   ztcl::vm create ?-cpus N? ?-memory MB? -kernel F ?-initrd F? ?-cmdline TEXT?
//!                   ?-disk {F ?rw?}? ... ?-share {HOST GUEST ?rw?}? ... ?-entropy 0|1? ?-warm 0|1?
//!   ztcl::vm start|stop ?-force?|status|delete VM
//!   ztcl::vm vsock VM PORT ?-timeout MS?
//!   ztcl::vm exec VM ?-stdin DATA? ?-env LIST? ?-cwd DIR? ?-timeout MS? ?--? PROGRAM ?ARG ...?
//!   ztcl::vm mount VM TAG PATH ?-readonly?
//!   ztcl::vm console VM
//!
//! `exec` and `mount` speak to the guest agent on port 1024
//! (`vmagent.zig`, `docs/dev/vm-agent.md`), on macOS in this version.
//!
//! macOS has Virtualization.framework through `vz.zig`, and x86-64
//! Linux has the KVM monitor of `kvm.zig`. On another platform each
//! command gives the error `ZTCL VM UNAVAILABLE`, until the arm64 KVM
//! and HCS parts of the plan.
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
//! On Linux, the user needs read and write access to `/dev/kvm` and
//! `/dev/vhost-vsock` (the `kvm` group). Without it, `create` gives the
//! error `ZTCL VM UNAVAILABLE` with the fix. ztcl opens each path of a
//! guest in the file jail and gives the monitor the open descriptor, so
//! a swap of the file after the check cannot reach the guest. A share is
//! not available on Linux yet (`ZTCL VM SHARE`).
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
const on_kvm = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
const kvm = if (on_kvm) @import("kvm.zig") else struct {};

/// The limits of the embedder for the guests of one interpreter.
pub const Host = struct {
    max_cpus: u32 = 4,
    max_memory_mb: u32 = 2048,
    max_guests: u32 = 4,
};

/// The port of the guest agent. A warm guest pauses when a program of
/// the guest accepts a connection on it.
pub const agent_port: u32 = 1024;

const usage = "ztcl::vm create|start|stop|status|vsock|exec|mount|console|delete ?arg ...?";
const vmagent = @import("vmagent.zig");

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("ztcl::vm", cmdVm);
}

fn unavailable(it: *Interp) Error {
    const name = switch (builtin.os.tag) {
        .linux => "this Linux architecture",
        .windows => "Windows",
        else => "this platform",
    };
    return it.failCode("ZTCL VM UNAVAILABLE", "ztcl::vm is not available on {s} yet", .{name});
}

fn cmdVm(it: *Interp, args: []const Value, _: ?*interp.Cmd) Error!Value {
    if (args.len < 2) return it.wrongArgs(usage);
    if (comptime on_kvm) return lin.run(it, args);
    if (comptime !on_mac) return unavailable(it);
    return mac.run(it, args);
}

/// Stops and frees each guest of the interpreter, at its end.
pub fn closeAll(it: *Interp) void {
    if (comptime on_mac) mac.closeAll(it);
    if (comptime on_kvm) lin.closeAll(it);
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

fn binaryChannel(it: *Interp, prefix: []const u8, fd: i32) Error!Value {
    const ch = try chan.adopt(it, prefix, fd, true, true);
    ch.kind = .pipe;
    ch.input = .binary;
    ch.output = .binary;
    ch.binary = true;
    ch.buffering = "none";
    return .{ .str = ch.name };
}

/// The arguments of `ztcl::vm vsock VM PORT ?-timeout MS?`.
fn vsockArgs(it: *Interp, args: []const Value) Error!struct { port: u32, timeout: u32 } {
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
    return .{ .port = @intCast(port), .timeout = timeout };
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
        if (std.mem.eql(u8, sub, "exec")) return execCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "mount")) return mountCmd(it, g, args[3..]);
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
        return it.fail("bad option \"{s}\": must be console, create, delete, exec, mount, start, status, stop, or vsock", .{sub});
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

    fn vsock(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const a = try vsockArgs(it, args);
        const port = a.port;
        const timeout = a.timeout;
        if (g.machine.state() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const conn = connect(&g.machine, port, timeout) orelse
            return it.failCode("ZTCL VM CONNECT", "no program of the guest {s} accepted a connection on port {d}", .{ g.name, port });
        // The connection object owns its descriptor: the channel gets a
        // copy, and the object goes.
        const fd = c.dup(conn.fd);
        conn.close();
        if (fd < 0) return it.failCode("ZTCL VM CONNECT", "no descriptor for the connection", .{});
        return binaryChannel(it, "vsock", fd);
    }

    /// A connection to the agent, after its `HELLO`.
    fn agent(it: *Interp, g: *Guest, timeout: u32) Error!vmagent.Conn {
        if (g.machine.state() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const conn = connect(&g.machine, vmagent.port, timeout) orelse
            return it.failCode("ZTCL VM AGENT", "the agent of the guest {s} did not answer on port {d}", .{ g.name, vmagent.port });
        const fd = c.dup(conn.fd);
        conn.close();
        if (fd < 0) return it.failCode("ZTCL VM CONNECT", "no descriptor for the connection", .{});
        var a: vmagent.Conn = .{ .fd = fd, .timeout_ms = @intCast(@min(timeout, std.math.maxInt(i32))) };
        _ = a.hello(it.alloc()) catch |e| {
            _ = c.close(fd);
            return agentFail(it, g, &a, e);
        };
        return a;
    }

    fn agentFail(it: *Interp, g: *Guest, a: *vmagent.Conn, e: vmagent.Error) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Timeout => it.failCode("ZTCL VM TIMEOUT", "the guest {s} gave no answer in time", .{g.name}),
            error.Version => it.failCode("ZTCL VM AGENT", "the agent of the guest {s} has another version of the protocol", .{g.name}),
            error.Agent => it.failCode("ZTCL VM AGENT", "{s} (errno {d})", .{ a.last_error.message[0..a.last_error.len], a.last_error.errno }),
            else => it.failCode("ZTCL VM AGENT", "the connection to the agent of the guest {s} failed: {s}", .{ g.name, @errorName(e) }),
        };
    }

    /// `exec`: a dict of `exit`, `stdout`, and `stderr`.
    fn execCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const use = "ztcl::vm exec vm ?-stdin data? ?-env list? ?-cwd dir? ?-timeout ms? ?--? program ?arg ...?";
        var stdin: ?[]const u8 = null;
        var env: []const []const u8 = &.{};
        var cwd: []const u8 = "";
        var timeout: u32 = 30000;
        var i: usize = 0;
        while (i < args.len) {
            const o = try it.str(args[i]);
            if (std.mem.eql(u8, o, "--")) {
                i += 1;
                break;
            }
            if (o.len == 0 or o[0] != '-') break;
            if (i + 1 >= args.len) return it.wrongArgs(use);
            const v = args[i + 1];
            if (std.mem.eql(u8, o, "-stdin")) {
                stdin = try it.str(v);
            } else if (std.mem.eql(u8, o, "-cwd")) {
                cwd = try it.str(v);
            } else if (std.mem.eql(u8, o, "-timeout")) {
                const t = try it.int(v);
                if (t < 1) return it.fail("bad timeout \"{d}\"", .{t});
                timeout = @intCast(@min(t, std.math.maxInt(i32)));
            } else if (std.mem.eql(u8, o, "-env")) {
                const items = try it.list(v);
                const e = try it.alloc().alloc([]const u8, items.len);
                for (items, e) |x, *y| y.* = try it.str(x);
                env = e;
            } else return it.fail("bad option \"{s}\": must be -cwd, -env, -stdin, or -timeout", .{o});
            i += 2;
        }
        if (i >= args.len) return it.wrongArgs(use);
        const argv = try it.alloc().alloc([]const u8, args.len - i);
        for (args[i..], argv) |x, *y| y.* = try it.str(x);
        var a = try agent(it, g, timeout);
        defer _ = c.close(a.fd);
        const r = vmagent.exec(&a, it.alloc(), argv, env, cwd, stdin, 64 << 20) catch |e| return agentFail(it, g, &a, e);
        var items = [6]Value{
            .{ .str = "exit" },   .{ .int = r.code },
            .{ .str = "stdout" }, .{ .str = r.stdout },
            .{ .str = "stderr" }, .{ .str = r.stderr },
        };
        return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &items));
    }

    fn mountCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const use = "ztcl::vm mount vm tag path ?-readonly?";
        if (args.len != 2 and args.len != 3) return it.wrongArgs(use);
        const ro = args.len == 3;
        if (ro and !std.mem.eql(u8, try it.str(args[2]), "-readonly")) return it.wrongArgs(use);
        var a = try agent(it, g, 5000);
        defer _ = c.close(a.fd);
        vmagent.mount(&a, it.alloc(), try it.str(args[0]), try it.str(args[1]), ro) catch |e| return agentFail(it, g, &a, e);
        return .{ .str = "" };
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

const lin = if (on_kvm) struct {
    const linux = std.os.linux;
    const AF_VSOCK = 40;

    const Guest = struct {
        name: []const u8,
        machine: *kvm,
        kernel: []u8,
        initrd: []u8,
        cmdline: []u8,
        disks: []kvm.Disk,
        /// The end of the console socket that the monitor has, and the
        /// end of the script, until `console` gives it as a channel.
        console_vm: i32,
        console_host: i32,
        warm: bool,
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

    /// The error of a failed step of the monitor, with the fix for a
    /// host without access to KVM or vhost-vsock.
    fn failure(it: *Interp, e: kvm.Fail) Error {
        return switch (e) {
            error.KvmAccess => it.failCode("ZTCL VM UNAVAILABLE", "no access to /dev/kvm: add the user to the kvm group (sudo usermod -aG kvm $USER), then log in again", .{}),
            error.NoKvm => it.failCode("ZTCL VM UNAVAILABLE", "this Linux has no /dev/kvm: turn on virtualization in the firmware and load the module kvm_intel or kvm_amd", .{}),
            error.VhostAccess => it.failCode("ZTCL VM UNAVAILABLE", "no access to /dev/vhost-vsock: add the user to the kvm group (sudo usermod -aG kvm $USER), then log in again", .{}),
            error.NoVhost => it.failCode("ZTCL VM UNAVAILABLE", "this Linux has no /dev/vhost-vsock: load the module vhost_vsock (sudo modprobe vhost_vsock)", .{}),
            error.Kernel => it.failCode("ZTCL VM KERNEL", "{s}", .{kvm.why}),
            error.Memory => it.failCode("ZTCL VM MEMORY", "{s}", .{kvm.why}),
            error.OutOfMemory => error.OutOfMemory,
            error.Setup => it.failCode("ZTCL VM KVM", "{s} failed", .{kvm.why}),
        };
    }

    pub fn run(it: *Interp, args: []const Value) Error!Value {
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
            g.machine.stop();
            return .{ .str = "" };
        }
        if (std.mem.eql(u8, sub, "status")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm status vm");
            return .{ .str = status(g) };
        }
        if (std.mem.eql(u8, sub, "vsock")) return vsock(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "console")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm console vm");
            if (g.console_host < 0) return it.failCode("ZTCL VM CONSOLE", "the console of the guest {s} is a channel already", .{g.name});
            const v = try binaryChannel(it, "vmcon", g.console_host);
            g.console_host = -1;
            return v;
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

    /// Opens a path of the script below the root folder.
    fn openPath(it: *Interp, path: []const u8, write: bool) Error!i32 {
        if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok())
            return it.failCode("ZTCL VM NOFILE", "a path of ztcl::vm needs the file capability", .{});
        const rel = try fsroot.need(it, path);
        const r = try fsroot.openRel(it, rel, .{ .access = if (write) .read_write else .read }, 0);
        return switch (r) {
            .fd => |fd| fd,
            .err => |e| fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't open \"{s}\": ", .{path})),
        };
    }

    /// The bytes of a file of the script, for the kernel and the
    /// initramfs.
    fn readPath(it: *Interp, path: []const u8) Error![]u8 {
        const fd = try openPath(it, path, false);
        defer sys.close(fd);
        const end: i64 = @bitCast(linux.lseek(fd, 0, linux.SEEK.END));
        if (end < 0) return it.failCode("ZTCL VM PATH", "\"{s}\" is not a file", .{path});
        const buf = try it.heap.backing.alloc(u8, @intCast(end));
        errdefer it.heap.backing.free(buf);
        var off: usize = 0;
        while (off < buf.len) {
            const rc = linux.pread(fd, buf[off..].ptr, buf.len - off, @intCast(off));
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    off += rc;
                },
                .INTR => continue,
                else => return it.failCode("ZTCL VM PATH", "couldn't read \"{s}\"", .{path}),
            }
        }
        return buf[0..off];
    }

    fn create(it: *Interp, args: []const Value) Error!Value {
        const a = it.alloc();
        const b = it.heap.backing;
        const host = it.vm_host;
        const s = try state(it);
        if (s.guests.items.len >= host.max_guests)
            return it.failCode("ZTCL VM LIMIT", "the interpreter has {d} guests, the limit", .{s.guests.items.len});
        if (args.len % 2 != 0) return it.wrongArgs("ztcl::vm create ?-option value ...?");
        kvm.probe() catch |e| return failure(it, e);
        var cfg: kvm.Config = .{ .kernel = "", .cmdline = "console=hvc0 quiet", .console = -1 };
        var kernel: []const u8 = "";
        var initrd: []const u8 = "";
        var disks: std.ArrayList(struct { path: []const u8, rw: bool }) = .empty;
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
                kernel = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-initrd")) {
                initrd = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-cmdline")) {
                cfg.cmdline = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-entropy")) {
                cfg.entropy = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-warm")) {
                warm = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-disk")) {
                const l = try it.readList(v);
                if (l.len < 1 or l.len > 2) return it.fail("a disk is {{file ?rw?}}", .{});
                if (disks.items.len >= kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks", .{kvm.max_disks});
                try disks.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 2 and try isRw(it, l[1]) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                return it.failCode("ZTCL VM SHARE", "a share is not available on Linux yet", .{});
            } else return it.fail("bad option \"{s}\": must be -cmdline, -cpus, -disk, -entropy, -initrd, -kernel, -memory, -share, or -warm", .{opt});
        }
        if (kernel.len == 0) return it.failCode("ZTCL VM KERNEL", "a guest needs -kernel until the base image of the plan", .{});

        const g = try b.create(Guest);
        g.* = .{ .name = "", .machine = undefined, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .console_vm = -1, .console_host = -1, .warm = warm };
        var made = false;
        errdefer if (!made) freeGuest(it, g);
        g.kernel = try readPath(it, kernel);
        if (initrd.len != 0) g.initrd = try readPath(it, initrd);
        g.cmdline = try b.dupe(u8, cfg.cmdline);
        g.disks = try b.alloc(kvm.Disk, disks.items.len);
        for (g.disks) |*d| d.fd = -1;
        for (disks.items, g.disks) |d, *out| out.* = .{ .fd = try openPath(it, d.path, d.rw), .read_only = !d.rw };
        var pair: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS)
            return it.failCode("ZTCL VM KVM", "no socket for the console", .{});
        g.console_vm = pair[0];
        g.console_host = pair[1];
        cfg.kernel = g.kernel;
        cfg.initrd = g.initrd;
        cfg.cmdline = g.cmdline;
        cfg.disks = g.disks;
        cfg.console = g.console_vm;
        g.machine = kvm.init(b, cfg) catch |e| return failure(it, e);
        made = true;
        g.name = try std.fmt.allocPrint(b, "vm{d}", .{s.next});
        s.next += 1;
        s.guests.append(b, g) catch |e| {
            destroy(it, g);
            return e;
        };
        if (warm) {
            g.machine.start() catch |e| return failure(it, e);
            const fd = connect(g.machine, agent_port, 10_000) orelse
                return it.failCode("ZTCL VM AGENT", "no program of the guest accepted a connection on port {d}", .{agent_port});
            _ = linux.close(fd);
            g.machine.pause();
        }
        return .{ .str = g.name };
    }

    fn start(it: *Interp, g: *Guest) Error!void {
        switch (g.machine.getState()) {
            .paused => g.machine.@"resume"(),
            .created, .stopped, .failed => g.machine.start() catch |e| return failure(it, e),
            .running => return it.failCode("ZTCL VM STATE", "the guest {s} is running", .{g.name}),
        }
    }

    fn status(g: *Guest) []const u8 {
        return switch (g.machine.getState()) {
            .created => "created",
            .running => "running",
            .paused => "paused",
            .stopped => "stopped",
            .failed => "error",
        };
    }

    fn nowMs() u64 {
        return kvm.nowNs() / std.time.ns_per_ms;
    }

    /// Connects to a port of the guest, again after each refused
    /// connection, until `timeout_ms` pass. Gives a blocking socket.
    fn connect(m: *kvm, port: u32, timeout_ms: u32) ?i32 {
        const end = nowMs() + timeout_ms;
        while (m.getState() == .running) {
            const rc = linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
            if (linux.errno(rc) != .SUCCESS) return null;
            const fd: i32 = @intCast(rc);
            var addr: extern struct { family: u16 = AF_VSOCK, reserved1: u16 = 0, port: u32, cid: u32, flags: u8 = 0, zero: [3]u8 = @splat(0) } = .{ .port = port, .cid = @intCast(m.cid) };
            var good = false;
            const c = linux.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
            switch (linux.errno(c)) {
                .SUCCESS => good = true,
                .INPROGRESS => {
                    const left = end -| nowMs();
                    var p = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&p, 1, @intCast(@min(left, 1000)));
                    var err: i32 = 1;
                    var len: linux.socklen_t = @sizeOf(i32);
                    if (p[0].revents != 0 and linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&err), &len)) == .SUCCESS and err == 0) good = true;
                },
                else => {},
            }
            if (good) {
                sys.setBlocking(fd, true);
                return fd;
            }
            _ = linux.close(fd);
            if (nowMs() >= end) return null;
            var ts: linux.timespec = .{ .sec = 0, .nsec = 50_000 };
            _ = linux.nanosleep(&ts, null);
        }
        return null;
    }

    fn vsock(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const a = try vsockArgs(it, args);
        if (g.machine.getState() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const fd = connect(g.machine, a.port, a.timeout) orelse
            return it.failCode("ZTCL VM CONNECT", "no program of the guest {s} accepted a connection on port {d}", .{ g.name, a.port });
        return binaryChannel(it, "vsock", fd);
    }

    fn freeGuest(it: *Interp, g: *Guest) void {
        const b = it.heap.backing;
        for (g.disks) |d| if (d.fd >= 0) sys.close(d.fd);
        b.free(g.disks);
        b.free(g.kernel);
        b.free(g.initrd);
        b.free(g.cmdline);
        if (g.console_vm >= 0) sys.close(g.console_vm);
        if (g.console_host >= 0) sys.close(g.console_host);
        b.free(g.name);
        b.destroy(g);
    }

    fn destroy(it: *Interp, g: *Guest) void {
        g.machine.deinit();
        freeGuest(it, g);
    }

    pub fn closeAll(it: *Interp) void {
        const s: *State = @ptrCast(@alignCast(it.vm_state orelse return));
        for (s.guests.items) |g| destroy(it, g);
        s.guests.deinit(it.heap.backing);
        it.heap.backing.destroy(s);
        it.vm_state = null;
    }
} else struct {};
