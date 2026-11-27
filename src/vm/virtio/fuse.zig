//! A server of the FUSE protocol for the virtio-fs device (`fs.zig`), on
//! the `Fs` of the backends of 9p (`ninep.zig`): the files of a share of
//! the host, by path. The plan is `docs/dev/virtiofs.md`, and the layouts
//! of the messages are in `docs/references/virtiofs.md`.
//!
//! The guest names a file by a node ID. The server keeps a table of node
//! ID to path with a count of lookups: each reply that gives a node (a
//! LOOKUP, a CREATE, a MKDIR, an entry of READDIRPLUS) adds one, and
//! FORGET and BATCH_FORGET take them off. A node at 0 goes. The root is
//! node 1, with the path "". A rename moves the path of each node at and
//! below the old path. A file handle (`fh`) is the handle of the `Fs`.
//!
//! Each reply gives the guest a time to keep a name and a set of
//! attributes (`ttl_ns`, 1 s by default). A read and a write carry up to
//! `max_pages` pages, so a large file moves in messages of 1 MiB, where
//! the 9p client of Linux sends one page in each message.
//!
//! This file makes no system calls. An error is a Linux errno, sent as
//! its negative in the reply header with no payload.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const ninep = @import("ninep.zig");

const Fs = ninep.Fs;
const Attr = ninep.Attr;
const E = ninep.E;

pub const op = struct {
    pub const lookup = 1;
    pub const forget = 2;
    pub const getattr = 3;
    pub const setattr = 4;
    pub const readlink = 5;
    pub const symlink = 6;
    pub const mknod = 8;
    pub const mkdir = 9;
    pub const unlink = 10;
    pub const rmdir = 11;
    pub const rename = 12;
    pub const link = 13;
    pub const open = 14;
    pub const read = 15;
    pub const write = 16;
    pub const statfs = 17;
    pub const release = 18;
    pub const fsync = 20;
    pub const flush = 25;
    pub const init = 26;
    pub const opendir = 27;
    pub const readdir = 28;
    pub const releasedir = 29;
    pub const fsyncdir = 30;
    pub const access = 34;
    pub const create = 35;
    pub const interrupt = 36;
    pub const destroy = 38;
    pub const batch_forget = 42;
    pub const readdirplus = 44;
    pub const rename2 = 45;
    pub const setupmapping = 48;
    pub const removemapping = 49;
};

/// The flags of FUSE_INIT that the server accepts from the guest.
pub const init_flag = struct {
    pub const async_read: u32 = 1 << 0;
    pub const atomic_o_trunc: u32 = 1 << 3;
    pub const big_writes: u32 = 1 << 5;
    pub const do_readdirplus: u32 = 1 << 13;
    pub const readdirplus_auto: u32 = 1 << 14;
    pub const parallel_dirops: u32 = 1 << 18;
    pub const max_pages: u32 = 1 << 22;
    pub const map_alignment: u32 = 1 << 26;
    pub const init_ext: u32 = 1 << 30;
};

/// The flags of `flags2` of FUSE_INIT, with FUSE_INIT_EXT.
pub const init_flag2 = struct {
    pub const has_inode_dax: u32 = 1 << 1;
};

/// FUSE_ATTR_DAX in the `flags` of fuse_attr: the guest maps the file
/// in the DAX window.
pub const attr_dax: u32 = 1 << 1;

/// A regular file has FUSE_ATTR_DAX at this size or more, or at 0 bytes:
/// a small file costs less to read with FUSE_READ than with a mapping of
/// its own, and a new file gets the writes of DAX, which skip the page
/// cache of the guest.
pub const dax_min: u64 = 256 << 10;

/// The write flag of fuse_setupmapping_in.
const setupmapping_write: u64 = 1 << 0;

/// The DAX window of a device: the monitor maps a range of an open file
/// at an offset in the window, and removes ranges. Each call gives 0 or
/// a Linux errno.
pub const Dax = struct {
    ctx: *anyopaque,
    /// The size of the window in bytes.
    size: u64,
    /// The alignment of a mapping, as a power of 2: of the offset in
    /// the file, the offset in the window, and the length.
    align_log2: u16,
    setup: *const fn (ctx: *anyopaque, node: u64, fh: u64, foffset: u64, len: u64, write: bool, moffset: u64) u32,
    remove: *const fn (ctx: *anyopaque, moffset: u64, len: u64) u32,
    /// Drops the host views of the mappings of a node, and keeps the
    /// ranges: the next access of the guest maps them again. The server
    /// calls it before a change of the size or the name of a file, and
    /// at its release, so the host can change the file.
    drop: *const fn (ctx: *anyopaque, node: u64) void,
    /// The guest has no open handle of the node (`on`), or has one again:
    /// the monitor drops the views of an idle node after a while.
    idle: *const fn (ctx: *anyopaque, node: u64, on: bool) void,
    /// Removes each mapping, at the end of a session.
    clear: *const fn (ctx: *anyopaque) void,
};

const fattr = struct {
    const mode: u32 = 1 << 0;
    const uid: u32 = 1 << 1;
    const gid: u32 = 1 << 2;
    const size: u32 = 1 << 3;
    const atime: u32 = 1 << 4;
    const mtime: u32 = 1 << 5;
    const atime_now: u32 = 1 << 7;
    const mtime_now: u32 = 1 << 8;
};

pub const in_header_len = 40;
pub const out_header_len = 16;
const attr_len = 88;
const entry_out_len = 40 + attr_len;
const attr_out_len = 16 + attr_len;
/// The most pages of a read or a write, and their bytes.
pub const max_pages = 256;
pub const max_write = max_pages * 4096;

const Node = struct {
    path: []u8,
    lookups: u64,
    /// The open handles of the guest for the node.
    opens: u32 = 0,
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    fs: Fs,
    nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty,
    /// The node of each path, so a second lookup gives the same node.
    by_path: std.StringHashMapUnmanaged(u64) = .empty,
    next_node: u64 = 2,
    /// The time that the guest keeps a name and its attributes.
    ttl_ns: u64 = std.time.ns_per_s,
    /// The minor version of the protocol of the session, from FUSE_INIT.
    minor: u32 = 0,
    /// The buffer of a request in one piece.
    req: []u8 = &.{},
    rep: []u8 = &.{},
    bad_chains: u64 = 0,
    /// The DAX window of the device, when it has one.
    dax: ?Dax = null,
    /// The guest uses DAX for each file that has FUSE_ATTR_DAX
    /// (FUSE_HAS_INODE_DAX of FUSE_INIT).
    inode_dax: bool = false,

    pub fn init(alloc: std.mem.Allocator, fs: Fs) Server {
        return .{ .alloc = alloc, .fs = fs };
    }

    pub fn deinit(s: *Server) void {
        s.reset();
        s.nodes.deinit(s.alloc);
        s.by_path.deinit(s.alloc);
        s.alloc.free(s.req);
        s.alloc.free(s.rep);
        s.req = &.{};
        s.rep = &.{};
    }

    /// The end of a session: each node goes. The handles of the `Fs` are
    /// the guest's to release, and a reset of the device drops them with
    /// the session.
    pub fn reset(s: *Server) void {
        var it = s.nodes.valueIterator();
        while (it.next()) |n| s.alloc.free(n.path);
        s.nodes.clearRetainingCapacity();
        s.by_path.clearRetainingCapacity();
        s.next_node = 2;
        s.minor = 0;
        s.inode_dax = false;
        if (s.dax) |d| d.clear(d.ctx);
    }

    /// The configuration of the device: the tag in 36 bytes, padded with
    /// zeros, and one request queue.
    pub fn config(tag: []const u8, out: []u8) u8 {
        @memset(out[0..44], 0);
        const n = @min(tag.len, 36);
        @memcpy(out[0..n], tag[0..n]);
        std.mem.writeInt(u32, out[36..40], 1, .little);
        return 44;
    }

    /// The path of a node, or null for a node that the server does not
    /// know.
    fn pathOf(s: *Server, node: u64) ?[]const u8 {
        if (node == 1) return "";
        const n = s.nodes.getPtr(node) orelse return null;
        return n.path;
    }

    /// The node of `path`, with one more lookup.
    fn nodeOf(s: *Server, path: []const u8) !u64 {
        if (path.len == 0) return 1;
        if (s.by_path.get(path)) |id| {
            s.nodes.getPtr(id).?.lookups += 1;
            return id;
        }
        const p = try s.alloc.dupe(u8, path);
        errdefer s.alloc.free(p);
        const id = s.next_node;
        try s.nodes.put(s.alloc, id, .{ .path = p, .lookups = 1 });
        errdefer _ = s.nodes.remove(id);
        try s.by_path.put(s.alloc, p, id);
        s.next_node += 1;
        return id;
    }

    fn forgetNode(s: *Server, node: u64, count: u64) void {
        if (node == 1) return;
        const n = s.nodes.getPtr(node) orelse return;
        n.lookups -|= count;
        if (n.lookups != 0) return;
        if (s.by_path.get(n.path)) |id| if (id == node) {
            _ = s.by_path.remove(n.path);
        };
        s.alloc.free(n.path);
        _ = s.nodes.remove(node);
    }

    /// The paths of the nodes at and below `old` move to `new`.
    fn moved(s: *Server, old: []const u8, new: []const u8) void {
        var it = s.nodes.iterator();
        while (it.next()) |e| {
            const p = e.value_ptr.path;
            const under = std.mem.eql(u8, p, old) or
                (p.len > old.len and std.mem.startsWith(u8, p, old) and p[old.len] == '/');
            if (!under) continue;
            const np = std.mem.concat(s.alloc, u8, &.{ new, p[old.len..] }) catch continue;
            if (s.by_path.get(p)) |id| if (id == e.key_ptr.*) {
                _ = s.by_path.remove(p);
            };
            s.alloc.free(p);
            e.value_ptr.path = np;
            s.by_path.put(s.alloc, np, e.key_ptr.*) catch {};
        }
    }

    /// A name that left the folder: its node keeps its path until FORGET,
    /// and a new file of the name gets a new node.
    fn gone(s: *Server, path: []const u8) void {
        _ = s.by_path.remove(path);
    }

    /// Runs each chain of the queue `q`. True when a chain was used.
    pub fn run(s: *Server, q: *Queue, mem: Mem) bool {
        var any = false;
        while (q.next(mem)) |head| {
            any = true;
            q.putUsed(mem, head, s.one(q, mem, head));
        }
        return any;
    }

    /// Runs one chain, and gives the count of bytes of its answer.
    fn one(s: *Server, q: *Queue, mem: Mem, head: u16) u32 {
        const c = Chain.read(q, mem, head) orelse {
            s.bad_chains += 1;
            return 0;
        };
        var in_len: usize = 0;
        var out_len: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (w) out_len += b.len else in_len += b.len;
        }
        if (in_len < in_header_len) return 0;
        const cap = max_write + 4096;
        if (s.req.len < cap) {
            s.alloc.free(s.req);
            s.alloc.free(s.rep);
            s.req = &.{};
            s.rep = &.{};
            s.req = s.alloc.alloc(u8, cap) catch return 0;
            s.rep = s.alloc.alloc(u8, cap) catch return 0;
        }
        var n: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (w) continue;
            const k = @min(b.len, s.req.len - n);
            @memcpy(s.req[n..][0..k], b[0..k]);
            n += k;
        }
        const len = s.handle(s.req[0..n], s.rep[0..@min(out_len, s.rep.len)]);
        var off: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (!w or off >= len) continue;
            const k = @min(b.len, len - off);
            @memcpy(b[0..k], s.rep[off..][0..k]);
            off += k;
        }
        return @intCast(len);
    }

    /// Answers one request in `out`, and gives the length of the answer:
    /// 0 for a request with no reply (FORGET, BATCH_FORGET, INTERRUPT).
    pub fn handle(s: *Server, msg: []const u8, out: []u8) usize {
        if (msg.len < in_header_len or out.len < out_header_len) return 0;
        const len = std.mem.readInt(u32, msg[0..4], .little);
        const opcode = std.mem.readInt(u32, msg[4..8], .little);
        const unique = std.mem.readInt(u64, msg[8..16], .little);
        const node = std.mem.readInt(u64, msg[16..24], .little);
        const body = msg[in_header_len..@min(@max(len, in_header_len), msg.len)];
        switch (opcode) {
            op.forget => {
                if (body.len >= 8) s.forgetNode(node, std.mem.readInt(u64, body[0..8], .little));
                return 0;
            },
            op.batch_forget => {
                if (body.len < 8) return 0;
                const count = std.mem.readInt(u32, body[0..4], .little);
                var k: usize = 0;
                while (k < count and 8 + 16 * (k + 1) <= body.len) : (k += 1) {
                    const at = 8 + 16 * k;
                    s.forgetNode(std.mem.readInt(u64, body[at..][0..8], .little), std.mem.readInt(u64, body[at + 8 ..][0..8], .little));
                }
                return 0;
            },
            op.interrupt => return 0,
            else => {},
        }
        var w: Writer = .{ .b = out, .n = out_header_len };
        const err = s.dispatch(opcode, node, body, &w);
        if (err != 0 or w.over) w.n = out_header_len;
        std.mem.writeInt(u32, out[0..4], @intCast(w.n), .little);
        const status: i32 = if (err != 0) -@as(i32, @intCast(err)) else if (w.over) -@as(i32, E.IO) else 0;
        std.mem.writeInt(i32, out[4..8], status, .little);
        std.mem.writeInt(u64, out[8..16], unique, .little);
        return w.n;
    }

    fn dispatch(s: *Server, opcode: u32, node: u64, body: []const u8, w: *Writer) u32 {
        const vt = s.fs.vt;
        const ctx = s.fs.ctx;
        const ro = s.fs.read_only;
        if (opcode == op.init) return s.initSession(body, w);
        if (opcode == op.destroy) return 0;
        if (opcode == op.removemapping) return s.mapping(opcode, node, "", body);
        const path = s.pathOf(node) orelse return E.NOENT;
        if (opcode == op.setupmapping) return s.mapping(opcode, node, path, body);
        var buf: [ninep.max_path]u8 = undefined;
        switch (opcode) {
            op.lookup => {
                const name = cstr(body) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.NOENT;
                return s.entry(p, w);
            },
            op.getattr => {
                var a: Attr = .{};
                const e = vt.stat(ctx, path, &a);
                if (e != 0) return e;
                s.attrOut(&a, w);
                return 0;
            },
            op.setattr => {
                if (body.len < 88) return E.INVAL;
                if (ro) return E.ROFS;
                const valid = rd32(body, 0);
                var sa: ninep.SetAttr = .{};
                if (valid & fattr.mode != 0) sa.mode = rd32(body, 68);
                if (valid & fattr.uid != 0) sa.uid = rd32(body, 76);
                if (valid & fattr.gid != 0) sa.gid = rd32(body, 80);
                if (valid & fattr.size != 0) sa.size = rd64(body, 16);
                if (valid & fattr.atime_now != 0) sa.atime = .now else if (valid & fattr.atime != 0) sa.atime = .{ .at = .{ .sec = rd64(body, 32), .nsec = rd32(body, 56) } };
                if (valid & fattr.mtime_now != 0) sa.mtime = .now else if (valid & fattr.mtime != 0) sa.mtime = .{ .at = .{ .sec = rd64(body, 40), .nsec = rd32(body, 60) } };
                if (sa.size != null) s.dropNode(node);
                var e = vt.setattr(ctx, path, sa);
                if (e != 0) return e;
                var a: Attr = .{};
                e = vt.stat(ctx, path, &a);
                if (e != 0) return e;
                s.attrOut(&a, w);
                return 0;
            },
            op.readlink => {
                const room = w.b.len -| w.n;
                var n: usize = 0;
                const e = vt.readlink(ctx, path, w.b[w.n..][0..@min(room, ninep.max_path)], &n);
                if (e != 0) return e;
                w.n += n;
                return 0;
            },
            op.symlink => {
                if (ro) return E.ROFS;
                const name = cstr(body) orelse return E.INVAL;
                const target = cstr(body[name.len + 1 ..]) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.INVAL;
                const e = vt.symlink(ctx, path, name, target);
                if (e != 0) return e;
                return s.entry(p, w);
            },
            op.mknod => {
                if (body.len < 16) return E.INVAL;
                if (ro) return E.ROFS;
                const mode = rd32(body, 0);
                // Only a regular file, as `open` with O_CREAT makes it.
                if (mode & 0o170000 != 0o100000) return E.PERM;
                const name = cstr(body[16..]) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.INVAL;
                var h: u64 = 0;
                const e = vt.create(ctx, path, name, ninep.O.WRONLY | ninep.O.EXCL, mode & 0o7777, &h);
                if (e != 0) return e;
                vt.close(ctx, h);
                return s.entry(p, w);
            },
            op.mkdir => {
                if (body.len < 8) return E.INVAL;
                if (ro) return E.ROFS;
                const name = cstr(body[8..]) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.INVAL;
                const e = vt.mkdir(ctx, path, name, rd32(body, 0) & 0o7777);
                if (e != 0) return e;
                return s.entry(p, w);
            },
            op.unlink, op.rmdir => {
                if (ro) return E.ROFS;
                const name = cstr(body) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.INVAL;
                s.dropPath(p);
                const e = vt.unlink(ctx, path, name, opcode == op.rmdir);
                if (e != 0) return e;
                s.gone(p);
                return 0;
            },
            op.rename, op.rename2 => {
                if (ro) return E.ROFS;
                const head: usize = if (opcode == op.rename2) 16 else 8;
                if (body.len < head) return E.INVAL;
                if (opcode == op.rename2 and rd32(body, 8) != 0) return E.INVAL;
                const new_path = s.pathOf(rd64(body, 0)) orelse return E.NOENT;
                const name = cstr(body[head..]) orelse return E.INVAL;
                const new_name = cstr(body[head + name.len + 1 ..]) orelse return E.INVAL;
                const old = child(&buf, path, name) orelse return E.INVAL;
                var buf2: [ninep.max_path]u8 = undefined;
                const new = child(&buf2, new_path, new_name) orelse return E.INVAL;
                s.dropPath(old);
                s.dropPath(new);
                const e = vt.rename(ctx, path, name, new_path, new_name);
                if (e != 0) return e;
                s.gone(new);
                s.moved(old, new);
                return 0;
            },
            op.link => {
                if (body.len < 8) return E.INVAL;
                if (ro) return E.ROFS;
                const from = s.pathOf(rd64(body, 0)) orelse return E.NOENT;
                const name = cstr(body[8..]) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.INVAL;
                const e = vt.link(ctx, from, path, name);
                if (e != 0) return e;
                return s.entry(p, w);
            },
            op.open, op.opendir => {
                if (body.len < 8) return E.INVAL;
                var flags = rd32(body, 0) & (ninep.O.ACCMODE | ninep.O.TRUNC | ninep.O.APPEND | ninep.O.SYNC | ninep.O.DSYNC);
                if (opcode == op.opendir) flags = ninep.O.RDONLY | ninep.O.DIRECTORY;
                if (ro and (flags & ninep.O.ACCMODE != ninep.O.RDONLY or flags & ninep.O.TRUNC != 0)) return E.ROFS;
                // Windows truncates no file with a view.
                if (flags & ninep.O.TRUNC != 0) s.dropNode(node);
                var h: u64 = 0;
                const e = vt.open(ctx, path, flags, &h);
                if (e != 0) return e;
                if (opcode == op.open) s.opened(node);
                openOut(h, w);
                return 0;
            },
            op.create => {
                if (body.len < 16) return E.INVAL;
                if (ro) return E.ROFS;
                const flags = rd32(body, 0) & (ninep.O.ACCMODE | ninep.O.TRUNC | ninep.O.APPEND | ninep.O.EXCL | ninep.O.SYNC | ninep.O.DSYNC);
                const name = cstr(body[16..]) orelse return E.INVAL;
                const p = child(&buf, path, name) orelse return E.INVAL;
                var h: u64 = 0;
                var e = vt.create(ctx, path, name, flags, rd32(body, 4) & 0o7777, &h);
                if (e != 0) return e;
                e = s.entry(p, w);
                if (e != 0) {
                    vt.close(ctx, h);
                    return e;
                }
                if (s.by_path.get(p)) |id| s.opened(id);
                openOut(h, w);
                return 0;
            },
            op.read, op.readdir, op.readdirplus => {
                if (body.len < 24) return E.INVAL;
                const h = rd64(body, 0);
                const off = rd64(body, 8);
                const size: usize = rd32(body, 16);
                const room = @min(size, w.b.len -| w.n);
                if (opcode == op.read) {
                    var n: usize = 0;
                    const e = vt.read(ctx, h, off, w.b[w.n..][0..room], &n);
                    if (e != 0) return e;
                    w.n += n;
                    return 0;
                }
                var sink: DirSink = .{ .s = s, .w = w, .end = w.n + room, .dir = path, .plus = opcode == op.readdirplus };
                return vt.readdir(ctx, h, off, .{ .ctx = &sink, .put = DirSink.put });
            },
            op.write => {
                if (body.len < 40) return E.INVAL;
                if (ro) return E.ROFS;
                const h = rd64(body, 0);
                const off = rd64(body, 8);
                const size: usize = rd32(body, 16);
                if (body.len < 40 + size) return E.INVAL;
                var n: usize = 0;
                const e = vt.write(ctx, h, off, body[40..][0..size], &n);
                if (e != 0) return e;
                w.u32_(@intCast(n));
                w.u32_(0);
                return 0;
            },
            op.release, op.releasedir => {
                if (body.len < 8) return E.INVAL;
                if (opcode == op.release) s.released(node);
                vt.close(ctx, rd64(body, 0));
                return 0;
            },
            op.flush => return 0,
            op.fsync, op.fsyncdir => {
                if (body.len < 16) return E.INVAL;
                return vt.fsync(ctx, rd64(body, 0), rd32(body, 8) & 1 != 0);
            },
            op.statfs => {
                var st: ninep.StatFs = .{};
                const e = vt.statfs(ctx, &st);
                if (e != 0) return e;
                w.u64_(st.blocks);
                w.u64_(st.bfree);
                w.u64_(st.bavail);
                w.u64_(st.files);
                w.u64_(st.ffree);
                w.u32_(st.bsize);
                w.u32_(st.namelen);
                w.u32_(st.bsize);
                w.u32_(0);
                for (0..6) |_| w.u32_(0);
                return 0;
            },
            op.access => {
                var a: Attr = .{};
                return vt.stat(ctx, path, &a);
            },
            else => return E.NOSYS,
        }
    }

    /// FUSE_INIT: the version of the guest, and the reply with the flags
    /// that both sides have.
    fn initSession(s: *Server, body: []const u8, w: *Writer) u32 {
        if (body.len < 16) return E.INVAL;
        const major = rd32(body, 0);
        const minor = rd32(body, 4);
        const max_readahead = rd32(body, 8);
        const flags = rd32(body, 12);
        // A newer major version: the reply is only our major, and the
        // guest sends INIT again.
        if (major > 7) {
            w.u32_(7);
            return 0;
        }
        if (major < 7) return E.PROTO;
        s.reset();
        s.minor = @min(minor, 36);
        const ours = init_flag.async_read | init_flag.atomic_o_trunc | init_flag.big_writes |
            init_flag.do_readdirplus | init_flag.readdirplus_auto | init_flag.parallel_dirops | init_flag.max_pages;
        var reply = flags & ours;
        var flags2: u32 = 0;
        var alignment: u16 = 0;
        if (s.dax) |d| {
            if (flags & init_flag.map_alignment != 0) {
                reply |= init_flag.map_alignment;
                alignment = d.align_log2;
            }
            const theirs2: u32 = if (flags & init_flag.init_ext != 0 and body.len >= 20) rd32(body, 16) else 0;
            if (theirs2 & init_flag2.has_inode_dax != 0) {
                reply |= init_flag.init_ext;
                flags2 = init_flag2.has_inode_dax;
                s.inode_dax = true;
            }
        }
        w.u32_(7);
        w.u32_(s.minor);
        w.u32_(max_readahead);
        w.u32_(reply);
        // Before 7.23 the reply is 24 bytes.
        if (s.minor < 23) {
            w.u16_(16);
            w.u16_(12);
            w.u32_(max_write);
            return 0;
        }
        w.u16_(16); // max_background
        w.u16_(12); // congestion_threshold
        w.u32_(max_write);
        w.u32_(1); // time_gran: 1 ns
        w.u16_(max_pages);
        w.u16_(alignment); // map_alignment, a power of 2
        w.u32_(flags2);
        w.u32_(0); // max_stack_depth
        w.u16_(0); // request_timeout
        for (0..11) |_| w.u16_(0);
        return 0;
    }

    /// A fuse_entry_out of `path`, with one more lookup of its node.
    fn entry(s: *Server, path: []const u8, w: *Writer) u32 {
        var a: Attr = .{};
        const e = s.fs.vt.stat(s.fs.ctx, path, &a);
        if (e != 0) return e;
        const id = s.nodeOf(path) catch return E.NOMEM;
        s.entryOut(id, &a, w);
        return 0;
    }

    fn entryOut(s: *Server, id: u64, a: *const Attr, w: *Writer) void {
        w.u64_(id);
        w.u64_(0); // generation
        w.u64_(s.ttl_ns / std.time.ns_per_s);
        w.u64_(s.ttl_ns / std.time.ns_per_s);
        w.u32_(@intCast(s.ttl_ns % std.time.ns_per_s));
        w.u32_(@intCast(s.ttl_ns % std.time.ns_per_s));
        attrBody(a, s.attrFlags(a), w);
    }

    fn attrOut(s: *Server, a: *const Attr, w: *Writer) void {
        w.u64_(s.ttl_ns / std.time.ns_per_s);
        w.u32_(@intCast(s.ttl_ns % std.time.ns_per_s));
        w.u32_(0);
        attrBody(a, s.attrFlags(a), w);
    }

    /// FUSE_SETUPMAPPING: a range of an open file at an offset of the
    /// window. FUSE_REMOVEMAPPING: a count, then each range of the window
    /// as an offset and a length. Each one has an empty reply.
    fn mapping(s: *Server, opcode: u32, node: u64, path: []const u8, body: []const u8) u32 {
        const d = s.dax orelse return E.NOSYS;
        const mask = (@as(u64, 1) << @intCast(d.align_log2)) - 1;
        if (opcode == op.setupmapping) {
            if (body.len < 40) return E.INVAL;
            const fh = rd64(body, 0);
            const foffset = rd64(body, 8);
            const len = rd64(body, 16);
            const flags = rd64(body, 24);
            const moffset = rd64(body, 32);
            if (len == 0 or foffset & mask != 0 or moffset & mask != 0) return E.INVAL;
            if (moffset > d.size or len > d.size - moffset) return E.INVAL;
            if (flags & setupmapping_write != 0 and s.fs.read_only) return E.ROFS;
            const write = flags & setupmapping_write != 0;
            // The guest maps a file by its node, with no open handle (an fh
            // of all ones): the server opens the path for the setup.
            var e: u32 = 0;
            if (fh != std.math.maxInt(u64)) {
                e = d.setup(d.ctx, node, fh, foffset, len, write, moffset);
            } else {
                var h: u64 = 0;
                e = s.fs.vt.open(s.fs.ctx, path, if (write) ninep.O.RDWR else ninep.O.RDONLY, &h);
                if (e != 0) return e;
                defer s.fs.vt.close(s.fs.ctx, h);
                e = d.setup(d.ctx, node, h, foffset, len, write, moffset);
            }
            // A mapping of a file with no open handle of the guest (a page of
            // an mmap after its close) starts idle.
            const n = s.nodes.get(node);
            if (e == 0 and (n == null or n.?.opens == 0)) d.idle(d.ctx, node, true);
            return e;
        }
        if (body.len < 4) return E.INVAL;
        const count = rd32(body, 0);
        if (body.len < 4 + @as(u64, count) * 16) return E.INVAL;
        for (0..count) |i| {
            const moffset = rd64(body, 4 + i * 16);
            const len = rd64(body, 4 + i * 16 + 8);
            if (moffset > d.size or len > d.size - moffset) return E.INVAL;
            const e = d.remove(d.ctx, moffset, len);
            if (e != 0) return e;
        }
        return 0;
    }

    fn opened(s: *Server, node: u64) void {
        const n = s.nodes.getPtr(node) orelse return;
        n.opens += 1;
        if (n.opens == 1) if (s.dax) |d| d.idle(d.ctx, node, false);
    }

    fn released(s: *Server, node: u64) void {
        const n = s.nodes.getPtr(node) orelse return;
        n.opens -|= 1;
        if (n.opens == 0) if (s.dax) |d| d.idle(d.ctx, node, true);
    }

    fn dropNode(s: *Server, node: u64) void {
        if (s.dax) |d| d.drop(d.ctx, node);
    }

    /// Drops the views of the node of `path`, when the guest has one.
    fn dropPath(s: *Server, path: []const u8) void {
        const d = s.dax orelse return;
        if (s.by_path.get(path)) |node| d.drop(d.ctx, node);
    }

    /// FUSE_ATTR_DAX for a regular file, when the guest uses DAX by file.
    fn attrFlags(s: *const Server, a: *const Attr) u32 {
        if (!s.inode_dax or a.mode & 0o170000 != 0o100000) return 0;
        return if (a.size == 0 or a.size >= dax_min) attr_dax else 0;
    }
};

fn attrBody(a: *const Attr, flags: u32, w: *Writer) void {
    w.u64_(a.ino);
    w.u64_(a.size);
    w.u64_(a.blocks);
    w.u64_(a.atime.sec);
    w.u64_(a.mtime.sec);
    w.u64_(a.ctime.sec);
    w.u32_(@intCast(a.atime.nsec));
    w.u32_(@intCast(a.mtime.nsec));
    w.u32_(@intCast(a.ctime.nsec));
    w.u32_(a.mode);
    w.u32_(@intCast(@min(a.nlink, std.math.maxInt(u32))));
    w.u32_(a.uid);
    w.u32_(a.gid);
    w.u32_(@intCast(@min(a.rdev, std.math.maxInt(u32))));
    w.u32_(@intCast(@min(a.blksize, std.math.maxInt(u32))));
    w.u32_(flags);
}

fn openOut(h: u64, w: *Writer) void {
    w.u64_(h);
    w.u32_(0); // open_flags
    // backing_id: the 16 bytes of the reply before 7.47, and the guest
    // asks for no passthrough, so `backing_id_64` stays out.
    w.u32_(0);
}

/// The sink of READDIR and READDIRPLUS: each entry is a fuse_dirent, or a
/// fuse_entry_out then a fuse_dirent, padded to 8 bytes.
const DirSink = struct {
    s: *Server,
    w: *Writer,
    end: usize,
    dir: []const u8,
    plus: bool,

    fn put(ctx: *anyopaque, e: ninep.Dirent) bool {
        const d: *DirSink = @ptrCast(@alignCast(ctx));
        const head: usize = if (d.plus) entry_out_len + 24 else 24;
        const size = std.mem.alignForward(usize, head + e.name.len, 8);
        if (d.w.n + size > d.end) return false;
        const w = d.w;
        const start = w.n;
        if (d.plus) {
            const dot = std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..");
            var buf: [ninep.max_path]u8 = undefined;
            const p = if (dot) null else child(&buf, d.dir, e.name);
            var a: Attr = .{};
            const ok = p != null and d.s.fs.vt.stat(d.s.fs.ctx, p.?, &a) == 0;
            const id: ?u64 = if (ok) d.s.nodeOf(p.?) catch null else null;
            if (id) |n| {
                d.s.entryOut(n, &a, w);
            } else {
                // Node 0: the guest makes no node for the entry.
                @memset(w.b[w.n..][0..entry_out_len], 0);
                w.n += entry_out_len;
            }
        }
        w.u64_(e.ino);
        w.u64_(e.next);
        w.u32_(@intCast(e.name.len));
        w.u32_(e.kind);
        @memcpy(w.b[w.n..][0..e.name.len], e.name);
        w.n += e.name.len;
        @memset(w.b[w.n .. start + size], 0);
        w.n = start + size;
        return true;
    }
};

const Writer = struct {
    b: []u8,
    n: usize,
    over: bool = false,

    fn room(w: *Writer, k: usize) bool {
        if (w.n + k > w.b.len) {
            w.over = true;
            return false;
        }
        return true;
    }
    fn u16_(w: *Writer, v: u16) void {
        if (!w.room(2)) return;
        std.mem.writeInt(u16, w.b[w.n..][0..2], v, .little);
        w.n += 2;
    }
    fn u32_(w: *Writer, v: u32) void {
        if (!w.room(4)) return;
        std.mem.writeInt(u32, w.b[w.n..][0..4], v, .little);
        w.n += 4;
    }
    fn u64_(w: *Writer, v: u64) void {
        if (!w.room(8)) return;
        std.mem.writeInt(u64, w.b[w.n..][0..8], v, .little);
        w.n += 8;
    }
};

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn rd64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

/// The text up to the first NUL byte of `b`, or null with no NUL.
fn cstr(b: []const u8) ?[]const u8 {
    const n = std.mem.indexOfScalar(u8, b, 0) orelse return null;
    return b[0..n];
}

/// The path of `name` in the folder `dir`, in `buf`.
fn child(buf: *[ninep.max_path]u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (!ninep.validName(name)) return null;
    const n = dir.len + @intFromBool(dir.len != 0) + name.len;
    if (n > buf.len) return null;
    var i: usize = 0;
    if (dir.len != 0) {
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = '/';
        i = dir.len + 1;
    }
    @memcpy(buf[i..][0..name.len], name);
    return buf[0..n];
}

const queue = @import("queue.zig");
const Queue = queue.Queue;
const Mem = queue.Mem;
const Chain = queue.Chain;

// The tests run the server against a file system in memory: a root
// folder with the file "a" ("hello") and the folder "d".

const MemFs = struct {
    data: [64]u8 = "hello".* ++ @as([59]u8, @splat(0)),
    len: usize = 5,
    made: bool = false,
    moved: bool = false,
    opens: u32 = 0,

    fn attr(kind: u32, ino: u64, size: u64) Attr {
        return .{ .mode = kind | 0o755, .ino = ino, .size = size, .nlink = 1 };
    }
    fn stat(ctx: *anyopaque, path: []const u8, out: *Attr) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        const d = if (m.moved) "e" else "d";
        if (path.len == 0) {
            out.* = attr(0o040000, 1, 0);
        } else if (std.mem.eql(u8, path, "a")) {
            out.* = attr(0o100000, 2, m.len);
        } else if (std.mem.eql(u8, path, d)) {
            out.* = attr(0o040000, 3, 0);
        } else if (m.made and path.len == 3 and std.mem.startsWith(u8, path, d) and std.mem.endsWith(u8, path, "/n")) {
            out.* = attr(0o100000, 4, 0);
        } else return E.NOENT;
        return 0;
    }
    fn open(ctx: *anyopaque, path: []const u8, _: u32, out: *u64) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        var a: Attr = .{};
        const e = stat(ctx, path, &a);
        if (e != 0) return e;
        m.opens += 1;
        out.* = a.ino;
        return 0;
    }
    fn create(ctx: *anyopaque, dir: []const u8, name: []const u8, _: u32, _: u32, out: *u64) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, dir, "d") or !std.mem.eql(u8, name, "n")) return E.PERM;
        m.made = true;
        m.opens += 1;
        out.* = 4;
        return 0;
    }
    fn close(ctx: *anyopaque, _: u64) void {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        m.opens -= 1;
    }
    fn read(ctx: *anyopaque, h: u64, off: u64, buf: []u8, n: *usize) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        if (h != 2) return E.ISDIR;
        const o: usize = @intCast(@min(off, m.len));
        n.* = @min(buf.len, m.len - o);
        @memcpy(buf[0..n.*], m.data[o..][0..n.*]);
        return 0;
    }
    fn write(ctx: *anyopaque, h: u64, off: u64, data: []const u8, n: *usize) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        if (h != 2 or off + data.len > m.data.len) return E.IO;
        @memcpy(m.data[@intCast(off)..][0..data.len], data);
        m.len = @max(m.len, off + data.len);
        n.* = data.len;
        return 0;
    }
    fn readdir(_: *anyopaque, h: u64, off: u64, sink: ninep.DirSink) u32 {
        if (h != 1) return E.NOTDIR;
        const all = [_]ninep.Dirent{ .{ .ino = 2, .next = 1, .kind = 8, .name = "a" }, .{ .ino = 3, .next = 2, .kind = 4, .name = "d" } };
        for (all[@intCast(@min(off, 2))..]) |e| if (!sink.put(sink.ctx, e)) break;
        return 0;
    }
    fn fsync(_: *anyopaque, _: u64, _: bool) u32 {
        return 0;
    }
    fn mkdir(_: *anyopaque, _: []const u8, _: []const u8, _: u32) u32 {
        return E.PERM;
    }
    fn symlink(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) u32 {
        return E.PERM;
    }
    fn readlink(_: *anyopaque, _: []const u8, _: []u8, _: *usize) u32 {
        return E.INVAL;
    }
    fn unlink(_: *anyopaque, _: []const u8, _: []const u8, _: bool) u32 {
        return E.PERM;
    }
    fn rename(ctx: *anyopaque, dir: []const u8, name: []const u8, new_dir: []const u8, new_name: []const u8) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        if (dir.len != 0 or new_dir.len != 0 or !std.mem.eql(u8, name, "d") or !std.mem.eql(u8, new_name, "e")) return E.PERM;
        m.moved = true;
        return 0;
    }
    fn setattr(_: *anyopaque, _: []const u8, _: ninep.SetAttr) u32 {
        return 0;
    }
    fn statfs(_: *anyopaque, out: *ninep.StatFs) u32 {
        out.* = .{ .blocks = 10, .bsize = 4096 };
        return 0;
    }
    const vt: Fs.VTable = .{ .stat = stat, .open = open, .create = create, .close = close, .read = read, .write = write, .readdir = readdir, .fsync = fsync, .mkdir = mkdir, .symlink = symlink, .link = symlink, .readlink = readlink, .unlink = unlink, .rename = rename, .setattr = setattr, .statfs = statfs };
};

/// A request: the header with `opcode` and `node`, then the body.
const Req = struct {
    b: [256]u8 = @splat(0),
    n: usize = in_header_len,

    fn init(opcode: u32, node: u64) Req {
        var r: Req = .{};
        std.mem.writeInt(u32, r.b[4..8], opcode, .little);
        std.mem.writeInt(u64, r.b[8..16], 77, .little);
        std.mem.writeInt(u64, r.b[16..24], node, .little);
        return r;
    }
    fn u32_(r: *Req, v: u32) *Req {
        std.mem.writeInt(u32, r.b[r.n..][0..4], v, .little);
        r.n += 4;
        return r;
    }
    fn u64_(r: *Req, v: u64) *Req {
        std.mem.writeInt(u64, r.b[r.n..][0..8], v, .little);
        r.n += 8;
        return r;
    }
    /// A name with its NUL byte.
    fn name(r: *Req, s: []const u8) *Req {
        @memcpy(r.b[r.n..][0..s.len], s);
        r.b[r.n + s.len] = 0;
        r.n += s.len + 1;
        return r;
    }
    fn done(r: *Req) []const u8 {
        std.mem.writeInt(u32, r.b[0..4], @intCast(r.n), .little);
        return r.b[0..r.n];
    }
};

fn testServer(fs: *MemFs, read_only: bool) Server {
    return Server.init(std.testing.allocator, .{ .ctx = fs, .read_only = read_only, .vt = &MemFs.vt });
}

/// The status of the reply in `out` (0 or a negative errno), after a
/// check of its length and its `unique`.
fn replyStatus(out: []const u8, n: usize) !i32 {
    try std.testing.expect(n >= out_header_len);
    try std.testing.expectEqual(@as(u32, @intCast(n)), rd32(out, 0));
    try std.testing.expectEqual(@as(u64, 77), rd64(out, 8));
    return std.mem.readInt(i32, out[4..8], .little);
}

fn startSession(s: *Server, out: []u8) !void {
    var r = Req.init(op.init, 0);
    const flags = init_flag.async_read | init_flag.max_pages | init_flag.do_readdirplus | init_flag.map_alignment;
    const n = s.handle(r.u32_(7).u32_(31).u32_(131072).u32_(flags).u32_(0).done(), out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(out, n));
}

test "fuse: INIT gives the version, the flags of both sides, and 1 MiB writes" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [256]u8 = undefined;
    try startSession(&s, &out);
    try std.testing.expectEqual(@as(u32, 7), rd32(&out, 16));
    try std.testing.expectEqual(@as(u32, 31), rd32(&out, 20));
    // The flags of the guest that the server has: no map_alignment.
    try std.testing.expectEqual(init_flag.async_read | init_flag.max_pages | init_flag.do_readdirplus, rd32(&out, 28));
    try std.testing.expectEqual(@as(u32, max_write), rd32(&out, 36));
    try std.testing.expectEqual(@as(u16, max_pages), std.mem.readInt(u16, out[44..46], .little));
    try std.testing.expectEqual(@as(u32, out_header_len + 64), rd32(&out, 0));

    // A guest of 7.22 gets the reply of 24 bytes.
    var r = Req.init(op.init, 0);
    var n = s.handle(r.u32_(7).u32_(22).u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(usize, out_header_len + 24), n);

    // A newer major version: the reply is only the major of the server.
    r = Req.init(op.init, 0);
    n = s.handle(r.u32_(8).u32_(0).u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(usize, out_header_len + 4), n);
    try std.testing.expectEqual(@as(u32, 7), rd32(&out, 16));
}

test "fuse: the configuration has the tag and one request queue" {
    var cfg: [48]u8 = @splat(0xaa);
    try std.testing.expectEqual(@as(u8, 44), Server.config("share0", &cfg));
    try std.testing.expectEqualStrings("share0", cfg[0..6]);
    try std.testing.expectEqual(@as(u8, 0), cfg[35]);
    try std.testing.expectEqual(@as(u32, 1), rd32(&cfg, 36));
    try std.testing.expectEqual(@as(u32, 0), rd32(&cfg, 40));
}

test "fuse: LOOKUP gives one node for a path, and FORGET removes it" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);

    var r = Req.init(op.lookup, 1);
    var n = s.handle(r.name("a").done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(usize, out_header_len + entry_out_len), n);
    const id = rd64(&out, 16);
    // The time of the name (1 s), then the inode and the size of "a".
    try std.testing.expectEqual(@as(u64, 1), rd64(&out, 32));
    try std.testing.expectEqual(@as(u64, 2), rd64(&out, 56));
    try std.testing.expectEqual(@as(u64, 5), rd64(&out, 64));

    r = Req.init(op.lookup, 1);
    n = s.handle(r.name("a").done(), &out);
    try std.testing.expectEqual(id, rd64(&out, 16));
    try std.testing.expectEqual(@as(u64, 2), s.nodes.get(id).?.lookups);

    r = Req.init(op.lookup, 1);
    n = s.handle(r.name("none").done(), &out);
    try std.testing.expectEqual(-@as(i32, E.NOENT), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(usize, out_header_len), n);

    // ".." is not a name of the folder.
    r = Req.init(op.lookup, 1);
    n = s.handle(r.name("..").done(), &out);
    try std.testing.expectEqual(-@as(i32, E.NOENT), try replyStatus(&out, n));

    r = Req.init(op.forget, id);
    try std.testing.expectEqual(@as(usize, 0), s.handle(r.u64_(1).done(), &out));
    try std.testing.expect(s.nodes.contains(id));
    r = Req.init(op.forget, id);
    try std.testing.expectEqual(@as(usize, 0), s.handle(r.u64_(1).done(), &out));
    try std.testing.expect(!s.nodes.contains(id));

    r = Req.init(op.getattr, id);
    n = s.handle(r.u32_(0).u32_(0).u64_(0).done(), &out);
    try std.testing.expectEqual(-@as(i32, E.NOENT), try replyStatus(&out, n));
}

test "fuse: BATCH_FORGET removes the lookups of several nodes" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);
    var ids: [2]u64 = undefined;
    for ([_][]const u8{ "a", "d" }, 0..) |name, i| {
        var r = Req.init(op.lookup, 1);
        _ = s.handle(r.name(name).done(), &out);
        ids[i] = rd64(&out, 16);
    }
    var r = Req.init(op.batch_forget, 0);
    try std.testing.expectEqual(@as(usize, 0), s.handle(r.u32_(2).u32_(0).u64_(ids[0]).u64_(1).u64_(ids[1]).u64_(1).done(), &out));
    try std.testing.expectEqual(@as(u32, 0), s.nodes.count());
    try std.testing.expectEqual(@as(u32, 0), s.by_path.count());
}

test "fuse: OPEN, READ, WRITE, and RELEASE of a file" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);
    var r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("a").done(), &out);
    const id = rd64(&out, 16);

    r = Req.init(op.open, id);
    var n = s.handle(r.u32_(ninep.O.RDWR).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    // fuse_open_out of 16 bytes.
    try std.testing.expectEqual(@as(usize, out_header_len + 16), n);
    const fh = rd64(&out, 16);
    try std.testing.expectEqual(@as(u32, 1), fs.opens);

    r = Req.init(op.write, id);
    _ = r.u64_(fh).u64_(5).u32_(3).u32_(0).u64_(0).u32_(0).u32_(0);
    @memcpy(r.b[r.n..][0..3], "!!!");
    r.n += 3;
    n = s.handle(r.done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(u32, 3), rd32(&out, 16));

    r = Req.init(op.read, id);
    n = s.handle(r.u64_(fh).u64_(1).u32_(100).u32_(0).u64_(0).u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqualStrings("ello!!!", out[out_header_len..n]);

    // A read with a buffer of the guest that is too small.
    n = s.handle(r.done(), out[0 .. out_header_len + 2]);
    try std.testing.expectEqualStrings("el", out[out_header_len..n]);

    r = Req.init(op.release, id);
    n = s.handle(r.u64_(fh).u32_(0).u32_(0).u64_(0).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(u32, 0), fs.opens);
}

test "fuse: CREATE gives an entry and a handle, and a read-only share refuses it" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);
    var r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("d").done(), &out);
    const d = rd64(&out, 16);

    r = Req.init(op.create, d);
    var n = s.handle(r.u32_(ninep.O.RDWR).u32_(0o644).u32_(0o022).u32_(0).name("n").done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(usize, out_header_len + entry_out_len + 16), n);
    try std.testing.expectEqual(@as(u64, 4), rd64(&out, out_header_len + entry_out_len));
    try std.testing.expectEqualStrings("d/n", s.pathOf(rd64(&out, 16)).?);
    try std.testing.expectEqual(@as(u32, 1), fs.opens);

    var fs2: MemFs = .{};
    var ro = testServer(&fs2, true);
    defer ro.deinit();
    try startSession(&ro, &out);
    r = Req.init(op.create, 1);
    n = ro.handle(r.u32_(ninep.O.RDWR).u32_(0o644).u32_(0).u32_(0).name("n").done(), &out);
    try std.testing.expectEqual(-@as(i32, E.ROFS), try replyStatus(&out, n));
    r = Req.init(op.open, 1);
    n = ro.handle(r.u32_(ninep.O.WRONLY).u32_(0).done(), &out);
    try std.testing.expectEqual(-@as(i32, E.ROFS), try replyStatus(&out, n));
}

test "fuse: READDIRPLUS in small pieces, with an entry for each name" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);
    // Room for one entry: "a", then "d" at offset 1.
    var r = Req.init(op.readdirplus, 1);
    var n = s.handle(r.u64_(1).u64_(0).u32_(200).u32_(0).u64_(0).u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    const one = std.mem.alignForward(usize, entry_out_len + 24 + 1, 8);
    try std.testing.expectEqual(@as(usize, out_header_len + one), n);
    const dirent = out_header_len + entry_out_len;
    try std.testing.expectEqual(@as(u64, 2), rd64(&out, dirent));
    try std.testing.expectEqual(@as(u64, 1), rd64(&out, dirent + 8));
    try std.testing.expectEqual(@as(u8, 'a'), out[dirent + 24]);
    try std.testing.expectEqualStrings("a", s.pathOf(rd64(&out, out_header_len)).?);

    r = Req.init(op.readdirplus, 1);
    n = s.handle(r.u64_(1).u64_(1).u32_(200).u32_(0).u64_(0).u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(usize, out_header_len + one), n);
    try std.testing.expectEqual(@as(u8, 'd'), out[dirent + 24]);

    // READDIR: both entries of 32 bytes in one reply.
    r = Req.init(op.readdir, 1);
    n = s.handle(r.u64_(1).u64_(0).u32_(4096).u32_(0).u64_(0).u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(usize, out_header_len + 64), n);
}

test "fuse: RENAME moves the path of each node below the folder" {
    var fs: MemFs = .{ .made = true };
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);
    var r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("d").done(), &out);
    const d = rd64(&out, 16);
    r = Req.init(op.lookup, d);
    _ = s.handle(r.name("n").done(), &out);
    const n_id = rd64(&out, 16);
    try std.testing.expectEqualStrings("d/n", s.pathOf(n_id).?);

    r = Req.init(op.rename, 1);
    const n = s.handle(r.u64_(1).name("d").name("e").done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqualStrings("e", s.pathOf(d).?);
    try std.testing.expectEqualStrings("e/n", s.pathOf(n_id).?);

    r = Req.init(op.getattr, n_id);
    _ = s.handle(r.u32_(0).u32_(0).u64_(0).done(), &out);
    try std.testing.expectEqual(@as(u64, 4), rd64(&out, out_header_len + 16));

    // A lookup of the new name gives the same node.
    r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("e").done(), &out);
    try std.testing.expectEqual(d, rd64(&out, 16));
}

test "fuse: an opcode the server does not have gives ENOSYS, and STATFS" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    try startSession(&s, &out);
    var r = Req.init(22, 1); // GETXATTR
    var n = s.handle(r.u32_(0).u32_(0).done(), &out);
    try std.testing.expectEqual(-@as(i32, E.NOSYS), try replyStatus(&out, n));

    r = Req.init(op.statfs, 1);
    n = s.handle(r.done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(usize, out_header_len + 80), n);
    try std.testing.expectEqual(@as(u64, 10), rd64(&out, 16));
    try std.testing.expectEqual(@as(u32, 4096), rd32(&out, 56));

    // A request shorter than its header has no reply.
    try std.testing.expectEqual(@as(usize, 0), s.handle(out[0..20], &out));
}

/// A DAX window that records the calls of the server.
const TestDax = struct {
    setups: u32 = 0,
    last_fh: u64 = 0,
    last_node: u64 = 0,
    last_write: bool = false,
    removes: u32 = 0,
    drops: u32 = 0,
    idles: u32 = 0,
    busy: u32 = 0,
    clears: u32 = 0,
    opens_at_setup: u32 = 0,
    fs: *MemFs,

    fn setup(ctx: *anyopaque, node: u64, fh: u64, _: u64, _: u64, write: bool, _: u64) u32 {
        const t: *TestDax = @ptrCast(@alignCast(ctx));
        t.setups += 1;
        t.last_fh = fh;
        t.last_node = node;
        t.last_write = write;
        t.opens_at_setup = t.fs.opens;
        return 0;
    }
    fn remove(ctx: *anyopaque, _: u64, _: u64) u32 {
        const t: *TestDax = @ptrCast(@alignCast(ctx));
        t.removes += 1;
        return 0;
    }
    fn drop(ctx: *anyopaque, _: u64) void {
        const t: *TestDax = @ptrCast(@alignCast(ctx));
        t.drops += 1;
    }
    fn idle(ctx: *anyopaque, _: u64, on: bool) void {
        const t: *TestDax = @ptrCast(@alignCast(ctx));
        if (on) t.idles += 1 else t.busy += 1;
    }
    fn clear(ctx: *anyopaque) void {
        const t: *TestDax = @ptrCast(@alignCast(ctx));
        t.clears += 1;
    }
    fn dax(t: *TestDax) Dax {
        return .{ .ctx = t, .size = 1 << 30, .align_log2 = 16, .setup = setup, .remove = remove, .drop = drop, .idle = idle, .clear = clear };
    }
};

/// INIT with FUSE_INIT_EXT and FUSE_HAS_INODE_DAX in `flags2`.
fn startDaxSession(s: *Server, out: []u8) !void {
    var r = Req.init(op.init, 0);
    const flags = init_flag.async_read | init_flag.max_pages | init_flag.map_alignment | init_flag.init_ext;
    const n = s.handle(r.u32_(7).u32_(46).u32_(131072).u32_(flags).u32_(init_flag2.has_inode_dax).done(), out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(out, n));
}

/// The `flags` of the fuse_attr of an entry reply in `out`.
fn entryAttrFlags(out: []const u8) u32 {
    return rd32(out, out_header_len + 40 + 84);
}

test "fuse: INIT gives DAX by file, and the alignment of the window" {
    var fs: MemFs = .{};
    var t: TestDax = .{ .fs = &fs };
    var s = testServer(&fs, false);
    defer s.deinit();
    s.dax = t.dax();
    var out: [512]u8 = undefined;
    try startDaxSession(&s, &out);
    try std.testing.expectEqual(@as(u32, 36), rd32(&out, 20));
    const flags = rd32(&out, 28);
    try std.testing.expect(flags & init_flag.map_alignment != 0);
    try std.testing.expect(flags & init_flag.init_ext != 0);
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, out[46..48], .little));
    try std.testing.expectEqual(init_flag2.has_inode_dax, rd32(&out, 48));
    try std.testing.expect(s.inode_dax);
    // Each INIT starts a session and removes each mapping.
    try std.testing.expectEqual(@as(u32, 1), t.clears);

    // With no window, the server offers no DAX.
    var fs2: MemFs = .{};
    var plain = testServer(&fs2, false);
    defer plain.deinit();
    try startDaxSession(&plain, &out);
    try std.testing.expectEqual(@as(u32, 0), rd32(&out, 28) & (init_flag.map_alignment | init_flag.init_ext));
    try std.testing.expectEqual(@as(u32, 0), rd32(&out, 48));
}

test "fuse: FUSE_ATTR_DAX for a new file and a large one, and none for a small one" {
    var fs: MemFs = .{ .made = true };
    var t: TestDax = .{ .fs = &fs };
    var s = testServer(&fs, false);
    defer s.deinit();
    s.dax = t.dax();
    var out: [512]u8 = undefined;
    try startDaxSession(&s, &out);
    var r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("a").done(), &out);
    // "a" has 5 bytes.
    try std.testing.expectEqual(@as(u32, 0), entryAttrFlags(&out));
    r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("d").done(), &out);
    const d = rd64(&out, 16);
    // A folder has no DAX.
    try std.testing.expectEqual(@as(u32, 0), entryAttrFlags(&out));
    r = Req.init(op.lookup, d);
    _ = s.handle(r.name("n").done(), &out);
    // "d/n" has 0 bytes.
    try std.testing.expectEqual(attr_dax, entryAttrFlags(&out));
    fs.len = dax_min;
    r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("a").done(), &out);
    try std.testing.expectEqual(attr_dax, entryAttrFlags(&out));
}

test "fuse: SETUPMAPPING by node opens the file for the setup, and REMOVEMAPPING" {
    var fs: MemFs = .{};
    var t: TestDax = .{ .fs = &fs };
    var s = testServer(&fs, false);
    defer s.deinit();
    s.dax = t.dax();
    var out: [512]u8 = undefined;
    try startDaxSession(&s, &out);
    var r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("a").done(), &out);
    const a = rd64(&out, 16);

    // An fh of all ones: the server opens "a" for the setup, and closes it.
    r = Req.init(op.setupmapping, a);
    var n = s.handle(r.u64_(std.math.maxInt(u64)).u64_(0).u64_(2 << 20).u64_(2).u64_(0).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(usize, out_header_len), n);
    try std.testing.expectEqual(@as(u32, 1), t.setups);
    try std.testing.expectEqual(@as(u64, 2), t.last_fh);
    try std.testing.expectEqual(a, t.last_node);
    try std.testing.expect(!t.last_write);
    try std.testing.expectEqual(@as(u32, 1), t.opens_at_setup);
    try std.testing.expectEqual(@as(u32, 0), fs.opens);
    // The guest has no open handle of "a", so the mapping starts idle.
    try std.testing.expectEqual(@as(u32, 1), t.idles);

    // An offset that is not a multiple of 64 KiB, and a range past the window.
    r = Req.init(op.setupmapping, a);
    n = s.handle(r.u64_(7).u64_(4096).u64_(2 << 20).u64_(2).u64_(0).done(), &out);
    try std.testing.expectEqual(-@as(i32, E.INVAL), try replyStatus(&out, n));
    r = Req.init(op.setupmapping, a);
    n = s.handle(r.u64_(7).u64_(0).u64_(2 << 20).u64_(2).u64_(1 << 30).done(), &out);
    try std.testing.expectEqual(-@as(i32, E.INVAL), try replyStatus(&out, n));

    // REMOVEMAPPING of two ranges.
    r = Req.init(op.removemapping, a);
    n = s.handle(r.u32_(2).u64_(0).u64_(2 << 20).u64_(2 << 20).u64_(2 << 20).done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(u32, 2), t.removes);

    // A write mapping on a read-only share.
    var fs2: MemFs = .{};
    var t2: TestDax = .{ .fs = &fs2 };
    var ro = testServer(&fs2, true);
    defer ro.deinit();
    ro.dax = t2.dax();
    try startDaxSession(&ro, &out);
    r = Req.init(op.setupmapping, 1);
    n = ro.handle(r.u64_(7).u64_(0).u64_(2 << 20).u64_(1).u64_(0).done(), &out);
    try std.testing.expectEqual(-@as(i32, E.ROFS), try replyStatus(&out, n));
}

test "fuse: the views of a file go idle at its last release, and go before a size change" {
    var fs: MemFs = .{};
    var t: TestDax = .{ .fs = &fs };
    var s = testServer(&fs, false);
    defer s.deinit();
    s.dax = t.dax();
    var out: [512]u8 = undefined;
    try startDaxSession(&s, &out);
    var r = Req.init(op.lookup, 1);
    _ = s.handle(r.name("a").done(), &out);
    const a = rd64(&out, 16);

    var fhs: [2]u64 = undefined;
    for (&fhs) |*fh| {
        r = Req.init(op.open, a);
        _ = s.handle(r.u32_(ninep.O.RDONLY).u32_(0).done(), &out);
        fh.* = rd64(&out, 16);
    }
    try std.testing.expectEqual(@as(u32, 1), t.busy);
    r = Req.init(op.release, a);
    _ = s.handle(r.u64_(fhs[0]).u32_(0).u32_(0).u64_(0).done(), &out);
    try std.testing.expectEqual(@as(u32, 0), t.idles);
    r = Req.init(op.release, a);
    _ = s.handle(r.u64_(fhs[1]).u32_(0).u32_(0).u64_(0).done(), &out);
    try std.testing.expectEqual(@as(u32, 1), t.idles);

    // SETATTR of the size, and OPEN with O_TRUNC, drop the views first.
    r = Req.init(op.setattr, a);
    _ = r.u32_(1 << 3).u32_(0).u64_(0).u64_(3);
    r.n += 88 - 24;
    var n = s.handle(r.done(), &out);
    try std.testing.expectEqual(@as(i32, 0), try replyStatus(&out, n));
    try std.testing.expectEqual(@as(u32, 1), t.drops);
    r = Req.init(op.open, a);
    n = s.handle(r.u32_(ninep.O.RDWR | ninep.O.TRUNC).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(u32, 2), t.drops);
    r = Req.init(op.release, a);
    _ = s.handle(r.u64_(rd64(&out, 16)).u32_(0).u32_(0).u64_(0).done(), &out);
}
