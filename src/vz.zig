//! Virtualization.framework from Zig, for `ztcl::vm` on macOS (ztcl#203).
//!
//! The calls go through the Objective-C runtime: `objc_msgSend` cast to a
//! function pointer of the type of each method, as the AppKit backend of
//! ztk does. The runtime and the framework load with `dlopen` at the
//! first call, so a build of ztcl for macOS needs no SDK.
//!
//! A `VZVirtualMachine` belongs to the serial dispatch queue that it was
//! made with: each call to it runs on that queue (`onQueue`), and its
//! completion handlers run there too. A handler is a block. `Block` makes
//! one on the stack of the caller from a Zig function and a pointer to
//! Zig data; the framework copies it to the heap before the call returns.
//!
//! The process needs the entitlement `com.apple.security.virtualization`
//! (tools/vm-guest/vz.entitlements) in its signature, an ad hoc one too.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub const Id = *opaque {};
pub const Sel = *opaque {};
pub const Class = *opaque {};

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

pub const Queue = *opaque {};
pub const Semaphore = *opaque {};
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) Queue;
extern "c" fn dispatch_async_f(q: Queue, ctx: ?*anyopaque, f: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_sync_f(q: Queue, ctx: ?*anyopaque, f: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_semaphore_create(n: isize) Semaphore;
extern "c" fn dispatch_semaphore_signal(s: Semaphore) isize;
extern "c" fn dispatch_semaphore_wait(s: Semaphore, timeout: u64) isize;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;

pub const Error = error{ Unavailable, Framework };

const Rt = struct {
    msg_send: *const anyopaque,
    get_class: *const fn ([*:0]const u8) callconv(.c) ?Class,
    sel: *const fn ([*:0]const u8) callconv(.c) Sel,
    stack_block: *anyopaque,
    alloc_class: *const fn (super: Class, name: [*:0]const u8, extra: usize) callconv(.c) ?Class,
    add_method: *const fn (cls: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) callconv(.c) bool,
    register_class: *const fn (cls: Class) callconv(.c) void,
};

var rt: ?Rt = null;

/// Loads the Objective-C runtime and Virtualization.framework. Gives
/// `error.Unavailable` on a system with no framework (before macOS 11).
pub fn load() Error!void {
    if (rt != null) return;
    const objc = dlopen("/usr/lib/libobjc.A.dylib", 1) orelse return error.Unavailable;
    const system = dlopen("/usr/lib/libSystem.B.dylib", 1) orelse return error.Unavailable;
    _ = dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", 1) orelse return error.Unavailable;
    _ = dlopen("/System/Library/Frameworks/Virtualization.framework/Virtualization", 1) orelse return error.Unavailable;
    rt = .{
        .msg_send = dlsym(objc, "objc_msgSend") orelse return error.Unavailable,
        .get_class = @ptrCast(@alignCast(dlsym(objc, "objc_getClass") orelse return error.Unavailable)),
        .sel = @ptrCast(@alignCast(dlsym(objc, "sel_registerName") orelse return error.Unavailable)),
        .stack_block = dlsym(system, "_NSConcreteStackBlock") orelse return error.Unavailable,
        .alloc_class = @ptrCast(@alignCast(dlsym(objc, "objc_allocateClassPair") orelse return error.Unavailable)),
        .add_method = @ptrCast(@alignCast(dlsym(objc, "class_addMethod") orelse return error.Unavailable)),
        .register_class = @ptrCast(@alignCast(dlsym(objc, "objc_registerClassPair") orelse return error.Unavailable)),
    };
}

pub fn class(name: [*:0]const u8) Error!Class {
    return rt.?.get_class(name) orelse error.Unavailable;
}

/// Sends `selector` to `target` with `args`. `Fn` is the type of the
/// method as a C function, with the receiver and the selector first.
pub fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    const f: *const Fn = @ptrCast(@alignCast(rt.?.msg_send));
    const Receiver = @typeInfo(Fn).@"fn".param_types[0].?;
    return @call(.auto, f, .{ @as(Receiver, @ptrCast(target)), rt.?.sel(selector) } ++ args);
}

pub fn send0(target: anytype, selector: [*:0]const u8) Id {
    return call(fn (@TypeOf(target), Sel) callconv(.c) Id, target, selector, .{});
}

pub fn send1(target: anytype, selector: [*:0]const u8, arg: anytype) Id {
    return call(fn (@TypeOf(target), Sel, @TypeOf(arg)) callconv(.c) Id, target, selector, .{arg});
}

pub fn setter(target: Id, selector: [*:0]const u8, arg: anytype) void {
    call(fn (Id, Sel, @TypeOf(arg)) callconv(.c) void, target, selector, .{arg});
}

/// `[[cls alloc] init]`.
pub fn new(name: [*:0]const u8) Error!Id {
    return send0(send0(try class(name), "alloc"), "init");
}

pub fn alloc(name: [*:0]const u8) Error!Id {
    return send0(try class(name), "alloc");
}

pub fn retain(obj: Id) void {
    _ = send0(obj, "retain");
}

pub fn release(obj: Id) void {
    _ = send0(obj, "release");
}

/// An autoreleased `NSString` with a copy of `text`.
pub fn string(text: []const u8) Error!Id {
    const s = call(fn (Id, Sel, [*]const u8, usize, usize) callconv(.c) Id, try alloc("NSString"), "initWithBytes:length:encoding:", .{ text.ptr, text.len, 4 });
    return send0(s, "autorelease");
}

/// An autoreleased file URL of `path`.
pub fn fileUrl(path: []const u8) Error!Id {
    return send1(try class("NSURL"), "fileURLWithPath:", try string(path));
}

/// An autoreleased `NSArray` with one object.
pub fn array1(obj: Id) Error!Id {
    return send1(try class("NSArray"), "arrayWithObject:", obj);
}

/// The text of an `NSError`, valid while the autorelease pool lives.
pub fn errorText(err: ?Id) []const u8 {
    const e = err orelse return "no error";
    const d = send0(e, "localizedDescription");
    const p = call(fn (Id, Sel) callconv(.c) ?[*:0]const u8, d, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// A block on the stack of the caller: a Zig function of the C calling
/// convention, with the block as its first parameter, and a pointer to
/// Zig data. The callee copies it with `Block_copy` when it keeps it, so
/// the block lives until the call that it is an argument of returns.
pub fn Block(comptime Ctx: type) type {
    return extern struct {
        isa: *anyopaque,
        flags: i32 = 0,
        reserved: i32 = 0,
        invoke: *const anyopaque,
        descriptor: *const Descriptor,
        ctx: *Ctx,

        const Self = @This();
        const Descriptor = extern struct { reserved: usize = 0, size: usize };
        const desc: Descriptor = .{ .size = @sizeOf(Self) };

        /// `invoke` has the type `fn (*Self, ...) callconv(.c) void`.
        pub fn init(ctx: *Ctx, invoke: *const anyopaque) Self {
            return .{ .isa = rt.?.stack_block, .invoke = invoke, .descriptor = &desc, .ctx = ctx };
        }
    };
}

pub fn queue(label: [*:0]const u8) Queue {
    return dispatch_queue_create(label, null);
}

/// Runs `f(ctx)` on `q` and waits for it to return.
pub fn onQueue(q: Queue, comptime Ctx: type, ctx: *Ctx, comptime f: fn (*Ctx) void) void {
    const S = struct {
        fn run(p: ?*anyopaque) callconv(.c) void {
            const pool = send0(send0(class("NSAutoreleasePool") catch unreachable, "alloc"), "init");
            defer release(pool);
            f(@ptrCast(@alignCast(p.?)));
        }
    };
    dispatch_sync_f(q, ctx, S.run);
}

/// A semaphore that a completion handler signals and a thread waits on.
pub const Signal = struct {
    sem: Semaphore,

    pub fn init() Signal {
        return .{ .sem = dispatch_semaphore_create(0) };
    }
    pub fn post(s: Signal) void {
        _ = dispatch_semaphore_signal(s.sem);
    }
    /// False when `seconds` pass first.
    pub fn wait(s: Signal, seconds: f64) bool {
        const ns: i64 = @intFromFloat(seconds * 1e9);
        return dispatch_semaphore_wait(s.sem, dispatch_time(0, ns)) == 0;
    }
};

pub const Share = struct { path: []const u8, tag: []const u8, read_only: bool = true };
pub const Disk = struct { path: []const u8, read_only: bool = true };

/// An autoreleased `NSMutableArray`.
fn mutableArray() Error!Id {
    return send0(try class("NSMutableArray"), "array");
}

fn push(list: Id, obj: Id) void {
    setter(list, "addObject:", obj);
    release(obj);
}

/// The parts of a Linux guest.
pub const Config = struct {
    kernel: []const u8,
    initrd: ?[]const u8 = null,
    cmdline: []const u8 = "console=hvc0",
    cpus: usize = 1,
    memory_mb: u64 = 256,
    /// The descriptors of the console of the guest (`hvc0`): the guest
    /// reads `in` and writes `out`, which can be one socket. No console
    /// when null.
    console: ?struct { in: c_int, out: c_int } = null,
    /// The directories of the host for virtio-fs, each with the tag that
    /// the guest mounts.
    shares: []const Share = &.{},
    /// The disk image files, as virtio block devices in this order.
    disks: []const Disk = &.{},
    vsock: bool = true,
    entropy: bool = true,
    /// One end of a `socketpair(AF_UNIX, SOCK_DGRAM)` for a virtio-net
    /// device: each datagram is one Ethernet frame (the NAT of ztcl#461).
    /// No network device when null.
    net_fd: ?c_int = null,
    /// The MAC address of the network device, as `52:54:00:12:34:56`.
    net_mac: []const u8 = "52:54:00:12:34:56",
    /// The `VZGenericMachineIdentifier` of the platform. A saved state
    /// restores only on a machine with the same identifier. Null gives a
    /// new one.
    machine_id: ?Id = null,
};

/// Makes and checks a `VZVirtualMachineConfiguration`. On an error,
/// `why` has the text of the framework.
pub fn configure(c: Config, why: *[]const u8) Error!Id {
    const boot = send1(try alloc("VZLinuxBootLoader"), "initWithKernelURL:", try fileUrl(c.kernel));
    if (c.initrd) |p| setter(boot, "setInitialRamdiskURL:", try fileUrl(p));
    setter(boot, "setCommandLine:", try string(c.cmdline));

    const vc = try new("VZVirtualMachineConfiguration");
    setter(vc, "setBootLoader:", boot);
    release(boot);
    setter(vc, "setCPUCount:", c.cpus);
    setter(vc, "setMemorySize:", c.memory_mb * 1024 * 1024);
    const plat = try new("VZGenericPlatformConfiguration");
    if (c.machine_id) |id| setter(plat, "setMachineIdentifier:", id);
    setter(vc, "setPlatform:", plat);
    release(plat);

    if (c.console) |con| {
        const fh_in = call(fn (Id, Sel, c_int) callconv(.c) Id, try alloc("NSFileHandle"), "initWithFileDescriptor:", .{con.in});
        const fh_out = call(fn (Id, Sel, c_int) callconv(.c) Id, try alloc("NSFileHandle"), "initWithFileDescriptor:", .{con.out});
        const att = call(fn (Id, Sel, Id, Id) callconv(.c) Id, try alloc("VZFileHandleSerialPortAttachment"), "initWithFileHandleForReading:fileHandleForWriting:", .{ fh_in, fh_out });
        release(fh_in);
        release(fh_out);
        const port = try new("VZVirtioConsoleDeviceSerialPortConfiguration");
        setter(port, "setAttachment:", att);
        release(att);
        setter(vc, "setSerialPorts:", try array1(port));
        release(port);
    }

    if (c.entropy) {
        const rng = try new("VZVirtioEntropyDeviceConfiguration");
        setter(vc, "setEntropyDevices:", try array1(rng));
        release(rng);
    }

    if (c.net_fd) |fd| {
        const fh = call(fn (Id, Sel, c_int) callconv(.c) Id, try alloc("NSFileHandle"), "initWithFileDescriptor:", .{fd});
        const att = send1(try alloc("VZFileHandleNetworkDeviceAttachment"), "initWithFileHandle:", fh);
        release(fh);
        const net = try new("VZVirtioNetworkDeviceConfiguration");
        setter(net, "setAttachment:", att);
        release(att);
        const mac = send1(try alloc("VZMACAddress"), "initWithString:", try string(c.net_mac));
        setter(net, "setMACAddress:", mac);
        release(mac);
        setter(vc, "setNetworkDevices:", try array1(net));
        release(net);
    }

    if (c.vsock) {
        const sock = try new("VZVirtioSocketDeviceConfiguration");
        setter(vc, "setSocketDevices:", try array1(sock));
        release(sock);
    }

    if (c.shares.len > 0) {
        const list = try mutableArray();
        for (c.shares) |sh| {
            const dir = call(fn (Id, Sel, Id, bool) callconv(.c) Id, try alloc("VZSharedDirectory"), "initWithURL:readOnly:", .{ try fileUrl(sh.path), sh.read_only });
            const single = send1(try alloc("VZSingleDirectoryShare"), "initWithDirectory:", dir);
            release(dir);
            const fs = send1(try alloc("VZVirtioFileSystemDeviceConfiguration"), "initWithTag:", try string(sh.tag));
            setter(fs, "setShare:", single);
            release(single);
            push(list, fs);
        }
        setter(vc, "setDirectorySharingDevices:", list);
    }

    if (c.disks.len > 0) {
        const list = try mutableArray();
        for (c.disks) |d| {
            var err: ?Id = null;
            const att = call(fn (Id, Sel, Id, bool, *?Id) callconv(.c) ?Id, try alloc("VZDiskImageStorageDeviceAttachment"), "initWithURL:readOnly:error:", .{ try fileUrl(d.path), d.read_only, &err }) orelse {
                why.* = errorText(err);
                release(vc);
                return error.Framework;
            };
            const blk = send1(try alloc("VZVirtioBlockDeviceConfiguration"), "initWithAttachment:", att);
            release(att);
            push(list, blk);
        }
        setter(vc, "setStorageDevices:", list);
    }

    var err: ?Id = null;
    if (!call(fn (Id, Sel, *?Id) callconv(.c) bool, vc, "validateWithError:", .{&err})) {
        why.* = errorText(err);
        release(vc);
        return error.Framework;
    }
    return vc;
}

/// A running Linux guest of Virtualization.framework.
pub const Machine = struct {
    q: Queue,
    vm: Id,

    /// Makes the machine of a checked configuration, on a queue of its own.
    pub fn init(vc: Id) Error!Machine {
        const q = queue("org.beetlebug.ztcl.vm");
        const vm = call(fn (Id, Sel, Id, Queue) callconv(.c) Id, try alloc("VZVirtualMachine"), "initWithConfiguration:queue:", .{ vc, q });
        return .{ .q = q, .vm = vm };
    }

    pub fn deinit(m: *Machine) void {
        release(m.vm);
    }

    const Done = struct {
        m: *Machine,
        sig: Signal,
        sel: [*:0]const u8 = "",
        url: ?Id = null,
        err: ?Id = null,
        port: u32 = 0,
        conn: ?Id = null,
    };

    fn errDone(b: *Block(Done), err: ?Id) callconv(.c) void {
        if (err) |e| retain(e);
        b.ctx.err = err;
        b.ctx.sig.post();
    }

    fn sendOp(x: *Done) void {
        var b = Block(Done).init(x, @ptrCast(&errDone));
        if (x.url) |u|
            call(fn (Id, Sel, Id, *Block(Done)) callconv(.c) void, x.m.vm, x.sel, .{ u, &b })
        else
            call(fn (Id, Sel, *Block(Done)) callconv(.c) void, x.m.vm, x.sel, .{&b});
    }

    /// Sends an operation with a completion handler of one `NSError`,
    /// such as `startWithCompletionHandler:`, and waits for the handler.
    fn op(m: *Machine, sel: [*:0]const u8, url: ?Id, seconds: f64, why: *[]const u8) Error!void {
        var d: Done = .{ .m = m, .sig = Signal.init(), .sel = sel, .url = url };
        onQueue(m.q, Done, &d, sendOp);
        if (!d.sig.wait(seconds)) {
            why.* = "the operation timed out";
            return error.Framework;
        }
        if (d.err) |e| {
            why.* = errorText(e);
            return error.Framework;
        }
    }

    /// Starts the guest and waits for the framework to say that it runs.
    pub fn start(m: *Machine, why: *[]const u8) Error!void {
        return m.op("startWithCompletionHandler:", null, 30, why);
    }

    /// Stops the guest at once, as a pull of its power cord.
    pub fn stop(m: *Machine) void {
        var why: []const u8 = "";
        m.op("stopWithCompletionHandler:", null, 10, &why) catch {};
    }

    /// The states of `VZVirtualMachineState`.
    pub const State = enum(isize) { stopped = 0, running, paused, @"error", starting, pausing, resuming, stopping, saving, restoring, _ };

    pub fn state(m: *Machine) State {
        const S = struct { m: *Machine, out: isize = 0 };
        var x: S = .{ .m = m };
        onQueue(m.q, S, &x, struct {
            fn f(p: *S) void {
                p.out = call(fn (Id, Sel) callconv(.c) isize, p.m.vm, "state", .{});
            }
        }.f);
        return @fromBackingInt(x.out);
    }

    /// Asks the guest to power off, as a press of its power button.
    /// False when the guest cannot get the request.
    pub fn requestStop(m: *Machine) bool {
        const S = struct { m: *Machine, ok: bool = false };
        var x: S = .{ .m = m };
        onQueue(m.q, S, &x, struct {
            fn f(p: *S) void {
                if (!call(fn (Id, Sel) callconv(.c) bool, p.m.vm, "canRequestStop", .{})) return;
                var err: ?Id = null;
                p.ok = call(fn (Id, Sel, *?Id) callconv(.c) bool, p.m.vm, "requestStopWithError:", .{&err});
            }
        }.f);
        return x.ok;
    }

    pub fn pause(m: *Machine, why: *[]const u8) Error!void {
        return m.op("pauseWithCompletionHandler:", null, 10, why);
    }

    pub fn @"resume"(m: *Machine, why: *[]const u8) Error!void {
        return m.op("resumeWithCompletionHandler:", null, 10, why);
    }

    /// Saves the memory and the devices of a paused guest (macOS 14).
    pub fn save(m: *Machine, path: []const u8, why: *[]const u8) Error!void {
        return m.op("saveMachineStateToURL:completionHandler:", try fileUrl(path), 60, why);
    }

    /// Restores a saved state into a stopped machine of the same
    /// configuration; the guest is paused after it.
    pub fn restore(m: *Machine, path: []const u8, why: *[]const u8) Error!void {
        return m.op("restoreMachineStateFromURL:completionHandler:", try fileUrl(path), 60, why);
    }

    fn connDone(b: *Block(Done), conn: ?Id, err: ?Id) callconv(.c) void {
        if (conn) |c| retain(c);
        if (err) |e| retain(e);
        b.ctx.conn = conn;
        b.ctx.err = err;
        b.ctx.sig.post();
    }

    /// A connection to a vsock port of the guest. The connection owns
    /// the file descriptor: `close` releases it.
    pub const Conn = struct {
        obj: Id,
        fd: c_int,
        pub fn close(c: Conn) void {
            release(c.obj);
        }
    };

    /// Connects to `port` of the guest. `error.Framework` when no program
    /// of the guest listens on it.
    pub fn connect(m: *Machine, port: u32, why: *[]const u8) Error!Conn {
        var d: Done = .{ .m = m, .sig = Signal.init(), .port = port };
        onQueue(m.q, Done, &d, struct {
            fn f(x: *Done) void {
                const devs = send0(x.m.vm, "socketDevices");
                const dev = send0(devs, "firstObject");
                var b = Block(Done).init(x, @ptrCast(&connDone));
                call(fn (Id, Sel, u32, *Block(Done)) callconv(.c) void, dev, "connectToPort:completionHandler:", .{ x.port, &b });
            }
        }.f);
        if (!d.sig.wait(10)) {
            why.* = "the connection timed out";
            return error.Framework;
        }
        if (d.conn) |c| {
            const fd = call(fn (Id, Sel) callconv(.c) c_int, c, "fileDescriptor", .{});
            return .{ .obj = c, .fd = fd };
        }
        why.* = errorText(d.err);
        return error.Framework;
    }
};

// ---- Connections of the guest to the host (VZVirtioSocketListener) ----

/// A listener of the host on a vsock port of a guest. The delegate of the
/// framework runs on the queue of the machine: it takes a copy of the
/// descriptor of each new connection, keeps it in `pending`, and writes
/// its number to `pipe_w`, so the thread of the interpreter hears of it.
/// `take` gives a descriptor only once, and only one that `pending` has.
pub const Listener = struct {
    m: *Machine,
    port: u32,
    pipe_w: c_int,
    delegate: Id = undefined,
    listener: Id = undefined,
    lock: @import("thread.zig").Lock = .{},
    pending: [64]c_int = @splat(-1),

    /// Takes the descriptor `fd` that the delegate kept, or false.
    pub fn take(l: *Listener, fd: c_int) bool {
        l.lock.lock();
        defer l.lock.unlock();
        for (&l.pending) |*p| if (p.* == fd and fd >= 0) {
            p.* = -1;
            return true;
        };
        return false;
    }
};

var listeners_lock: @import("thread.zig").Lock = .{};
var listeners: std.ArrayList(*Listener) = .empty;

fn listenerOf(delegate: Id) ?*Listener {
    listeners_lock.lock();
    defer listeners_lock.unlock();
    for (listeners.items) |l| if (l.delegate == delegate) return l;
    return null;
}

fn onAccept(delegate: Id, _: Sel, _: Id, conn: Id, _: Id) callconv(.c) bool {
    const l = listenerOf(delegate) orelse return false;
    const fd = dup(call(fn (Id, Sel) callconv(.c) c_int, conn, "fileDescriptor", .{}));
    if (fd < 0) return false;
    l.lock.lock();
    const slot: ?*c_int = for (&l.pending) |*p| {
        if (p.* < 0) break p;
    } else null;
    if (slot) |p| p.* = fd;
    l.lock.unlock();
    if (slot == null) {
        _ = close(fd);
        return false;
    }
    var n: c_int = fd;
    _ = write(l.pipe_w, std.mem.asBytes(&n), @sizeOf(c_int));
    return true;
}

extern "c" fn dup(fd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

var delegate_class: ?Class = null;

fn delegateClass() Error!Class {
    if (delegate_class) |c| return c;
    if (rt.?.get_class("ZtclVsockListener")) |c| {
        delegate_class = c;
        return c;
    }
    const cls = rt.?.alloc_class(try class("NSObject"), "ZtclVsockListener", 0) orelse return error.Unavailable;
    _ = rt.?.add_method(cls, rt.?.sel("listener:shouldAcceptNewConnection:fromSocketDevice:"), @ptrCast(&onAccept), "c@:@@@");
    rt.?.register_class(cls);
    delegate_class = cls;
    return cls;
}

/// Listens on `port` of the guest of `m`. A new connection writes its
/// descriptor to `pipe_w`. The caller owns the listener: `unlisten`.
pub fn listen(gpa: std.mem.Allocator, m: *Machine, port: u32, pipe_w: c_int) Error!*Listener {
    const l = gpa.create(Listener) catch return error.Framework;
    l.* = .{ .m = m, .port = port, .pipe_w = pipe_w };
    l.delegate = send0(send0(try delegateClass(), "alloc"), "init");
    l.listener = try new("VZVirtioSocketListener");
    setter(l.listener, "setDelegate:", l.delegate);
    listeners_lock.lock();
    listeners.append(std.heap.c_allocator, l) catch {
        listeners_lock.unlock();
        release(l.listener);
        release(l.delegate);
        gpa.destroy(l);
        return error.Framework;
    };
    listeners_lock.unlock();
    onQueue(m.q, Listener, l, struct {
        fn f(x: *Listener) void {
            const dev = send0(send0(x.m.vm, "socketDevices"), "firstObject");
            call(fn (Id, Sel, Id, u32) callconv(.c) void, dev, "setSocketListener:forPort:", .{ x.listener, x.port });
        }
    }.f);
    return l;
}

/// Stops a listener and closes each connection that no script took.
pub fn unlisten(gpa: std.mem.Allocator, l: *Listener) void {
    onQueue(l.m.q, Listener, l, struct {
        fn f(x: *Listener) void {
            const dev = send0(send0(x.m.vm, "socketDevices"), "firstObject");
            call(fn (Id, Sel, u32) callconv(.c) void, dev, "removeSocketListenerForPort:", .{x.port});
        }
    }.f);
    listeners_lock.lock();
    for (listeners.items, 0..) |x, i| if (x == l) {
        _ = listeners.swapRemove(i);
        break;
    };
    listeners_lock.unlock();
    for (l.pending) |fd| if (fd >= 0) {
        _ = close(fd);
    };
    release(l.listener);
    release(l.delegate);
    gpa.destroy(l);
}

/// Checks that a configuration can save and restore its state.
pub fn checkSaveRestore(vc: Id, why: *[]const u8) bool {
    var err: ?Id = null;
    if (call(fn (Id, Sel, *?Id) callconv(.c) bool, vc, "validateSaveRestoreSupportWithError:", .{&err})) return true;
    why.* = errorText(err);
    return false;
}
