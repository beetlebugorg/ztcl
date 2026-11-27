//! The WASI preview 1 imports of the wasm engine, on the capabilities
//! of ztcl.
//!
//! A module that imports from `wasi_snapshot_preview1` gets these host
//! functions. Each function reads its arguments from the linear memory
//! of the instance and gives an errno of WASI. The capabilities of the
//! interpreter gate the reach of each function:
//!
//! - Files: a folder of `-dirs` is a preopened descriptor. Its path is a
//!   path of ztcl, so it is below the root folder of the jail, or a host
//!   path in host mode. A path of the guest resolves inside its preopen:
//!   `..` above the preopen gives ENOTCAPABLE. Each open goes through
//!   `fsroot.zig`. With no `file` capability, a module gets no preopen.
//! - Clocks: `clock_time_get` reads the clock of ztcl (and its recorded
//!   tape) with the `clock` capability. Without it, it gives ENOTCAPABLE.
//! - Random bytes: `random_get` needs the `random` capability.
//! - The arguments and the environment come only from the script.
//! - Standard output and error go through `puts`, so they reach the
//!   channel or the callback of the embedder. Standard input reads the
//!   text of `-stdin`, then the end of the file.
//! - `poll_oneoff` does not sleep: a clock subscription is due at once.
//! - Sockets give ENOTSUP.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("../interp.zig");
const Interp = interp.Interp;
const Value = @import("../value.zig").Value;
const fsroot = @import("../fsroot.zig");
const sys = @import("../sys.zig");
const mod = @import("module.zig");
const exec = @import("exec.zig");

pub const module_name = "wasi_snapshot_preview1";

const E = struct {
    const success: u32 = 0;
    const acces: u32 = 2;
    const again: u32 = 6;
    const badf: u32 = 8;
    const busy: u32 = 10;
    const exist: u32 = 20;
    const fault: u32 = 21;
    const inval: u32 = 28;
    const io: u32 = 29;
    const isdir: u32 = 31;
    const loop: u32 = 32;
    const mfile: u32 = 33;
    const nametoolong: u32 = 37;
    const noent: u32 = 44;
    const nospc: u32 = 51;
    const nosys: u32 = 52;
    const notdir: u32 = 54;
    const notempty: u32 = 55;
    const notsup: u32 = 58;
    const perm: u32 = 63;
    const rofs: u32 = 69;
    const spipe: u32 = 70;
    const xdev: u32 = 75;
    const notcapable: u32 = 76;
};

const FileType = struct {
    const unknown: u8 = 0;
    const char_device: u8 = 2;
    const directory: u8 = 3;
    const regular: u8 = 4;
    const symlink: u8 = 7;
};

const Fd = struct {
    kind: enum { stdin, stdout, stderr, dir, file },
    host: sys.Fd = -1,
    /// The normal path of ztcl.
    rel: []const u8 = "",
    /// The name of a preopen, for `fd_prestat_dir_name`.
    preopen: ?[]const u8 = null,
    append: bool = false,
};

pub const Options = struct {
    args: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    /// Pairs of a guest name and a path of ztcl.
    dirs: []const [2][]const u8 = &.{},
    stdin: []const u8 = "",
};

pub const Wasi = struct {
    it: *Interp,
    gpa: std.mem.Allocator,
    args: [][]u8 = &.{},
    env: [][]u8 = &.{},
    fds: std.ArrayList(?Fd) = .empty,
    stdin: []u8 = &.{},
    stdin_pos: usize = 0,
    mem: ?*exec.Memory = null,
    exit_code: u32 = 0,
    /// The error of a Tcl command inside a call, such as `puts`. It
    /// points to the field of the state of `cmd.zig`.
    pending: *?interp.Error,
    calls: std.ArrayList(*Call) = .empty,

    /// Closes the files, and drops the memory of the deleted instance.
    pub fn closeFds(w: *Wasi) void {
        for (w.fds.items) |*f| if (f.*) |x| {
            if (x.kind == .file) sys.close(x.host);
            w.gpa.free(x.rel);
            if (x.preopen) |p| w.gpa.free(p);
            f.* = null;
        };
        w.mem = null;
    }

    pub fn deinit(w: *Wasi) void {
        for (w.fds.items) |f| if (f) |x| {
            if (x.kind == .file) sys.close(x.host);
            w.gpa.free(x.rel);
            if (x.preopen) |p| w.gpa.free(p);
        };
        w.fds.deinit(w.gpa);
        for (w.args) |x| w.gpa.free(x);
        w.gpa.free(w.args);
        for (w.env) |x| w.gpa.free(x);
        w.gpa.free(w.env);
        w.gpa.free(w.stdin);
        for (w.calls.items) |c| w.gpa.destroy(c);
        w.calls.deinit(w.gpa);
        w.gpa.destroy(w);
    }

    fn slice(w: *Wasi, ptr: u64, len: u64) ?[]u8 {
        const m = w.mem orelse return null;
        const p = ptr & 0xffff_ffff;
        const n = len & 0xffff_ffff;
        if (p + n > m.bytes.len) return null;
        return m.bytes[@intCast(p)..@intCast(p + n)];
    }

    fn put(w: *Wasi, comptime T: type, ptr: u64, v: T) bool {
        const s = w.slice(ptr, @sizeOf(T)) orelse return false;
        std.mem.writeInt(T, s[0..@sizeOf(T)], v, .little);
        return true;
    }

    fn get(w: *Wasi, comptime T: type, ptr: u64) ?T {
        const s = w.slice(ptr, @sizeOf(T)) orelse return null;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn fd(w: *Wasi, n: u64) ?*Fd {
        if (n >= w.fds.items.len) return null;
        if (w.fds.items[@intCast(n)]) |*f| return f;
        return null;
    }

    fn hasCap(w: *const Wasi, c: interp.Capability) bool {
        return w.it.capabilities & @backingInt(c) != 0;
    }
};

/// Makes the WASI state for one instance. The caller sets `mem` after
/// the instantiation.
pub fn create(it: *Interp, gpa: std.mem.Allocator, o: Options, pending: *?interp.Error) !*Wasi {
    const w = try gpa.create(Wasi);
    w.* = .{ .it = it, .gpa = gpa, .pending = pending };
    errdefer w.deinit();
    w.args = try gpa.alloc([]u8, o.args.len);
    for (w.args) |*x| x.* = &.{};
    for (o.args, w.args) |x, *y| y.* = try gpa.dupe(u8, x);
    w.env = try gpa.alloc([]u8, o.env.len);
    for (w.env) |*x| x.* = &.{};
    for (o.env, w.env) |x, *y| y.* = try gpa.dupe(u8, x);
    w.stdin = try gpa.dupe(u8, o.stdin);
    try w.fds.append(gpa, .{ .kind = .stdin });
    try w.fds.append(gpa, .{ .kind = .stdout });
    try w.fds.append(gpa, .{ .kind = .stderr });
    for (o.dirs) |d| try w.fds.append(gpa, .{ .kind = .dir, .rel = try gpa.dupe(u8, d[1]), .preopen = try gpa.dupe(u8, d[0]) });
    return w;
}

pub const Call = struct {
    w: *Wasi,
    def: *const Def,
};

const Impl = *const fn (w: *Wasi, a: []const u64) exec.Error!u32;

const Def = struct {
    name: []const u8,
    /// The params: `i` for i32 and `l` for i64.
    params: []const u8,
    /// True when the function gives an errno.
    result: bool = true,
    impl: Impl,
};

fn types(comptime s: []const u8) []const mod.ValType {
    comptime {
        var out: [s.len]mod.ValType = undefined;
        for (s, 0..) |c, i| out[i] = if (c == 'i') .i32 else .i64;
        const final = out;
        return &final;
    }
}

const one_i32 = [_]mod.ValType{.i32};

/// The type of a definition.
fn typeOf(comptime d: Def) mod.FuncType {
    return .{ .params = types(d.params), .results = if (d.result) &one_i32 else &.{} };
}

fn nosys(_: *Wasi, _: []const u64) exec.Error!u32 {
    return E.nosys;
}

fn notsup(_: *Wasi, _: []const u64) exec.Error!u32 {
    return E.notsup;
}

fn ok(_: *Wasi, _: []const u64) exec.Error!u32 {
    return E.success;
}

const defs = [_]Def{
    .{ .name = "args_get", .params = "ii", .impl = argsGet },
    .{ .name = "args_sizes_get", .params = "ii", .impl = argsSizes },
    .{ .name = "environ_get", .params = "ii", .impl = environGet },
    .{ .name = "environ_sizes_get", .params = "ii", .impl = environSizes },
    .{ .name = "clock_res_get", .params = "ii", .impl = clockRes },
    .{ .name = "clock_time_get", .params = "ili", .impl = clockTime },
    .{ .name = "fd_advise", .params = "illi", .impl = fdCheck },
    .{ .name = "fd_allocate", .params = "ill", .impl = notsup },
    .{ .name = "fd_close", .params = "i", .impl = fdClose },
    .{ .name = "fd_datasync", .params = "i", .impl = fdCheck },
    .{ .name = "fd_fdstat_get", .params = "ii", .impl = fdStat },
    .{ .name = "fd_fdstat_set_flags", .params = "ii", .impl = fdSetFlags },
    .{ .name = "fd_fdstat_set_rights", .params = "ill", .impl = fdCheck },
    .{ .name = "fd_filestat_get", .params = "ii", .impl = fdFilestat },
    .{ .name = "fd_filestat_set_size", .params = "il", .impl = notsup },
    .{ .name = "fd_filestat_set_times", .params = "illi", .impl = notsup },
    .{ .name = "fd_pread", .params = "iiili", .impl = fdPread },
    .{ .name = "fd_prestat_get", .params = "ii", .impl = prestatGet },
    .{ .name = "fd_prestat_dir_name", .params = "iii", .impl = prestatName },
    .{ .name = "fd_pwrite", .params = "iiili", .impl = fdPwrite },
    .{ .name = "fd_read", .params = "iiii", .impl = fdRead },
    .{ .name = "fd_readdir", .params = "iiili", .impl = fdReaddir },
    .{ .name = "fd_renumber", .params = "ii", .impl = fdRenumber },
    .{ .name = "fd_seek", .params = "ilii", .impl = fdSeek },
    .{ .name = "fd_sync", .params = "i", .impl = fdCheck },
    .{ .name = "fd_tell", .params = "ii", .impl = fdTell },
    .{ .name = "fd_write", .params = "iiii", .impl = fdWrite },
    .{ .name = "path_create_directory", .params = "iii", .impl = pathMkdir },
    .{ .name = "path_filestat_get", .params = "iiiii", .impl = pathFilestat },
    .{ .name = "path_filestat_set_times", .params = "iiiilli", .impl = notsup },
    .{ .name = "path_link", .params = "iiiiiii", .impl = notsup },
    .{ .name = "path_open", .params = "iiiiillii", .impl = pathOpen },
    .{ .name = "path_readlink", .params = "iiiiii", .impl = pathReadlink },
    .{ .name = "path_remove_directory", .params = "iii", .impl = pathRmdir },
    .{ .name = "path_rename", .params = "iiiiii", .impl = pathRename },
    .{ .name = "path_symlink", .params = "iiiii", .impl = notsup },
    .{ .name = "path_unlink_file", .params = "iii", .impl = pathUnlink },
    .{ .name = "poll_oneoff", .params = "iiii", .impl = pollOneoff },
    .{ .name = "proc_exit", .params = "i", .result = false, .impl = procExit },
    .{ .name = "proc_raise", .params = "i", .impl = notsup },
    .{ .name = "sched_yield", .params = "", .impl = ok },
    .{ .name = "random_get", .params = "ii", .impl = randomGet },
    .{ .name = "sock_accept", .params = "iii", .impl = notsup },
    .{ .name = "sock_recv", .params = "iiiiii", .impl = notsup },
    .{ .name = "sock_send", .params = "iiiii", .impl = notsup },
    .{ .name = "sock_shutdown", .params = "ii", .impl = notsup },
};

const def_types = blk: {
    var out: [defs.len]mod.FuncType = undefined;
    for (defs, 0..) |d, i| out[i] = typeOf(d);
    break :blk out;
};

fn hostCall(ctx: ?*anyopaque, _: *exec.Store, args: []const u64, results: []u64) exec.Error!void {
    const c: *Call = @ptrCast(@alignCast(ctx.?));
    // Each call of WASI uses one compute unit, as a command does.
    const it = c.w.it;
    if (it.compute_limit == 0) return error.ComputeLimit;
    it.compute_limit -= 1;
    const e = try c.def.impl(c.w, args);
    if (results.len > 0) results[0] = e;
}

/// Gives the host function of the import `name`, or null for a name
/// that WASI preview 1 does not have.
pub fn link(w: *Wasi, s: *exec.Store, name: []const u8) !?u32 {
    for (&defs, 0..) |*d, i| {
        if (!std.mem.eql(u8, d.name, name)) continue;
        const c = try w.gpa.create(Call);
        errdefer w.gpa.destroy(c);
        c.* = .{ .w = w, .def = d };
        try w.calls.append(w.gpa, c);
        return try s.addHost(def_types[i], .{ .ctx = c, .call = hostCall });
    }
    return null;
}

// ---- Arguments and environment ----

fn writeStrings(w: *Wasi, list: []const []const u8, ptrs: u64, buf: u64) u32 {
    var at = buf & 0xffff_ffff;
    for (list, 0..) |s, i| {
        if (!w.put(u32, ptrs + i * 4, @intCast(at))) return E.fault;
        const dst = w.slice(at, s.len + 1) orelse return E.fault;
        @memcpy(dst[0..s.len], s);
        dst[s.len] = 0;
        at += s.len + 1;
    }
    return E.success;
}

fn sizes(w: *Wasi, list: []const []const u8, count: u64, size: u64) u32 {
    var n: usize = 0;
    for (list) |s| n += s.len + 1;
    if (!w.put(u32, count, @intCast(list.len)) or !w.put(u32, size, @intCast(n))) return E.fault;
    return E.success;
}

fn argsGet(w: *Wasi, a: []const u64) exec.Error!u32 {
    return writeStrings(w, w.args, a[0], a[1]);
}
fn argsSizes(w: *Wasi, a: []const u64) exec.Error!u32 {
    return sizes(w, w.args, a[0], a[1]);
}
fn environGet(w: *Wasi, a: []const u64) exec.Error!u32 {
    return writeStrings(w, w.env, a[0], a[1]);
}
fn environSizes(w: *Wasi, a: []const u64) exec.Error!u32 {
    return sizes(w, w.env, a[0], a[1]);
}

// ---- Clock and random ----

fn clockRes(w: *Wasi, a: []const u64) exec.Error!u32 {
    if (!w.hasCap(.clock)) return E.notcapable;
    if (a[0] > 3) return E.inval;
    return if (w.put(u64, a[1], 1000)) E.success else E.fault;
}

fn clockTime(w: *Wasi, a: []const u64) exec.Error!u32 {
    if (!w.hasCap(.clock)) return E.notcapable;
    if (a[0] > 3) return E.inval;
    const it = w.it;
    const h = it.clock_host orelse return E.notcapable;
    const us = @import("../tape.zig").time(it, .clock, h.ctx, h.now) catch |e| return pend(w, e);
    const ns: u64 = @intCast(@max(us, 0) * 1000);
    return if (w.put(u64, a[2], ns)) E.success else E.fault;
}

fn fillRandom(ctx: ?*anyopaque, al: std.mem.Allocator) std.mem.Allocator.Error!?[]const u8 {
    const n: *const usize = @ptrCast(@alignCast(ctx.?));
    const buf = try al.alloc(u8, n.*);
    @import("../isoproto.zig").entropy(buf);
    return buf;
}

fn randomGet(w: *Wasi, a: []const u64) exec.Error!u32 {
    if (!w.hasCap(.random)) return E.notcapable;
    const dst = w.slice(a[0], a[1]) orelse return E.fault;
    var n = dst.len;
    const got = (@import("../tape.zig").bytes(w.it, .random, &n, fillRandom) catch |e| return pend(w, e)) orelse return E.io;
    if (got.len != dst.len) return E.io;
    @memcpy(dst, got);
    return E.success;
}

fn pend(w: *Wasi, e: interp.Error) exec.Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    w.pending.* = e;
    return error.HostError;
}

fn procExit(w: *Wasi, a: []const u64) exec.Error!u32 {
    w.exit_code = @truncate(a[0]);
    return error.Exit;
}

// ---- Descriptors ----

fn fdCheck(w: *Wasi, a: []const u64) exec.Error!u32 {
    return if (w.fd(a[0]) != null) E.success else E.badf;
}

fn fdClose(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    if (f.kind == .file) sys.close(f.host);
    w.gpa.free(f.rel);
    if (f.preopen) |p| w.gpa.free(p);
    w.fds.items[@intCast(a[0])] = null;
    return E.success;
}

fn fdRenumber(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    const to = w.fd(a[1]) orelse return E.badf;
    const keep = f.*;
    if (to.kind == .file) sys.close(to.host);
    w.gpa.free(to.rel);
    if (to.preopen) |p| w.gpa.free(p);
    w.fds.items[@intCast(a[1])] = keep;
    w.fds.items[@intCast(a[0])] = null;
    return E.success;
}

fn fileType(f: *const Fd) u8 {
    return switch (f.kind) {
        .stdin, .stdout, .stderr => FileType.char_device,
        .dir => FileType.directory,
        .file => FileType.regular,
    };
}

fn fdStat(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    const out = w.slice(a[1], 24) orelse return E.fault;
    @memset(out, 0);
    out[0] = fileType(f);
    std.mem.writeInt(u16, out[2..4], if (f.append) 1 else 0, .little);
    std.mem.writeInt(u64, out[8..16], std.math.maxInt(u64), .little);
    std.mem.writeInt(u64, out[16..24], std.math.maxInt(u64), .little);
    return E.success;
}

fn fdSetFlags(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    f.append = a[1] & 1 != 0;
    return E.success;
}

fn writeFilestat(w: *Wasi, ptr: u64, ft: u8, info: ?fsroot.Info) u32 {
    const out = w.slice(ptr, 64) orelse return E.fault;
    @memset(out, 0);
    out[16] = ft;
    if (info) |i| {
        std.mem.writeInt(u64, out[0..8], i.dev, .little);
        std.mem.writeInt(u64, out[8..16], i.ino, .little);
        std.mem.writeInt(u64, out[24..32], i.nlink, .little);
        std.mem.writeInt(u64, out[32..40], i.size, .little);
        std.mem.writeInt(u64, out[40..48], @as(u64, @intCast(@max(i.atime, 0))) * std.time.ns_per_s, .little);
        std.mem.writeInt(u64, out[48..56], @as(u64, @intCast(@max(i.mtime, 0))) * std.time.ns_per_s, .little);
        std.mem.writeInt(u64, out[56..64], @as(u64, @intCast(@max(i.ctime, 0))) * std.time.ns_per_s, .little);
    }
    return E.success;
}

fn typeOfMode(mode: u32) u8 {
    if (fsroot.isDir(mode)) return FileType.directory;
    if (fsroot.isFile(mode)) return FileType.regular;
    if (mode & 0o170000 == 0o120000) return FileType.symlink;
    return FileType.unknown;
}

fn statRel(w: *Wasi, rel: []const u8) exec.Error!union(enum) { ok: fsroot.Info, err: u32 } {
    const r = fsroot.stat(w.it, rel) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = E.notcapable };
    };
    return switch (r) {
        .ok => |i| .{ .ok = i },
        .err => |e| .{ .err = errnoOf(e) },
    };
}

fn fdFilestat(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    if (f.kind != .file and f.kind != .dir) return writeFilestat(w, a[1], FileType.char_device, null);
    switch (try statRel(w, f.rel)) {
        .ok => |i| return writeFilestat(w, a[1], typeOfMode(i.mode), i),
        .err => |e| return e,
    }
}

fn prestatGet(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    const name = f.preopen orelse return E.badf;
    if (!w.put(u32, a[1], 0) or !w.put(u32, a[1] + 4, @intCast(name.len))) return E.fault;
    return E.success;
}

fn prestatName(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    const name = f.preopen orelse return E.badf;
    const out = w.slice(a[1], a[2]) orelse return E.fault;
    if (out.len < name.len) return E.nametoolong;
    @memcpy(out[0..name.len], name);
    return E.success;
}

/// Calls `f(chunk)` for each iovec of the list at `iovs`.
fn eachIovec(w: *Wasi, iovs: u64, n: u64, ctx: anytype, comptime f: anytype) exec.Error!u32 {
    var total: u64 = 0;
    var i: u64 = 0;
    while (i < (n & 0xffff_ffff)) : (i += 1) {
        const ptr = w.get(u32, iovs + i * 8) orelse return E.fault;
        const len = w.get(u32, iovs + i * 8 + 4) orelse return E.fault;
        const buf = w.slice(ptr, len) orelse return E.fault;
        switch (try f(ctx, buf)) {
            .n => |got| {
                total += got;
                if (got < buf.len) break;
            },
            .err => |e| return e,
        }
    }
    ctx.total = total;
    return E.success;
}

const Step = union(enum) { n: usize, err: u32 };

const WriteCtx = struct {
    w: *Wasi,
    f: *Fd,
    total: u64 = 0,
    fn step(c: *WriteCtx, buf: []u8) exec.Error!Step {
        switch (c.f.kind) {
            .stdout, .stderr => {
                const it = c.w.it;
                const text = try it.alloc().dupe(u8, buf);
                const words = [_]Value{ .{ .str = "puts" }, .{ .str = "-nonewline" }, .{ .str = if (c.f.kind == .stdout) "stdout" else "stderr" }, .{ .str = text } };
                _ = @import("../cmds.zig").cmdPuts(it, &words, null) catch |e| return pend(c.w, e);
                return .{ .n = buf.len };
            },
            .file => {
                if (c.f.append) _ = sys.seek(c.f.host, 0, 2);
                var off: usize = 0;
                while (off < buf.len) {
                    switch (sys.writeFile(c.f.host, buf[off..])) {
                        .n => |n| {
                            if (n == 0) break;
                            off += n;
                        },
                        .err => |e| return .{ .err = errnoOf(e) },
                    }
                }
                return .{ .n = off };
            },
            .dir => return .{ .err = E.isdir },
            .stdin => return .{ .err = E.badf },
        }
    }
};

const ReadCtx = struct {
    w: *Wasi,
    f: *Fd,
    total: u64 = 0,
    fn step(c: *ReadCtx, buf: []u8) exec.Error!Step {
        switch (c.f.kind) {
            .stdin => {
                const rest = c.w.stdin[c.w.stdin_pos..];
                const n = @min(rest.len, buf.len);
                @memcpy(buf[0..n], rest[0..n]);
                c.w.stdin_pos += n;
                return .{ .n = n };
            },
            .file => {
                var off: usize = 0;
                while (off < buf.len) {
                    switch (sys.readFile(c.f.host, buf[off..])) {
                        .n => |n| {
                            if (n == 0) break;
                            off += n;
                        },
                        .err => |e| return .{ .err = errnoOf(e) },
                    }
                }
                return .{ .n = off };
            },
            .dir => return .{ .err = E.isdir },
            else => return .{ .err = E.badf },
        }
    }
};

fn fdWrite(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    var c: WriteCtx = .{ .w = w, .f = f };
    const e = try eachIovec(w, a[1], a[2], &c, WriteCtx.step);
    if (e != E.success) return e;
    return if (w.put(u32, a[3], @intCast(c.total))) E.success else E.fault;
}

fn fdRead(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    var c: ReadCtx = .{ .w = w, .f = f };
    const e = try eachIovec(w, a[1], a[2], &c, ReadCtx.step);
    if (e != E.success) return e;
    return if (w.put(u32, a[3], @intCast(c.total))) E.success else E.fault;
}

fn positioned(w: *Wasi, a: []const u64, comptime write: bool) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    if (f.kind != .file) return E.spipe;
    const here = switch (sys.seek(f.host, 0, 1)) {
        .at => |x| x,
        .err => |e| return errnoOf(e),
    };
    defer _ = sys.seek(f.host, here, 0);
    switch (sys.seek(f.host, @bitCast(a[3]), 0)) {
        .at => {},
        .err => |e| return errnoOf(e),
    }
    var e: u32 = undefined;
    var total: u64 = 0;
    if (write) {
        var c: WriteCtx = .{ .w = w, .f = f };
        const keep = f.append;
        f.append = false;
        defer f.append = keep;
        e = try eachIovec(w, a[1], a[2], &c, WriteCtx.step);
        total = c.total;
    } else {
        var c: ReadCtx = .{ .w = w, .f = f };
        e = try eachIovec(w, a[1], a[2], &c, ReadCtx.step);
        total = c.total;
    }
    if (e != E.success) return e;
    return if (w.put(u32, a[4], @intCast(total))) E.success else E.fault;
}

fn fdPread(w: *Wasi, a: []const u64) exec.Error!u32 {
    return positioned(w, a, false);
}

fn fdPwrite(w: *Wasi, a: []const u64) exec.Error!u32 {
    return positioned(w, a, true);
}

fn fdSeek(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    if (f.kind == .dir) return E.badf;
    if (f.kind != .file) return E.spipe;
    if (a[2] > 2) return E.inval;
    switch (sys.seek(f.host, @bitCast(a[1]), @intCast(a[2]))) {
        .at => |x| return if (w.put(u64, a[3], @intCast(x))) E.success else E.fault,
        .err => |e| return errnoOf(e),
    }
}

fn fdTell(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    if (f.kind != .file) return E.spipe;
    switch (sys.seek(f.host, 0, 1)) {
        .at => |x| return if (w.put(u64, a[1], @intCast(x))) E.success else E.fault,
        .err => |e| return errnoOf(e),
    }
}

fn fdReaddir(w: *Wasi, a: []const u64) exec.Error!u32 {
    const f = w.fd(a[0]) orelse return E.badf;
    if (f.kind != .dir) return E.notdir;
    const it = w.it;
    const names = switch (fsroot.listDir(it, f.rel) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return E.notcapable;
    }) {
        .ok => |x| x,
        .err => |e| return errnoOf(e),
    };
    const buf = w.slice(a[1], a[2]) orelse return E.fault;
    var used: usize = 0;
    var i: u64 = a[3];
    // Entries 0 and 1 are `.` and `..`.
    while (i < names.len + 2 and used < buf.len) : (i += 1) {
        const name: []const u8 = if (i == 0) "." else if (i == 1) ".." else names[@intCast(i - 2)];
        var hdr: [24]u8 = @splat(0);
        std.mem.writeInt(u64, hdr[0..8], i + 1, .little);
        std.mem.writeInt(u32, hdr[16..20], @intCast(name.len), .little);
        var ft: u8 = FileType.directory;
        if (i >= 2) {
            const rel = try std.fmt.allocPrint(it.alloc(), "{s}{s}{s}", .{ f.rel, if (f.rel.len > 0 and f.rel[f.rel.len - 1] != '/') "/" else "", name });
            ft = switch (try statRel(w, if (it.fs.host or f.rel.len > 0) rel else name)) {
                .ok => |info| blk: {
                    std.mem.writeInt(u64, hdr[8..16], info.ino, .little);
                    break :blk typeOfMode(info.mode);
                },
                .err => FileType.unknown,
            };
        }
        hdr[20] = ft;
        const n1 = @min(hdr.len, buf.len - used);
        @memcpy(buf[used .. used + n1], hdr[0..n1]);
        used += n1;
        const n2 = @min(name.len, buf.len - used);
        @memcpy(buf[used .. used + n2], name[0..n2]);
        used += n2;
    }
    return if (w.put(u32, a[4], @intCast(used))) E.success else E.fault;
}

// ---- Paths ----

const PathResult = union(enum) { rel: []const u8, err: u32 };

/// The normal path of ztcl for a guest path below the folder `dirfd`.
fn resolve(w: *Wasi, dirfd: u64, ptr: u64, len: u64) exec.Error!PathResult {
    if (!w.hasCap(.file)) return .{ .err = E.notcapable };
    const f = w.fd(dirfd) orelse return .{ .err = E.badf };
    if (f.kind != .dir) return .{ .err = E.notdir };
    const p = w.slice(ptr, len) orelse return .{ .err = E.fault };
    if (p.len > 0 and p[0] == '/') return .{ .err = E.notcapable };
    const it = w.it;
    const base = f.rel;
    const text = if (it.fs.host)
        try std.fmt.allocPrint(it.alloc(), "{s}/{s}", .{ base, p })
    else
        try std.fmt.allocPrint(it.alloc(), "/{s}/{s}", .{ base, p });
    const norm = (fsroot.normal(it, text) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = E.notcapable };
    }) orelse return .{ .err = E.notcapable };
    // The path must stay inside the preopen.
    const inside = base.len == 0 and !it.fs.host or std.mem.eql(u8, norm, base) or
        (std.mem.startsWith(u8, norm, base) and (norm.len > base.len and (norm[base.len] == '/' or base[base.len - 1] == '/')));
    if (!inside) return .{ .err = E.notcapable };
    return .{ .rel = norm };
}

fn pathFilestat(w: *Wasi, a: []const u64) exec.Error!u32 {
    const rel = switch (try resolve(w, a[0], a[2], a[3])) {
        .rel => |r| r,
        .err => |e| return e,
    };
    switch (try statRel(w, rel)) {
        .ok => |i| return writeFilestat(w, a[4], typeOfMode(i.mode), i),
        .err => |e| return e,
    }
}

fn pathReadlink(w: *Wasi, a: []const u64) exec.Error!u32 {
    switch (try resolve(w, a[0], a[1], a[2])) {
        .rel => return E.inval,
        .err => |e| return e,
    }
}

fn pathOpen(w: *Wasi, a: []const u64) exec.Error!u32 {
    const rel = switch (try resolve(w, a[0], a[2], a[3])) {
        .rel => |r| r,
        .err => |e| return e,
    };
    const oflags = a[4];
    const rights = a[5];
    const fdflags = a[7];
    const creat = oflags & 1 != 0;
    const want_dir = oflags & 2 != 0;
    const excl = oflags & 4 != 0;
    const trunc = oflags & 8 != 0;
    const wr = rights & (1 << 6) != 0 or trunc or fdflags & 1 != 0;
    const rd = rights & (1 << 1) != 0 or !wr;
    const it = w.it;
    // A folder opens as a path, for the calls of `fd_readdir` and the paths below it.
    const st = try statRel(w, rel);
    const is_dir = st == .ok and fsroot.isDir(st.ok.mode);
    if (want_dir or (is_dir and !wr)) {
        if (st == .err) return st.err;
        if (!is_dir) return E.notdir;
        if (creat and excl) return E.exist;
        return addFd(w, .{ .kind = .dir, .rel = try w.gpa.dupe(u8, rel) }, a[8]);
    }
    if (is_dir) return E.isdir;
    const flags: sys.OpenFlags = .{
        .access = if (rd and wr) .read_write else if (wr) .write else .read,
        .create = creat,
        .exclusive = excl,
        .truncate = trunc,
        .append = fdflags & 1 != 0,
    };
    const r = fsroot.openRel(it, rel, flags, 0o666) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return E.notcapable;
    };
    switch (r) {
        .fd => |hfd| {
            const n = addFd(w, .{ .kind = .file, .host = hfd, .rel = w.gpa.dupe(u8, rel) catch {
                sys.close(hfd);
                return error.OutOfMemory;
            }, .append = fdflags & 1 != 0 }, a[8]);
            return n;
        },
        .err => |e| return errnoOf(e),
    }
}

fn addFd(w: *Wasi, f: Fd, out: u64) exec.Error!u32 {
    var idx: usize = w.fds.items.len;
    for (w.fds.items, 0..) |x, i| if (x == null) {
        idx = i;
        break;
    };
    if (!w.put(u32, out, @intCast(idx))) {
        if (f.kind == .file) sys.close(f.host);
        w.gpa.free(f.rel);
        return E.fault;
    }
    if (idx == w.fds.items.len) {
        w.fds.append(w.gpa, f) catch {
            if (f.kind == .file) sys.close(f.host);
            w.gpa.free(f.rel);
            return error.OutOfMemory;
        };
    } else w.fds.items[idx] = f;
    return E.success;
}

fn parentOp(w: *Wasi, rel: []const u8) exec.Error!union(enum) { ok: fsroot.Parent, err: u32 } {
    const r = fsroot.parentOf(w.it, rel) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = E.notcapable };
    };
    return switch (r) {
        .ok => |p| .{ .ok = p },
        .err => |e| .{ .err = errnoOf(e) },
    };
}

fn closeParent(_: *Wasi, p: fsroot.Parent) void {
    // A close of AT_FDCWD in host mode has no effect.
    sys.close(p.fd);
}

fn pathMkdir(w: *Wasi, a: []const u64) exec.Error!u32 {
    const rel = switch (try resolve(w, a[0], a[1], a[2])) {
        .rel => |r| r,
        .err => |e| return e,
    };
    const p = switch (try parentOp(w, rel)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    defer closeParent(w, p);
    return if (fsroot.mkdirAt(p)) |e| errnoOf(e) else E.success;
}

fn removePath(w: *Wasi, a: []const u64, dir: bool) exec.Error!u32 {
    const rel = switch (try resolve(w, a[0], a[1], a[2])) {
        .rel => |r| r,
        .err => |e| return e,
    };
    const p = switch (try parentOp(w, rel)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    defer closeParent(w, p);
    return if (fsroot.removeAt(p, dir)) |e| errnoOf(e) else E.success;
}

fn pathRmdir(w: *Wasi, a: []const u64) exec.Error!u32 {
    return removePath(w, a, true);
}

fn pathUnlink(w: *Wasi, a: []const u64) exec.Error!u32 {
    return removePath(w, a, false);
}

fn pathRename(w: *Wasi, a: []const u64) exec.Error!u32 {
    const from = switch (try resolve(w, a[0], a[1], a[2])) {
        .rel => |r| r,
        .err => |e| return e,
    };
    const to = switch (try resolve(w, a[3], a[4], a[5])) {
        .rel => |r| r,
        .err => |e| return e,
    };
    const p = switch (try parentOp(w, from)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    defer closeParent(w, p);
    const q = switch (try parentOp(w, to)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    defer closeParent(w, q);
    return if (fsroot.renameAt(p, q)) |e| errnoOf(e) else E.success;
}

// ---- Poll ----

fn pollOneoff(w: *Wasi, a: []const u64) exec.Error!u32 {
    const n = a[2] & 0xffff_ffff;
    if (n == 0) return E.inval;
    const subs = w.slice(a[0], n * 48) orelse return E.fault;
    const events = w.slice(a[1], n * 32) orelse return E.fault;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = subs[i * 48 ..][0..48];
        const e = events[i * 32 ..][0..32];
        @memset(e, 0);
        @memcpy(e[0..8], s[0..8]);
        const tag = s[8];
        e[10] = tag;
        if (tag == 1 or tag == 2) {
            const fdn = std.mem.readInt(u32, s[16..20], .little);
            if (w.fd(fdn) == null) std.mem.writeInt(u16, e[8..10], E.badf, .little);
        } else if (tag != 0) {
            std.mem.writeInt(u16, e[8..10], E.inval, .little);
        }
    }
    return if (w.put(u32, a[3], @intCast(n))) E.success else E.fault;
}

// ---- Errors ----

/// The errno of WASI for a host error.
fn errnoOf(e: sys.Errno) u32 {
    const pairs = .{
        .{ "NOENT", E.noent },       .{ "ACCES", E.acces },             .{ "PERM", E.perm },
        .{ "EXIST", E.exist },       .{ "NOTDIR", E.notdir },           .{ "ISDIR", E.isdir },
        .{ "NOTEMPTY", E.notempty }, .{ "INVAL", E.inval },             .{ "BADF", E.badf },
        .{ "LOOP", E.loop },         .{ "NAMETOOLONG", E.nametoolong }, .{ "NOSPC", E.nospc },
        .{ "MFILE", E.mfile },       .{ "XDEV", E.xdev },               .{ "ROFS", E.rofs },
        .{ "BUSY", E.busy },         .{ "AGAIN", E.again },             .{ "SPIPE", E.spipe },
    };
    const T = @TypeOf(e);
    if (@typeInfo(T) != .@"enum") return E.io;
    inline for (pairs) |p| {
        if (@hasField(T, p[0]) and e == @field(T, p[0])) return p[1];
    }
    return E.io;
}
