//! `ztcl::vm`: small Linux guests on the hypervisor of the host
//! (capability `vm`, ztcl#203). The plan is `docs/dev/vm.md`.
//!
//!   ztcl::vm create ?-cpus N? ?-memory MB? -kernel F ?-initrd F? ?-cmdline TEXT?
//!                   ?-disk {F ?rw?}? ... ?-share {HOST GUEST ?rw?}? ... ?-entropy 0|1? ?-net nat|none? ?-warm 0|1?
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
const nat_engine = @import("vm/nat/engine.zig");
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
    /// The guest of `thread::create -isolation vm` (Linux with KVM): host
    /// paths of a kernel and of an initramfs whose /sbin/ztcl is a ztcl
    /// runner (`isovm.zig`). Empty: the level vm gives ZTCL ISOLATION
    /// LEVEL.
    iso_kernel: []const u8 = "",
    iso_initrd: []const u8 = "",
    /// The memory of the guest of each vm thread, in MB.
    iso_memory_mb: u32 = 256,
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

/// The stack of the pool, listener, and pump threads. With glibc, the
/// stack of a new thread also holds the static TLS of the program, and
/// pthread_create gives EINVAL when the TLS does not fit. An embedder
/// with a large TLS (dockyard: 266 KB) needs more than 256 KB, as for the
/// threads of kvm.zig. The pages that a thread does not touch take no
/// memory.
const thread_stack = 2 * 1024 * 1024;

pub const FetchError = error{ Network, Status, Io, OutOfMemory };

/// The runner gives the download of `image fetch` (`zig build -Dvm-fetch`).
pub const runner_fetch = @hasDecl(@import("build_options"), "vm_fetch") and @import("build_options").vm_fetch;

/// The release of the images by default: a GitHub release that the
/// publisher moves to each new image (docs/dev/vm-image.md).
pub const image_base = "https://github.com/beetlebugorg/ztcl/releases/download/";
/// The releases of ztcl, newest first, for a fetch with no -version.
pub const releases_api = "https://api.github.com/repos/beetlebugorg/ztcl/releases?per_page=100";

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

/// The spawner of `thread::create -isolation vm` for the interpreter
/// `root`, or null when this host has no level vm.
pub fn isoSpawner(root: *Interp) ?@import("isothread.zig").Spawner {
    if (comptime !on_kvm) return null;
    return lin.isoSpawner(root);
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
pub const Loaded = struct { kernel: []u8, initrd: []u8, cmdline: []const u8, disks: []i32, counter: u64 = 0 };

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
    return .{ .kernel = kernel, .initrd = initrd, .cmdline = try a.dupe(u8, x.cmdline), .disks = disks, .counter = counter };
}

/// The disks of release `counter` of the image `name`, read-only, opened
/// through the store, for the restore of a snapshot: the memory of the
/// snapshot has the kernel and the initramfs.
pub fn openImageDisks(it: *Interp, name: []const u8, counter: u64) Error![]i32 {
    const s = try store(it);
    defer s.close();
    const a = it.alloc();
    var c = s.load(a, name, counter) catch |e| return storeFail(it, e);
    defer c.deinit();
    const x = c.parsed.value.archs.map.get(vmstore.host_arch) orelse return storeFail(it, error.Missing);
    const disks = try a.alloc(i32, x.disks.len);
    var n: usize = 0;
    errdefer for (disks[0..n]) |fd| sys.close(fd);
    for (x.disks) |d| {
        disks[n] = s.openObject(a, d.sha256) catch |e| return storeFail(it, e);
        n += 1;
    }
    return disks;
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
    const s = try store(it);
    defer s.close();
    if (base) |b| return fetchFrom(it, hook, s, a, if (std.mem.endsWith(u8, b, "/")) b else try std.fmt.allocPrint(a, "{s}/", .{b}), force);
    if (version) |v| return fetchFrom(it, hook, s, a, try std.fmt.allocPrint(a, "{s}vm-image-v{s}/", .{ image_base, v }), force);
    // No -version: the releases vm-image-vN of ztcl, the highest version
    // first. A release that fails (no download, or a check of install)
    // gives way to the next, and with none the error of the highest.
    const list = blk: {
        var t = s.tempDir(a) catch |e| return storeFail(it, e);
        defer t.remove(a, s);
        try download(it, hook, t, a, "", releases_api);
        break :blk vmstore.readAll(a, t.fd, "releases.json", 16 << 20) catch |e| return storeFail(it, e);
    };
    const tags = imageTags(a, list) catch return it.failCode("ZTCL VM FETCH", "the list of releases of {s} is not JSON", .{releases_api});
    if (tags.len == 0) return it.failCode("ZTCL VM FETCH", "ztcl has no release vm-image-vN", .{});
    var first: ?struct { result: Value, code: Value } = null;
    for (tags) |tag| {
        const r = fetchFrom(it, hook, s, a, try std.fmt.allocPrint(a, "{s}{s}/", .{ image_base, tag }), force) catch |e| {
            if (e != error.TclError) return e;
            if (first == null) first = .{ .result = it.result, .code = it.error_code };
            continue;
        };
        return r;
    }
    it.result = first.?.result;
    it.error_code = first.?.code;
    return error.TclError;
}

/// The tags `vm-image-vN` of a list of GitHub releases (JSON), with no
/// draft, the highest version first. N is numbers with dots.
pub fn imageTags(a: std.mem.Allocator, json: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always });
    if (parsed != .array) return error.NotList;
    var tags: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |rel| {
        if (rel != .object) continue;
        if (rel.object.get("draft")) |d| if (d == .bool and d.bool) continue;
        const t = rel.object.get("tag_name") orelse continue;
        if (t != .string or !std.mem.startsWith(u8, t.string, "vm-image-v")) continue;
        if (versionKey(t.string["vm-image-v".len..]) == null) continue;
        try tags.append(a, t.string);
    }
    const items = try tags.toOwnedSlice(a);
    std.mem.sort([]const u8, items, {}, struct {
        fn gt(_: void, x: []const u8, y: []const u8) bool {
            return versionOrder(x["vm-image-v".len..], y["vm-image-v".len..]) == .gt;
        }
    }.gt);
    return items;
}

/// The numbers of a version such as 1 or 1.2.3, or null.
fn versionKey(v: []const u8) ?[4]u64 {
    var k: [4]u64 = @splat(0);
    var parts = std.mem.splitScalar(u8, v, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (n == k.len or p.len == 0) return null;
        k[n] = std.fmt.parseInt(u64, p, 10) catch return null;
    }
    return k;
}

fn versionOrder(x: []const u8, y: []const u8) std.math.Order {
    const kx = versionKey(x).?;
    const ky = versionKey(y).?;
    for (kx, ky) |p, q| if (p != q) return std.math.order(p, q);
    return .eq;
}

/// True for a URL of plain HTTP with the host 127.0.0.1 and no user
/// part. `http://127.0.0.1.example.com/` and
/// `http://127.0.0.1:1@example.com/` are false.
fn isLoopbackHttp(url: []const u8) bool {
    const u = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, u.scheme, "http") or u.user != null or u.password != null) return false;
    const h = u.host orelse return false;
    return switch (h) {
        .raw, .percent_encoded => |s| std.mem.eql(u8, s, "127.0.0.1"),
    };
}

test "a release over plain HTTP comes from 127.0.0.1 only" {
    try std.testing.expect(isLoopbackHttp("http://127.0.0.1/"));
    try std.testing.expect(isLoopbackHttp("http://127.0.0.1:8080/rel/"));
    try std.testing.expect(!isLoopbackHttp("http://127.0.0.1.example.com/"));
    try std.testing.expect(!isLoopbackHttp("http://127.0.0.1:1@example.com/"));
    try std.testing.expect(!isLoopbackHttp("http://127.0.0.1@example.com/"));
    try std.testing.expect(!isLoopbackHttp("https://127.0.0.1/"));
}

/// A fetch of the release at the folder `root`: the manifest and its
/// signature, then the files of this architecture, then `install`.
fn fetchFrom(it: *Interp, hook: anytype, s: vmstore.Store, a: std.mem.Allocator, root: []const u8, force: bool) Error!Value {
    if (!std.mem.startsWith(u8, root, "https://") and !isLoopbackHttp(root))
        return it.fail("a release is fetched over https", .{});
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

/// Downloads `root` + `name` into the file `name` of `t`, or, with an
/// empty `root`, the URL `name` into the file releases.json.
fn download(it: *Interp, hook: anytype, t: vmstore.Temp, a: std.mem.Allocator, root: []const u8, name: []const u8) Error!void {
    const fd = t.create(a, if (root.len == 0) "releases.json" else name) catch |e| return storeFail(it, e);
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

/// The arguments of `listen VM PORT -command SCRIPT ?-framed 0|1?`.
fn listenArgs(it: *Interp, args: []const Value) Error!struct { port: i64, script: Value, framed: bool } {
    const use = "ztcl::vm listen vm port -command script ?-framed 0|1?";
    if (args.len != 3 and args.len != 5) return it.wrongArgs(use);
    const port = try it.int(args[0]);
    if (port < 1) return it.fail("bad port \"{d}\"", .{port});
    var script: ?Value = null;
    var framed = false;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const o = try it.str(args[i]);
        if (std.mem.eql(u8, o, "-command")) {
            script = args[i + 1];
        } else if (std.mem.eql(u8, o, "-framed")) {
            framed = try it.int(args[i + 1]) != 0;
        } else return it.wrongArgs(use);
    }
    return .{ .port = port, .script = script orelse return it.wrongArgs(use), .framed = framed };
}

/// The channel of an accepted connection: the descriptor itself, or for
/// `-framed 1` the end of the script of a relay (`vmrelay.zig`), which
/// owns the descriptor.
fn acceptChannel(it: *Interp, fd: i32, framed: bool) Error!Value {
    if (!framed) return binaryChannel(it, "vsock", fd);
    const local = @import("vmrelay.zig").start(fd) catch {
        _ = sys.os.close(fd);
        return it.failCode("ZTCL VM LISTEN", "no relay for the connection", .{});
    };
    return binaryChannel(it, "vsock", local);
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

/// The network of the NAT for the agent: address/prefix, gateway, DNS.
const nat_cmdline = "ztcl.net=10.0.2.15/24,10.0.2.2,10.0.2.3";

/// The network policy of the interpreter for each host address of the
/// NAT of a guest, on the thread of the NAT. The policy of an
/// interpreter does not change after the embedder sets it.
fn natPolicy(ctx: ?*anyopaque, _: nat_engine.Proto, ip: nat_engine.Ip4, port: u16, name: ?[]const u8) bool {
    const it: *Interp = @ptrCast(@alignCast(ctx.?));
    var addr: sys.Addr = .{ .port = port };
    @memcpy(addr.bytes[0..4], &ip);
    // The name of an address of a DNS answer lets a host rule of the
    // policy match the connection.
    return @import("sock.zig").permits(it.net, addr, port, name);
}

/// The rules of `-allow` or `-deny`: a list of host names (or
/// `*.SUFFIX`), addresses, and ranges in CIDR form, each with an
/// optional `:port` or `:port-port`, as the rules of a network policy.
fn natRules(it: *Interp, v: Value) Error![]nat_engine.policy.Rule {
    const items = try it.list(v);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    try text.appendSlice(it.alloc(), "allow=");
    for (items, 0..) |x, i| {
        const t = try it.str(x);
        if (std.mem.indexOfScalar(u8, t, ',') != null) return it.fail("bad rule \"{s}\"", .{t});
        if (i > 0) try text.append(it.alloc(), ',');
        try text.appendSlice(it.alloc(), t);
    }
    const pol = (try @import("sock.zig").parsePolicy(it.alloc(), text.items)) orelse return it.fail("bad rule list \"{s}\"", .{text.items[6..]});
    const rules = pol.allow;
    const out = try it.alloc().alloc(nat_engine.policy.Rule, rules.len);
    for (rules, out) |r, *o| {
        o.* = .{ .host = r.host, .port_lo = r.port_lo, .port_hi = r.port_hi };
        if (r.net) |a| {
            if (a.v6) return it.fail("the NAT has no IPv6: \"{s}\"", .{text.items[6..]});
            @memcpy(&o.net, a.bytes[0..4]);
            o.bits = @intCast(@min(r.bits, 32));
        }
    }
    return out;
}

/// The names that the DNS relay of the NAT can look up: each name
/// with the `any` policy, none with `loopback`, and the host names
/// of an `allow=` list (a name, or `*.SUFFIX`).
fn natDnsPolicy(ctx: ?*anyopaque, name: []const u8) bool {
    const it: *Interp = @ptrCast(@alignCast(ctx.?));
    switch (it.net) {
        .any => return true,
        .loopback => return false,
        .allow => |rules| {
            for (rules) |r| if (r.host) |h| if (nat_engine.nameMatch(h, name)) return true;
            return false;
        },
    }
}

/// The events of the NAT of a guest, for `ztcl::vm netlog`, and the
/// counts of its bytes for the meter of the interpreter (ztcl#243).
/// The engine adds events on its own thread; `netlog` takes them.
const NetLog = struct {
    gpa: std.mem.Allocator,
    meter: ?*@import("meter.zig").Meter,
    lock: std.atomic.Value(bool) = .init(false),
    ring: [max]Entry = undefined,
    head: usize = 0,
    n: usize = 0,
    /// The events that a full ring dropped since the last `netlog`.
    dropped: u64 = 0,

    const max = 1024;
    const Entry = struct {
        ev: nat_engine.Event,
        name: [253]u8,
        name_len: u8,
    };

    fn create(gpa: std.mem.Allocator, it: *Interp) !*NetLog {
        const l = try gpa.create(NetLog);
        l.* = .{ .gpa = gpa, .meter = it.meter };
        if (l.meter) |m| m.retain();
        return l;
    }

    fn destroy(l: *NetLog) void {
        if (l.meter) |m| m.release();
        l.gpa.destroy(l);
    }

    fn acquire(l: *NetLog) void {
        while (l.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(l: *NetLog) void {
        l.lock.store(false, .release);
    }

    /// The hook `Config.event` of the engine.
    fn event(ctx: ?*anyopaque, ev: *const nat_engine.Event) void {
        const l: *NetLog = @ptrCast(@alignCast(ctx.?));
        if (l.meter) |m| {
            var hb: [24]u8 = undefined;
            const host = std.fmt.bufPrint(&hb, "{d}.{d}.{d}.{d}", .{ ev.addr[0], ev.addr[1], ev.addr[2], ev.addr[3] }) catch "";
            switch (ev.kind) {
                .connect => m.addConnection(host),
                .close => {
                    m.addIo(.socket, true, ev.bytes_in, host);
                    m.addIo(.socket, false, ev.bytes_out, host);
                },
                .dns => m.addIo(.socket, false, ev.bytes_out, host),
                else => {},
            }
        }
        l.acquire();
        defer l.release();
        if (l.n == max) {
            l.head = (l.head + 1) % max;
            l.n -= 1;
            l.dropped += 1;
        }
        const e = &l.ring[(l.head + l.n) % max];
        e.ev = ev.*;
        const k = @min(ev.name.len, e.name.len);
        @memcpy(e.name[0..k], ev.name[0..k]);
        e.name_len = @intCast(k);
        e.ev.name = "";
        l.n += 1;
    }

    /// `ztcl::vm netlog VM`: the events since the last call, oldest
    /// first, each a dict.
    fn take(l: *NetLog, it: *Interp) Error!Value {
        var copy: [max]Entry = undefined;
        l.acquire();
        const n = l.n;
        for (0..n) |i| copy[i] = l.ring[(l.head + i) % max];
        const dropped = l.dropped;
        l.head = 0;
        l.n = 0;
        l.dropped = 0;
        l.release();
        const a = it.alloc();
        var out = try a.alloc(Value, n + @intFromBool(dropped > 0));
        for (copy[0..n], 0..) |*e, i| {
            const ev = &e.ev;
            var items: std.ArrayListUnmanaged(Value) = .empty;
            try items.appendSlice(a, &.{
                .{ .str = "event" },   .{ .str = @tagName(ev.kind) },
                .{ .str = "proto" },   .{ .str = @tagName(ev.proto) },
                .{ .str = "port" },    .{ .int = ev.guest_port },
                .{ .str = "address" }, .{ .str = try std.fmt.allocPrint(a, "{d}.{d}.{d}.{d}:{d}", .{ ev.addr[0], ev.addr[1], ev.addr[2], ev.addr[3], ev.port }) },
            });
            if (ev.kind == .refuse) try items.appendSlice(a, &.{ .{ .str = "rule" }, .{ .int = ev.rule } });
            if (ev.kind == .close) try items.appendSlice(a, &.{ .{ .str = "in" }, .{ .int = @intCast(ev.bytes_in) }, .{ .str = "out" }, .{ .int = @intCast(ev.bytes_out) } });
            if (e.name_len > 0) try items.appendSlice(a, &.{ .{ .str = "name" }, .{ .str = try a.dupe(u8, e.name[0..e.name_len]) } });
            out[i] = try value.wrapList(a, items.items);
        }
        if (dropped > 0) {
            var items = [4]Value{ .{ .str = "event" }, .{ .str = "dropped" }, .{ .str = "count" }, .{ .int = @intCast(dropped) } };
            out[n] = try value.wrapList(a, try a.dupe(Value, &items));
        }
        return value.wrapList(a, out);
    }
};

/// `-net nat`: a network through the user-mode NAT of ztcl#461. It needs
/// the capability `socket`, as each connection of the guest is a
/// connection of the host under its policy. Off by default.
fn netOption(it: *Interp, v: Value) Error!bool {
    const w = try it.str(v);
    if (std.mem.eql(u8, w, "none")) return false;
    if (!std.mem.eql(u8, w, "nat")) return it.fail("bad network \"{s}\": must be nat or none", .{w});
    if (it.capabilities & @backingInt(interp.Capability.socket) == 0)
        return it.failCode("ZTCL VM NONET", "-net nat needs the socket capability", .{});
    return true;
}

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
        /// The network of `-net nat`.
        net: ?*Net = null,
    };

    const Listen = struct { port: u32, l: *vz.Listener, pipe_w: c_int, chan: []const u8, framed: bool = false };

    /// The network of a guest with `-net nat`: a datagram socket pair, one
    /// end for the virtio-net device of the framework
    /// (`VZFileHandleNetworkDeviceAttachment`, one Ethernet frame for each
    /// datagram) and one for the NAT engine (`Nat.initSocket`), which reads
    /// and writes it on its own thread.
    const Net = struct {
        vm_fd: c_int,
        nat: *nat_engine.Nat,
        /// The events of the engine, for `netlog`.
        log: ?*NetLog = null,

        fn init(gpa: std.mem.Allocator, cfg: nat_engine.Config) !*Net {
            var pair: [2]c.fd_t = undefined;
            if (c.socketpair(c.AF.UNIX, c.SOCK.DGRAM, 0, &pair) != 0) return error.NoSocket;
            const size: c_int = 4 << 20;
            _ = c.setsockopt(pair[0], c.SOL.SOCKET, c.SO.SNDBUF, std.mem.asBytes(&size), @sizeOf(c_int));
            _ = c.setsockopt(pair[0], c.SOL.SOCKET, c.SO.RCVBUF, std.mem.asBytes(&size), @sizeOf(c_int));
            // The engine owns pair[1] once initSocket returns.
            const engine = nat_engine.Nat.initSocket(gpa, cfg, pair[1]) catch |e| {
                _ = c.close(pair[0]);
                _ = c.close(pair[1]);
                return e;
            };
            errdefer engine.deinit();
            try engine.start();
            const n = try gpa.create(Net);
            n.* = .{ .vm_fd = pair[0], .nat = engine };
            return n;
        }

        /// Stops the thread of the engine. The end of the framework closes
        /// after the machine, in `close`.
        fn stop(n: *Net) void {
            n.nat.stop();
        }

        fn close(n: *Net, gpa: std.mem.Allocator) void {
            n.nat.deinit();
            _ = c.close(n.vm_fd);
            if (n.log) |l| l.destroy();
            gpa.destroy(n);
        }
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
        if (std.mem.eql(u8, sub, "netlog")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm netlog vm");
            const n = g.net orelse return it.failCode("ZTCL VM NONET", "the guest {s} has no -net nat", .{g.name});
            return n.log.?.take(it);
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
        return it.fail("bad option \"{s}\": must be console, create, delete, exec, mount, netlog, start, status, stop, or vsock", .{sub});
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
        var net_nat = false;
        var dns = true;
        var allow: []nat_engine.policy.Rule = &.{};
        var deny: []nat_engine.policy.Rule = &.{};
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
            } else if (std.mem.eql(u8, opt, "-net")) {
                net_nat = try netOption(it, v);
            } else if (std.mem.eql(u8, opt, "-dns")) {
                dns = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-allow")) {
                allow = try natRules(it, v);
            } else if (std.mem.eql(u8, opt, "-deny")) {
                deny = try natRules(it, v);
            } else if (std.mem.eql(u8, opt, "-disk")) {
                const l = try it.list(v);
                if (l.len < 1 or l.len > 2) return it.fail("a disk is {{file ?rw?}}", .{});
                try disks.append(a, .{ .path = try hostPath(it, try it.str(l[0]), false), .read_only = !(l.len == 2 and try isRw(it, l[1])) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                const l = try it.list(v);
                if (l.len < 2 or l.len > 3) return it.fail("a share is {{host guest ?rw?}}", .{});
                const tag = try std.fmt.allocPrint(a, "share{d}", .{shares.items.len});
                try shares.append(a, .{ .path = try hostPath(it, try it.str(l[0]), true), .tag = tag, .read_only = !(l.len == 3 and try isRw(it, l[2])) });
            } else return it.fail("bad option \"{s}\": must be -allow, -cmdline, -cpus, -deny, -disk, -dns, -entropy, -image, -initrd, -kernel, -memory, -net, -share, or -warm", .{opt});
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
        // The host knows the network of the NAT, so the agent takes it from
        // the command line with no DHCP (docs/dev/vm-agent.md).
        if (net_nat) cfg.cmdline = try std.fmt.allocPrint(a, "{s} {s}", .{ cfg.cmdline, nat_cmdline });
        cfg.shares = shares.items;
        cfg.disks = disks.items;
        // A guest of the image from the pool: no share and no disk of its
        // own, so its configuration is the one of the pool.
        if (image != null and it.vm_host.pool_size > 0 and shares.items.len == 0 and disks.items.len == image_disks and !warm and !net_nat) {
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
        if (!net_nat and allow.len + deny.len > 0) return it.fail("-allow and -deny need -net nat", .{});
        const log: ?*NetLog = if (net_nat) try NetLog.create(it.heap.backing, it) else null;
        const net: ?*Net = if (net_nat) Net.init(it.heap.backing, .{ .policy = natPolicy, .dns_allow = natDnsPolicy, .policy_ctx = it, .dns = dns, .allow = allow, .deny = deny, .event = NetLog.event, .event_ctx = log }) catch {
            log.?.destroy();
            return it.failCode("ZTCL VM FRAMEWORK", "no socket for the network of the guest", .{});
        } else null;
        if (net) |x| x.log = log;
        var keep_net = false;
        defer if (!keep_net) if (net) |n| n.close(it.heap.backing);
        if (net) |n| cfg.net_fd = n.vm_fd;
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
            .net = net,
        };
        s.next += 1;
        try s.guests.append(it.heap.backing, g);
        keep = true;
        keep_net = true;
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
        const la = try listenArgs(it, args);
        const port = la.port;
        if (port > std.math.maxInt(u32)) return it.fail("bad port \"{d}\"", .{port});
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
        try g.listens.append(it.heap.backing, .{ .port = @intCast(port), .l = l, .pipe_w = pipe[1], .chan = name, .framed = la.framed });
        if (it.findCommand("::ztcl::vmpriv::accept") == null) _ = try it.eval(listen_glue);
        var words = [_]Value{ .{ .str = "::ztcl::vmpriv::accept" }, .{ .str = g.name }, .{ .int = port }, ch, la.script };
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
        return acceptChannel(it, @intCast(fd), g.listens.items[i].framed);
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
        if (g.net) |n| n.stop();
        g.machine.deinit();
        vz.release(g.config);
        if (g.net) |n| n.close(it.heap.backing);
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
        /// The events of `-net nat`, for `netlog`.
        netlog: ?*NetLog = null,
        /// The image of the guest as "name counter" (the tag of its
        /// snapshot), and the count of its disks that are the disks of
        /// the image.
        image_tag: []u8 = &.{},
        image_disks: usize = 0,
        /// A guest of a snapshot before its first start: the start
        /// sends the agent the time and new entropy.
        restored: bool = false,
    };

    const Listen = struct { port: u32, l: *Listener, chan: []const u8, framed: bool = false };

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
        if (std.mem.eql(u8, sub, "netlog")) {
            if (args.len != 3) return it.wrongArgs("ztcl::vm netlog vm");
            const l = g.netlog orelse return it.failCode("ZTCL VM NONET", "the guest {s} has no -net nat", .{g.name});
            return l.take(it);
        }
        if (std.mem.eql(u8, sub, "snapshot")) {
            if (args.len != 4) return it.wrongArgs("ztcl::vm snapshot vm file");
            return snapshot(it, g, try it.str(args[3]));
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
        return it.fail("bad option \"{s}\": must be console, create, delete, exec, mount, netlog, snapshot, start, status, stop, or vsock", .{sub});
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
        var k: usize = 0;
        while (k < args.len) : (k += 2) if (std.mem.eql(u8, try it.str(args[k]), "-snapshot")) return createSnapshot(it, args);
        var cfg: kvm.Config = .{ .kernel = "", .cmdline = "console=hvc0 quiet", .console = -1 };
        var kernel: []const u8 = "";
        var initrd: []const u8 = "";
        var disks: std.ArrayList(struct { path: []const u8, rw: bool }) = .empty;
        var shares: std.ArrayList(struct { path: []const u8, rw: bool }) = .empty;
        var warm = false;
        var image: ?[]const u8 = null;
        var own_boot = false;
        var dns = true;
        var allow: []nat_engine.policy.Rule = &.{};
        var deny: []nat_engine.policy.Rule = &.{};
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
            } else if (std.mem.eql(u8, opt, "-balloon")) {
                cfg.balloon = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-warm")) {
                warm = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-net")) {
                const kind = try it.str(v);
                if (std.mem.eql(u8, kind, "none")) {
                    cfg.net = null;
                } else if (std.mem.eql(u8, kind, "nat")) {
                    if (it.capabilities & @backingInt(interp.Capability.socket) == 0)
                        return it.failCode("ZTCL VM NONET", "-net nat needs the socket capability", .{});
                    cfg.net = .{ .policy = natPolicy, .dns_allow = natDnsPolicy, .policy_ctx = it };
                } else return it.fail("bad network \"{s}\": must be nat or none", .{kind});
            } else if (std.mem.eql(u8, opt, "-dns")) {
                dns = try it.int(v) != 0;
            } else if (std.mem.eql(u8, opt, "-allow")) {
                allow = try natRules(it, v);
            } else if (std.mem.eql(u8, opt, "-deny")) {
                deny = try natRules(it, v);
            } else if (std.mem.eql(u8, opt, "-disk")) {
                const l = try it.list(v);
                if (l.len < 1 or l.len > 2) return it.fail("a disk is {{file ?rw?}}", .{});
                if (disks.items.len + shares.items.len >= kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{kvm.max_disks});
                try disks.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 2 and try isRw(it, l[1]) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                const l = try it.list(v);
                if (l.len < 2 or l.len > 3) return it.fail("a share is {{host guest ?rw?}}", .{});
                if (disks.items.len + shares.items.len >= kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{kvm.max_disks});
                try shares.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 3 and try isRw(it, l[2]) });
            } else return it.fail("bad option \"{s}\": must be -allow, -balloon, -cmdline, -cpus, -deny, -disk, -dns, -entropy, -image, -initrd, -kernel, -memory, -net, -share, or -warm", .{opt});
        }
        if (cfg.net) |*nc| {
            nc.dns = dns;
            nc.allow = allow;
            nc.deny = deny;
        } else if (allow.len + deny.len > 0) return it.fail("-allow and -deny need -net nat", .{});
        if (cfg.net != null and disks.items.len + shares.items.len >= kvm.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest with -net nat has at most {d} disks and shares", .{kvm.max_disks - 1});
        if (image != null and own_boot) return it.fail("-image gives the kernel, the initramfs, and the command line: no -kernel, -initrd, or -cmdline with it", .{});
        if (image == null and kernel.len == 0) return it.failCode("ZTCL VM KERNEL", "a guest needs -kernel or -image", .{});

        // A guest of the image from the pool: no share and no disk of its
        // own, so its configuration is the one of the pool.
        var fp: ?[]const u8 = null;
        if (image != null and host.pool_size > 0 and shares.items.len == 0 and disks.items.len == 0 and !warm and cfg.net == null) {
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
                g.* = .{ .name = "", .machine = p.machine, .kernel = p.kernel, .initrd = p.initrd, .cmdline = p.cmdline, .disks = p.disks, .shares = &.{}, .console_vm = p.console_vm, .console_host = p.console_host, .warm = true, .pooled = true, .restored = p.restored };
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
            g.image_tag = std.fmt.allocPrint(b, "{s} {d}", .{ name, l.counter }) catch |e| {
                for (l.disks) |fd| sys.close(fd);
                b.free(l.kernel);
                b.free(l.initrd);
                return e;
            };
            g.image_disks = l.disks.len;
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
        // The agent sets the network of the NAT from the command line,
        // with no DHCP.
        if (cfg.net != null) {
            const line = try std.fmt.allocPrint(b, "{s} ztcl.net=10.0.2.15/24,10.0.2.2,10.0.2.3", .{g.cmdline});
            b.free(g.cmdline);
            g.cmdline = line;
        }
        cfg.cmdline = g.cmdline;
        cfg.disks = g.disks;
        cfg.shares = g.shares;
        cfg.console = g.console_vm;
        if (cfg.net) |*nc| {
            g.netlog = try NetLog.create(it.heap.backing, it);
            nc.event = NetLog.event;
            nc.event_ctx = g.netlog;
        }
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
        if (g.restored) {
            g.restored = false;
            resumeAgent(it, g);
        }
    }

    /// The first start of a guest of a snapshot: the agent sets the
    /// clock of the guest to the time of the host and adds new entropy
    /// to the random pool of the guest, so the clones of one snapshot
    /// have different random numbers. An agent without the request
    /// `RESUME` (feature bit 3) gets nothing.
    fn resumeAgent(it: *Interp, g: *Guest) void {
        _ = kvm.snapshot.waitReset(g.machine, 100_000);
        var rnd: [32]u8 = undefined;
        if (linux.getrandom(&rnd, rnd.len, 0) != rnd.len) return;
        // Port 1027 of the agent: the prelude of `isovm.zig`, served with
        // no fork. An agent without it refuses the connection, and the
        // request RESUME on port 1024 follows.
        if (connectTry(g.machine, resume_port, 20, 250)) |rf| {
            defer _ = linux.close(rf);
            const p = isovm.prelude(realtimeNs(), &rnd);
            if (linux.write(rf, &p, p.len) == p.len) {
                var ack = [1]linux.pollfd{.{ .fd = rf, .events = linux.POLL.IN, .revents = 0 }};
                var one: [1]u8 = undefined;
                if (linux.poll(&ack, 1, 2000) == 1 and linux.read(rf, &one, 1) == 1) return;
            }
        }
        const fd = connectTry(g.machine, vmagent.port, 2000, 250) orelse return;
        defer _ = linux.close(fd);
        var a: vmagent.Conn = .{ .fd = fd, .timeout_ms = 2000 };
        const h = a.hello(it.alloc()) catch return;
        if (h.features & vmagent.f_resume == 0) return;
        vmagent.resumeGuest(&a, it.alloc(), realtimeNs(), &rnd) catch {};
    }

    /// The port of the agent for the resume prelude.
    const resume_port: u32 = 1027;

    fn realtimeNs() u64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.REALTIME, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    /// `ztcl::vm snapshot VM FILE`: the state and the memory of the guest
    /// to FILE (`vm/kvm_snapshot.zig`). Gives the bytes of guest memory
    /// that the file holds.
    fn snapshot(it: *Interp, g: *Guest, path: []const u8) Error!Value {
        if (g.shares.len != 0) return it.failCode("ZTCL VM SNAPSHOT", "the guest {s} has a share: a guest with a share has no snapshot", .{g.name});
        if (g.disks.len != g.image_disks) return it.failCode("ZTCL VM SNAPSHOT", "the guest {s} has a -disk: only the disks of an image go in a snapshot", .{g.name});
        switch (g.machine.getState()) {
            .running, .paused => {},
            else => return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) }),
        }
        if (it.capabilities & @backingInt(interp.Capability.file) == 0 or !it.fs_ok())
            return it.failCode("ZTCL VM NOFILE", "a path of ztcl::vm needs the file capability", .{});
        const rel = try fsroot.need(it, path);
        const fd = switch (try fsroot.openRel(it, rel, .{ .access = .read_write, .create = true, .truncate = true }, 0o600)) {
            .fd => |fd| fd,
            .err => |e| return fsroot.posixError(it, e, try std.fmt.allocPrint(it.alloc(), "couldn't open \"{s}\": ", .{path})),
        };
        defer sys.close(fd);
        const n = kvm.snapshot.save(g.machine, fd, g.image_tag) catch |e| return failure(it, e);
        return .{ .int = @intCast(n) };
    }

    /// `ztcl::vm create -snapshot FILE ?-count N?`: N guests (1 with no
    /// -count) of one snapshot, each paused until its start. With
    /// -count the result is the list of their names.
    fn createSnapshot(it: *Interp, args: []const Value) Error!Value {
        const b = it.heap.backing;
        const s = try state(it);
        var path: []const u8 = "";
        var count: u32 = 1;
        var list = false;
        var i: usize = 0;
        while (i < args.len) : (i += 2) {
            const opt = try it.str(args[i]);
            if (std.mem.eql(u8, opt, "-snapshot")) {
                path = try it.str(args[i + 1]);
            } else if (std.mem.eql(u8, opt, "-count")) {
                count = try limit(it, args[i + 1], "clone count", it.vm_host.max_guests);
                list = true;
            } else return it.fail("bad option \"{s}\": -snapshot goes with -count only", .{opt});
        }
        if (s.guests.items.len + count > it.vm_host.max_guests)
            return it.failCode("ZTCL VM LIMIT", "the interpreter has {d} guests, and the limit is {d}", .{ s.guests.items.len, it.vm_host.max_guests });
        const fd = try openPath(it, path, false);
        defer sys.close(fd);
        var hdr: kvm.snapshot.Header = undefined;
        const in = kvm.snapshot.info(fd, &hdr) catch return it.failCode("ZTCL VM SNAPSHOT", "\"{s}\" is not a snapshot of this version of ztcl::vm", .{path});
        if (in.cpus > it.vm_host.max_cpus) return it.failCode("ZTCL VM LIMIT", "the snapshot has {d} CPUs, and the limit is {d}", .{ in.cpus, it.vm_host.max_cpus });
        if (in.memory_mb > it.vm_host.max_memory_mb) return it.failCode("ZTCL VM LIMIT", "the snapshot has {d} MB of memory, and the limit is {d}", .{ in.memory_mb, it.vm_host.max_memory_mb });
        // The disks of the image of the tag ("name counter").
        var image_fds: []i32 = &.{};
        defer for (image_fds) |x| sys.close(x);
        if (in.tag.len != 0) {
            const sp = std.mem.lastIndexOfScalar(u8, in.tag, ' ') orelse return it.failCode("ZTCL VM SNAPSHOT", "the image tag of the snapshot is bad", .{});
            const counter = std.fmt.parseInt(u64, in.tag[sp + 1 ..], 10) catch return it.failCode("ZTCL VM SNAPSHOT", "the image tag of the snapshot is bad", .{});
            image_fds = try openImageDisks(it, in.tag[0..sp], counter);
        }
        if (image_fds.len != in.disks) return it.failCode("ZTCL VM SNAPSHOT", "the snapshot has {d} disks, and its image has {d}", .{ in.disks, image_fds.len });

        // A guest with no disk is a restore into a prepared machine of
        // the spares, when the pool is on.
        const set: ?*SpareSet = if (image_fds.len == 0 and it.vm_host.pool_size > 0) spareSet(in.cpus, in.memory_mb, in.entropy, in.balloon) else null;
        var names: std.ArrayList(Value) = .empty;
        for (0..count) |_| {
            const took = if (set) |x| takeSpare(x, it.vm_host.pool_size) else null;
            if (took) |sp| {
                const g = b.create(Guest) catch |e| {
                    sp.machine.deinit();
                    sys.close(sp.console_vm);
                    sys.close(sp.console_host);
                    return e;
                };
                g.* = .{ .name = "", .machine = sp.machine, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .shares = &.{}, .console_vm = sp.console_vm, .console_host = sp.console_host, .warm = true, .pooled = true, .restored = true };
                kvm.snapshot.restore(g.machine, fd) catch |e| {
                    destroy(it, g);
                    return failure(it, e);
                };
                g.name = std.fmt.allocPrint(b, "vm{d}", .{s.next}) catch |e| {
                    destroy(it, g);
                    return e;
                };
                s.next += 1;
                s.guests.append(b, g) catch |e| {
                    destroy(it, g);
                    return e;
                };
                try names.append(it.alloc(), .{ .str = g.name });
                continue;
            }
            const g = try b.create(Guest);
            g.* = .{ .name = "", .machine = undefined, .kernel = &.{}, .initrd = &.{}, .cmdline = &.{}, .disks = &.{}, .shares = &.{}, .console_vm = -1, .console_host = -1, .warm = true, .restored = true };
            var made = false;
            errdefer if (!made) freeGuest(it, g);
            g.image_tag = try b.dupe(u8, in.tag);
            g.image_disks = image_fds.len;
            g.disks = try b.alloc(kvm.Disk, image_fds.len);
            for (g.disks) |*d| d.fd = -1;
            for (image_fds, g.disks) |x, *d| {
                const rc = linux.fcntl(x, linux.F.DUPFD_CLOEXEC, 0);
                if (linux.errno(rc) != .SUCCESS) return it.failCode("ZTCL VM KVM", "no descriptor for a disk", .{});
                d.* = .{ .fd = @intCast(rc), .read_only = true };
            }
            var pair: [2]i32 = undefined;
            if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS)
                return it.failCode("ZTCL VM KVM", "no socket for the console", .{});
            g.console_vm = pair[0];
            g.console_host = pair[1];
            const cfg: kvm.Config = .{ .kernel = "", .cmdline = "", .cpus = in.cpus, .memory_mb = in.memory_mb, .disks = g.disks, .entropy = in.entropy, .balloon = in.balloon, .console = g.console_vm };
            g.machine = kvm.init(b, cfg) catch |e| return failure(it, e);
            made = true;
            kvm.snapshot.restore(g.machine, fd) catch |e| {
                destroy(it, g);
                return failure(it, e);
            };
            g.name = std.fmt.allocPrint(b, "vm{d}", .{s.next}) catch |e| {
                destroy(it, g);
                return e;
            };
            s.next += 1;
            s.guests.append(b, g) catch |e| {
                destroy(it, g);
                return e;
            };
            try names.append(it.alloc(), .{ .str = g.name });
        }
        if (!list) return names.items[0];
        return value.wrapList(it.alloc(), names.items);
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
        return connectTry(m, port, timeout_ms, 1000_000);
    }

    /// `connect` with at most `try_us` microseconds for each try. After a
    /// restore the guest drops a request that comes before it reads its
    /// new context ID, so the first start of a restore tries again after
    /// 250 us.
    fn connectTry(m: *kvm, port: u32, timeout_ms: u32, try_us: u64) ?i32 {
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
                    const wait_us = @min(left * 1000, try_us);
                    var ts: linux.timespec = .{ .sec = @intCast(wait_us / 1_000_000), .nsec = @intCast((wait_us % 1_000_000) * 1000) };
                    _ = linux.ppoll(&p, 1, &ts, null);
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
        b.free(g.image_tag);
        if (g.console_vm >= 0) sys.close(g.console_vm);
        if (g.console_host >= 0) sys.close(g.console_host);
        if (g.netlog) |l| l.destroy();
        it.heap.backing.free(g.name);
        it.heap.backing.destroy(g);
    }

    // ---- The pool of booted guests (Host.pool_size) ----

    /// A guest of the pool: booted to the agent, then paused.
    const Pooled = struct { machine: *kvm, kernel: []u8, initrd: []u8, cmdline: []u8, disks: []kvm.Disk, console_vm: i32, console_host: i32, restored: bool = false };

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
        /// A snapshot of the first guest of the pool in a memfd: each
        /// later guest is a restore of it, a clone that shares the pages
        /// that it does not write. -1 until the first guest is ready.
        snap_fd: i32 = -1,
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
        if (t.snap_fd >= 0) sys.close(t.snap_fd);
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
            // A clone of the snapshot of the pool, when it has one.
            if (t.snap_fd >= 0) {
                if (kvm.snapshot.restore(p.machine, t.snap_fd)) |_| {
                    p.restored = true;
                    break :blk true;
                } else |_| {}
            }
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
            if (t.snap_fd < 0) snapTemplate(t, p.machine);
            break :blk true;
        };
        if (good) return p;
        if (made) p.machine.deinit();
        dropBytes(p);
        return null;
    }

    /// Writes the snapshot of the pool from its first guest, paused, to a
    /// memfd. A failure leaves the pool on boots.
    fn snapTemplate(t: *Template, m: *kvm) void {
        const rc = linux.memfd_create("ztcl-vm-pool", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return;
        const fd: i32 = @intCast(rc);
        _ = kvm.snapshot.save(m, fd, "") catch {
            sys.close(fd);
            return;
        };
        t.snap_fd = fd;
    }

    // ---- Prepared machines for `create -snapshot` ----

    /// A machine of `kvm.snapshot.prepare` with its console, for a restore
    /// with no disk.
    const Spare = struct { machine: *kvm, console_vm: i32, console_host: i32 };
    const SpareSet = struct { cpus: u32, memory_mb: u32, entropy: bool, balloon: bool, ready: std.ArrayList(Spare) = .empty, filling: bool = false, size: u32 = 0 };
    var spares: std.ArrayList(*SpareSet) = .empty;

    fn spareSet(cpus: u32, memory_mb: u32, entropy: bool, balloon: bool) ?*SpareSet {
        pool_lock.lock();
        defer pool_lock.unlock();
        for (spares.items) |x| if (x.cpus == cpus and x.memory_mb == memory_mb and x.entropy == entropy and x.balloon == balloon) return x;
        const x = pa.create(SpareSet) catch return null;
        x.* = .{ .cpus = cpus, .memory_mb = memory_mb, .entropy = entropy, .balloon = balloon };
        spares.append(pa, x) catch {
            pa.destroy(x);
            return null;
        };
        return x;
    }

    fn makeSpare(x: *SpareSet) ?Spare {
        var pair: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS) return null;
        const m = kvm.init(pa, .{ .kernel = "", .cmdline = "", .cpus = x.cpus, .memory_mb = x.memory_mb, .entropy = x.entropy, .balloon = x.balloon, .console = pair[0] }) catch {
            sys.close(pair[0]);
            sys.close(pair[1]);
            return null;
        };
        kvm.snapshot.prepare(m) catch {
            m.deinit();
            sys.close(pair[0]);
            sys.close(pair[1]);
            return null;
        };
        return .{ .machine = m, .console_vm = pair[0], .console_host = pair[1] };
    }

    fn spareMain(x: *SpareSet) void {
        while (true) {
            pool_lock.lock();
            if (x.ready.items.len >= x.size) break;
            pool_lock.unlock();
            const sp = makeSpare(x) orelse {
                pool_lock.lock();
                break;
            };
            pool_lock.lock();
            x.ready.append(pa, sp) catch {
                pool_lock.unlock();
                sp.machine.deinit();
                sys.close(sp.console_vm);
                sys.close(sp.console_host);
                pool_lock.lock();
                break;
            };
            pool_lock.unlock();
        }
        x.filling = false;
        pool_lock.unlock();
    }

    /// A prepared machine of the set, or null. Starts a refill to `size`
    /// either way.
    fn takeSpare(x: *SpareSet, size: u32) ?Spare {
        pool_lock.lock();
        const sp = x.ready.pop();
        x.size = size;
        const go = !x.filling and size > 0;
        if (go) x.filling = true;
        pool_lock.unlock();
        if (go) {
            const th = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, spareMain, .{x}) catch {
                pool_lock.lock();
                x.filling = false;
                pool_lock.unlock();
                return sp;
            };
            th.detach();
        }
        return sp;
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
        const th = std.Thread.spawn(.{ .stack_size = thread_stack }, refillMain, .{t}) catch {
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
            x.thread = std.Thread.spawn(.{ .stack_size = thread_stack }, acceptMain, .{x}) catch {
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
        const la = try listenArgs(it, args);
        const port = la.port;
        if (port > std.math.maxInt(u32) - 1) return it.fail("bad port \"{d}\"", .{port});
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
        try g.listens.append(it.heap.backing, .{ .port = @intCast(port), .l = l, .chan = name, .framed = la.framed });
        if (it.findCommand("::ztcl::vmpriv::accept") == null) _ = try it.eval(listen_glue);
        var words = [_]Value{ .{ .str = "::ztcl::vmpriv::accept" }, .{ .str = g.name }, .{ .int = port }, ch, la.script };
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
        return acceptChannel(it, @intCast(fd), g.listens.items[i].framed);
    }

    // ---- The guests of `thread::create -isolation vm` (isovm.zig) ----

    const isovm = @import("isovm.zig");
    const IsoFd = @import("isothread.zig").Fd;

    /// The guest of the vm threads: the bytes of its boot, a snapshot of
    /// it at the listen of the runner (a memfd), and the machines of the
    /// threads that run.
    const IsoTemplate = struct {
        kernel: []u8,
        initrd: []u8,
        cmdline: []u8,
        memory_mb: u32,
        snap_fd: i32 = -1,
        pool_size: u32,
        lock: thread_lock = .{},
        live: std.ArrayList(IsoLive) = .empty,
    };
    const IsoLive = struct { machine: *kvm, console_vm: i32, console_host: i32 };
    var iso_template: ?*IsoTemplate = null;

    fn readHost(path: []const u8) ?[]u8 {
        const z = pa.dupeSentinel(u8, path, 0) catch return null;
        defer pa.free(z);
        const rc = linux.openat(linux.AT.FDCWD, z, .{ .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        defer sys.close(fd);
        const end: i64 = @bitCast(linux.lseek(fd, 0, linux.SEEK.END));
        if (end <= 0) return null;
        const buf = pa.alloc(u8, @intCast(end)) catch return null;
        var off: usize = 0;
        while (off < buf.len) {
            const n = linux.pread(fd, buf[off..].ptr, buf.len - off, @intCast(off));
            if (linux.errno(n) != .SUCCESS or n == 0) {
                pa.free(buf);
                return null;
            }
            off += n;
        }
        return buf;
    }

    pub fn isoSpawner(root: *Interp) ?@import("isothread.zig").Spawner {
        const h = root.vm_host;
        if (h.iso_kernel.len == 0 or h.iso_initrd.len == 0) return null;
        kvm.probe() catch return null;
        pool_lock.lock();
        defer pool_lock.unlock();
        if (iso_template == null) {
            const kernel = readHost(h.iso_kernel) orelse return null;
            const initrd = readHost(h.iso_initrd) orelse {
                pa.free(kernel);
                return null;
            };
            const cmdline = std.fmt.allocPrint(pa, "console=hvc0 quiet rdinit=/sbin/ztcl -- --iso-vsock {d}", .{isovm.port}) catch return null;
            const t = pa.create(IsoTemplate) catch return null;
            t.* = .{ .kernel = kernel, .initrd = initrd, .cmdline = cmdline, .memory_mb = h.iso_memory_mb, .pool_size = @max(h.pool_size, 1) };
            iso_template = t;
        }
        return .{ .ctx = iso_template.?, .spawn = isoSpawn };
    }

    /// Frees the machines of the vm threads that ended: the runner exits
    /// at the end of its thread, and the guest stops.
    fn isoReap(t: *IsoTemplate) void {
        t.lock.lock();
        defer t.lock.unlock();
        var i: usize = 0;
        while (i < t.live.items.len) {
            const l = t.live.items[i];
            switch (l.machine.getState()) {
                .stopped, .failed => {
                    l.machine.deinit();
                    sys.close(l.console_vm);
                    sys.close(l.console_host);
                    _ = t.live.swapRemove(i);
                },
                else => i += 1,
            }
        }
    }

    /// Boots the guest of the runner to its listen, pauses it, and writes
    /// its snapshot to a memfd. The guest stays, paused, for the thread
    /// that asked.
    fn isoBoot(t: *IsoTemplate, l: *IsoLive, made: *bool) bool {
        l.machine = kvm.init(pa, .{ .cpus = 1, .memory_mb = t.memory_mb, .kernel = t.kernel, .initrd = t.initrd, .cmdline = t.cmdline, .console = l.console_vm }) catch return false;
        made.* = true;
        l.machine.start() catch return false;
        // A probe: a connection with no prelude, which the runner closes.
        const fd = connect(l.machine, isovm.port, 10_000) orelse return false;
        sys.close(fd);
        l.machine.pause();
        const rc = linux.memfd_create("ztcl-vm-iso", linux.MFD.CLOEXEC);
        if (linux.errno(rc) == .SUCCESS) {
            const m: i32 = @intCast(rc);
            if (kvm.snapshot.save(l.machine, m, "")) |_| t.snap_fd = m else |_| sys.close(m);
        }
        return true;
    }

    /// The spawn of a vm thread: a clone of the snapshot of the runner
    /// guest in a prepared machine (or a boot, the first time), its
    /// start, a vsock connection to the runner, and the prelude. Gives
    /// the descriptor of the transport.
    fn isoSpawn(ctx: ?*anyopaque) ?IsoFd {
        const t: *IsoTemplate = @ptrCast(@alignCast(ctx.?));
        isoReap(t);
        var pair: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS) return null;
        var l: IsoLive = .{ .machine = undefined, .console_vm = pair[0], .console_host = pair[1] };
        var made = false;
        var restored = false;
        const good = blk: {
            t.lock.lock();
            const snap = t.snap_fd;
            if (snap < 0) {
                const booted = isoBoot(t, &l, &made);
                t.lock.unlock();
                if (!booted) break :blk false;
            } else {
                t.lock.unlock();
                const set = spareSet(1, t.memory_mb, false, true);
                if (set) |x| if (takeSpare(x, t.pool_size)) |sp| {
                    sys.close(l.console_vm);
                    sys.close(l.console_host);
                    l = .{ .machine = sp.machine, .console_vm = sp.console_vm, .console_host = sp.console_host };
                    made = true;
                };
                if (!made) {
                    l.machine = kvm.init(pa, .{ .cpus = 1, .memory_mb = t.memory_mb, .kernel = "", .cmdline = "", .console = l.console_vm }) catch break :blk false;
                    made = true;
                }
                kvm.snapshot.restore(l.machine, snap) catch break :blk false;
                restored = true;
            }
            break :blk true;
        };
        if (!good) {
            if (made) l.machine.deinit();
            sys.close(l.console_vm);
            sys.close(l.console_host);
            return null;
        }
        l.machine.@"resume"();
        if (restored) _ = kvm.snapshot.waitReset(l.machine, 100_000);
        const fd = connectTry(l.machine, isovm.port, 5000, 250) orelse {
            l.machine.deinit();
            sys.close(l.console_vm);
            sys.close(l.console_host);
            return null;
        };
        var rnd: [32]u8 = undefined;
        _ = linux.getrandom(&rnd, rnd.len, 0);
        const p = isovm.prelude(realtimeNs(), &rnd);
        if (linux.write(fd, &p, p.len) != p.len) {
            sys.close(fd);
            l.machine.deinit();
            sys.close(l.console_vm);
            sys.close(l.console_host);
            return null;
        }
        t.lock.lock();
        t.live.append(pa, l) catch {};
        t.lock.unlock();
        return fd;
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
    /// The MB of the memory of a guest that get the map of the hypervisor
    /// after its start, with no `-prefault`: the first allocations of the
    /// guest come from there, and a guest of 1 GB holds 256 MB of the host
    /// at once. A guest of the pool gets none until a `create` uses it.
    const default_prefault_mb: u32 = 256;
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
        /// The guest sends no more (`eof`), and the pump ended the writes of
        /// its end of the pair.
        eof: bool = false,
        eof_sent: bool = false,
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
        /// The shares are virtio-fs (`docs/dev/virtiofs.md`), or 9p with
        /// `ZTCL_VM_SHARE=9p` in the environment, for a guest with no
        /// virtio-fs driver.
        virtiofs: bool = true,
        /// Each virtio-fs share has a DAX window, unless `ZTCL_VM_DAX=0`.
        dax: bool = true,
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
        /// The listeners of `listen`, and the streams of the guest that the
        /// device took for them, as (stream, port), which wait for the pump.
        /// Both under `lock`.
        listens: std.ArrayList(Listen) = .empty,
        accepted: std.ArrayList([2]u32) = .empty,
    };

    /// A listener of `listen`: the end of the pump of its pair of notices,
    /// the name of the channel of the other end, and the ends of the
    /// script of its connections that wait for `accept`.
    const Listen = struct { port: u32, notify: i32, chan: []const u8, waiting: std.ArrayList(i32) = .empty };

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
        if (std.mem.eql(u8, sub, "listen")) return listenCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "unlisten")) return unlistenCmd(it, g, args[3..]);
        if (std.mem.eql(u8, sub, "accept")) return acceptCmd(it, g, args[3..]);
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
        // The MB of the memory that gets the map of the hypervisor after the
        // start (`whp.setPrefault`).
        var prefault_mb: u32 = default_prefault_mb;
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
            } else if (std.mem.eql(u8, opt, "-prefault")) {
                const mb = try it.int(v);
                if (mb < 0) return it.fail("bad -prefault \"{d}\": must be 0 or more", .{mb});
                prefault_mb = @intCast(@min(mb, std.math.maxInt(u32)));
            } else if (std.mem.eql(u8, opt, "-disk")) {
                const l = try it.list(v);
                if (l.len < 1 or l.len > 2) return it.fail("a disk is {{file ?rw?}}", .{});
                if (disks.items.len >= whp.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks", .{whp.max_disks});
                try disks.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 2 and try isRw(it, l[1]) });
            } else if (std.mem.eql(u8, opt, "-share")) {
                const l = try it.list(v);
                if (l.len < 2 or l.len > 3) return it.fail("a share is {{host guest ?rw?}}", .{});
                if (disks.items.len + shares.items.len >= whp.max_disks) return it.failCode("ZTCL VM LIMIT", "a guest has at most {d} disks and shares", .{whp.max_disks});
                try shares.append(a, .{ .path = try it.str(l[0]), .rw = l.len == 3 and try isRw(it, l[2]) });
            } else return it.fail("bad option \"{s}\": must be -cmdline, -cpus, -disk, -entropy, -image, -initrd, -kernel, -memory, -prefault, -share, or -warm", .{opt});
        }
        prefault_mb = @min(prefault_mb, memory_mb);
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
                    // A guest of the pool holds only the memory of its boot
                    // until a create uses it.
                    pg.machine.setPrefault(prefault_mb);
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
        g.virtiofs = !envIs("ZTCL_VM_SHARE", "9p");
        g.dax = g.virtiofs and !envIs("ZTCL_VM_DAX", "0");
        g.shares = try ga.alloc(whp.Share, shares.items.len);
        for (g.shares) |*sh| sh.fd = -1;
        for (shares.items, g.shares) |d, *out| out.* = .{ .fd = try jailDir(it, d.path), .read_only = !d.rw };
        machineOf(g, cpus, memory_mb, entropy, prefault_mb) catch |e| switch (e) {
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
                    g.pump = std.Thread.spawn(.{ .stack_size = thread_stack }, pumpMain, .{g}) catch return error.Thread;
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
        const st = &g.streams[conn];
        switch (e) {
            .connected => st.state = .open,
            .refused => st.state = .refused,
            .closed => st.state = .closed,
            .eof => st.eof = true,
        }
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
            pumpAccepted(g);
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
        // The end of the bytes of the guest, once they are out: the script
        // reads the end, and can still write.
        const half = fd >= 0 and drained and st.eof and !st.eof_sent;
        if (half) st.eof_sent = true;
        g.lock.unlock();
        if (fd < 0) return;
        if (half) sys.shutdown(fd, 1);
        if (s == .closed) {
            // The guest ended the stream: the script reads the end once
            // the bytes of the guest are out.
            if (!drained) return;
            g.lock.lock();
            st.fd = -1;
            st.state = .free;
            st.eof = false;
            st.eof_sent = false;
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

    /// A REQUEST of the guest to `port` of the host, on the vCPU thread:
    /// a stream for a listener, which waits for the pump.
    fn streamAccept(ctx: *anyopaque, conn: u32, port: u32) bool {
        const g = guestOf(ctx);
        g.lock.lock();
        defer g.lock.unlock();
        // The pump still drains the last stream of this slot: RST.
        if (g.streams[conn].fd >= 0) return false;
        for (g.listens.items) |l| {
            if (l.port != port) continue;
            g.accepted.append(ga, .{ conn, port }) catch return false;
            g.streams[conn] = .{ .state = .open, .out = g.streams[conn].out, .in = g.streams[conn].in };
            g.streams[conn].out.clearRetainingCapacity();
            g.streams[conn].in.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    /// The streams of the guest that the device took: a pair for each, the
    /// end of the pump in the stream, and the end of the script as 4 bytes
    /// on the pair of notices of its listener, for `accept`.
    fn pumpAccepted(g: *Guest) void {
        while (true) {
            g.lock.lock();
            if (g.accepted.items.len == 0) {
                g.lock.unlock();
                return;
            }
            const conn, const port = g.accepted.orderedRemove(0);
            g.lock.unlock();
            const p = pair() orelse {
                g.machine.close(conn);
                continue;
            };
            sys.setBlocking(p[0], false);
            g.lock.lock();
            var notify: i32 = -1;
            for (g.listens.items) |*l| if (l.port == port) {
                l.waiting.append(ga, p[1]) catch break;
                notify = l.notify;
                break;
            };
            if (notify >= 0) g.streams[conn].fd = p[0];
            g.lock.unlock();
            if (notify < 0) {
                // The script removed the listener.
                sys.close(p[0]);
                sys.close(p[1]);
                g.machine.close(conn);
                continue;
            }
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, p[1], .little);
            _ = sys.write(notify, &b);
        }
    }

    fn findListen(g: *Guest, port: u32) ?usize {
        for (g.listens.items, 0..) |x, i| if (x.port == port) return i;
        return null;
    }

    /// Closes the channel of a listener and the ends of its connections
    /// that no `accept` took.
    fn dropListen(it: *Interp, x: Listen) void {
        sys.close(x.notify);
        for (x.waiting.items) |fd| sys.close(fd);
        var w = x.waiting;
        w.deinit(ga);
        const script = std.fmt.allocPrint(it.alloc(), "catch {{close {{{s}}}}}", .{x.chan}) catch return;
        _ = it.eval(script) catch {};
        it.heap.backing.free(x.chan);
    }

    /// `listen VM PORT -command SCRIPT`, as on macOS and Linux: the device
    /// of the monitor gets each connection of the guest to the port.
    fn listenCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const use = "ztcl::vm listen vm port -command script";
        if (args.len != 3 or !std.mem.eql(u8, try it.str(args[1]), "-command")) return it.wrongArgs(use);
        const port = try it.int(args[0]);
        if (port < 1 or port > std.math.maxInt(u32) - 1) return it.fail("bad port \"{d}\"", .{port});
        if (it.findCommand("fileevent") == null) return it.failCode("ZTCL VM NOEVENT", "ztcl::vm listen needs the event capability", .{});
        g.lock.lock();
        const had = findListen(g, @intCast(port)) != null;
        g.lock.unlock();
        if (had) return it.failCode("ZTCL VM LISTEN", "the guest {s} has a listener on port {d} already", .{ g.name, port });
        const p = pair() orelse return it.failCode("ZTCL VM WHP", "no pair of sockets for the listener", .{});
        sys.setBlocking(p[0], false);
        const ch = binaryChannel(it, "vmlisten", p[1]) catch |e| {
            sys.close(p[0]);
            sys.close(p[1]);
            return e;
        };
        const name = try it.heap.backing.dupe(u8, try it.str(ch));
        g.lock.lock();
        g.listens.append(ga, .{ .port = @intCast(port), .notify = p[0], .chan = name }) catch {
            g.lock.unlock();
            dropListen(it, .{ .port = @intCast(port), .notify = p[0], .chan = name });
            return error.OutOfMemory;
        };
        g.lock.unlock();
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
        g.lock.lock();
        const i = if (port >= 0 and port <= std.math.maxInt(u32)) findListen(g, @intCast(port)) else null;
        const x: ?Listen = if (i) |k| g.listens.swapRemove(k) else null;
        g.lock.unlock();
        dropListen(it, x orelse return it.failCode("ZTCL VM LISTEN", "the guest {s} has no listener on port {d}", .{ g.name, port }));
        return .{ .str = "" };
    }

    /// `accept VM PORT FD`, from the glue of `listen`: the channel of a
    /// connection that waits on the port.
    fn acceptCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        if (args.len != 2) return it.wrongArgs("ztcl::vm accept vm port fd");
        const port = try it.int(args[0]);
        const fd = try it.int(args[1]);
        g.lock.lock();
        var took = false;
        if (port >= 0 and port <= std.math.maxInt(u32)) if (findListen(g, @intCast(port))) |i| {
            const w = &g.listens.items[i].waiting;
            for (w.items, 0..) |x, k| if (x == fd) {
                _ = w.swapRemove(k);
                took = true;
                break;
            };
        };
        g.lock.unlock();
        if (!took) return it.failCode("ZTCL VM LISTEN", "no connection {d} waits on port {d}", .{ fd, port });
        return binaryChannel(it, "vsock", @intCast(fd));
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

    /// True when the environment variable `name` is `want`, in ASCII.
    fn envIs(comptime name: []const u8, comptime want: []const u8) bool {
        var buf: [16]u16 = undefined;
        const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(name), &buf, buf.len);
        if (n != want.len) return false;
        for (want, buf[0..want.len]) |c, u| if (u != c) return false;
        return true;
    }
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
    /// `mount` through the agent: the share of the tag (virtio-fs, or 9p)
    /// at a path of the guest.
    fn mountCmd(it: *Interp, g: *Guest, args: []const Value) Error!Value {
        const r = try mountArgs(it, args);
        if (g.machine.getState() != .running) return it.failCode("ZTCL VM STATE", "the guest {s} is {s}", .{ g.name, status(g) });
        const fd = connect(g, vmagent.port, 5000) orelse
            return it.failCode("ZTCL VM AGENT", "the agent of the guest {s} did not answer on port {d}", .{ g.name, vmagent.port });
        defer sys.close(fd);
        var a: vmagent.Conn = .{ .fd = fd, .timeout_ms = 5000 };
        _ = a.hello(it.alloc()) catch |e| return agentFail(it, g.name, &a, e);
        return agentMount(it, g.name, &a, r, if (g.virtiofs) .virtiofs else .nine_p);
    }

    /// The console pair and the machine of a guest whose kernel, initramfs,
    /// command line, and disks are in place.
    fn machineOf(g: *Guest, cpus: u32, memory_mb: u32, entropy: bool, prefault_mb: u32) (whp.Fail || error{Pair})!void {
        const con = pair() orelse return error.Pair;
        g.console_vm = con[0];
        g.console_host = con[1];
        sys.setBlocking(g.console_vm, false);
        g.machine = try whp.init(ga, .{
            .cpus = cpus,
            .memory_mb = memory_mb,
            .prefault_mb = prefault_mb,
            .kernel = g.kernel,
            .initrd = g.initrd,
            .cmdline = g.cmdline,
            .disks = g.disks,
            .shares = g.shares,
            .virtiofs = g.virtiofs,
            .dax = g.dax,
            .entropy = entropy,
            .console = .{ .ctx = g, .write = consoleWrite },
            .vsock = .{ .ctx = g, .data = streamData, .event = streamEvent, .accept = streamAccept },
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
            machineOf(g, 1, j.memory_mb, j.entropy, 0) catch break :blk false;
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
        g.lock.lock();
        const ls = g.listens;
        g.listens = .empty;
        g.lock.unlock();
        for (ls.items) |l| dropListen(it, l);
        var copy = ls;
        copy.deinit(ga);
        destroyRaw(g);
        g.accepted.deinit(ga);
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
