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
//! (`vmagent.zig`, `docs/dev/vm-agent.md`): `exec` on macOS, KVM, and Windows,
//! and `mount` on macOS and KVM, in this version.
//!
//! macOS has Virtualization.framework through `vz.zig`, and x86-64
//! Linux has the KVM monitor of `kvm.zig`. x86-64 Windows has the monitor
//! of `whp.zig` on the Windows Hypervisor Platform: a pump thread moves
//! the bytes of the console and of each vsock stream between the monitor
//! and a pair of loopback sockets, and the script gets one end of each
//! pair as its channel. On another platform each
//! command gives the error `ZTCL VM UNAVAILABLE`, until the arm64 KVM
//! part of the plan.
//!
//! The paths of `-kernel`, `-initrd`, `-disk`, and `-share` also need
//! the `file` capability, and each is a path below the root folder of
//! the file jail. The framework gets the final path of the open
//! descriptor (`F_GETPATH`), so a link in the root folder cannot point
//! the guest outside it.
//!
//! A share is the tag `share0`, `share1`, ..., in the order of
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
//! a swap of the file after the check cannot reach the guest. A share on
//! Linux is the 9p device of ztcl (`vm/virtio/ninep.zig`), with the tag
//! `share0`, `share1`, ..., and the agent mounts it with 9p.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const more = @import("more.zig");
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
const on_whp = builtin.os.tag == .windows and builtin.cpu.arch == .x86_64;
const whp = if (on_whp) @import("whp.zig") else struct {};

/// The limits of the embedder for the guests of one interpreter.
pub const Host = struct {
    max_cpus: u32 = 4,
    max_memory_mb: u32 = 2048,
    max_guests: u32 = 4,
    /// The folder of the store of signed images (`vmstore.zig`), a path
    /// of the host. Empty: `ztcl::vm image` gives ZTCL VM STORE.
    image_store: []const u8 = "",
    /// The guests of each image that wait, booted to the agent and
    /// paused, for `create -image` (macOS, Windows, and KVM).
    /// Virtualization.framework starts each guest in a new process, about
    /// 86 ms, and a KVM guest of an image answers its first exec after
    /// about 85 ms; a guest of the pool resumes in under 1 ms. 0 turns the pool off. Each guest of
    /// the pool holds the memory that it touched.
    pool_size: u32 = 0,
    /// Downloads `url` (HTTPS) into the open file `fd`, for `ztcl::vm
    /// image fetch` and `update`. The runner gives one on std.http; an
    /// embedder with no network leaves it null, and fetch then gives
    /// ZTCL VM UNAVAILABLE. A file passes the checks of the signed
    /// manifest before it counts, so the hook needs no trust.
    fetch: ?*const fn (ctx: ?*anyopaque, url: []const u8, fd: i32) FetchError!void = null,
    fetch_ctx: ?*anyopaque = null,
    /// The image keys of the embedder, trusted with the keys of ztcl.
    /// An embedder signs its own images (a guest with its own tools)
    /// with one of them. Give a test key `test_only`, so that it signs
    /// only a name that ends in `-test`, and keep it out of a release
    /// build.
    image_keys: []const @import("vmimage.zig").Key = &.{},
};

pub const FetchError = error{ Network, Status, Io, OutOfMemory };

/// The runner gives the download of `image fetch` (`zig build -Dvm-fetch`).
pub const runner_fetch = @hasDecl(@import("build_options"), "vm_fetch") and @import("build_options").vm_fetch;

/// The release of the images by default: a GitHub release that the
/// publisher moves to each new image (docs/dev/vm-image.md).
pub const image_base = "https://github.com/beetlebugorg/ztcl/releases/download/";

/// The port of the guest agent. A warm guest pauses when a program of
/// the guest accepts a connection on it.
pub const agent_port: u32 = 1024;

const usage = "ztcl::vm create|start|stop|status|vsock|exec|mount|console|delete ?arg ...?";
const vmagent = @import("vmagent.zig");

var warned = std.atomic.Value(bool).init(false);

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    // A build that trusts the test key of the images says so, once.
    if (comptime vmimage.trusts_test_key and !builtin.is_test) {
        if (!warned.swap(true, .monotonic)) std.debug.print("{s}\n", .{vmimage.test_key_warning});
    }
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
    if (std.mem.eql(u8, try it.str(args[1]), "image")) {
        if (comptime !vmstore.supported) return unavailable(it);
        return imageCmd(it, args[2..]);
    }
    if (comptime on_kvm) return lin.run(it, args);
    if (comptime on_whp) return win.run(it, args);
    if (comptime !on_mac) return unavailable(it);
    return mac.run(it, args);
}

/// Stops and frees each guest of the interpreter, at its end.
pub fn closeAll(it: *Interp) void {
    if (comptime on_mac) mac.closeAll(it);
    if (comptime on_kvm) lin.closeAll(it);
    if (comptime on_whp) win.closeAll(it);
}

// ---- ztcl::vm image: the store of signed images (vmstore.zig) ----

const vmstore = @import("vmstore.zig");
const vmimage = @import("vmimage.zig");

fn store(it: *Interp) Error!vmstore.Store {
    if (comptime !vmstore.supported) return it.failCode("ZTCL VM UNAVAILABLE", "the store of images is not available on this platform", .{});
    var s = vmstore.Store.open(it.alloc(), it.vm_host.image_store) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return it.failCode("ZTCL VM STORE", "no store of images: {s}", .{if (it.vm_host.image_store.len == 0) "the embedder gives no folder" else @errorName(e)}),
    };
    s.keys = it.vm_host.image_keys;
    return s;
}

fn storeFail(it: *Interp, e: vmstore.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadSignature => it.failCode("ZTCL VM IMAGE SIGNATURE", "the signature of the manifest is not good", .{}),
        error.Untrusted => it.failCode("ZTCL VM IMAGE SIGNATURE", "the manifest is not signed by a key that this ztcl trusts", .{}),
        error.Namespace => it.failCode("ZTCL VM IMAGE SIGNATURE", "the signature is not for ztcl-vm-image", .{}),
        error.Rollback => it.failCode("ZTCL VM IMAGE ROLLBACK", "the store has a newer release of the image: pass -force to install an older one", .{}),
        error.Hash => it.failCode("ZTCL VM IMAGE HASH", "a file of the image does not have the SHA-256 of its manifest", .{}),
        error.BadManifest => it.failCode("ZTCL VM IMAGE MANIFEST", "the manifest of the image is not valid", .{}),
        error.Missing => it.failCode("ZTCL VM IMAGE MISSING", "the image has no files for {s}", .{vmstore.host_arch}),
        error.NotFound => it.failCode("ZTCL VM IMAGE NAME", "no such image or release", .{}),
        else => it.failCode("ZTCL VM STORE", "the store of images failed: {s}", .{@errorName(e)}),
    };
}

/// The current release of `name`, checked, for `create -image`.
pub const Resolved = struct { kernel: []u8, initrd: ?[]u8, cmdline: []const u8, disks: [][]u8 };

pub fn resolveImage(it: *Interp, name: []const u8) Error!Resolved {
    const s = try store(it);
    defer s.close();
    const a = it.alloc();
    const counter = (s.current(a, name) catch |e| return storeFail(it, e)) orelse
        return it.failCode("ZTCL VM IMAGE NAME", "no image named \"{s}\" in the store: install it with ztcl::vm image install", .{name});
    // The kernel and the initramfs get a check of their hash at each use;
    // a disk with verity checks itself on each read in the guest.
    _ = s.verifyRelease(a, name, counter, vmstore.host_arch) catch |e| return storeFail(it, e);
    var c = s.load(a, name, counter) catch |e| return storeFail(it, e);
    defer c.deinit();
    const x = c.parsed.value.archs.map.get(vmstore.host_arch) orelse return storeFail(it, error.Missing);
    const disks = try a.alloc([]u8, x.disks.len);
    for (x.disks, disks) |d, *p| p.* = try s.objectPath(a, d.sha256);
    return .{
        .kernel = try s.objectPath(a, x.kernel.sha256),
        .initrd = if (x.initrd) |f| try s.objectPath(a, f.sha256) else null,
        .cmdline = try a.dupe(u8, x.cmdline),
        .disks = disks,
    };
}

/// The current release of `name`, for a monitor that boots from memory:
/// the kernel and the initramfs in memory of `b`, each checked against
/// its SHA-256 on the bytes that the guest gets, and a descriptor of
/// each disk, read-only, opened through the store. A disk with verity
/// checks itself in the guest.
pub const Loaded = struct { kernel: []u8, initrd: []u8, cmdline: []const u8, disks: []i32 };

pub fn loadImage(it: *Interp, b: std.mem.Allocator, name: []const u8) Error!Loaded {
    const s = try store(it);
    defer s.close();
    const a = it.alloc();
    const counter = (s.current(a, name) catch |e| return storeFail(it, e)) orelse
        return it.failCode("ZTCL VM IMAGE NAME", "no image named \"{s}\" in the store: install it with ztcl::vm image install", .{name});
    var c = s.load(a, name, counter) catch |e| return storeFail(it, e);
    defer c.deinit();
    const x = c.parsed.value.archs.map.get(vmstore.host_arch) orelse return storeFail(it, error.Missing);
    const kernel = s.readObject(b, x.kernel.sha256) catch |e| return storeFail(it, e);
    errdefer b.free(kernel);
    const initrd: []u8 = if (x.initrd) |f| s.readObject(b, f.sha256) catch |e| return storeFail(it, e) else &.{};
    errdefer b.free(initrd);
    const disks = try a.alloc(i32, x.disks.len);
    var n: usize = 0;
    errdefer for (disks[0..n]) |fd| sys.close(fd);
    for (x.disks) |d| {
        disks[n] = s.openObject(a, d.sha256) catch |e| return storeFail(it, e);
        n += 1;
    }
    return .{ .kernel = kernel, .initrd = initrd, .cmdline = try a.dupe(u8, x.cmdline), .disks = disks };
}

fn imageCmd(it: *Interp, args: []const Value) Error!Value {
    const use = "ztcl::vm image install|list|verify|remove ?arg ...?";
    if (args.len < 1) return it.wrongArgs(use);
    const sub = try it.str(args[0]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "install")) {
        // ztcl::vm image install DIR ?-force?: a folder of the file jail.
        const force = args.len == 3 and std.mem.eql(u8, try it.str(args[2]), "-force");
        if (args.len != 2 and !force) return it.wrongArgs("ztcl::vm image install dir ?-force?");
        const dir = try jailDir(it, try it.str(args[1]));
        defer sys.close(dir);
        const s = try store(it);
        defer s.close();
        const r = s.install(a, dir, vmstore.host_arch, force) catch |e| return storeFail(it, e);
        var items = [6]Value{ .{ .str = "name" }, .{ .str = r.name }, .{ .str = "counter" }, .{ .int = @intCast(r.counter) }, .{ .str = "key" }, .{ .str = r.key } };
        return value.wrapList(a, try a.dupe(Value, &items));
    }
    if (std.mem.eql(u8, sub, "fetch") or std.mem.eql(u8, sub, "update")) return fetchCmd(it, args, std.mem.eql(u8, sub, "update"));
    if (std.mem.eql(u8, sub, "list")) {
        if (args.len != 1) return it.wrongArgs("ztcl::vm image list");
        const s = try store(it);
        defer s.close();
        const entries = s.list(a) catch |e| return storeFail(it, e);
        var out: std.ArrayList(Value) = .empty;
        for (entries) |e| {
            var cs: std.ArrayList(Value) = .empty;
            for (e.counters) |c| try cs.append(a, .{ .int = @intCast(c) });
            var items = [6]Value{ .{ .str = "name" }, .{ .str = e.name }, .{ .str = "releases" }, try value.wrapList(a, cs.items), .{ .str = "current" }, if (e.current) |c| .{ .int = @intCast(c) } else .{ .str = "" } };
            try out.append(a, try value.wrapList(a, try a.dupe(Value, &items)));
        }
        return value.wrapList(a, out.items);
    }
    if (std.mem.eql(u8, sub, "verify")) {
        if (args.len != 2) return it.wrongArgs("ztcl::vm image verify name");
        const name = try it.str(args[1]);
        const s = try store(it);
        defer s.close();
        const counter = (s.current(a, name) catch |e| return storeFail(it, e)) orelse return storeFail(it, error.NotFound);
        var c = s.load(a, name, counter) catch |e| return storeFail(it, e);
        const key = c.key.name;
        c.deinit();
        const n = s.verifyRelease(a, name, counter, vmstore.host_arch) catch |e| return storeFail(it, e);
        if (vmimage.trusts_test_key) std.debug.print("{s}\n", .{vmimage.test_key_warning});
        var items = [8]Value{ .{ .str = "name" }, .{ .str = name }, .{ .str = "counter" }, .{ .int = @intCast(counter) }, .{ .str = "key" }, .{ .str = key }, .{ .str = "files" }, .{ .int = @intCast(n) } };
        return value.wrapList(a, try a.dupe(Value, &items));
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (args.len != 2 and args.len != 3) return it.wrongArgs("ztcl::vm image remove name ?counter?");
        const name = try it.str(args[1]);
        const counter: ?u64 = if (args.len == 3) @intCast(@max(0, try it.int(args[2]))) else null;
        const s = try store(it);
        defer s.close();
        s.remove(a, name, counter) catch |e| return storeFail(it, e);
        return .{ .str = "" };
    }
    return it.fail("bad option \"{s}\": must be fetch, install, list, remove, update, or verify", .{sub});
}

/// `image fetch ?-version V? ?-url BASE? ?-force?` and `image update`:
/// the manifest and its signature first, then the files of this
/// architecture, into a folder of tmp/ of the store, then `install`.
fn fetchCmd(it: *Interp, args: []const Value, update: bool) Error!Value {
    const use_update = "ztcl::vm image update ?-url base?";
    const use_fetch = "ztcl::vm image fetch ?-version v? ?-url base? ?-force?";
    if (it.capabilities & @backingInt(interp.Capability.socket) == 0)
        return it.failCode("ZTCL VM NONET", "ztcl::vm image {s} needs the socket capability", .{if (update) "update" else "fetch"});
    const hook = it.vm_host.fetch orelse return it.failCode("ZTCL VM UNAVAILABLE", "this program gives ztcl::vm no download", .{});
    const a = it.alloc();
    var version: ?[]const u8 = null;
    var base: ?[]const u8 = null;
    var force = false;
    var i: usize = 1;
    while (i < args.len) {
        const o = try it.str(args[i]);
        if (std.mem.eql(u8, o, "-force") and !update) {
            force = true;
            i += 1;
            continue;
        }
        if (i + 1 >= args.len) return if (update) it.wrongArgs(use_update) else it.wrongArgs(use_fetch);
        if (std.mem.eql(u8, o, "-version") and !update) {
            version = try it.str(args[i + 1]);
        } else if (std.mem.eql(u8, o, "-url")) {
            base = try it.str(args[i + 1]);
        } else return if (update) it.wrongArgs(use_update) else it.wrongArgs(use_fetch);
        i += 2;
    }
    const root = if (base) |b|
        (if (std.mem.endsWith(u8, b, "/")) b else try std.fmt.allocPrint(a, "{s}/", .{b}))
    else
        try std.fmt.allocPrint(a, "{s}vm-image-{s}/", .{ image_base, if (version) |v| try std.fmt.allocPrint(a, "v{s}", .{v}) else "latest" });
    if (!std.mem.startsWith(u8, root, "https://") and !std.mem.startsWith(u8, root, "http://127.0.0.1"))
        return it.fail("a release is fetched over https", .{});
    const s = try store(it);
    defer s.close();
    var t = s.tempDir(a) catch |e| return storeFail(it, e);
    defer t.remove(a, s);
    for ([_][]const u8{ "manifest.json", "manifest.json.sig" }) |name| try download(it, hook, t, a, root, name);
    // The manifest first: its signature, and whether it is new.
    const pre = (s.peek(a, t.fd) catch |e| return storeFail(it, e));
    const cur = s.current(a, pre.name) catch |e| return storeFail(it, e);
    if (cur) |c| if (pre.counter <= c and !force) {
        var items = [6]Value{ .{ .str = "name" }, .{ .str = pre.name }, .{ .str = "counter" }, .{ .int = @intCast(c) }, .{ .str = "status" }, .{ .str = "current" } };
        return value.wrapList(a, try a.dupe(Value, &items));
    };
    for (pre.files) |f| {
        if (std.mem.indexOfAny(u8, f, "/\\") != null or std.mem.startsWith(u8, f, ".")) return storeFail(it, error.BadManifest);
        try download(it, hook, t, a, root, f);
    }
    const r = s.install(a, t.fd, vmstore.host_arch, force) catch |e| return storeFail(it, e);
    var items = [8]Value{ .{ .str = "name" }, .{ .str = r.name }, .{ .str = "counter" }, .{ .int = @intCast(r.counter) }, .{ .str = "key" }, .{ .str = r.key }, .{ .str = "status" }, .{ .str = "installed" } };
    return value.wrapList(a, try a.dupe(Value, &items));
}

fn download(it: *Interp, hook: anytype, t: vmstore.Temp, a: std.mem.Allocator, root: []const u8, name: []const u8) Error!void {
    const fd = t.create(a, name) catch |e| return storeFail(it, e);
    defer sys.close(fd);
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ root, name });
    hook(it.vm_host.fetch_ctx, url, fd) catch |e| return it.failCode("ZTCL VM FETCH", "the download of {s} failed: {s}", .{ url, @errorName(e) });
}

/// A descriptor of a folder of the script, below the root folder,
/// opened through the jail. The store reads the release through it with
/// no symlink, so no swap of a path after the check of the jail counts.
fn jailDir(it: *Interp, path: []const u8) Error!i32 {
    if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok())
        return it.failCode("ZTCL VM NOFILE", "a path of ztcl::vm needs the file capability", .{});
    const rel = try fsroot.need(it, path);
    return switch (try fsroot.openRel(it, rel, .{ .directory = true }, 0)) {
        .fd => |f| f,
        .err => |e| fsroot.posixError(it, e, "couldn't open the folder: "),
    };
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

/// The glue of `listen`: the pipe gives the number of each new
/// descriptor, and `accept` turns it into a channel for the script.
const listen_glue =
    \\namespace eval ::ztcl::vmpriv {
    \\    proc accept {vm port pipe cmd} {
    \\        set b [read $pipe 4]
    \\        if {[string length $b] != 4} { return }
    \\        binary scan $b i fd
    \\        set ch [::ztcl::vm accept $vm $port $fd]
    \\        uplevel #0 [linsert $cmd end $ch]
    \\    }
    \\}
;

/// The arguments of `ztcl::vm exec`.
const ExecReq = struct {
    argv: []const []const u8,
    env: []const []const u8 = &.{},
    cwd: []const u8 = "",
    stdin: ?[]const u8 = null,
    timeout: u32 = 30000,
    /// `-binary 1`: each character of `-stdin` is one byte (below 256),
    /// and each byte of the output is one character.
    binary: bool = false,
};

fn execArgs(it: *Interp, args: []const Value) Error!ExecReq {
    const use = "ztcl::vm exec vm ?-stdin data? ?-binary bool? ?-env list? ?-cwd dir? ?-timeout ms? ?--? program ?arg ...?";
    var r: ExecReq = .{ .argv = &.{} };
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
            r.stdin = try it.str(v);
        } else if (std.mem.eql(u8, o, "-binary")) {
            r.binary = try it.int(v) != 0;
        } else if (std.mem.eql(u8, o, "-cwd")) {
            r.cwd = try it.str(v);
        } else if (std.mem.eql(u8, o, "-timeout")) {
            const t = try it.int(v);
            if (t < 1) return it.fail("bad timeout \"{d}\"", .{t});
            r.timeout = @intCast(@min(t, std.math.maxInt(i32)));
        } else if (std.mem.eql(u8, o, "-env")) {
            const items = try it.list(v);
            const e = try it.alloc().alloc([]const u8, items.len);
            for (items, e) |x, *y| y.* = try it.str(x);
            r.env = e;
        } else return it.fail("bad option \"{s}\": must be -binary, -cwd, -env, -stdin, or -timeout", .{o});
        i += 2;
    }
    if (i >= args.len) return it.wrongArgs(use);
    if (r.binary) if (r.stdin) |text| {
        r.stdin = try more.toBytes(it, text);
    };
    const argv = try it.alloc().alloc([]const u8, args.len - i);
    for (args[i..], argv) |x, *y| y.* = try it.str(x);
    r.argv = argv;
    return r;
}

/// The arguments of `ztcl::vm mount`.
const MountReq = struct { tag: []const u8, path: []const u8, read_only: bool };

fn mountArgs(it: *Interp, args: []const Value) Error!MountReq {
    const use = "ztcl::vm mount vm tag path ?-readonly?";
    if (args.len != 2 and args.len != 3) return it.wrongArgs(use);
    const ro = args.len == 3;
    if (ro and !std.mem.eql(u8, try it.str(args[2]), "-readonly")) return it.wrongArgs(use);
    return .{ .tag = try it.str(args[0]), .path = try it.str(args[1]), .read_only = ro };
}

fn agentFail(it: *Interp, name: []const u8, a: *vmagent.Conn, e: vmagent.Error) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => it.failCode("ZTCL VM TIMEOUT", "the guest {s} gave no answer in time", .{name}),
        error.Version => it.failCode("ZTCL VM AGENT", "the agent of the guest {s} has another version of the protocol", .{name}),
        error.Agent => it.failCode("ZTCL VM AGENT", "{s} (errno {d})", .{ a.last_error.message[0..a.last_error.len], a.last_error.errno }),
        else => it.failCode("ZTCL VM AGENT", "the connection to the agent of the guest {s} failed: {s}", .{ name, @errorName(e) }),
    };
}

/// Runs `exec` on a connection after its `HELLO`: a dict of `exit`,
/// `stdout`, and `stderr`.
fn agentExec(it: *Interp, name: []const u8, a: *vmagent.Conn, r: ExecReq) Error!Value {
    const res = vmagent.exec(a, it.alloc(), r.argv, r.env, r.cwd, r.stdin, 64 << 20) catch |e| return agentFail(it, name, a, e);
    const out = if (r.binary) try more.fromBytes(it, res.stdout) else res.stdout;
    const err = if (r.binary) try more.fromBytes(it, res.stderr) else res.stderr;
    var items = [6]Value{
        .{ .str = "exit" },   .{ .int = res.code },
        .{ .str = "stdout" }, .{ .str = out },
        .{ .str = "stderr" }, .{ .str = err },
    };
    return value.wrapList(it.alloc(), try it.alloc().dupe(Value, &items));
}

fn agentMount(it: *Interp, name: []const u8, a: *vmagent.Conn, r: MountReq, kind: vmagent.Share) Error!Value {
    vmagent.mount(a, it.alloc(), r.tag, r.path, r.read_only, kind) catch |e| return agentFail(it, name, a, e);
    return .{ .str = "" };
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
        /// The listeners of `listen`, each with the write end of its pipe.
        listens: std.ArrayListUnmanaged(Listen) = .empty,
    };

    const Listen = struct { port: u32, l: *vz.Listener, pipe_w: c_int, chan: []const u8 };

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
        if (std.mem.eql(u8, sub, "listen")) return listenCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "unlisten")) return unlistenCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "accept")) return acceptCmd(it, g, args[3..]);
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
        var image: ?[]const u8 = null;
        var image_disks: usize = 0;
        {
            // -image gives the kernel, the initramfs, and the command line.
            var has_image = false;
            var own_boot = false;
            var k: usize = 0;
            while (k + 1 < args.len) : (k += 2) {
                const o = try it.str(args[k]);
                if (std.mem.eql(u8, o, "-image")) has_image = true;
                if (std.mem.eql(u8, o, "-kernel") or std.mem.eql(u8, o, "-initrd") or std.mem.eql(u8, o, "-cmdline")) own_boot = true;
            }
            if (has_image and own_boot) return it.fail("-image gives the kernel, the initramfs, and the command line: no -kernel, -initrd, or -cmdline with it", .{});
        }
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            const opt = try it.str(args[i]);
            const v = args[i + 1];
            if (std.mem.eql(u8, opt, "-image")) {
                image = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-cpus")) {
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
            } else return it.fail("bad option \"{s}\": must be -cmdline, -cpus, -disk, -entropy, -image, -initrd, -kernel, -memory, -share, or -warm", .{opt});
        }
        if (image) |name| {
            const r = try resolveImage(it, name);
            cfg.kernel = r.kernel;
            cfg.initrd = r.initrd;
            // The virtio devices of the framework probe in parallel: each
            // waits about 1 ms for its reset, and the root waits for its
            // disk (dm-mod.waitfor), so this saves about 2.4 ms of boot.
            cfg.cmdline = try std.fmt.allocPrint(a, "console=hvc0 driver_async_probe=virtio-pci {s}", .{r.cmdline});
            // The disks of the image come first: /dev/vda is its root.
            var all: std.ArrayList(vz.Disk) = .empty;
            for (r.disks) |p| try all.append(a, .{ .path = p, .read_only = true });
            image_disks = r.disks.len;
            try all.appendSlice(a, disks.items);
            disks = all;
        }
        if (cfg.kernel.len == 0) return it.failCode("ZTCL VM KERNEL", "a guest needs -kernel or -image", .{});
        cfg.shares = shares.items;
        cfg.disks = disks.items;
        // A guest of the image from the pool: no share and no disk of its
        // own, so its configuration is the one of the pool.
        if (image != null and it.vm_host.pool_size > 0 and shares.items.len == 0 and disks.items.len == image_disks and !warm) {
            const fp = try fingerprint(a, cfg);
            const got = take(fp);
            refill(fp, cfg, it.vm_host.pool_size);
            if (got) |p| {
                const g = try it.heap.backing.create(Guest);
                g.* = .{
                    .name = try std.fmt.allocPrint(it.heap.backing, "vm{d}", .{s.next}),
                    .config = p.config,
                    .machine = p.machine,
                    .console_vm = p.console_vm,
                    .console_host = p.console_host,
                    .warm = true,
                    .started = true,
                };
                s.next += 1;
                try s.guests.append(it.heap.backing, g);
                return .{ .str = g.name };
            }
        }

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

    // ---- The pool of booted guests (Host.pool_size) ----

    /// A guest of the pool: booted to the agent, then paused.
    const Pooled = struct { config: vz.Id, machine: vz.Machine, console_vm: c_int, console_host: c_int };

    const Pool = struct {
        lock: thread_lock = .{},
        /// The guests that wait, by the fingerprint of their configuration.
        ready: std.StringHashMapUnmanaged(std.ArrayList(Pooled)) = .empty,
        /// The fingerprints with a refill that runs.
        filling: std.StringHashMapUnmanaged(void) = .empty,
    };
    const thread_lock = @import("thread.zig").Lock;
    var the_pool: Pool = .{};
    const pa = std.heap.c_allocator;

    /// The fingerprint of a configuration of the pool.
    fn fingerprint(a: std.mem.Allocator, cfg: vz.Config) ![]u8 {
        var l: std.ArrayList(u8) = .empty;
        try l.print(a, "{s}|{s}|{s}|{d}|{d}", .{ cfg.kernel, cfg.initrd orelse "", cfg.cmdline, cfg.memory_mb, cfg.cpus });
        for (cfg.disks) |d| try l.print(a, "|{s}", .{d.path});
        return l.toOwnedSlice(a);
    }

    /// Boots one guest of `cfg` to the agent and pauses it.
    fn warmOne(cfg_in: vz.Config) ?Pooled {
        const ap = vz.new("NSAutoreleasePool") catch return null;
        defer vz.release(ap);
        var pair: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair) != 0) return null;
        var cfg = cfg_in;
        cfg.console = .{ .in = pair[0], .out = pair[0] };
        var why: []const u8 = "";
        const vc = vz.configure(cfg, &why) catch {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            return null;
        };
        var m = vz.Machine.init(vc) catch {
            vz.release(vc);
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            return null;
        };
        const good = blk: {
            m.start(&why) catch break :blk false;
            const conn = connect(&m, agent_port, 10_000) orelse break :blk false;
            conn.close();
            m.pause(&why) catch break :blk false;
            break :blk true;
        };
        if (!good) {
            m.deinit();
            vz.release(vc);
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            return null;
        }
        return .{ .config = vc, .machine = m, .console_vm = pair[0], .console_host = pair[1] };
    }

    /// The copy of a configuration that a refill thread owns.
    const Owned = struct {
        fp: []u8,
        cfg: vz.Config,
        want: u32,

        fn make(fp: []const u8, cfg: vz.Config, want: u32) !*Owned {
            const o = try pa.create(Owned);
            const disks = try pa.alloc(vz.Disk, cfg.disks.len);
            for (cfg.disks, disks) |d, *x| x.* = .{ .path = try pa.dupe(u8, d.path), .read_only = d.read_only };
            o.* = .{ .fp = try pa.dupe(u8, fp), .want = want, .cfg = .{
                .kernel = try pa.dupe(u8, cfg.kernel),
                .initrd = if (cfg.initrd) |x| try pa.dupe(u8, x) else null,
                .cmdline = try pa.dupe(u8, cfg.cmdline),
                .cpus = cfg.cpus,
                .memory_mb = cfg.memory_mb,
                .disks = disks,
                .entropy = cfg.entropy,
            } };
            return o;
        }

        fn free(o: *Owned) void {
            for (o.cfg.disks) |d| pa.free(d.path);
            pa.free(o.cfg.disks);
            pa.free(o.cfg.kernel);
            if (o.cfg.initrd) |x| pa.free(x);
            pa.free(o.cfg.cmdline);
            pa.free(o.fp);
            pa.destroy(o);
        }
    };

    fn countReady(fp: []const u8) usize {
        return if (the_pool.ready.getPtr(fp)) |l| l.items.len else 0;
    }

    fn endFill(fp: []const u8) void {
        the_pool.lock.lock();
        if (the_pool.filling.fetchRemove(fp)) |kv| pa.free(kv.key);
        the_pool.lock.unlock();
    }

    fn refillMain(o: *Owned) void {
        defer o.free();
        while (true) {
            the_pool.lock.lock();
            const have = countReady(o.fp);
            the_pool.lock.unlock();
            if (have >= o.want) return endFill(o.fp);
            const g = warmOne(o.cfg) orelse return endFill(o.fp);
            the_pool.lock.lock();
            const gop = the_pool.ready.getOrPut(pa, o.fp) catch {
                the_pool.lock.unlock();
                return endFill(o.fp);
            };
            if (!gop.found_existing) {
                gop.key_ptr.* = pa.dupe(u8, o.fp) catch {
                    the_pool.ready.removeByPtr(gop.key_ptr);
                    the_pool.lock.unlock();
                    return endFill(o.fp);
                };
                gop.value_ptr.* = .empty;
            }
            gop.value_ptr.append(pa, g) catch {};
            the_pool.lock.unlock();
        }
    }

    /// Starts a refill of the pool of `cfg` to `size` guests, when none
    /// runs.
    fn refill(fp: []const u8, cfg: vz.Config, size: u32) void {
        the_pool.lock.lock();
        if (the_pool.filling.contains(fp) or countReady(fp) >= size) {
            the_pool.lock.unlock();
            return;
        }
        const key = pa.dupe(u8, fp) catch {
            the_pool.lock.unlock();
            return;
        };
        the_pool.filling.put(pa, key, {}) catch {
            pa.free(key);
            the_pool.lock.unlock();
            return;
        };
        the_pool.lock.unlock();
        const o = Owned.make(fp, cfg, size) catch return endFill(fp);
        const t = std.Thread.spawn(.{}, refillMain, .{o}) catch {
            o.free();
            return endFill(fp);
        };
        t.detach();
    }

    /// A guest of the pool for `fp`, or null.
    fn take(fp: []const u8) ?Pooled {
        the_pool.lock.lock();
        defer the_pool.lock.unlock();
        const l = the_pool.ready.getPtr(fp) orelse return null;
        return l.pop();
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

    // ---- Connections of the guest to the host (`listen`) ----

    fn findListen(g: *Guest, port: u32) ?usize {
        for (g.listens.items, 0..) |x, i| if (x.port == port) return i;
        return null;
    }

    fn dropListen(it: *Interp, x: Listen) void {
        vz.unlisten(it.heap.backing, x.l);
        _ = c.close(x.pipe_w);
        const script = std.fmt.allocPrint(it.alloc(), "catch {{close {{{s}}}}}", .{x.chan}) catch return;
        _ = it.eval(script) catch {};
        it.heap.backing.free(x.chan);
    }

    /// `listen VM PORT -command SCRIPT`: a program of the guest connects
    /// to the host on `PORT`, and the event loop calls `SCRIPT` with a
    /// channel of the connection appended.
    fn listenCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const use = "ztcl::vm listen vm port -command script";
        if (args.len != 3 or !std.mem.eql(u8, try it.str(args[1]), "-command")) return it.wrongArgs(use);
        const port = try it.int(args[0]);
        if (port < 1 or port > std.math.maxInt(u32)) return it.fail("bad port \"{d}\"", .{port});
        if (it.findCommand("fileevent") == null) return it.failCode("ZTCL VM NOEVENT", "ztcl::vm listen needs the event capability", .{});
        if (findListen(g, @intCast(port)) != null) return it.failCode("ZTCL VM LISTEN", "the guest {s} has a listener on port {d} already", .{ g.name, port });
        var pipe: [2]c_int = undefined;
        if (c.pipe(&pipe) != 0) return it.failCode("ZTCL VM FRAMEWORK", "no pipe for the listener", .{});
        _ = c.fcntl(pipe[0], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(pipe[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        const ch = binaryChannel(it, "vmlisten", pipe[0]) catch |e| {
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            return e;
        };
        const l = vz.listen(it.heap.backing, &g.machine, @intCast(port), pipe[1]) catch {
            _ = c.close(pipe[1]);
            return it.failCode("ZTCL VM FRAMEWORK", "the guest {s} cannot listen on port {d}", .{ g.name, port });
        };
        const name = try it.heap.backing.dupe(u8, try it.str(ch));
        try g.listens.append(it.heap.backing, .{ .port = @intCast(port), .l = l, .pipe_w = pipe[1], .chan = name });
        if (it.findCommand("::ztcl::vmpriv::accept") == null) _ = try it.eval(listen_glue);
        var words = [_]Value{ .{ .str = "::ztcl::vmpriv::accept" }, .{ .str = g.name }, .{ .int = port }, ch, args[2] };
        const handler = try value.wrapList(it.alloc(), try it.alloc().dupe(Value, &words));
        var fe = [_]Value{ .{ .str = "fileevent" }, ch, .{ .str = "readable" }, handler };
        _ = try it.evalWords(&fe);
        return .{ .str = "" };
    }

    fn unlistenCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        if (args.len != 1) return it.wrongArgs("ztcl::vm unlisten vm port");
        const port = try it.int(args[0]);
        const i = (if (port >= 0 and port <= std.math.maxInt(u32)) findListen(g, @intCast(port)) else null) orelse
            return it.failCode("ZTCL VM LISTEN", "the guest {s} has no listener on port {d}", .{ g.name, port });
        dropListen(it, g.listens.swapRemove(i));
        return .{ .str = "" };
    }

    /// `accept VM PORT FD`: the channel of a connection that the listener
    /// kept. The glue of `listen` calls it; a descriptor that the
    /// listener did not keep is an error.
    fn acceptCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        if (args.len != 2) return it.wrongArgs("ztcl::vm accept vm port fd");
        const port = try it.int(args[0]);
        const fd = try it.int(args[1]);
        const i = (if (port >= 0 and port <= std.math.maxInt(u32)) findListen(g, @intCast(port)) else null) orelse
            return it.failCode("ZTCL VM LISTEN", "the guest {s} has no listener on port {d}", .{ g.name, port });
        if (fd < 0 or fd > std.math.maxInt(c_int) or !g.listens.items[i].l.take(@intCast(fd)))
            return it.failCode("ZTCL VM LISTEN", "no connection {d} waits on port {d}", .{ fd, port });
        return binaryChannel(it, "vsock", @intCast(fd));
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
            return agentFail(it, g.name, &a, e);
        };
        return a;
    }

    fn execCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const r = try execArgs(it, args);
        var a = try agent(it, g, r.timeout);
        defer _ = c.close(a.fd);
        return agentExec(it, g.name, &a, r);
    }

    fn mountCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const r = try mountArgs(it, args);
        var a = try agent(it, g, 5000);
        defer _ = c.close(a.fd);
        return agentMount(it, g.name, &a, r, .virtiofs);
    }

    fn console(it: *Interp, g: *Guest) Error!Value {
        if (g.console_host < 0) return it.failCode("ZTCL VM CONSOLE", "the console of the guest {s} is a channel already", .{g.name});
        const v = try binaryChannel(it, "vmcon", g.console_host);
        g.console_host = -1;
        return v;
    }

    fn destroy(it: *Interp, g: *Guest) void {
        for (g.listens.items) |x| dropListen(it, x);
        g.listens.deinit(it.heap.backing);
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
        shares: []kvm.Share,
        /// The end of the console socket that the monitor has, and the
        /// end of the script, until `console` gives it as a channel.
        console_vm: i32,
        console_host: i32,
        warm: bool,
        /// A guest of the pool: its bytes, its disks, and its machine
        /// use `pa`.
        pooled: bool = false,
        /// The listeners of `listen`.
        listens: std.ArrayListUnmanaged(Listen) = .empty,
    };

    const Listen = struct { port: u32, l: *Listener, chan: []const u8 };

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
        if (std.mem.eql(u8, sub, "listen")) return listenCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "unlisten")) return unlistenCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "accept")) return acceptCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "exec")) {
            const r = try execArgs(it, args[3..]);
            var a = try agent(it, g, r.timeout);
            defer _ = linux.close(a.fd);
            return agentExec(it, g.name, &a, r);
        }
        if (std.mem.eql(u8, sub, "mount")) {
            const r = try mountArgs(it, args[3..]);
            var a = try agent(it, g, 5000);
            defer _ = linux.close(a.fd);
            return agentMount(it, g.name, &a, r, .nine_p);
        }
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
        return it.fail("bad option \"{s}\": must be console, create, delete, exec, mount, start, status, stop, or vsock", .{sub});
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

    /// Opens a folder of the script below the root folder, with
    /// `O_PATH`, for the root folder of a share.
    fn openDir(it: *Interp, path: []const u8) Error!i32 {
        if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok())
            return it.failCode("ZTCL VM NOFILE", "a path of ztcl::vm needs the file capability", .{});
        const rel = try fsroot.need(it, path);
        const r = try fsroot.openRel(it, rel, .{ .directory = true, .path_only = true }, 0);
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
        var shares: std.ArrayList(struct { path: []const u8, rw: bool }) = .empty;
        var warm = false;
        var image: ?[]const u8 = null;
        var own_boot = false;
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            const opt = try it.str(args[i]);
            const v = args[i + 1];
            if (std.mem.eql(u8, opt, "-kernel") or std.mem.eql(u8, opt, "-initrd") or std.mem.eql(u8, opt, "-cmdline")) own_boot = true;
            if (std.mem.eql(u8, opt, "-image")) {
                image = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-cpus")) {
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
                if (disks.items.len + shares.items.len >= kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{kvm.max_disks});
                try disks.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 2 and try isRw(it, l[1]) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                const l = try it.readList(v);
                if (l.len < 2 or l.len > 3) return it.fail("a share is {{host guest ?rw?}}", .{});
                if (disks.items.len + shares.items.len >= kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{kvm.max_disks});
                try shares.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 3 and try isRw(it, l[2]) });
            } else return it.fail("bad option \"{s}\": must be -cmdline, -cpus, -disk, -entropy, -image, -initrd, -kernel, -memory, -share, or -warm", .{opt});
        }
        if (image != null and own_boot) return it.fail("-image gives the kernel, the initramfs, and the command line: no -kernel, -initrd, or -cmdline with it", .{});
        if (image == null and kernel.len == 0) return it.failCode("ZTCL VM KERNEL", "a guest needs -kernel or -image", .{});

        // A guest of the image from the pool: no share and no disk of its
        // own, so its configuration is the one of the pool.
        var fp: ?[]const u8 = null;
        if (image != null and host.pool_size > 0 and shares.items.len == 0 and disks.items.len == 0 and !warm) {
            const st = try store(it);
            defer st.close();
            const counter = (st.current(a, image.?) catch |e| return storeFail(it, e)) orelse
                return it.failCode("ZTCL VM IMAGE NAME", "no image named \"{s}\" in the store: install it with ztcl::vm image install", .{image.?});
            fp = try std.fmt.allocPrint(a, "{s}|{d}|{d}|{d}|{d}", .{ image.?, counter, cfg.cpus, cfg.memory_mb, @intFromBool(cfg.entropy) });
            if (take(fp.?, host.pool_size)) |p| {
                const g = b.create(Guest) catch |e| {
                    dropPooled(p);
                    return e;
                };
                g.* = .{ .name = "", .machine = p.machine, .kernel = p.kernel, .initrd = p.initrd, .cmdline = p.cmdline, .disks = p.disks, .shares = &.{}, .console_vm = p.console_vm, .console_host = p.console_host, .warm = true, .pooled = true };
                g.name = std.fmt.allocPrint(b, "vm{d}", .{s.next}) catch |e| {
                    destroy(it, g);
                    return e;
                };
                s.next += 1;
                s.guests.append(b, g) catch |e| {
                    destroy(it, g);
                    return e;
                };
                return .{ .str = g.name };
            }
        }

        const g = try b.create(Guest);
        g.* = .{ .name = "", .machine = undefined, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .shares = &.{}, .console_vm = -1, .console_host = -1, .warm = warm };
        var made = false;
        errdefer if (!made) freeGuest(it, g);
        // The disks of an image come first, read-only: /dev/vda is its
        // root, which the command line of the manifest gives to dm-verity.
        var image_disks: []const i32 = &.{};
        if (image) |name| {
            const l = try loadImage(it, b, name);
            g.kernel = l.kernel;
            g.initrd = l.initrd;
            image_disks = l.disks;
            g.disks = b.alloc(kvm.Disk, l.disks.len + disks.items.len) catch |e| {
                for (l.disks) |fd| sys.close(fd);
                return e;
            };
            for (g.disks) |*d| d.fd = -1;
            for (l.disks, g.disks[0..l.disks.len]) |fd, *out| out.* = .{ .fd = fd, .read_only = true };
            if (g.disks.len + shares.items.len > kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{kvm.max_disks});
            g.cmdline = try std.fmt.allocPrint(b, "console=hvc0 {s}", .{l.cmdline});
        } else {
            g.kernel = try readPath(it, kernel);
            if (initrd.len != 0) g.initrd = try readPath(it, initrd);
            g.cmdline = try b.dupe(u8, cfg.cmdline);
            g.disks = try b.alloc(kvm.Disk, disks.items.len);
            for (g.disks) |*d| d.fd = -1;
        }
        for (disks.items, g.disks[image_disks.len..]) |d, *out| out.* = .{ .fd = try openPath(it, d.path, d.rw), .read_only = !d.rw };
        g.shares = try b.alloc(kvm.Share, shares.items.len);
        for (g.shares) |*d| d.fd = -1;
        for (shares.items, g.shares) |d, *out| out.* = .{ .fd = try openDir(it, d.path), .read_only = !d.rw };
        var pair: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS)
            return it.failCode("ZTCL VM KVM", "no socket for the console", .{});
        g.console_vm = pair[0];
        g.console_host = pair[1];
        cfg.kernel = g.kernel;
        cfg.initrd = g.initrd;
        cfg.cmdline = g.cmdline;
        cfg.disks = g.disks;
        cfg.shares = g.shares;
        cfg.console = g.console_vm;
        g.machine = kvm.init(b, cfg) catch |e| return failure(it, e);
        made = true;
        // The first guest of an image for the pool: its bytes and disks
        // become the template of the pool, and a thread boots its guests.
        if (fp) |key| seed(key, cfg, host.pool_size);
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

    /// A connection to the agent on port 1024, after its `HELLO`.
    fn agent(it: *Interp, g: *Guest, timeout: u32) Error!vmagent.Conn {
        if (g.machine.getState() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const fd = connect(g.machine, vmagent.port, timeout) orelse
            return it.failCode("ZTCL VM AGENT", "the agent of the guest {s} did not answer on port {d}", .{ g.name, vmagent.port });
        var a: vmagent.Conn = .{ .fd = fd, .timeout_ms = @intCast(@min(timeout, std.math.maxInt(i32))) };
        _ = a.hello(it.alloc()) catch |e| {
            _ = linux.close(fd);
            return agentFail(it, g.name, &a, e);
        };
        return a;
    }

    fn freeGuest(it: *Interp, g: *Guest) void {
        const b = if (g.pooled) pa else it.heap.backing;
        for (g.disks) |d| if (d.fd >= 0) sys.close(d.fd);
        b.free(g.disks);
        for (g.shares) |d| if (d.fd >= 0) sys.close(d.fd);
        b.free(g.shares);
        b.free(g.kernel);
        b.free(g.initrd);
        b.free(g.cmdline);
        if (g.console_vm >= 0) sys.close(g.console_vm);
        if (g.console_host >= 0) sys.close(g.console_host);
        it.heap.backing.free(g.name);
        it.heap.backing.destroy(g);
    }

    // ---- The pool of booted guests (Host.pool_size) ----

    /// A guest of the pool: booted to the agent, then paused.
    const Pooled = struct { machine: *kvm, kernel: []u8, initrd: []u8, cmdline: []u8, disks: []kvm.Disk, console_vm: i32, console_host: i32 };

    /// The configuration of the pool of one fingerprint: copies of the
    /// bytes of the image and of the descriptors of its disks. Each guest
    /// of the pool gets copies of these.
    const Template = struct {
        kernel: []u8,
        initrd: []u8,
        cmdline: []u8,
        disks: []i32,
        cpus: u32,
        memory_mb: u32,
        entropy: bool,
        size: u32,
        ready: std.ArrayList(Pooled) = .empty,
        filling: bool = false,
    };
    const thread_lock = @import("thread.zig").Lock;
    var pool_lock: thread_lock = .{};
    /// The templates by fingerprint: the name and the counter of the
    /// image, the CPU count, the memory, and the entropy device.
    var pools: std.StringHashMapUnmanaged(*Template) = .empty;
    const pa = std.heap.smp_allocator;

    /// Makes the template of `fp` from the configuration of a guest of
    /// the image, when it has none, and starts a refill.
    fn seed(fp: []const u8, cfg: kvm.Config, size: u32) void {
        pool_lock.lock();
        const have = pools.get(fp);
        pool_lock.unlock();
        if (have) |t| return refill(t, size);
        const t = makeTemplate(cfg, size) catch return;
        pool_lock.lock();
        const key = pa.dupe(u8, fp) catch {
            pool_lock.unlock();
            return freeTemplate(t);
        };
        const gop = pools.getOrPut(pa, key) catch {
            pool_lock.unlock();
            pa.free(key);
            return freeTemplate(t);
        };
        if (gop.found_existing) {
            pool_lock.unlock();
            pa.free(key);
            freeTemplate(t);
            return;
        }
        gop.value_ptr.* = t;
        pool_lock.unlock();
        refill(t, size);
    }

    fn makeTemplate(cfg: kvm.Config, size: u32) !*Template {
        const t = try pa.create(Template);
        t.* = .{ .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .cpus = cfg.cpus, .memory_mb = cfg.memory_mb, .entropy = cfg.entropy, .size = size };
        errdefer freeTemplate(t);
        t.kernel = try pa.dupe(u8, cfg.kernel);
        t.initrd = try pa.dupe(u8, cfg.initrd);
        t.cmdline = try pa.dupe(u8, cfg.cmdline);
        t.disks = try pa.alloc(i32, cfg.disks.len);
        @memset(t.disks, -1);
        for (cfg.disks, t.disks) |d, *fd| fd.* = try dupFd(d.fd);
        return t;
    }

    fn freeTemplate(t: *Template) void {
        for (t.disks) |fd| if (fd >= 0) sys.close(fd);
        pa.free(t.disks);
        pa.free(t.kernel);
        pa.free(t.initrd);
        pa.free(t.cmdline);
        pa.destroy(t);
    }

    fn dupFd(fd: i32) !i32 {
        const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.NoDescriptor;
        return @intCast(rc);
    }

    /// Boots one guest of the template to the agent and pauses it.
    fn warmOne(t: *Template) ?Pooled {
        var p: Pooled = .{ .machine = undefined, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .console_vm = -1, .console_host = -1 };
        var made = false;
        const good = blk: {
            p.kernel = pa.dupe(u8, t.kernel) catch break :blk false;
            p.initrd = pa.dupe(u8, t.initrd) catch break :blk false;
            p.cmdline = pa.dupe(u8, t.cmdline) catch break :blk false;
            p.disks = pa.alloc(kvm.Disk, t.disks.len) catch break :blk false;
            for (p.disks) |*d| d.* = .{ .fd = -1, .read_only = true };
            for (t.disks, p.disks) |fd, *d| d.fd = dupFd(fd) catch break :blk false;
            var pair: [2]i32 = undefined;
            if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS) break :blk false;
            p.console_vm = pair[0];
            p.console_host = pair[1];
            p.machine = kvm.init(pa, .{ .cpus = t.cpus, .memory_mb = t.memory_mb, .kernel = p.kernel, .initrd = p.initrd, .cmdline = p.cmdline, .disks = p.disks, .entropy = t.entropy, .console = p.console_vm }) catch break :blk false;
            made = true;
            p.machine.start() catch break :blk false;
            const fd = connect(p.machine, agent_port, 10_000) orelse break :blk false;
            // One program of the image runs before the pause, so its
            // pages are in the page cache of the guest: the first exec of
            // a guest of the pool does not read them from the root disk
            // through dm-verity. An image without /bin/busybox only skips
            // this.
            var arena = std.heap.ArenaAllocator.init(pa);
            defer arena.deinit();
            var conn: vmagent.Conn = .{ .fd = fd, .timeout_ms = 10_000 };
            if (conn.hello(arena.allocator())) |_| {
                _ = vmagent.exec(&conn, arena.allocator(), &.{ "/bin/busybox", "true" }, &.{}, "/", null, 4096) catch {};
            } else |_| {}
            _ = linux.close(fd);
            p.machine.pause();
            break :blk true;
        };
        if (good) return p;
        if (made) p.machine.deinit();
        dropBytes(p);
        return null;
    }

    fn dropBytes(p: Pooled) void {
        for (p.disks) |d| if (d.fd >= 0) sys.close(d.fd);
        pa.free(p.disks);
        pa.free(p.kernel);
        pa.free(p.initrd);
        pa.free(p.cmdline);
        if (p.console_vm >= 0) sys.close(p.console_vm);
        if (p.console_host >= 0) sys.close(p.console_host);
    }

    fn dropPooled(p: Pooled) void {
        p.machine.deinit();
        dropBytes(p);
    }

    fn refillMain(t: *Template) void {
        while (true) {
            pool_lock.lock();
            if (t.ready.items.len >= t.size) {
                t.filling = false;
                pool_lock.unlock();
                return;
            }
            pool_lock.unlock();
            const p = warmOne(t) orelse break;
            pool_lock.lock();
            t.ready.append(pa, p) catch {
                pool_lock.unlock();
                dropPooled(p);
                break;
            };
            pool_lock.unlock();
        }
        pool_lock.lock();
        t.filling = false;
        pool_lock.unlock();
    }

    /// Starts a refill of the pool to `size` guests, when none runs.
    fn refill(t: *Template, size: u32) void {
        pool_lock.lock();
        t.size = size;
        if (t.filling or t.ready.items.len >= size) {
            pool_lock.unlock();
            return;
        }
        t.filling = true;
        pool_lock.unlock();
        const th = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, refillMain, .{t}) catch {
            pool_lock.lock();
            t.filling = false;
            pool_lock.unlock();
            return;
        };
        th.detach();
    }

    /// A guest of the pool for `fp`, or null. Starts a refill either way.
    fn take(fp: []const u8, size: u32) ?Pooled {
        pool_lock.lock();
        const t = pools.get(fp) orelse {
            pool_lock.unlock();
            return null;
        };
        const p = t.ready.pop();
        pool_lock.unlock();
        refill(t, size);
        return p;
    }

    fn destroy(it: *Interp, g: *Guest) void {
        for (g.listens.items) |x| dropListen(it, x);
        g.listens.deinit(it.heap.backing);
        g.machine.deinit();
        freeGuest(it, g);
    }

    // ---- Connections of the guest to the host (`listen`) ----
    //
    // The vsock ports of the host are one space for the whole host, so a
    // port has one listening socket in this process (`PortSock`), bound to
    // VMADDR_CID_ANY. Its thread accepts each connection and gives it to
    // the `Listener` of the guest with the CID of the peer; a connection
    // of any other CID closes. The listener keeps the descriptor in its
    // pending set and writes its number to its pipe, and `accept` gives
    // only a descriptor of that set.

    const vmaddr_cid_any: u32 = 0xffffffff;
    const SockaddrVm = extern struct { family: u16 = AF_VSOCK, reserved1: u16 = 0, port: u32, cid: u32, flags: u8 = 0, zero: [3]u8 = @splat(0) };
    const Lock = @import("thread.zig").Lock;
    const lpa = std.heap.smp_allocator;

    const Listener = struct {
        /// The machine of the guest: its CID changes at each start.
        machine: *kvm,
        pipe_w: i32,
        lock: Lock = .{},
        pending: std.ArrayListUnmanaged(i32) = .empty,

        /// True when `fd` waits in the pending set; it then leaves it.
        fn take(l: *Listener, fd: i32) bool {
            l.lock.lock();
            defer l.lock.unlock();
            const i = std.mem.indexOfScalar(i32, l.pending.items, fd) orelse return false;
            _ = l.pending.swapRemove(i);
            return true;
        }
    };

    const PortSock = struct {
        port: u32,
        fd: i32,
        stop: i32,
        thread: std.Thread = undefined,
        listeners: std.ArrayListUnmanaged(*Listener) = .empty,
    };

    var ports_lock: Lock = .{};
    var ports: std.ArrayListUnmanaged(*PortSock) = .empty;

    fn acceptMain(p: *PortSock) void {
        while (true) {
            var fds = [_]linux.pollfd{
                .{ .fd = p.stop, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = p.fd, .events = linux.POLL.IN, .revents = 0 },
            };
            if (linux.errno(linux.poll(&fds, 2, -1)) != .SUCCESS) continue;
            if (fds[0].revents != 0) return;
            var addr: SockaddrVm = .{ .port = 0, .cid = 0 };
            var len: linux.socklen_t = @sizeOf(SockaddrVm);
            const rc = linux.accept4(p.fd, @ptrCast(&addr), &len, linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) continue;
            const fd: i32 = @intCast(rc);
            ports_lock.lock();
            var to: ?*Listener = null;
            for (p.listeners.items) |l| if (@atomicLoad(u64, &l.machine.cid, .acquire) == addr.cid) {
                to = l;
            };
            const kept = if (to) |l| blk: {
                l.lock.lock();
                defer l.lock.unlock();
                l.pending.append(lpa, fd) catch break :blk false;
                const n: i32 = fd;
                _ = linux.write(l.pipe_w, std.mem.asBytes(&n), 4);
                break :blk true;
            } else false;
            ports_lock.unlock();
            if (!kept) _ = linux.close(fd);
        }
    }

    /// Adds a listener of the guest of `machine` to the socket of `port`, and makes that
    /// socket when it is the first listener of the port.
    fn addListener(port: u32, machine: *kvm, pipe_w: i32) error{ InUse, Fail }!*Listener {
        ports_lock.lock();
        defer ports_lock.unlock();
        const p = for (ports.items) |x| {
            if (x.port == port) break x;
        } else blk: {
            const rc = linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
            if (linux.errno(rc) != .SUCCESS) return error.Fail;
            const fd: i32 = @intCast(rc);
            var addr: SockaddrVm = .{ .port = port, .cid = vmaddr_cid_any };
            const b = linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm));
            if (linux.errno(b) != .SUCCESS or linux.errno(linux.listen(fd, 64)) != .SUCCESS) {
                _ = linux.close(fd);
                return if (linux.errno(b) == .ADDRINUSE) error.InUse else error.Fail;
            }
            const ev = linux.eventfd(0, linux.EFD.CLOEXEC);
            if (linux.errno(ev) != .SUCCESS) {
                _ = linux.close(fd);
                return error.Fail;
            }
            const x = lpa.create(PortSock) catch {
                _ = linux.close(fd);
                _ = linux.close(@intCast(ev));
                return error.Fail;
            };
            x.* = .{ .port = port, .fd = fd, .stop = @intCast(ev) };
            x.thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, acceptMain, .{x}) catch {
                _ = linux.close(fd);
                _ = linux.close(x.stop);
                lpa.destroy(x);
                return error.Fail;
            };
            ports.append(lpa, x) catch {};
            break :blk x;
        };
        for (p.listeners.items) |l| if (l.machine == machine) return error.InUse;
        const l = lpa.create(Listener) catch return error.Fail;
        l.* = .{ .machine = machine, .pipe_w = pipe_w };
        p.listeners.append(lpa, l) catch {
            lpa.destroy(l);
            return error.Fail;
        };
        return l;
    }

    /// Takes the listener off its port, closes the descriptors that no
    /// `accept` took, and closes the socket of the port after its last
    /// listener.
    fn removeListener(port: u32, l: *Listener) void {
        ports_lock.lock();
        var last: ?*PortSock = null;
        for (ports.items, 0..) |p, i| if (p.port == port) {
            if (std.mem.indexOfScalar(*Listener, p.listeners.items, l)) |j| _ = p.listeners.swapRemove(j);
            if (p.listeners.items.len == 0) {
                last = p;
                _ = ports.swapRemove(i);
            }
            break;
        };
        ports_lock.unlock();
        if (last) |p| {
            const one: u64 = 1;
            _ = linux.write(p.stop, std.mem.asBytes(&one), 8);
            p.thread.join();
            _ = linux.close(p.fd);
            _ = linux.close(p.stop);
            p.listeners.deinit(lpa);
            lpa.destroy(p);
        }
        for (l.pending.items) |fd| _ = linux.close(fd);
        l.pending.deinit(lpa);
        _ = linux.close(l.pipe_w);
        lpa.destroy(l);
    }

    fn findListen(g: *Guest, port: u32) ?usize {
        for (g.listens.items, 0..) |x, i| if (x.port == port) return i;
        return null;
    }

    fn dropListen(it: *Interp, x: Listen) void {
        removeListener(x.port, x.l);
        const script = std.fmt.allocPrint(it.alloc(), "catch {{close {{{s}}}}}", .{x.chan}) catch return;
        _ = it.eval(script) catch {};
        it.heap.backing.free(x.chan);
    }

    /// `listen VM PORT -command SCRIPT`, as on macOS.
    fn listenCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const use = "ztcl::vm listen vm port -command script";
        if (args.len != 3 or !std.mem.eql(u8, try it.str(args[1]), "-command")) return it.wrongArgs(use);
        const port = try it.int(args[0]);
        if (port < 1 or port > std.math.maxInt(u32) - 1) return it.fail("bad port \"{d}\"", .{port});
        if (it.findCommand("fileevent") == null) return it.failCode("ZTCL VM NOEVENT", "ztcl::vm listen needs the event capability", .{});
        if (findListen(g, @intCast(port)) != null) return it.failCode("ZTCL VM LISTEN", "the guest {s} has a listener on port {d} already", .{ g.name, port });
        var pipe: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return it.failCode("ZTCL VM KVM", "no pipe for the listener", .{});
        const ch = binaryChannel(it, "vmlisten", pipe[0]) catch |e| {
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
            return e;
        };
        const l = addListener(@intCast(port), g.machine, pipe[1]) catch |e| {
            _ = linux.close(pipe[1]);
            const script = std.fmt.allocPrint(it.alloc(), "catch {{close {{{s}}}}}", .{try it.str(ch)}) catch "";
            _ = it.eval(script) catch {};
            return switch (e) {
                error.InUse => it.failCode("ZTCL VM LISTEN", "vsock port {d} of the host is in use", .{port}),
                error.Fail => it.failCode("ZTCL VM KVM", "the guest {s} cannot listen on port {d}", .{ g.name, port }),
            };
        };
        const name = try it.heap.backing.dupe(u8, try it.str(ch));
        try g.listens.append(it.heap.backing, .{ .port = @intCast(port), .l = l, .chan = name });
        if (it.findCommand("::ztcl::vmpriv::accept") == null) _ = try it.eval(listen_glue);
        var words = [_]Value{ .{ .str = "::ztcl::vmpriv::accept" }, .{ .str = g.name }, .{ .int = port }, ch, args[2] };
        const handler = try value.wrapList(it.alloc(), try it.alloc().dupe(Value, &words));
        var fe = [_]Value{ .{ .str = "fileevent" }, ch, .{ .str = "readable" }, handler };
        _ = try it.evalWords(&fe);
        return .{ .str = "" };
    }

    fn unlistenCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        if (args.len != 1) return it.wrongArgs("ztcl::vm unlisten vm port");
        const port = try it.int(args[0]);
        const i = (if (port >= 0 and port <= std.math.maxInt(u32)) findListen(g, @intCast(port)) else null) orelse
            return it.failCode("ZTCL VM LISTEN", "the guest {s} has no listener on port {d}", .{ g.name, port });
        dropListen(it, g.listens.swapRemove(i));
        return .{ .str = "" };
    }

    fn acceptCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        if (args.len != 2) return it.wrongArgs("ztcl::vm accept vm port fd");
        const port = try it.int(args[0]);
        const fd = try it.int(args[1]);
        const i = (if (port >= 0 and port <= std.math.maxInt(u32)) findListen(g, @intCast(port)) else null) orelse
            return it.failCode("ZTCL VM LISTEN", "the guest {s} has no listener on port {d}", .{ g.name, port });
        if (fd < 0 or fd > std.math.maxInt(i32) or !g.listens.items[i].l.take(@intCast(fd)))
            return it.failCode("ZTCL VM LISTEN", "no connection {d} waits on port {d}", .{ fd, port });
        return binaryChannel(it, "vsock", @intCast(fd));
    }

    pub fn closeAll(it: *Interp) void {
        const s: *State = @ptrCast(@alignCast(it.vm_state orelse return));
        for (s.guests.items) |g| destroy(it, g);
        s.guests.deinit(it.heap.backing);
        it.heap.backing.destroy(s);
        it.vm_state = null;
    }
} else struct {};

/// x86-64 Windows: the monitor of `whp.zig` on the Windows Hypervisor
/// Platform. The monitor has no descriptor of a vsock stream, so a pump
/// thread of each guest moves the bytes between the monitor and one end
/// of a pair of loopback sockets, and the script gets the other end as
/// its channel. The console is a pair too. The callbacks of the monitor
/// run on its vCPU thread with the lock of a device held, so they only
/// queue the bytes for the pump.
const win = if (on_whp) struct {
    const vsock = @import("vm/virtio/vsock.zig");
    /// The allocator of the guests: thread safe, and apart from an
    /// interpreter, since a guest of the pool boots on a thread of its own.
    const ga = std.heap.smp_allocator;

    const StreamState = enum { free, connecting, open, refused, closed };

    const Stream = struct {
        state: StreamState = .free,
        /// The end of the pair that the pump has, or -1.
        fd: i32 = -1,
        /// The bytes of the guest that wait for the socket.
        out: std.ArrayList(u8) = .empty,
        /// The bytes of the script that wait for the credit of the guest.
        in: std.ArrayList(u8) = .empty,
    };

    const Guest = struct {
        name: []const u8,
        machine: *whp,
        kernel: []u8,
        initrd: []u8,
        cmdline: []u8,
        disks: []whp.Disk,
        disk_fds: []i32,
        /// The 9p shares, with the descriptors of their root folders.
        shares: []whp.Share = &.{},
        /// The end of the console pair that the pump has, and the end of
        /// the script, until `console` gives it as a channel.
        console_vm: i32,
        console_host: i32,
        console_out: std.ArrayList(u8) = .empty,
        warm: bool,
        lock: Lock = .{},
        streams: [vsock.max_conns]Stream = @splat(.{}),
        pump: ?std.Thread = null,
        stop_pump: std.atomic.Value(bool) = .init(false),
    };

    const Lock = @import("vm/virtio/mmio.zig").Lock;

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

    fn failure(it: *Interp, e: whp.Fail) Error {
        return switch (e) {
            error.NoHypervisor => it.failCode("ZTCL VM UNAVAILABLE", "this Windows has no hypervisor for the Windows Hypervisor Platform: turn on Virtualization-based Security or the feature Windows Hypervisor Platform", .{}),
            error.Kernel => it.failCode("ZTCL VM KERNEL", "{s}", .{whp.why}),
            error.Memory => it.failCode("ZTCL VM MEMORY", "{s}", .{whp.why}),
            error.OutOfMemory => error.OutOfMemory,
            error.Setup => it.failCode("ZTCL VM WHP", "{s} failed", .{whp.why}),
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
        if (std.mem.eql(u8, sub, "vsock")) return vsockCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "exec")) return execCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "mount")) return mountCmd(it, g, args[3..]);
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
        return it.fail("bad option \"{s}\": must be console, create, delete, exec, mount, start, status, stop, or vsock", .{sub});
    }

    /// Opens a path of the script below the root folder. Gives its handle
    /// as a descriptor of `sys`.
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

    /// The bytes of a file of the script, for the kernel and the initramfs.
    fn readPath(it: *Interp, path: []const u8) Error![]u8 {
        const fd = try openPath(it, path, false);
        defer sys.close(fd);
        const end = switch (sys.seek(fd, 0, 2)) {
            .at => |p| p,
            else => return it.failCode("ZTCL VM PATH", "\"{s}\" is not a file", .{path}),
        };
        _ = sys.seek(fd, 0, 0);
        const buf = try ga.alloc(u8, @intCast(end));
        errdefer ga.free(buf);
        var off: usize = 0;
        while (off < buf.len) {
            switch (sys.readFile(fd, buf[off..])) {
                .n => |n| {
                    if (n == 0) break;
                    off += n;
                },
                else => return it.failCode("ZTCL VM PATH", "couldn't read \"{s}\"", .{path}),
            }
        }
        return buf[0..off];
    }

    /// Two connected loopback sockets. The accepted socket must be the one
    /// that this call connected, so no other program gets in.
    fn pair() ?[2]i32 {
        var lo: sys.Addr = .{ .port = 0 };
        lo.bytes[0] = 127;
        lo.bytes[3] = 1;
        const l = switch (sys.listenAt(lo, false)) {
            .fd => |fd| fd,
            .err => return null,
        };
        defer sys.close(l);
        const at = sys.sockName(l) orelse return null;
        const a = switch (sys.connectTo(at, null, true)) {
            .fd => |fd| fd,
            .err => return null,
        };
        const mine = sys.sockName(a) orelse {
            sys.close(a);
            return null;
        };
        var tries: usize = 0;
        while (tries < 1000) : (tries += 1) {
            if (sys.accept(l)) |acc| {
                if (acc.peer.port == mine.port and std.mem.eql(u8, &acc.peer.bytes, &mine.bytes)) return .{ a, acc.fd };
                sys.close(acc.fd);
            } else whp.sleepUs(100);
        }
        sys.close(a);
        return null;
    }

    fn create(it: *Interp, args: []const Value) Error!Value {
        const a = it.alloc();
        const b = it.heap.backing;
        // The guest lives in `ga`, so the pool can make one on its thread.
        const host = it.vm_host;
        const s = try state(it);
        if (s.guests.items.len >= host.max_guests)
            return it.failCode("ZTCL VM LIMIT", "the interpreter has {d} guests, the limit", .{s.guests.items.len});
        if (args.len % 2 != 0) return it.wrongArgs("ztcl::vm create ?-option value ...?");
        whp.probe() catch |e| return failure(it, e);
        var cpus: u32 = 1;
        var memory_mb: u32 = 256;
        var cmdline: []const u8 = "console=hvc0 quiet";
        var entropy = false;
        var kernel: []const u8 = "";
        var initrd: []const u8 = "";
        var disks: std.ArrayList(struct { path: []const u8, rw: bool }) = .empty;
        var shares: std.ArrayList(struct { path: []const u8, rw: bool }) = .empty;
        var warm = false;
        var image: ?[]const u8 = null;
        {
            // -image gives the kernel, the initramfs, and the command line.
            var has_image = false;
            var own_boot = false;
            var k: usize = 0;
            while (k + 1 < args.len) : (k += 2) {
                const o = try it.str(args[k]);
                if (std.mem.eql(u8, o, "-image")) has_image = true;
                if (std.mem.eql(u8, o, "-kernel") or std.mem.eql(u8, o, "-initrd") or std.mem.eql(u8, o, "-cmdline")) own_boot = true;
            }
            if (has_image and own_boot) return it.fail("-image gives the kernel, the initramfs, and the command line: no -kernel, -initrd, or -cmdline with it", .{});
        }
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            const opt = try it.str(args[i]);
            const v = args[i + 1];
            if (std.mem.eql(u8, opt, "-image")) {
                image = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-cpus")) {
                cpus = try limit(it, v, "CPU count", host.max_cpus);
                if (cpus != 1) return it.failCode("ZTCL VM LIMIT", "a guest on Windows has one CPU in this version", .{});
            } else if (std.mem.eql(u8, opt, "-memory")) {
                memory_mb = try limit(it, v, "memory in MB", host.max_memory_mb);
            } else if (std.mem.eql(u8, opt, "-kernel")) {
                kernel = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-initrd")) {
                initrd = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-cmdline")) {
                cmdline = try it.str(v);
            } else if (std.mem.eql(u8, opt, "-entropy")) {
                entropy = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-warm")) {
                warm = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-disk")) {
                const l = try it.readList(v);
                if (l.len < 1 or l.len > 2) return it.fail("a disk is {{file ?rw?}}", .{});
                if (disks.items.len >= whp.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks", .{whp.max_disks});
                try disks.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 2 and try isRw(it, l[1]) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                const l = try it.readList(v);
                if (l.len < 2 or l.len > 3) return it.fail("a share is {{host guest ?rw?}}", .{});
                if (disks.items.len + shares.items.len >= whp.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{whp.max_disks});
                try shares.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 3 and try isRw(it, l[2]) });
            } else return it.fail("bad option \"{s}\": must be -cmdline, -cpus, -disk, -entropy, -image, -initrd, -kernel, -memory, -share, or -warm", .{opt});
        }
        if (kernel.len == 0 and image == null) return it.failCode("ZTCL VM KERNEL", "a guest needs -kernel or -image", .{});

        // A guest of the image from the pool: no disk of its own and no
        // -warm, so it is the guest that the pool boots.
        if (image) |name| if (host.pool_size > 0 and disks.items.len == 0 and shares.items.len == 0 and !warm) {
            const st = try store(it);
            const counter = st.current(a, name) catch |e| {
                st.close();
                return storeFail(it, e);
            };
            st.close();
            if (counter) |cn| {
                const key = try poolKey(a, name, cn, memory_mb, entropy);
                const got = take(key);
                refill(key, host.image_store, name, memory_mb, entropy, host.pool_size);
                if (got) |pg| {
                    const n = std.fmt.allocPrint(ga, "vm{d}", .{s.next}) catch |e| {
                        destroyRaw(pg);
                        return e;
                    };
                    ga.free(pg.name);
                    pg.name = n;
                    s.guests.append(b, pg) catch |e| {
                        destroyRaw(pg);
                        return e;
                    };
                    s.next += 1;
                    return .{ .str = pg.name };
                }
            }
        };
        const g = try ga.create(Guest);
        g.* = .{ .name = "", .machine = undefined, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .disk_fds = &.{}, .console_vm = -1, .console_host = -1, .warm = warm };
        var made = false;
        errdefer if (!made) freeGuest(it, g);
        // The disks of an image come first, read-only: /dev/vda is its root.
        var image_disks: []i32 = &.{};
        if (image) |name| {
            const l = try loadImage(it, ga, name);
            g.kernel = l.kernel;
            g.initrd = l.initrd;
            cmdline = try std.fmt.allocPrint(a, "console=hvc0 {s}", .{l.cmdline});
            image_disks = l.disks;
            if (image_disks.len + disks.items.len > whp.max_disks) {
                for (image_disks) |fd| sys.close(fd);
                return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks", .{whp.max_disks});
            }
        } else {
            g.kernel = try readPath(it, kernel);
            if (initrd.len != 0) g.initrd = try readPath(it, initrd);
        }
        g.cmdline = try ga.dupe(u8, cmdline);
        const n_disks = image_disks.len + disks.items.len;
        g.disks = ga.alloc(whp.Disk, n_disks) catch |e| {
            for (image_disks) |fd| sys.close(fd);
            return e;
        };
        g.disk_fds = ga.alloc(i32, n_disks) catch |e| {
            for (image_disks) |fd| sys.close(fd);
            return e;
        };
        for (g.disk_fds) |*f| f.* = -1;
        // From here freeGuest closes each descriptor of disk_fds.
        for (image_disks, 0..) |fd, k| {
            g.disk_fds[k] = fd;
            g.disks[k] = .{ .handle = @ptrFromInt(@as(usize, @intCast(fd))), .read_only = true };
        }
        for (disks.items, g.disks[image_disks.len..], g.disk_fds[image_disks.len..]) |d, *out, *fd| {
            fd.* = try openPath(it, d.path, d.rw);
            out.* = .{ .handle = @ptrFromInt(@as(usize, @intCast(fd.*))), .read_only = !d.rw };
        }
        // The root folder of each share, in the file jail.
        if (g.disks.len + shares.items.len > whp.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{whp.max_disks});
        g.shares = try ga.alloc(whp.Share, shares.items.len);
        for (g.shares) |*sh| sh.fd = -1;
        for (shares.items, g.shares) |d, *out| out.* = .{ .fd = try jailDir(it, d.path), .read_only = !d.rw };
        machineOf(g, cpus, memory_mb, entropy) catch |e| switch (e) {
            error.Pair => return it.failCode("ZTCL VM WHP", "no socket pair for the console", .{}),
            else => |f| return failure(it, f),
        };
        made = true;
        g.name = try std.fmt.allocPrint(ga, "vm{d}", .{s.next});
        s.next += 1;
        s.guests.append(b, g) catch |e| {
            destroy(it, g);
            return e;
        };
        if (warm) {
            try start(it, g);
            const fd = connect(g, agent_port, 10_000) orelse
                return it.failCode("ZTCL VM AGENT", "no program of the guest accepted a connection on port {d}", .{agent_port});
            sys.close(fd);
            g.machine.pause();
        }
        return .{ .str = g.name };
    }

    fn start(it: *Interp, g: *Guest) Error!void {
        if (g.machine.getState() == .running) return it.failCode("ZTCL VM STATE", "the guest {s} is running", .{g.name});
        startRaw(g) catch |e| switch (e) {
            error.Thread => return it.failCode("ZTCL VM WHP", "no thread for the pump of the guest", .{}),
            else => |f| return failure(it, f),
        };
    }

    /// Starts or resumes the guest, and its pump thread.
    fn startRaw(g: *Guest) (whp.Fail || error{Thread})!void {
        switch (g.machine.getState()) {
            .paused => g.machine.@"resume"(),
            .created, .stopped, .failed => {
                try g.machine.start();
                if (g.pump == null) {
                    g.stop_pump.store(false, .seq_cst);
                    g.pump = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, pumpMain, .{g}) catch return error.Thread;
                }
            },
            .running => {},
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

    // The callbacks of the monitor, on its vCPU thread.

    fn guestOf(ctx: *anyopaque) *Guest {
        return @ptrCast(@alignCast(ctx));
    }

    fn consoleWrite(ctx: *anyopaque, bytes: []const u8) void {
        const g = guestOf(ctx);
        g.lock.lock();
        defer g.lock.unlock();
        g.console_out.appendSlice(std.heap.page_allocator, bytes) catch {};
    }

    fn streamData(ctx: *anyopaque, conn: u32, bytes: []const u8) void {
        const g = guestOf(ctx);
        g.lock.lock();
        defer g.lock.unlock();
        g.streams[conn].out.appendSlice(std.heap.page_allocator, bytes) catch {};
    }

    fn streamEvent(ctx: *anyopaque, conn: u32, e: vsock.Event) void {
        const g = guestOf(ctx);
        g.lock.lock();
        defer g.lock.unlock();
        g.streams[conn].state = switch (e) {
            .connected => .open,
            .refused => .refused,
            .closed => .closed,
        };
    }

    /// The pump: the console and each stream, between the monitor and its
    /// end of each pair, every millisecond.
    fn pumpMain(g: *Guest) void {
        var buf: [16 * 1024]u8 = undefined;
        while (!g.stop_pump.load(.seq_cst)) {
            // The output of the guest console.
            g.lock.lock();
            if (g.console_out.items.len > 0 and g.console_vm >= 0) {
                switch (sys.write(g.console_vm, g.console_out.items)) {
                    .n => |n| g.console_out.replaceRangeAssumeCapacity(0, n, &.{}),
                    else => {},
                }
            }
            g.lock.unlock();
            // The input of the script for the console.
            if (g.console_vm >= 0) switch (sys.read(g.console_vm, &buf)) {
                .n => |n| if (n > 0) g.machine.consoleInput(buf[0..n]),
                else => {},
            };
            for (&g.streams, 0..) |*st, k| pumpStream(g, st, @intCast(k), &buf);
            whp.sleepUs(1000);
        }
    }

    fn pumpStream(g: *Guest, st: *Stream, conn: u32, buf: []u8) void {
        g.lock.lock();
        const fd = st.fd;
        const s = st.state;
        if (fd >= 0 and st.out.items.len > 0) {
            switch (sys.write(fd, st.out.items)) {
                .n => |n| st.out.replaceRangeAssumeCapacity(0, n, &.{}),
                .again => {},
                .err => st.out.clearRetainingCapacity(),
            }
        }
        const drained = st.out.items.len == 0;
        g.lock.unlock();
        if (fd < 0) return;
        if (s == .closed) {
            // The guest ended the stream: the script reads the end once
            // the bytes of the guest are out.
            if (!drained) return;
            g.lock.lock();
            st.fd = -1;
            st.state = .free;
            st.in.clearRetainingCapacity();
            g.lock.unlock();
            sys.close(fd);
            return;
        }
        if (s != .open) return;
        // The bytes of the script, within the credit of the guest.
        if (st.in.items.len == 0) {
            switch (sys.read(fd, buf)) {
                .n => |n| {
                    if (n == 0) {
                        // The script closed its channel.
                        g.machine.close(conn);
                        g.lock.lock();
                        st.fd = -1;
                        g.lock.unlock();
                        sys.close(fd);
                        return;
                    }
                    st.in.appendSlice(std.heap.page_allocator, buf[0..n]) catch return;
                },
                .again => {},
                .err => {
                    g.machine.close(conn);
                    g.lock.lock();
                    st.fd = -1;
                    g.lock.unlock();
                    sys.close(fd);
                    return;
                },
            }
        }
        if (st.in.items.len > 0) {
            const took = g.machine.send(conn, st.in.items);
            st.in.replaceRangeAssumeCapacity(0, took, &.{});
        }
    }

    /// Connects to a port of the guest, again after each refused
    /// connection, until `timeout_ms` pass. Gives the end of the script
    /// of a new pair, a blocking socket.
    fn connect(g: *Guest, port: u32, timeout_ms: u32) ?i32 {
        const end = whp.nowNs() / std.time.ns_per_ms + timeout_ms;
        while (g.machine.getState() == .running) {
            const conn = g.machine.connect(port) orelse return null;
            const st = &g.streams[conn];
            g.lock.lock();
            if (st.state == .free) st.state = .connecting;
            g.lock.unlock();
            while (true) {
                g.lock.lock();
                const s = st.state;
                g.lock.unlock();
                if (s != .connecting) break;
                if (whp.nowNs() / std.time.ns_per_ms >= end) {
                    g.machine.close(conn);
                    return null;
                }
                whp.sleepUs(250);
            }
            g.lock.lock();
            const s = st.state;
            if (s != .open) st.state = .free;
            g.lock.unlock();
            if (s == .open) {
                const p = pair() orelse {
                    g.machine.close(conn);
                    return null;
                };
                sys.setBlocking(p[0], false);
                g.lock.lock();
                st.fd = p[0];
                g.lock.unlock();
                return p[1];
            }
            if (whp.nowNs() / std.time.ns_per_ms >= end) return null;
            whp.sleepUs(2000);
        }
        return null;
    }

    fn vsockCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const a = try vsockArgs(it, args);
        if (g.machine.getState() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const fd = connect(g, a.port, a.timeout) orelse
            return it.failCode("ZTCL VM CONNECT", "no program of the guest {s} accepted a connection on port {d}", .{ g.name, a.port });
        return binaryChannel(it, "vsock", fd);
    }

    /// `exec` through the agent: a dict of `exit`, `stdout`, and `stderr`.
    fn execCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const r = try execArgs(it, args);
        if (g.machine.getState() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const fd = connect(g, vmagent.port, r.timeout) orelse
            return it.failCode("ZTCL VM AGENT", "the agent of the guest {s} did not answer on port {d}", .{ g.name, vmagent.port });
        defer sys.close(fd);
        var a: vmagent.Conn = .{ .fd = fd, .timeout_ms = @intCast(@min(r.timeout, std.math.maxInt(i32))) };
        _ = a.hello(it.alloc()) catch |e| return agentFail(it, g.name, &a, e);
        return agentExec(it, g.name, &a, r);
    }

    /// `mount` through the agent: the 9p share of the tag at a path of the
    /// guest.
    fn mountCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const r = try mountArgs(it, args);
        if (g.machine.getState() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const fd = connect(g, vmagent.port, 5000) orelse
            return it.failCode("ZTCL VM AGENT", "the agent of the guest {s} did not answer on port {d}", .{ g.name, vmagent.port });
        defer sys.close(fd);
        var a: vmagent.Conn = .{ .fd = fd, .timeout_ms = 5000 };
        _ = a.hello(it.alloc()) catch |e| return agentFail(it, g.name, &a, e);
        return agentMount(it, g.name, &a, r, .nine_p);
    }

    /// The console pair and the machine of a guest whose kernel, initramfs,
    /// command line, and disks are in place.
    fn machineOf(g: *Guest, cpus: u32, memory_mb: u32, entropy: bool) (whp.Fail || error{Pair})!void {
        const con = pair() orelse return error.Pair;
        g.console_vm = con[0];
        g.console_host = con[1];
        sys.setBlocking(g.console_vm, false);
        g.machine = try whp.init(ga, .{
            .cpus = cpus,
            .memory_mb = memory_mb,
            .kernel = g.kernel,
            .initrd = g.initrd,
            .cmdline = g.cmdline,
            .disks = g.disks,
            .shares = g.shares,
            .entropy = entropy,
            .console = .{ .ctx = g, .write = consoleWrite },
            .vsock = .{ .ctx = g, .data = streamData, .event = streamEvent },
        });
    }

    // ---- The pool of booted guests (Host.pool_size) ----
    //
    // As on macOS: guests of the current release of an image, booted to the
    // agent and paused, by a key of the image, its counter, the memory, and
    // the entropy device. `create -image` gets one and names it, `start`
    // resumes it, and a thread boots the next one.

    const Pool = struct {
        lock: Lock = .{},
        ready: std.StringHashMapUnmanaged(std.ArrayList(*Guest)) = .empty,
        /// The keys with a refill that runs.
        filling: std.StringHashMapUnmanaged(void) = .empty,
    };
    var the_pool: Pool = .{};

    /// What a refill thread needs, in `ga`.
    const PoolJob = struct {
        key: []u8,
        store: []u8,
        name: []u8,
        memory_mb: u32,
        entropy: bool,
        want: u32,

        fn free(j: *PoolJob) void {
            ga.free(j.key);
            ga.free(j.store);
            ga.free(j.name);
            ga.destroy(j);
        }
    };

    fn poolKey(a: std.mem.Allocator, name: []const u8, counter: u64, memory_mb: u32, entropy: bool) ![]u8 {
        return std.fmt.allocPrint(a, "{s}|{d}|{d}|{}", .{ name, counter, memory_mb, entropy });
    }

    /// A guest of the current release of `j.name`, booted to the agent and
    /// paused, or null. The store checks the kernel and the initramfs as
    /// `loadImage` does.
    fn warmOne(j: *const PoolJob) ?*Guest {
        const s = vmstore.Store.open(ga, j.store) catch return null;
        defer s.close();
        const counter = (s.current(ga, j.name) catch return null) orelse return null;
        var c = s.load(ga, j.name, counter) catch return null;
        defer c.deinit();
        const x = c.parsed.value.archs.map.get(vmstore.host_arch) orelse return null;
        if (x.disks.len > whp.max_disks) return null;
        const g = ga.create(Guest) catch return null;
        g.* = .{ .name = "", .machine = undefined, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .disk_fds = &.{}, .console_vm = -1, .console_host = -1, .warm = true };
        var made = false;
        const ok = blk: {
            g.name = ga.dupe(u8, "") catch break :blk false;
            g.kernel = s.readObject(ga, x.kernel.sha256) catch break :blk false;
            if (x.initrd) |f| g.initrd = s.readObject(ga, f.sha256) catch break :blk false;
            g.cmdline = std.fmt.allocPrint(ga, "console=hvc0 {s}", .{x.cmdline}) catch break :blk false;
            g.disks = ga.alloc(whp.Disk, x.disks.len) catch break :blk false;
            g.disk_fds = ga.alloc(i32, x.disks.len) catch break :blk false;
            for (g.disk_fds) |*f| f.* = -1;
            for (x.disks, g.disks, g.disk_fds) |d, *out, *fd| {
                fd.* = s.openObject(ga, d.sha256) catch break :blk false;
                out.* = .{ .handle = @ptrFromInt(@as(usize, @intCast(fd.*))), .read_only = true };
            }
            machineOf(g, 1, j.memory_mb, j.entropy) catch break :blk false;
            made = true;
            startRaw(g) catch break :blk false;
            const fd = connect(g, agent_port, 10_000) orelse break :blk false;
            sys.close(fd);
            g.machine.pause();
            break :blk true;
        };
        if (!ok) {
            if (made) destroyRaw(g) else freeRaw(g);
            return null;
        }
        return g;
    }

    fn endFill(key: []const u8) void {
        the_pool.lock.lock();
        if (the_pool.filling.fetchRemove(key)) |kv| ga.free(kv.key);
        the_pool.lock.unlock();
    }

    fn countReady(key: []const u8) usize {
        return if (the_pool.ready.getPtr(key)) |l| l.items.len else 0;
    }

    fn refillMain(j: *PoolJob) void {
        defer j.free();
        while (true) {
            the_pool.lock.lock();
            const have = countReady(j.key);
            the_pool.lock.unlock();
            if (have >= j.want) return endFill(j.key);
            const g = warmOne(j) orelse return endFill(j.key);
            the_pool.lock.lock();
            const gop = the_pool.ready.getOrPut(ga, j.key) catch {
                the_pool.lock.unlock();
                destroyRaw(g);
                return endFill(j.key);
            };
            if (!gop.found_existing) {
                gop.key_ptr.* = ga.dupe(u8, j.key) catch {
                    the_pool.ready.removeByPtr(gop.key_ptr);
                    the_pool.lock.unlock();
                    destroyRaw(g);
                    return endFill(j.key);
                };
                gop.value_ptr.* = .empty;
            }
            gop.value_ptr.append(ga, g) catch {
                the_pool.lock.unlock();
                destroyRaw(g);
                return endFill(j.key);
            };
            the_pool.lock.unlock();
        }
    }

    /// Starts a refill of the pool of `key` to `want` guests, when none runs.
    fn refill(key: []const u8, store_root: []const u8, name: []const u8, memory_mb: u32, entropy: bool, want: u32) void {
        the_pool.lock.lock();
        if (the_pool.filling.contains(key) or countReady(key) >= want) {
            the_pool.lock.unlock();
            return;
        }
        const k = ga.dupe(u8, key) catch {
            the_pool.lock.unlock();
            return;
        };
        the_pool.filling.put(ga, k, {}) catch {
            ga.free(k);
            the_pool.lock.unlock();
            return;
        };
        the_pool.lock.unlock();
        const j = ga.create(PoolJob) catch return endFill(key);
        j.* = .{
            .key = ga.dupe(u8, key) catch return endFill(key),
            .store = ga.dupe(u8, store_root) catch return endFill(key),
            .name = ga.dupe(u8, name) catch return endFill(key),
            .memory_mb = memory_mb,
            .entropy = entropy,
            .want = want,
        };
        const t = std.Thread.spawn(.{}, refillMain, .{j}) catch {
            j.free();
            return endFill(key);
        };
        t.detach();
    }

    /// A guest of the pool for `key`, or null.
    fn take(key: []const u8) ?*Guest {
        the_pool.lock.lock();
        defer the_pool.lock.unlock();
        const l = the_pool.ready.getPtr(key) orelse return null;
        return l.pop();
    }

    fn freeGuest(it: *Interp, g: *Guest) void {
        _ = it;
        freeRaw(g);
    }

    fn freeRaw(g: *Guest) void {
        const b = ga;
        for (g.disk_fds) |fd| if (fd >= 0) sys.close(fd);
        b.free(g.disk_fds);
        b.free(g.disks);
        for (g.shares) |sh| if (sh.fd >= 0) sys.close(sh.fd);
        b.free(g.shares);
        b.free(g.kernel);
        b.free(g.initrd);
        b.free(g.cmdline);
        if (g.console_vm >= 0) sys.close(g.console_vm);
        if (g.console_host >= 0) sys.close(g.console_host);
        g.console_out.deinit(std.heap.page_allocator);
        for (&g.streams) |*st| {
            if (st.fd >= 0) sys.close(st.fd);
            st.out.deinit(std.heap.page_allocator);
            st.in.deinit(std.heap.page_allocator);
        }
        b.free(g.name);
        b.destroy(g);
    }

    fn destroy(it: *Interp, g: *Guest) void {
        _ = it;
        destroyRaw(g);
    }

    fn destroyRaw(g: *Guest) void {
        g.machine.stop();
        g.stop_pump.store(true, .seq_cst);
        if (g.pump) |t| t.join();
        g.pump = null;
        g.machine.deinit();
        freeRaw(g);
    }

    pub fn closeAll(it: *Interp) void {
        const s: *State = @ptrCast(@alignCast(it.vm_state orelse return));
        for (s.guests.items) |g| destroy(it, g);
        s.guests.deinit(it.heap.backing);
        it.heap.backing.destroy(s);
        it.vm_state = null;
    }
} else struct {};
