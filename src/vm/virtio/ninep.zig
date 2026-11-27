//! The 9p device of virtio (virtio 1.2, section 5.13 lists the ID 9)
//! and a server of the 9P2000.L protocol for it. The guest mounts it
//! with `-t 9p -o trans=virtio,version=9p2000.L` and the tag of the
//! configuration.
//!
//! The device has one queue. Each chain is one T-message in its
//! readable part and room for the R-message in its writable part. The
//! device runs each message at once, on the thread of the vCPU, and
//! puts the chain in the used ring.
//!
//! This file makes no system calls. The backend gives an `Fs`: the
//! files of the host below the root folder of the share. Each path that
//! the device gives the `Fs` is relative to that root folder: "" is the
//! root folder, and a longer path is names joined by "/", with no "",
//! ".", or ".." in it. The device keeps the path of each fid and makes
//! ".." of a walk with the names of the path, so a walk cannot leave
//! the root folder. The `Fs` must open each name with no step through a
//! symbolic link (`openat2` with `RESOLVE_BENEATH` and
//! `RESOLVE_NO_SYMLINKS` on Linux), because the guest resolves its
//! symbolic links itself with `readlink`.
//!
//! An error is a Linux errno, because the guest is Linux.
//!
//! The protocol: the 9P2000 manual pages of Plan 9 (section 5), and the
//! 9P2000.L additions (the message types 6 to 77) as the diod project
//! documents them.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const queue = @import("queue.zig");
const Mem = queue.Mem;
const Queue = queue.Queue;
const Chain = queue.Chain;

pub const id = 9;
/// VIRTIO_9P_MOUNT_TAG: the configuration has the tag.
pub const f_mount_tag: u64 = 1;
/// The largest message of the device. The guest asks for an `msize` in
/// `Tversion`, and the device gives the smaller of the two.
pub const max_msize: u32 = 256 * 1024;
/// The most fids of one guest at once.
pub const max_fids = 4096;
pub const max_path = 4096;

pub const E = struct {
    pub const PERM = 1;
    pub const NOENT = 2;
    pub const IO = 5;
    pub const BADF = 9;
    pub const NOMEM = 12;
    pub const EXIST = 17;
    pub const NOTDIR = 20;
    pub const ISDIR = 21;
    pub const INVAL = 22;
    pub const MFILE = 24;
    pub const ROFS = 30;
    pub const NAMETOOLONG = 36;
    pub const NOSYS = 38;
    pub const OPNOTSUPP = 95;
    pub const PROTO = 71;
};

/// The open flags of 9P2000.L, the values of Linux on x86.
pub const O = struct {
    pub const ACCMODE = 3;
    pub const RDONLY = 0;
    pub const WRONLY = 1;
    pub const RDWR = 2;
    pub const CREAT = 0o100;
    pub const EXCL = 0o200;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const DSYNC = 0o10000;
    pub const DIRECTORY = 0o200000;
    pub const SYNC = 0o4010000;
};

pub const Qid = struct {
    pub const dir = 0x80;
    pub const symlink = 0x02;
    pub const file = 0;
    kind: u8,
    version: u32 = 0,
    path: u64,
};

/// The attributes of a file, as `statx` gives them. `ino` mixes the
/// device and the inode of the host, so two files of the share have two
/// values.
pub const Attr = struct {
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u64 = 0,
    rdev: u64 = 0,
    size: u64 = 0,
    blksize: u64 = 4096,
    blocks: u64 = 0,
    atime: Time = .{},
    mtime: Time = .{},
    ctime: Time = .{},
    ino: u64 = 0,

    pub fn qid(a: Attr) Qid {
        const fmt = a.mode & 0o170000;
        return .{ .kind = if (fmt == 0o040000) Qid.dir else if (fmt == 0o120000) Qid.symlink else Qid.file, .path = a.ino };
    }
};

pub const Time = struct { sec: u64 = 0, nsec: u64 = 0 };

/// A change of the attributes of a file. A null field stays as it is.
/// `now` sets the time to the time of the host.
pub const SetAttr = struct {
    mode: ?u32 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    size: ?u64 = null,
    atime: TimeSet = .keep,
    mtime: TimeSet = .keep,
};

pub const TimeSet = union(enum) { keep, now, at: Time };

pub const StatFs = struct {
    kind: u32 = 0x01021997,
    bsize: u32 = 4096,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
    fsid: u64 = 0,
    namelen: u32 = 255,
};

/// An entry of a folder for `readdir`: `next` is the offset of the
/// entry after it, and `kind` is the `d_type` of Linux.
pub const Dirent = struct { ino: u64, next: u64, kind: u8, name: []const u8 };

/// The sink of `readdir`: `put` gives false when the entry does not
/// fit, and the backend stops.
pub const DirSink = struct {
    ctx: *anyopaque,
    put: *const fn (ctx: *anyopaque, e: Dirent) bool,
};

/// The files of a share. Each call gives 0 or an errno. A handle is an
/// open file of the backend.
pub const Fs = struct {
    ctx: *anyopaque,
    read_only: bool,
    vt: *const VTable,

    pub const VTable = struct {
        /// The attributes of `path`, with no step through a symbolic
        /// link at its end.
        stat: *const fn (ctx: *anyopaque, path: []const u8, out: *Attr) u32,
        /// Opens `path` with the flags of `O`.
        open: *const fn (ctx: *anyopaque, path: []const u8, flags: u32, out: *u64) u32,
        /// Makes the file `name` in the folder `dir` and opens it.
        create: *const fn (ctx: *anyopaque, dir: []const u8, name: []const u8, flags: u32, mode: u32, out: *u64) u32,
        close: *const fn (ctx: *anyopaque, h: u64) void,
        read: *const fn (ctx: *anyopaque, h: u64, off: u64, buf: []u8, n: *usize) u32,
        write: *const fn (ctx: *anyopaque, h: u64, off: u64, data: []const u8, n: *usize) u32,
        /// Gives the entries of an open folder from `off` (0 is the
        /// first) to the sink, until the sink is full or the folder ends.
        readdir: *const fn (ctx: *anyopaque, h: u64, off: u64, sink: DirSink) u32,
        fsync: *const fn (ctx: *anyopaque, h: u64, data_only: bool) u32,
        mkdir: *const fn (ctx: *anyopaque, dir: []const u8, name: []const u8, mode: u32) u32,
        symlink: *const fn (ctx: *anyopaque, dir: []const u8, name: []const u8, target: []const u8) u32,
        link: *const fn (ctx: *anyopaque, path: []const u8, dir: []const u8, name: []const u8) u32,
        readlink: *const fn (ctx: *anyopaque, path: []const u8, buf: []u8, n: *usize) u32,
        unlink: *const fn (ctx: *anyopaque, dir: []const u8, name: []const u8, is_dir: bool) u32,
        rename: *const fn (ctx: *anyopaque, dir: []const u8, name: []const u8, new_dir: []const u8, new_name: []const u8) u32,
        setattr: *const fn (ctx: *anyopaque, path: []const u8, s: SetAttr) u32,
        statfs: *const fn (ctx: *anyopaque, out: *StatFs) u32,
    };
};

const Fid = struct {
    path: []u8,
    handle: ?u64 = null,
};

/// The state of one 9p device: its tag, its `Fs`, its fids, and the
/// buffers of one message.
pub const Server = struct {
    alloc: std.mem.Allocator,
    fs: Fs,
    fids: std.AutoHashMapUnmanaged(u32, Fid) = .empty,
    /// The counts of the chains that got no answer (malformed) and of
    /// the requests that got an Rlerror before their parse (too long for
    /// msize, or no memory).
    bad_chains: u32 = 0,
    bad_requests: u32 = 0,
    msize: u32 = 8192,
    req: []u8 = &.{},
    rep: []u8 = &.{},

    pub fn init(alloc: std.mem.Allocator, fs: Fs) Server {
        return .{ .alloc = alloc, .fs = fs };
    }

    pub fn deinit(s: *Server) void {
        s.clunkAll();
        s.fids.deinit(s.alloc);
        s.alloc.free(s.req);
        s.alloc.free(s.rep);
        s.req = &.{};
        s.rep = &.{};
    }

    /// The configuration of the device: the length of the tag (u16)
    /// and the tag. The tag has at most 14 bytes.
    pub fn config(tag: []const u8, out: *[16]u8) u8 {
        const n: u16 = @intCast(@min(tag.len, 14));
        std.mem.writeInt(u16, out[0..2], n, .little);
        @memcpy(out[2..][0..n], tag[0..n]);
        return @intCast(2 + n);
    }

    fn clunkAll(s: *Server) void {
        var it = s.fids.valueIterator();
        while (it.next()) |f| s.freeFid(f.*);
        s.fids.clearRetainingCapacity();
    }

    fn freeFid(s: *Server, f: Fid) void {
        if (f.handle) |h| s.fs.vt.close(s.fs.ctx, h);
        s.alloc.free(f.path);
    }

    /// The driver reset the device: each fid goes.
    pub fn reset(s: *Server) void {
        s.clunkAll();
    }

    /// Runs the requests of the queue. Gives true when it put a chain in
    /// the used ring.
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
            // A malformed chain has no buffer to put an Rlerror in.
            s.bad_chains += 1;
            return 0;
        };
        var in_len: usize = 0;
        var out_len: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (w) out_len += b.len else in_len += b.len;
        }
        if (in_len < 7) {
            s.bad_chains += 1;
            return 0;
        }
        // The buffers: the size of a Tversion first, then the msize.
        const cap = @max(s.msize, 8192);
        if (s.req.len < cap) {
            s.alloc.free(s.req);
            s.alloc.free(s.rep);
            s.req = &.{};
            s.rep = &.{};
            s.req = s.alloc.alloc(u8, cap) catch return s.refuse(&c, E.NOMEM);
            s.rep = s.alloc.alloc(u8, cap) catch return s.refuse(&c, E.NOMEM);
        }
        var n: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (w) continue;
            const k = @min(b.len, s.req.len - n);
            @memcpy(s.req[n..][0..k], b[0..k]);
            n += k;
        }
        const size = std.mem.readInt(u32, s.req[0..4], .little);
        if (size < 7 or size > n) return s.refuse(&c, E.INVAL);
        const room: usize = @min(out_len, s.rep.len);
        const len = s.handle(s.req[0..size], s.rep[0..room]);
        var off: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (!w or off >= len) continue;
            const k = @min(b.len, len - off);
            @memcpy(b[0..k], s.rep[off..][0..k]);
            off += k;
        }
        return @intCast(len);
    }

    /// Answers the request of `c` with an Rlerror of `errno`, with the
    /// tag of the first 7 bytes of its readable part, and gives the
    /// length. The guest sees the error, and its request ends.
    fn refuse(s: *Server, c: *const Chain, errno: u32) u32 {
        s.bad_requests += 1;
        var head: [7]u8 = @splat(0);
        var n: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (w or n == head.len) continue;
            const k = @min(b.len, head.len - n);
            @memcpy(head[n..][0..k], b[0..k]);
            n += k;
        }
        var ans: [11]u8 = undefined;
        std.mem.writeInt(u32, ans[0..4], 11, .little);
        ans[4] = r_lerror;
        @memcpy(ans[5..7], head[5..7]);
        std.mem.writeInt(u32, ans[7..11], errno, .little);
        var off: usize = 0;
        for (c.bufs[0..c.n], c.writable[0..c.n]) |b, w| {
            if (!w or off >= ans.len) continue;
            const k = @min(b.len, ans.len - off);
            @memcpy(b[0..k], ans[off..][0..k]);
            off += k;
        }
        return @intCast(off);
    }

    /// Answers one T-message in `out`, and gives the length of the
    /// answer.
    pub fn handle(s: *Server, msg: []const u8, out: []u8) usize {
        if (out.len < 11) return 0;
        var r: Reader = .{ .b = msg[7..] };
        const kind = msg[4];
        const tag = std.mem.readInt(u16, msg[5..7], .little);
        var w: Writer = .{ .b = out, .n = 7 };
        const err = s.dispatch(kind, &r, &w);
        if (err != 0 or w.over) {
            w.n = 7;
            w.over = false;
            w.u32_(if (err != 0) err else E.IO);
            put(out, 7, tag, w.n);
            return w.n;
        }
        out[4] = kind + 1;
        std.mem.writeInt(u16, out[5..7], tag, .little);
        std.mem.writeInt(u32, out[0..4], @intCast(w.n), .little);
        return w.n;
    }

    fn put(out: []u8, kind: u8, tag: u16, n: usize) void {
        std.mem.writeInt(u32, out[0..4], @intCast(n), .little);
        out[4] = kind;
        std.mem.writeInt(u16, out[5..7], tag, .little);
    }

    fn fid(s: *Server, r: *Reader) ?*Fid {
        return s.fids.getPtr(r.u32_() orelse return null);
    }

    fn newFid(s: *Server, n: u32, path: []const u8) u32 {
        if (s.fids.contains(n)) return E.BADF;
        if (s.fids.count() >= max_fids) return E.MFILE;
        const p = s.alloc.dupe(u8, path) catch return E.NOMEM;
        s.fids.put(s.alloc, n, .{ .path = p }) catch {
            s.alloc.free(p);
            return E.NOMEM;
        };
        return 0;
    }

    fn stat(s: *Server, path: []const u8, a: *Attr) u32 {
        return s.fs.vt.stat(s.fs.ctx, path, a);
    }

    fn dispatch(s: *Server, kind: u8, r: *Reader, w: *Writer) u32 {
        const vt = s.fs.vt;
        const ctx = s.fs.ctx;
        const ro = s.fs.read_only;
        switch (kind) {
            t_version => {
                const want = r.u32_() orelse return E.PROTO;
                const ver = r.str() orelse return E.PROTO;
                s.clunkAll();
                s.msize = @max(@min(want, max_msize), 4096);
                w.u32_(s.msize);
                w.str(if (std.mem.eql(u8, ver, "9P2000.L")) "9P2000.L" else "unknown");
            },
            t_auth => return E.OPNOTSUPP,
            t_attach => {
                const n = r.u32_() orelse return E.PROTO;
                var a: Attr = .{};
                const e = s.stat("", &a);
                if (e != 0) return e;
                const ne = s.newFid(n, "");
                if (ne != 0) return ne;
                w.qid(a.qid());
            },
            t_flush => {},
            t_walk => {
                const n0 = r.u32_() orelse return E.PROTO;
                const f = s.fids.getPtr(n0) orelse return E.BADF;
                const nf = r.u32_() orelse return E.PROTO;
                const count = r.u16_() orelse return E.PROTO;
                if (count > 16) return E.INVAL;
                if (nf != n0 and s.fids.contains(nf)) return E.BADF;
                if (nf == n0 and count != 0 and f.handle != null) return E.BADF;
                var buf: [max_path]u8 = undefined;
                if (f.path.len > buf.len) return E.NAMETOOLONG;
                @memcpy(buf[0..f.path.len], f.path);
                var len = f.path.len;
                w.u16_(count);
                var done: u16 = 0;
                while (done < count) : (done += 1) {
                    const name = r.str() orelse return E.PROTO;
                    const next = stepPath(&buf, len, name) orelse {
                        if (done == 0) return E.NOENT;
                        break;
                    };
                    // The backend gives ENOTDIR or ELOOP for a name in a
                    // file or in a symbolic link.
                    var a: Attr = .{};
                    const e = s.stat(buf[0..next], &a);
                    if (e != 0) {
                        if (done == 0) return e;
                        break;
                    }
                    w.qid(a.qid());
                    len = next;
                }
                std.mem.writeInt(u16, w.b[7..9], done, .little);
                if (done == count) {
                    const p = s.alloc.dupe(u8, buf[0..len]) catch return E.NOMEM;
                    if (nf == n0) {
                        s.alloc.free(f.path);
                        f.path = p;
                    } else {
                        if (s.fids.count() >= max_fids) {
                            s.alloc.free(p);
                            return E.MFILE;
                        }
                        s.fids.put(s.alloc, nf, .{ .path = p }) catch {
                            s.alloc.free(p);
                            return E.NOMEM;
                        };
                    }
                }
            },
            t_clunk, t_remove => {
                const n = r.u32_() orelse return E.PROTO;
                const kv = s.fids.fetchRemove(n) orelse return E.BADF;
                defer s.freeFid(kv.value);
                if (kind == t_remove) {
                    if (ro) return E.ROFS;
                    const sp = split(kv.value.path) orelse return E.INVAL;
                    var a: Attr = .{};
                    const e = s.stat(kv.value.path, &a);
                    if (e != 0) return e;
                    return vt.unlink(ctx, sp.dir, sp.name, a.qid().kind == Qid.dir);
                }
            },
            t_getattr => {
                const f = s.fid(r) orelse return E.BADF;
                var a: Attr = .{};
                const e = s.stat(f.path, &a);
                if (e != 0) return e;
                w.u64_(0x7ff);
                w.qid(a.qid());
                w.u32_(a.mode);
                w.u32_(a.uid);
                w.u32_(a.gid);
                w.u64_(a.nlink);
                w.u64_(a.rdev);
                w.u64_(a.size);
                w.u64_(a.blksize);
                w.u64_(a.blocks);
                for ([_]Time{ a.atime, a.mtime, a.ctime, .{} }) |t| {
                    w.u64_(t.sec);
                    w.u64_(t.nsec);
                }
                w.u64_(0);
                w.u64_(0);
            },
            t_setattr => {
                const f = s.fid(r) orelse return E.BADF;
                const valid = r.u32_() orelse return E.PROTO;
                const mode = r.u32_() orelse return E.PROTO;
                const uid = r.u32_() orelse return E.PROTO;
                const gid = r.u32_() orelse return E.PROTO;
                const size = r.u64_() orelse return E.PROTO;
                const at: Time = .{ .sec = r.u64_() orelse return E.PROTO, .nsec = r.u64_() orelse return E.PROTO };
                const mt: Time = .{ .sec = r.u64_() orelse return E.PROTO, .nsec = r.u64_() orelse return E.PROTO };
                if (ro) return E.ROFS;
                var sa: SetAttr = .{};
                if (valid & 1 != 0) sa.mode = mode & 0o7777;
                if (valid & 2 != 0) sa.uid = uid;
                if (valid & 4 != 0) sa.gid = gid;
                if (valid & 8 != 0) sa.size = size;
                if (valid & 0x10 != 0) sa.atime = if (valid & 0x80 != 0) .{ .at = at } else .now;
                if (valid & 0x20 != 0) sa.mtime = if (valid & 0x100 != 0) .{ .at = mt } else .now;
                return vt.setattr(ctx, f.path, sa);
            },
            t_statfs => {
                _ = s.fid(r) orelse return E.BADF;
                var st: StatFs = .{};
                const e = vt.statfs(ctx, &st);
                if (e != 0) return e;
                w.u32_(st.kind);
                w.u32_(st.bsize);
                w.u64_(st.blocks);
                w.u64_(st.bfree);
                w.u64_(st.bavail);
                w.u64_(st.files);
                w.u64_(st.ffree);
                w.u64_(st.fsid);
                w.u32_(st.namelen);
            },
            t_lopen => {
                const f = s.fid(r) orelse return E.BADF;
                const flags = r.u32_() orelse return E.PROTO;
                if (f.handle != null) return E.BADF;
                if (ro and (flags & O.ACCMODE != O.RDONLY or flags & O.TRUNC != 0)) return E.ROFS;
                var a: Attr = .{};
                var e = s.stat(f.path, &a);
                if (e != 0) return e;
                var h: u64 = 0;
                e = vt.open(ctx, f.path, flags & (O.ACCMODE | O.TRUNC | O.APPEND | O.DIRECTORY | O.SYNC | O.DSYNC), &h);
                if (e != 0) return e;
                f.handle = h;
                w.qid(a.qid());
                w.u32_(0);
            },
            t_lcreate => {
                const f = s.fid(r) orelse return E.BADF;
                const name = r.str() orelse return E.PROTO;
                const flags = r.u32_() orelse return E.PROTO;
                const mode = r.u32_() orelse return E.PROTO;
                if (f.handle != null) return E.BADF;
                if (ro) return E.ROFS;
                var buf: [max_path]u8 = undefined;
                const np = child(&buf, f.path, name) orelse return E.INVAL;
                var h: u64 = 0;
                var e = vt.create(ctx, f.path, name, flags & (O.ACCMODE | O.TRUNC | O.APPEND | O.EXCL | O.SYNC | O.DSYNC), mode & 0o7777, &h);
                if (e != 0) return e;
                var a: Attr = .{};
                e = s.stat(np, &a);
                const p = if (e == 0) s.alloc.dupe(u8, np) catch null else null;
                if (p == null) {
                    vt.close(ctx, h);
                    return if (e != 0) e else E.NOMEM;
                }
                s.alloc.free(f.path);
                f.path = p.?;
                f.handle = h;
                w.qid(a.qid());
                w.u32_(0);
            },
            t_read => {
                const f = s.fid(r) orelse return E.BADF;
                const off = r.u64_() orelse return E.PROTO;
                const count = r.u32_() orelse return E.PROTO;
                const h = f.handle orelse return E.BADF;
                const room = w.b.len -| (w.n + 4);
                const want = @min(count, room);
                var n: usize = 0;
                const e = vt.read(ctx, h, off, w.b[w.n + 4 ..][0..want], &n);
                if (e != 0) return e;
                w.u32_(@intCast(n));
                w.n += n;
            },
            t_write => {
                const f = s.fid(r) orelse return E.BADF;
                const off = r.u64_() orelse return E.PROTO;
                const count = r.u32_() orelse return E.PROTO;
                const data = r.bytes(count) orelse return E.PROTO;
                const h = f.handle orelse return E.BADF;
                if (ro) return E.ROFS;
                var n: usize = 0;
                const e = vt.write(ctx, h, off, data, &n);
                if (e != 0) return e;
                w.u32_(@intCast(n));
            },
            t_readdir => {
                const f = s.fid(r) orelse return E.BADF;
                const off = r.u64_() orelse return E.PROTO;
                const count = r.u32_() orelse return E.PROTO;
                const h = f.handle orelse return E.BADF;
                const start = w.n + 4;
                const end = @min(w.b.len, start + count);
                var sink: Sink = .{ .b = w.b[start..end] };
                const e = vt.readdir(ctx, h, off, .{ .ctx = &sink, .put = Sink.put });
                if (e != 0 and sink.n == 0) return e;
                w.u32_(@intCast(sink.n));
                w.n += sink.n;
            },
            t_fsync => {
                const f = s.fid(r) orelse return E.BADF;
                const data_only = (r.u32_() orelse 0) != 0;
                const h = f.handle orelse return E.BADF;
                return vt.fsync(ctx, h, data_only);
            },
            t_mkdir => {
                const f = s.fid(r) orelse return E.BADF;
                const name = r.str() orelse return E.PROTO;
                const mode = r.u32_() orelse return E.PROTO;
                if (ro) return E.ROFS;
                var buf: [max_path]u8 = undefined;
                const np = child(&buf, f.path, name) orelse return E.INVAL;
                var e = vt.mkdir(ctx, f.path, name, mode & 0o7777);
                if (e != 0) return e;
                var a: Attr = .{};
                e = s.stat(np, &a);
                if (e != 0) return e;
                w.qid(a.qid());
            },
            t_symlink => {
                const f = s.fid(r) orelse return E.BADF;
                const name = r.str() orelse return E.PROTO;
                const target = r.str() orelse return E.PROTO;
                if (ro) return E.ROFS;
                var buf: [max_path]u8 = undefined;
                const np = child(&buf, f.path, name) orelse return E.INVAL;
                var e = vt.symlink(ctx, f.path, name, target);
                if (e != 0) return e;
                var a: Attr = .{};
                e = s.stat(np, &a);
                if (e != 0) return e;
                w.qid(a.qid());
            },
            t_mknod => return if (ro) E.ROFS else E.PERM,
            t_readlink => {
                const f = s.fid(r) orelse return E.BADF;
                var buf: [max_path]u8 = undefined;
                var n: usize = 0;
                const e = vt.readlink(ctx, f.path, &buf, &n);
                if (e != 0) return e;
                w.str(buf[0..n]);
            },
            t_link => {
                const d = s.fid(r) orelse return E.BADF;
                const f = s.fid(r) orelse return E.BADF;
                const name = r.str() orelse return E.PROTO;
                if (ro) return E.ROFS;
                if (!validName(name)) return E.INVAL;
                return vt.link(ctx, f.path, d.path, name);
            },
            t_rename => {
                const f = s.fid(r) orelse return E.BADF;
                const d = s.fid(r) orelse return E.BADF;
                const name = r.str() orelse return E.PROTO;
                if (ro) return E.ROFS;
                if (!validName(name)) return E.INVAL;
                const sp = split(f.path) orelse return E.INVAL;
                const e = vt.rename(ctx, sp.dir, sp.name, d.path, name);
                if (e != 0) return e;
                var buf: [max_path]u8 = undefined;
                if (child(&buf, d.path, name)) |np| {
                    if (s.alloc.dupe(u8, np)) |p| {
                        s.alloc.free(f.path);
                        f.path = p;
                    } else |_| {}
                }
            },
            t_renameat => {
                const od = s.fid(r) orelse return E.BADF;
                const oname = r.str() orelse return E.PROTO;
                const nd = s.fid(r) orelse return E.BADF;
                const nname = r.str() orelse return E.PROTO;
                if (ro) return E.ROFS;
                if (!validName(oname) or !validName(nname)) return E.INVAL;
                return vt.rename(ctx, od.path, oname, nd.path, nname);
            },
            t_unlinkat => {
                const d = s.fid(r) orelse return E.BADF;
                const name = r.str() orelse return E.PROTO;
                const flags = r.u32_() orelse return E.PROTO;
                if (ro) return E.ROFS;
                if (!validName(name)) return E.INVAL;
                return vt.unlink(ctx, d.path, name, flags & 0x200 != 0);
            },
            t_lock => {
                _ = s.fid(r) orelse return E.BADF;
                // Each lock of the guest is granted: the host has no
                // other client of the share.
                w.u8_(0);
            },
            t_getlock => {
                _ = s.fid(r) orelse return E.BADF;
                _ = r.u8_() orelse return E.PROTO;
                const start = r.u64_() orelse return E.PROTO;
                const length = r.u64_() orelse return E.PROTO;
                const pid = r.u32_() orelse return E.PROTO;
                const client = r.str() orelse return E.PROTO;
                w.u8_(2); // F_UNLCK: no lock is in the way.
                w.u64_(start);
                w.u64_(length);
                w.u32_(pid);
                w.str(client);
            },
            t_xattrwalk, t_xattrcreate => return E.OPNOTSUPP,
            else => return E.NOSYS,
        }
        return 0;
    }
};

const t_statfs = 8;
const t_lopen = 12;
const t_lcreate = 14;
const t_symlink = 16;
const t_mknod = 18;
const t_rename = 20;
const t_readlink = 22;
const t_getattr = 24;
const t_setattr = 26;
const t_xattrwalk = 30;
const t_xattrcreate = 32;
const t_readdir = 40;
const t_fsync = 50;
const t_lock = 52;
const t_getlock = 54;
const t_link = 70;
const t_mkdir = 72;
const t_renameat = 74;
const t_unlinkat = 76;
const t_version = 100;
const t_auth = 102;
const t_attach = 104;
const t_flush = 108;
const t_walk = 110;
const t_read = 116;
const t_write = 118;
const t_clunk = 120;
const t_remove = 122;
const r_lerror = 7;

/// A name of one folder entry: not empty, not "." or "..", and with no
/// "/" or NUL in it.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

/// The path of `name` in the folder `dir`, in `buf`.
fn child(buf: *[max_path]u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (!validName(name)) return null;
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

/// One step of a walk from the path `buf[0..len]`: ".." goes to the
/// parent (the root folder stays the root folder), and a name goes in.
/// Gives the new length.
fn stepPath(buf: *[max_path]u8, len: usize, name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "..")) {
        const i = std.mem.lastIndexOfScalar(u8, buf[0..len], '/') orelse return 0;
        return i;
    }
    if (std.mem.eql(u8, name, ".")) return len;
    if (!validName(name)) return null;
    const n = len + @intFromBool(len != 0) + name.len;
    if (n > buf.len) return null;
    var i = len;
    if (len != 0) {
        buf[len] = '/';
        i += 1;
    }
    @memcpy(buf[i..][0..name.len], name);
    return n;
}

/// The folder and the name of a path that is not the root folder.
fn split(path: []const u8) ?struct { dir: []const u8, name: []const u8 } {
    if (path.len == 0) return null;
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return .{ .dir = "", .name = path };
    return .{ .dir = path[0..i], .name = path[i + 1 ..] };
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,
    fn u8_(r: *Reader) ?u8 {
        if (r.i + 1 > r.b.len) return null;
        r.i += 1;
        return r.b[r.i - 1];
    }
    fn u16_(r: *Reader) ?u16 {
        if (r.i + 2 > r.b.len) return null;
        defer r.i += 2;
        return std.mem.readInt(u16, r.b[r.i..][0..2], .little);
    }
    fn u32_(r: *Reader) ?u32 {
        if (r.i + 4 > r.b.len) return null;
        defer r.i += 4;
        return std.mem.readInt(u32, r.b[r.i..][0..4], .little);
    }
    fn u64_(r: *Reader) ?u64 {
        if (r.i + 8 > r.b.len) return null;
        defer r.i += 8;
        return std.mem.readInt(u64, r.b[r.i..][0..8], .little);
    }
    fn bytes(r: *Reader, n: usize) ?[]const u8 {
        if (n > r.b.len - r.i) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
    fn str(r: *Reader) ?[]const u8 {
        const n = r.u16_() orelse return null;
        return r.bytes(n);
    }
};

const Writer = struct {
    b: []u8,
    n: usize,
    over: bool = false,
    fn room(w: *Writer, k: usize) ?[]u8 {
        if (w.n + k > w.b.len) {
            w.over = true;
            return null;
        }
        defer w.n += k;
        return w.b[w.n..][0..k];
    }
    fn u8_(w: *Writer, v: u8) void {
        if (w.room(1)) |p| p[0] = v;
    }
    fn u16_(w: *Writer, v: u16) void {
        if (w.room(2)) |p| std.mem.writeInt(u16, p[0..2], v, .little);
    }
    fn u32_(w: *Writer, v: u32) void {
        if (w.room(4)) |p| std.mem.writeInt(u32, p[0..4], v, .little);
    }
    fn u64_(w: *Writer, v: u64) void {
        if (w.room(8)) |p| std.mem.writeInt(u64, p[0..8], v, .little);
    }
    fn str(w: *Writer, s: []const u8) void {
        w.u16_(@intCast(@min(s.len, 0xffff)));
        if (w.room(s.len)) |p| @memcpy(p, s);
    }
    fn qid(w: *Writer, q: Qid) void {
        w.u8_(q.kind);
        w.u32_(q.version);
        w.u64_(q.path);
    }
};

/// The entries of `Treaddir`: qid, offset, type, and name.
const Sink = struct {
    b: []u8,
    n: usize = 0,
    fn put(ctx: *anyopaque, e: Dirent) bool {
        const s: *Sink = @ptrCast(@alignCast(ctx));
        const need = 13 + 8 + 1 + 2 + e.name.len;
        if (s.n + need > s.b.len) return false;
        var w: Writer = .{ .b = s.b, .n = s.n };
        w.qid(.{ .kind = if (e.kind == 4) Qid.dir else if (e.kind == 10) Qid.symlink else Qid.file, .path = e.ino });
        w.u64_(e.next);
        w.u8_(e.kind);
        w.str(e.name);
        s.n = w.n;
        return true;
    }
};

// The tests run the server against a file system in memory: a root
// folder with the file "a" (5 bytes) and the folder "d".

const MemFs = struct {
    data: [64]u8 = "hello".* ++ @as([59]u8, @splat(0)),
    len: usize = 5,
    made: bool = false,
    opens: u32 = 0,

    fn attr(kind: u32, ino: u64, size: u64) Attr {
        return .{ .mode = kind | 0o755, .ino = ino, .size = size, .nlink = 1 };
    }
    fn stat(ctx: *anyopaque, path: []const u8, out: *Attr) u32 {
        const m: *MemFs = @ptrCast(@alignCast(ctx));
        if (path.len == 0) out.* = attr(0o040000, 1, 0) else if (std.mem.eql(u8, path, "a")) out.* = attr(0o100000, 2, m.len) else if (std.mem.eql(u8, path, "d")) out.* = attr(0o040000, 3, 0) else if (m.made and std.mem.eql(u8, path, "d/n")) out.* = attr(0o100000, 4, 0) else return E.NOENT;
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
    fn readdir(_: *anyopaque, h: u64, off: u64, sink: DirSink) u32 {
        if (h != 1) return E.NOTDIR;
        const all = [_]Dirent{ .{ .ino = 2, .next = 1, .kind = 8, .name = "a" }, .{ .ino = 3, .next = 2, .kind = 4, .name = "d" } };
        for (all[@intCast(@min(off, 2))..]) |e| if (!sink.put(sink.ctx, e)) break;
        return 0;
    }
    fn fsync(_: *anyopaque, _: u64, _: bool) u32 {
        return 0;
    }
    fn none3(_: *anyopaque, _: []const u8, _: []const u8, _: u32) u32 {
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
    fn rename(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8) u32 {
        return E.PERM;
    }
    fn setattr(_: *anyopaque, _: []const u8, _: SetAttr) u32 {
        return 0;
    }
    fn statfs(_: *anyopaque, out: *StatFs) u32 {
        out.* = .{ .blocks = 10 };
        return 0;
    }
    const vt: Fs.VTable = .{ .stat = stat, .open = open, .create = create, .close = close, .read = read, .write = write, .readdir = readdir, .fsync = fsync, .mkdir = none3, .symlink = symlink, .link = symlink, .readlink = readlink, .unlink = unlink, .rename = rename, .setattr = setattr, .statfs = statfs };
};

const Msg = struct {
    b: [512]u8 = undefined,
    n: usize = 7,
    fn init(kind: u8) Msg {
        var m: Msg = .{};
        m.b[4] = kind;
        std.mem.writeInt(u16, m.b[5..7], 1, .little);
        return m;
    }
    fn w(m: *Msg) Writer {
        return .{ .b = &m.b, .n = m.n };
    }
    fn u32_(m: *Msg, v: u32) *Msg {
        var x = m.w();
        x.u32_(v);
        m.n = x.n;
        return m;
    }
    fn u64_(m: *Msg, v: u64) *Msg {
        var x = m.w();
        x.u64_(v);
        m.n = x.n;
        return m;
    }
    fn u16_(m: *Msg, v: u16) *Msg {
        var x = m.w();
        x.u16_(v);
        m.n = x.n;
        return m;
    }
    fn str(m: *Msg, s: []const u8) *Msg {
        var x = m.w();
        x.str(s);
        m.n = x.n;
        return m;
    }
    fn done(m: *Msg) []const u8 {
        std.mem.writeInt(u32, m.b[0..4], @intCast(m.n), .little);
        return m.b[0..m.n];
    }
};

fn testServer(fs: *MemFs, read_only: bool) Server {
    return Server.init(std.testing.allocator, .{ .ctx = fs, .read_only = read_only, .vt = &MemFs.vt });
}

fn call(s: *Server, msg: []const u8, out: []u8) []const u8 {
    return out[0..s.handle(msg, out)];
}

test "ninep: version, attach, walk, open, and read" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    var m = Msg.init(t_version);
    var r = call(&s, m.u32_(1 << 20).str("9P2000.L").done(), &out);
    try std.testing.expectEqual(@as(u8, t_version + 1), r[4]);
    try std.testing.expectEqual(max_msize, std.mem.readInt(u32, r[7..11], .little));
    m = Msg.init(t_attach);
    r = call(&s, m.u32_(0).u32_(~@as(u32, 0)).str("root").str("").u32_(0).done(), &out);
    try std.testing.expectEqual(@as(u8, t_attach + 1), r[4]);
    try std.testing.expectEqual(@as(u8, Qid.dir), r[7]);
    // A walk to "d", "..", and "a" ends at "a".
    m = Msg.init(t_walk);
    r = call(&s, m.u32_(0).u32_(1).u16_(3).str("d").str("..").str("a").done(), &out);
    try std.testing.expectEqual(@as(u8, t_walk + 1), r[4]);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, r[7..9], .little));
    try std.testing.expectEqualStrings("a", s.fids.get(1).?.path);
    // ".." of the root folder is the root folder.
    m = Msg.init(t_walk);
    r = call(&s, m.u32_(0).u32_(2).u16_(2).str("..").str("..").done(), &out);
    try std.testing.expectEqualStrings("", s.fids.get(2).?.path);
    // A name with "/" is refused.
    m = Msg.init(t_walk);
    r = call(&s, m.u32_(0).u32_(3).u16_(1).str("d/../a").done(), &out);
    try std.testing.expectEqual(@as(u8, r_lerror), r[4]);
    m = Msg.init(t_lopen);
    r = call(&s, m.u32_(1).u32_(O.RDONLY).done(), &out);
    try std.testing.expectEqual(@as(u8, t_lopen + 1), r[4]);
    m = Msg.init(t_read);
    r = call(&s, m.u32_(1).u64_(1).u32_(100).done(), &out);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, r[7..11], .little));
    try std.testing.expectEqualStrings("ello", r[11..15]);
    m = Msg.init(t_clunk);
    r = call(&s, m.u32_(1).done(), &out);
    try std.testing.expectEqual(@as(u8, t_clunk + 1), r[4]);
    try std.testing.expectEqual(@as(u32, 0), fs.opens);
}

test "ninep: a chain of msize 262,144 through the queue" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    var m = Msg.init(t_version);
    _ = call(&s, m.u32_(max_msize).str("9P2000.L").done(), &out);
    try std.testing.expectEqual(max_msize, s.msize);
    m = Msg.init(t_attach);
    _ = call(&s, m.u32_(0).u32_(~@as(u32, 0)).str("root").str("").u32_(0).done(), &out);
    m = Msg.init(t_walk);
    _ = call(&s, m.u32_(0).u32_(1).u16_(1).str("a").done(), &out);
    m = Msg.init(t_lopen);
    _ = call(&s, m.u32_(1).u32_(O.RDONLY).done(), &out);
    // The guest memory: the descriptors at 0, the available ring at
    // 0x2000, the used ring at 0x3000, the request at 0x4000, and 66
    // writable pages from 0x10000, as the guest gives them for an Rread
    // of msize 262,144.
    const mem_buf = try std.testing.allocator.alignedAlloc(u8, .@"8", 0x10000 + 66 * 4096);
    defer std.testing.allocator.free(mem_buf);
    @memset(mem_buf, 0);
    const mem: Mem = .{ .base = mem_buf.ptr, .size = mem_buf.len };
    var q: Queue = .{ .num = 256, .ready = true, .desc = 0, .avail = 0x2000, .used = 0x3000 };
    const Case = struct { msg: []const u8, kind: u8 };
    var big = Msg.init(t_read);
    var bad = Msg.init(t_read);
    for ([_]Case{
        .{ .msg = big.u32_(1).u64_(0).u32_(max_msize - 11).done(), .kind = t_read + 1 },
        // A size larger than the request: an Rlerror with its tag.
        .{ .msg = bad.u32_(1).u64_(0).u32_(100).done(), .kind = r_lerror },
    }, 0..) |c, round| {
        @memcpy(mem_buf[0x4000..][0..c.msg.len], c.msg);
        if (c.kind == r_lerror) std.mem.writeInt(u32, mem_buf[0x4000..][0..4], @intCast(c.msg.len + 100), .little);
        const n_desc = 67;
        for (0..n_desc) |i| {
            const at = 16 * i;
            const addr: u64 = if (i == 0) 0x4000 else 0x10000 + 4096 * (i - 1);
            const len: u32 = if (i == 0) @intCast(c.msg.len) else 4096;
            mem.put(u64, at, addr);
            mem.put(u32, at + 8, len);
            const next: u16 = if (i + 1 < n_desc) 1 else 0;
            mem.put(u16, at + 12, next | (if (i == 0) @as(u16, 0) else 2));
            mem.put(u16, at + 14, @intCast(i + 1));
        }
        mem.put(u16, 0x2004 + 2 * round, 0);
        mem.put(u16, 0x2002, @intCast(round + 1));
        try std.testing.expect(s.run(&q, mem));
        const len = std.mem.readInt(u32, mem_buf[0x3000 + 4 + 8 * round + 4 ..][0..4], .little);
        try std.testing.expect(len >= 11);
        try std.testing.expectEqual(c.kind, mem_buf[0x10000 + 4]);
        try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, mem_buf[0x10000 + 5 ..][0..2], .little));
    }
    try std.testing.expectEqual(@as(u32, 0), s.bad_chains);
    try std.testing.expectEqual(@as(u32, 1), s.bad_requests);
}

test "ninep: readdir in small pieces" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    var m = Msg.init(t_attach);
    _ = call(&s, m.u32_(0).u32_(~@as(u32, 0)).str("").str("").u32_(0).done(), &out);
    m = Msg.init(t_lopen);
    _ = call(&s, m.u32_(0).u32_(O.RDONLY | O.DIRECTORY).done(), &out);
    // Room for one entry of 25 bytes.
    m = Msg.init(t_readdir);
    var r = call(&s, m.u32_(0).u64_(0).u32_(30).done(), &out);
    try std.testing.expectEqual(@as(u32, 25), std.mem.readInt(u32, r[7..11], .little));
    try std.testing.expectEqualStrings("a", r[11 + 24 ..][0..1]);
    m = Msg.init(t_readdir);
    r = call(&s, m.u32_(0).u64_(1).u32_(300).done(), &out);
    try std.testing.expectEqual(@as(u32, 25), std.mem.readInt(u32, r[7..11], .little));
    try std.testing.expectEqualStrings("d", r[11 + 24 ..][0..1]);
}

test "ninep: create, write, and a read-only share" {
    var fs: MemFs = .{};
    var s = testServer(&fs, false);
    defer s.deinit();
    var out: [512]u8 = undefined;
    var m = Msg.init(t_attach);
    _ = call(&s, m.u32_(0).u32_(~@as(u32, 0)).str("").str("").u32_(0).done(), &out);
    m = Msg.init(t_walk);
    _ = call(&s, m.u32_(0).u32_(1).u16_(1).str("d").done(), &out);
    m = Msg.init(t_lcreate);
    var r = call(&s, m.u32_(1).str("n").u32_(O.RDWR).u32_(0o644).u32_(0).done(), &out);
    try std.testing.expectEqual(@as(u8, t_lcreate + 1), r[4]);
    try std.testing.expectEqualStrings("d/n", s.fids.get(1).?.path);
    m = Msg.init(t_walk);
    _ = call(&s, m.u32_(0).u32_(2).u16_(1).str("a").done(), &out);
    m = Msg.init(t_lopen);
    _ = call(&s, m.u32_(2).u32_(O.WRONLY).done(), &out);
    // The write: fid, offset, count, then the bytes.
    var wm = Msg.init(t_write);
    _ = wm.u32_(2).u64_(5).u32_(3);
    @memcpy(wm.b[wm.n..][0..3], "!!!");
    wm.n += 3;
    r = call(&s, wm.done(), &out);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, r[7..11], .little));
    try std.testing.expectEqualStrings("hello!!!", fs.data[0..fs.len]);

    var ro = testServer(&fs, true);
    defer ro.deinit();
    m = Msg.init(t_attach);
    _ = call(&ro, m.u32_(0).u32_(~@as(u32, 0)).str("").str("").u32_(0).done(), &out);
    m = Msg.init(t_lopen);
    r = call(&ro, m.u32_(0).u32_(O.RDWR).done(), &out);
    try std.testing.expectEqual(@as(u8, r_lerror), r[4]);
    try std.testing.expectEqual(@as(u32, E.ROFS), std.mem.readInt(u32, r[7..11], .little));
}
