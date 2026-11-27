//! The protocol between a parent and an isolated thread (ztcl#209), step
//! 2 of `docs/dev/isolation.md`: the transport, the frames, the
//! handshake, the sealing, and the byte form of values.
//!
//! A frame is a 4-byte length (little-endian), then the kind, the flags,
//! a 4-byte stream id, and the payload. The length counts each byte
//! after it, the 16-byte tag of a sealed frame too. After the handshake
//! each payload is sealed with ChaCha20-Poly1305, with the header as the
//! associated data and a nonce of 4 zero bytes and the 64-bit counter of
//! the direction (little-endian).
//!
//! The handshake: `HELLO` from the parent and `WELCOME` from the child,
//! in the clear. Each side makes a new X25519 key pair. HKDF-SHA256 makes
//! one key for each direction from the shared secret, with the bootstrap
//! secret of the level as the salt and the transcript (the SHA-256 of
//! `HELLO` and of `WELCOME` up to its proof) in the info. The proof of
//! the child is the tag of an empty message under the key of the child
//! with the counter 2^64 - 1, which no frame uses.
//!
//! Each reader treats the bytes of the other side as hostile: it checks
//! each length against its limits before it allocates, and a list of the
//! byte form nests at most `max_depth` levels.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const Value = value.Value;
const Allocator = std.mem.Allocator;
const on_win = builtin.os.tag == .windows;
const sys = if (on_win) struct {} else @import("sys.zig");
const posix = if (on_win) struct {} else sys.os;

pub const version: u16 = 1;
pub const max_payload: u32 = 1 << 20;
pub const max_depth = 200;
const header_len = 10;
const tag_len = 16;

pub const Error = error{ Closed, Canceled, Io, Protocol, Auth } || Allocator.Error;

pub const Kind = enum(u8) {
    hello = 1,
    welcome,
    start,
    ready,
    send,
    result,
    cancel,
    release,
    tsv,
    lock,
    unlock,
    output,
    bgerror,
    chan,
    fd,
    usage,
    exit,
    goodbye,
    _,
};

pub const flag_more: u8 = 1;
pub const flag_skip: u8 = 2;

/// Fills `buf` with random bytes of the system.
pub fn entropy(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos => std.c.arc4random_buf(buf.ptr, buf.len),
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const rc = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
                if (std.os.linux.errno(rc) == .SUCCESS) off += rc;
            }
        },
        .windows => _ = ProcessPrng(buf.ptr, buf.len),
        else => @compileError("no entropy for this platform"),
    }
}

extern "bcryptprimitives" fn ProcessPrng(data: [*]u8, len: usize) callconv(.winapi) c_int;

// ---- The transport ----

/// A stream of bytes in each direction: a socket pair or a pipe on
/// Linux and macOS, an overlapped named pipe on Windows. `cancel` wakes
/// a read that blocks, from another thread, and the read gives
/// `error.Canceled`.
pub const Transport = if (on_win) WinTransport else PosixTransport;

/// Descriptor passing (`SCM_RIGHTS`) on the socket pair: macOS for now.
/// Linux gets it with its runner, and Windows moves handles in its own
/// way (`docs/dev/isolation.md`).
pub const passes_fds = builtin.os.tag == .macos;

const Mac = struct {
    const iovec = extern struct { base: [*]u8, len: usize };
    const msghdr = extern struct {
        name: ?*anyopaque = null,
        namelen: u32 = 0,
        iov: *iovec,
        iovlen: c_int,
        control: ?*anyopaque,
        controllen: u32,
        flags: c_int = 0,
    };
    const cmsg_head = 12;
    const sol_socket: c_int = 0xffff;
    const scm_rights: c_int = 1;
    const msg_ctrunc: c_int = 0x20;
    extern "c" fn sendmsg(fd: c_int, msg: *const msghdr, flags: c_int) isize;
    extern "c" fn recvmsg(fd: c_int, msg: *msghdr, flags: c_int) isize;
};

/// The most descriptors that one frame brings.
pub const max_fds = 4;

const PosixTransport = struct {
    fd: i32,
    wake: [2]i32,
    /// The descriptors that came with the bytes read so far, oldest first.
    got: [16]i32 = undefined,
    ngot: usize = 0,

    pub fn init(fd: i32) Error!PosixTransport {
        var w: [2]i32 = undefined;
        if (posix.errno(posix.pipe2(&w, .{ .CLOEXEC = true })) != .SUCCESS) return error.Io;
        return .{ .fd = fd, .wake = w };
    }

    pub fn deinit(t: *PosixTransport) void {
        for (t.got[0..t.ngot]) |f| _ = posix.close(f);
        t.ngot = 0;
        _ = posix.close(t.fd);
        _ = posix.close(t.wake[0]);
        _ = posix.close(t.wake[1]);
    }

    pub fn cancel(t: *PosixTransport) void {
        const b = [1]u8{1};
        _ = posix.write(t.wake[1], &b, 1);
    }

    /// Reads at least one byte. `error.Closed` at the end of the stream.
    pub fn read(t: *PosixTransport, buf: []u8) Error!usize {
        while (true) {
            var fds = [2]posix.pollfd{
                .{ .fd = t.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = t.wake[0], .events = posix.POLL.IN, .revents = 0 },
            };
            const rc = posix.poll(&fds, 2, -1);
            if (posix.errno(rc) == .INTR) continue;
            if (posix.errno(rc) != .SUCCESS) return error.Io;
            if (fds[1].revents != 0) return error.Canceled;
            if (fds[0].revents == 0) continue;
            if (comptime passes_fds) {
                const n = t.readFds(buf);
                switch (posix.errno(@as(usize, @bitCast(n)))) {
                    .SUCCESS => return if (n == 0) error.Closed else @intCast(n),
                    .INTR, .AGAIN => continue,
                    else => return error.Io,
                }
            }
            const n = posix.read(t.fd, buf.ptr, buf.len);
            switch (posix.errno(n)) {
                .SUCCESS => return if (n == 0) error.Closed else n,
                .INTR, .AGAIN => continue,
                else => return error.Io,
            }
        }
    }

    /// `recvmsg`: the bytes, and each descriptor that came with them to
    /// `got`. A descriptor past the room of `got` closes.
    fn readFds(t: *PosixTransport, buf: []u8) isize {
        var iov: Mac.iovec = .{ .base = buf.ptr, .len = buf.len };
        var ctl: [Mac.cmsg_head + 4 * max_fds]u8 align(4) = undefined;
        var m: Mac.msghdr = .{ .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = ctl.len };
        const n = Mac.recvmsg(t.fd, &m, 0);
        if (n < 0 or m.controllen < Mac.cmsg_head) return n;
        const len = std.mem.readInt(u32, ctl[0..4], .little);
        const level = std.mem.readInt(i32, ctl[4..8], .little);
        const kind = std.mem.readInt(i32, ctl[8..12], .little);
        if (level != Mac.sol_socket or kind != Mac.scm_rights or len < Mac.cmsg_head) return n;
        const count = @min((len - Mac.cmsg_head) / 4, max_fds);
        for (0..count) |k| {
            const f = std.mem.readInt(i32, ctl[Mac.cmsg_head + 4 * k ..][0..4], .little);
            _ = std.c.fcntl(f, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
            if (t.ngot < t.got.len) {
                t.got[t.ngot] = f;
                t.ngot += 1;
            } else _ = posix.close(f);
        }
        return n;
    }

    /// Takes the oldest descriptor that came with the bytes, or null.
    pub fn takeFd(t: *PosixTransport) ?i32 {
        if (t.ngot == 0) return null;
        const f = t.got[0];
        std.mem.copyForwards(i32, t.got[0 .. t.ngot - 1], t.got[1..t.ngot]);
        t.ngot -= 1;
        return f;
    }

    /// Writes `bytes`, with `fds` on their first byte (`SCM_RIGHTS`).
    pub fn writeAllFds(t: *PosixTransport, bytes: []const u8, fds: []const i32) Error!void {
        if (comptime !passes_fds) return error.Io;
        if (fds.len == 0 or fds.len > max_fds or bytes.len == 0) return error.Protocol;
        var ctl: [Mac.cmsg_head + 4 * max_fds]u8 align(4) = undefined;
        const clen: u32 = @intCast(Mac.cmsg_head + 4 * fds.len);
        std.mem.writeInt(u32, ctl[0..4], clen, .little);
        std.mem.writeInt(i32, ctl[4..8], Mac.sol_socket, .little);
        std.mem.writeInt(i32, ctl[8..12], Mac.scm_rights, .little);
        for (fds, 0..) |f, k| std.mem.writeInt(i32, ctl[Mac.cmsg_head + 4 * k ..][0..4], f, .little);
        var iov: Mac.iovec = .{ .base = @constCast(bytes.ptr), .len = bytes.len };
        const m: Mac.msghdr = .{ .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = clen };
        while (true) {
            const n = Mac.sendmsg(t.fd, &m, 0);
            switch (posix.errno(@as(usize, @bitCast(n)))) {
                .SUCCESS => return t.writeAll(bytes[@intCast(n)..]),
                .INTR, .AGAIN => continue,
                .PIPE => return error.Closed,
                else => return error.Io,
            }
        }
    }

    pub fn writeAll(t: *PosixTransport, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = posix.write(t.fd, bytes[off..].ptr, bytes.len - off);
            switch (posix.errno(n)) {
                .SUCCESS => off += n,
                .INTR, .AGAIN => continue,
                .PIPE => return error.Closed,
                else => return error.Io,
            }
        }
    }
};

const WinTransport = struct {
    const w = std.os.windows;
    const HANDLE = w.HANDLE;
    const OVERLAPPED = extern struct {
        internal: usize = 0,
        internal_high: usize = 0,
        offset: u32 = 0,
        offset_high: u32 = 0,
        event: ?HANDLE = null,
    };
    extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: i32, initial: i32, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, got: ?*u32, ov: *OVERLAPPED) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, put: ?*u32, ov: *OVERLAPPED) callconv(.winapi) i32;
    extern "kernel32" fn GetOverlappedResult(h: HANDLE, ov: *OVERLAPPED, n: *u32, wait: i32) callconv(.winapi) i32;
    extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) i32;
    extern "kernel32" fn WaitForMultipleObjects(n: u32, hs: [*]const HANDLE, all: i32, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
    const error_io_pending = 997;
    const error_broken_pipe = 109;
    const error_operation_aborted = 995;
    const infinite = 0xffff_ffff;

    /// The pipe, opened with FILE_FLAG_OVERLAPPED.
    h: HANDLE,
    /// A manual-reset event of the read, of the write, and of `cancel`.
    rd_ev: HANDLE,
    wr_ev: HANDLE,
    cancel_ev: HANDLE,

    pub fn init(h: HANDLE) Error!WinTransport {
        const a = CreateEventW(null, 1, 0, null) orelse return error.Io;
        const b = CreateEventW(null, 1, 0, null) orelse return error.Io;
        const c = CreateEventW(null, 1, 0, null) orelse return error.Io;
        return .{ .h = h, .rd_ev = a, .wr_ev = b, .cancel_ev = c };
    }

    pub fn deinit(t: *WinTransport) void {
        _ = CloseHandle(t.h);
        _ = CloseHandle(t.rd_ev);
        _ = CloseHandle(t.wr_ev);
        _ = CloseHandle(t.cancel_ev);
    }

    pub fn cancel(t: *WinTransport) void {
        _ = SetEvent(t.cancel_ev);
    }

    pub fn read(t: *WinTransport, buf: []u8) Error!usize {
        var ov: OVERLAPPED = .{ .event = t.rd_ev };
        var n: u32 = 0;
        const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (ReadFile(t.h, buf.ptr, len, null, &ov) == 0) {
            const e = GetLastError();
            if (e == error_broken_pipe) return error.Closed;
            if (e != error_io_pending) return error.Io;
            const hs = [2]HANDLE{ t.rd_ev, t.cancel_ev };
            const r = WaitForMultipleObjects(2, &hs, 0, infinite);
            if (r == 1) {
                // The read must end before `ov` and `buf` go.
                _ = CancelIoEx(t.h, &ov);
                _ = GetOverlappedResult(t.h, &ov, &n, 1);
                return error.Canceled;
            }
            if (r != 0) return error.Io;
        }
        if (GetOverlappedResult(t.h, &ov, &n, 1) == 0) {
            return if (GetLastError() == error_broken_pipe) error.Closed else error.Io;
        }
        if (n == 0) return error.Closed;
        return n;
    }

    pub fn writeAll(t: *WinTransport, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            var ov: OVERLAPPED = .{ .event = t.wr_ev };
            var n: u32 = 0;
            const len: u32 = @intCast(@min(bytes.len - off, std.math.maxInt(u32)));
            if (WriteFile(t.h, bytes[off..].ptr, len, null, &ov) == 0 and GetLastError() != error_io_pending) {
                return if (GetLastError() == error_broken_pipe) error.Closed else error.Io;
            }
            if (GetOverlappedResult(t.h, &ov, &n, 1) == 0) {
                return if (GetLastError() == error_broken_pipe) error.Closed else error.Io;
            }
            off += n;
        }
    }
};

// ---- The frames ----

pub const Frame = struct {
    kind: Kind,
    flags: u8,
    stream: u32,
    /// Owned by the caller of `readFrame`.
    payload: []u8,
};

const Seal = struct {
    send_key: [32]u8,
    recv_key: [32]u8,
    send_ctr: u64 = 0,
    recv_ctr: u64 = 0,
};

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

fn nonce(ctr: u64) [12]u8 {
    var n: [12]u8 = @splat(0);
    std.mem.writeInt(u64, n[4..12], ctr, .little);
    return n;
}

/// One end of a connection.
pub const Conn = struct {
    t: *Transport,
    seal: ?Seal = null,
    /// The bytes read past the last frame.
    buf: [4096]u8 = undefined,
    have: usize = 0,
    start: usize = 0,

    pub fn init(t: *Transport) Conn {
        return .{ .t = t };
    }

    fn readExact(c: *Conn, out: []u8) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            if (c.start == c.have) {
                c.start = 0;
                c.have = 0;
                // A large payload goes straight to its buffer.
                if (out.len - off >= c.buf.len) {
                    off += try c.t.read(out[off..]);
                    continue;
                }
                c.have = try c.t.read(&c.buf);
            }
            const n = @min(out.len - off, c.have - c.start);
            @memcpy(out[off..][0..n], c.buf[c.start..][0..n]);
            c.start += n;
            off += n;
        }
    }

    fn header(len: u32, kind: Kind, flags: u8, stream: u32) [header_len]u8 {
        var h: [header_len]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], len, .little);
        h[4] = @backingInt(kind);
        h[5] = flags;
        std.mem.writeInt(u32, h[6..10], stream, .little);
        return h;
    }

    /// Writes one frame, sealed after the handshake.
    pub fn writeFrame(c: *Conn, a: Allocator, kind: Kind, flags: u8, stream: u32, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.Protocol;
        const sealed = c.seal != null;
        const body: usize = 6 + payload.len + @as(usize, if (sealed) tag_len else 0);
        const out = try a.alloc(u8, 4 + body);
        defer a.free(out);
        const h = header(@intCast(body), kind, flags, stream);
        @memcpy(out[0..header_len], &h);
        if (c.seal) |*s| {
            var tag: [tag_len]u8 = undefined;
            Aead.encrypt(out[header_len..][0..payload.len], &tag, payload, &h, nonce(s.send_ctr), s.send_key);
            @memcpy(out[header_len + payload.len ..][0..tag_len], &tag);
            s.send_ctr += 1;
        } else {
            @memcpy(out[header_len..][0..payload.len], payload);
        }
        try c.t.writeAll(out);
    }

    /// Reads one frame and checks its tag. A frame of an unknown kind
    /// with the flag `skip` is read and dropped.
    pub fn readFrame(c: *Conn, a: Allocator) Error!Frame {
        while (true) {
            var h: [header_len]u8 = undefined;
            try c.readExact(&h);
            const len = std.mem.readInt(u32, h[0..4], .little);
            const extra: u32 = if (c.seal != null) tag_len else 0;
            if (len < 6 + extra or len - 6 - extra > max_payload) return error.Protocol;
            const n = len - 6 - extra;
            const payload = try a.alloc(u8, n);
            errdefer a.free(payload);
            try c.readExact(payload);
            if (c.seal) |*s| {
                var tag: [tag_len]u8 = undefined;
                try c.readExact(&tag);
                Aead.decrypt(payload, payload, tag, &h, nonce(s.recv_ctr), s.recv_key) catch return error.Auth;
                s.recv_ctr += 1;
            }
            const kind: Kind = @fromBackingInt(h[4]);
            const known = @backingInt(kind) >= @backingInt(Kind.hello) and @backingInt(kind) <= @backingInt(Kind.goodbye);
            if (!known) {
                if (h[5] & flag_skip == 0) return error.Protocol;
                a.free(payload);
                continue;
            }
            return .{ .kind = kind, .flags = h[5], .stream = std.mem.readInt(u32, h[6..10], .little), .payload = payload };
        }
    }

    /// Writes one frame with descriptors (`passes_fds`). The payload
    /// fits in one frame.
    pub fn writeFrameFds(c: *Conn, a: Allocator, kind: Kind, stream: u32, payload: []const u8, fds: []const i32) Error!void {
        if (comptime !passes_fds) return error.Io;
        if (payload.len > max_payload) return error.Protocol;
        const sealed = c.seal != null;
        const body: usize = 6 + payload.len + @as(usize, if (sealed) tag_len else 0);
        const out = try a.alloc(u8, 4 + body);
        defer a.free(out);
        const h = header(@intCast(body), kind, 0, stream);
        @memcpy(out[0..header_len], &h);
        if (c.seal) |*s| {
            var tag: [tag_len]u8 = undefined;
            Aead.encrypt(out[header_len..][0..payload.len], &tag, payload, &h, nonce(s.send_ctr), s.send_key);
            @memcpy(out[header_len + payload.len ..][0..tag_len], &tag);
            s.send_ctr += 1;
        } else {
            @memcpy(out[header_len..][0..payload.len], payload);
        }
        try c.t.writeAllFds(out, fds);
    }

    /// Writes a message of any size as frames of at most `max_payload`
    /// bytes, with the flag `more` on each frame but the last.
    pub fn writeMessage(c: *Conn, a: Allocator, kind: Kind, stream: u32, payload: []const u8) Error!void {
        var off: usize = 0;
        while (true) {
            const n = @min(payload.len - off, max_payload);
            const last = off + n == payload.len;
            try c.writeFrame(a, kind, if (last) 0 else flag_more, stream, payload[off..][0..n]);
            off += n;
            if (last) return;
        }
    }
};

// ---- The handshake ----

pub const Hello = struct {
    min: u16,
    max: u16,
    services: []const []const u8,
    key: [32]u8,
    nonce: [32]u8,
};

pub const Welcome = struct {
    version: u16,
    service: []const u8,
    features: u32,
    key: [32]u8,
    nonce: [32]u8,
};

/// The child seals no frame (the wasm level).
pub const feature_plain: u32 = 1;
/// The child takes descriptors with its frames (`SCM_RIGHTS`, or a
/// handle on Windows).
pub const feature_fd: u32 = 2;

const W = struct {
    list: std.ArrayList(u8) = .empty,
    a: Allocator,
    fn u8_(w: *W, v: u8) !void {
        try w.list.append(w.a, v);
    }
    fn u16_(w: *W, v: u16) !void {
        try w.list.appendSlice(w.a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }
    fn u32_(w: *W, v: u32) !void {
        try w.list.appendSlice(w.a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }
    fn bytes(w: *W, b: []const u8) !void {
        try w.list.appendSlice(w.a, b);
    }
    fn short(w: *W, b: []const u8) !void {
        if (b.len > 255) return error.Protocol;
        try w.u8_(@intCast(b.len));
        try w.bytes(b);
    }
};

/// A reader of a payload. Each method fails with `error.Protocol` past
/// the end.
pub const Reader = struct {
    b: []const u8,
    i: usize = 0,

    pub fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.b.len - r.i < n) return error.Protocol;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
    pub fn int(r: *Reader, comptime T: type) Error!T {
        const s = try r.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
    fn short(r: *Reader) Error![]const u8 {
        return r.take((try r.take(1))[0]);
    }
    fn key(r: *Reader) Error![32]u8 {
        return (try r.take(32))[0..32].*;
    }
    pub fn done(r: *Reader) Error!void {
        if (r.i != r.b.len) return error.Protocol;
    }
};

fn frameBytes(a: Allocator, kind: Kind, payload: []const u8) Error![]u8 {
    const out = try a.alloc(u8, header_len + payload.len);
    const h = Conn.header(@intCast(6 + payload.len), kind, 0, 0);
    @memcpy(out[0..header_len], &h);
    @memcpy(out[header_len..], payload);
    return out;
}

const Keys = struct { p2c: [32]u8, c2p: [32]u8 };

fn keys(shared: [32]u8, secret: ?[32]u8, transcript: [32]u8) Keys {
    const H = std.crypto.kdf.hkdf.HkdfSha256;
    const zero: [32]u8 = @splat(0);
    const prk = H.extract(&(secret orelse zero), &shared);
    var info: [16 + 32]u8 = undefined;
    @memcpy(info[16..], &transcript);
    var out: Keys = undefined;
    @memcpy(info[0..16], "ztcl iso v1 p2c ");
    H.expand(&out.p2c, &info, prk);
    @memcpy(info[0..16], "ztcl iso v1 c2p ");
    H.expand(&out.c2p, &info, prk);
    return out;
}

const proof_ctr: u64 = std.math.maxInt(u64);

fn proofTag(key: [32]u8, transcript: [32]u8) [tag_len]u8 {
    var tag: [tag_len]u8 = undefined;
    Aead.encrypt(&.{}, &tag, &.{}, &transcript, nonce(proof_ctr), key);
    return tag;
}

fn newKeyPair() std.crypto.dh.X25519.KeyPair {
    var seed: [32]u8 = undefined;
    entropy(&seed);
    return std.crypto.dh.X25519.KeyPair.generateDeterministic(seed);
}

/// The handshake of the parent. `secret` is the bootstrap secret of the
/// level, or null. On success the frames of `c` are sealed, unless the
/// child asked for `feature_plain` and `allow_plain` is true.
pub fn parentHandshake(c: *Conn, a: Allocator, secret: ?[32]u8, services: []const []const u8, allow_plain: bool) Error!Welcome {
    const kp = newKeyPair();
    var np: [32]u8 = undefined;
    entropy(&np);
    var w: W = .{ .a = a };
    defer w.list.deinit(a);
    try w.u16_(version);
    try w.u16_(version);
    try w.u8_(@intCast(services.len));
    for (services) |s| try w.short(s);
    try w.bytes(&kp.public_key);
    try w.bytes(&np);
    try c.writeFrame(a, .hello, 0, 0, w.list.items);
    const hello_bytes = try frameBytes(a, .hello, w.list.items);
    defer a.free(hello_bytes);

    const f = try c.readFrame(a);
    defer a.free(f.payload);
    if (f.kind != .welcome or f.payload.len < tag_len) return error.Protocol;
    var r: Reader = .{ .b = f.payload[0 .. f.payload.len - tag_len] };
    const wel: Welcome = .{
        .version = try r.int(u16),
        .service = try a.dupe(u8, try r.short()),
        .features = try r.int(u32),
        .key = try r.key(),
        .nonce = try r.key(),
    };
    errdefer a.free(wel.service);
    try r.done();
    if (wel.version != version) return error.Protocol;
    var known = false;
    for (services) |s| known = known or std.mem.eql(u8, s, wel.service);
    if (!known) return error.Protocol;

    var th = std.crypto.hash.sha2.Sha256.init(.{});
    th.update(hello_bytes);
    const head = Conn.header(@intCast(f.payload.len + 6), .welcome, 0, 0);
    th.update(&head);
    th.update(f.payload[0 .. f.payload.len - tag_len]);
    const transcript = th.finalResult();
    const shared = std.crypto.dh.X25519.scalarmult(kp.secret_key, wel.key) catch return error.Auth;
    const k = keys(shared, secret, transcript);
    const want = proofTag(k.c2p, transcript);
    if (!std.crypto.timing_safe.eql([tag_len]u8, want, f.payload[f.payload.len - tag_len ..][0..tag_len].*)) return error.Auth;
    if (wel.features & feature_plain != 0) {
        if (!allow_plain) return error.Protocol;
    } else c.seal = .{ .send_key = k.p2c, .recv_key = k.c2p };
    return wel;
}

/// The handshake of the child: reads `HELLO`, picks `service`, and
/// answers. The parent proves its key with its first sealed frame.
pub fn childHandshake(c: *Conn, a: Allocator, secret: ?[32]u8, service: []const u8, features: u32) Error!void {
    const f = try c.readFrame(a);
    defer a.free(f.payload);
    if (f.kind != .hello) return error.Protocol;
    var r: Reader = .{ .b = f.payload };
    const min = try r.int(u16);
    const max = try r.int(u16);
    const n = (try r.take(1))[0];
    var offered = false;
    for (0..n) |_| offered = offered or std.mem.eql(u8, try r.short(), service);
    const ep = try r.key();
    _ = try r.key();
    try r.done();
    if (version < min or version > max or !offered) return error.Protocol;
    const hello_bytes = try frameBytes(a, .hello, f.payload);
    defer a.free(hello_bytes);

    const kp = newKeyPair();
    var nc: [32]u8 = undefined;
    entropy(&nc);
    var w: W = .{ .a = a };
    defer w.list.deinit(a);
    try w.u16_(version);
    try w.short(service);
    try w.u32_(features);
    try w.bytes(&kp.public_key);
    try w.bytes(&nc);
    var th = std.crypto.hash.sha2.Sha256.init(.{});
    th.update(hello_bytes);
    const head = Conn.header(@intCast(w.list.items.len + tag_len + 6), .welcome, 0, 0);
    th.update(&head);
    th.update(w.list.items);
    const transcript = th.finalResult();
    const shared = std.crypto.dh.X25519.scalarmult(kp.secret_key, ep) catch return error.Auth;
    const k = keys(shared, secret, transcript);
    try w.bytes(&proofTag(k.c2p, transcript));
    try c.writeFrame(a, .welcome, 0, 0, w.list.items);
    if (features & feature_plain == 0) c.seal = .{ .send_key = k.c2p, .recv_key = k.p2c };
}

// ---- The byte form of values ----

/// Appends the byte form of `v`: `i` and an 8-byte integer, `d` and an
/// 8-byte double, `s` with a 4-byte length and the bytes, or `l` with a
/// 4-byte count and the items. A list deeper than `max_depth` goes as
/// its string form, from `strOf`.
pub fn encodeValue(a: Allocator, out: *std.ArrayList(u8), v: Value, depth: u32, ctx: anytype, comptime strOf: fn (@TypeOf(ctx), Value) Allocator.Error![]const u8) Allocator.Error!void {
    switch (v) {
        .int => |i| {
            try out.append(a, 'i');
            try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(i64, i)));
        },
        .double => |d| {
            try out.append(a, 'd');
            try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(d))));
        },
        .str => |s| try encodeStr(a, out, s),
        .list => |l| {
            if (depth >= max_depth) return encodeStr(a, out, try strOf(ctx, v));
            const items = l.items();
            try out.append(a, 'l');
            try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(items.len))));
            for (items) |x| try encodeValue(a, out, x, depth + 1, ctx, strOf);
        },
    }
}

fn encodeStr(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, 's');
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(s.len))));
    try out.appendSlice(a, s);
}

/// Reads a value of the byte form into `a`. Bad bytes or a list deeper
/// than `max_depth` give `error.Protocol`.
pub fn decodeValue(a: Allocator, r: *Reader, depth: u32) Error!Value {
    if (depth > max_depth) return error.Protocol;
    const tag = (try r.take(1))[0];
    switch (tag) {
        'i' => return .{ .int = try r.int(i64) },
        'd' => return .{ .double = @bitCast(try r.int(u64)) },
        's' => {
            const n = try r.int(u32);
            return .{ .str = try a.dupe(u8, try r.take(n)) };
        },
        'l' => {
            const n = try r.int(u32);
            // Each item has at least one byte.
            if (n > r.b.len - r.i) return error.Protocol;
            const buf = try a.alloc(Value, n);
            for (buf) |*x| x.* = try decodeValue(a, r, depth + 1);
            return value.wrapList(a, buf);
        },
        else => return error.Protocol,
    }
}

// ---- Tests ----

fn testPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (builtin.os.tag == .linux) {
        if (std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return error.Io;
    } else {
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.Io;
    }
    return fds;
}

const ChildCtx = struct {
    t: *Transport,
    secret: ?[32]u8,
    features: u32 = 0,
    err: ?anyerror = null,
    got: [64]u8 = undefined,
    got_len: usize = 0,
};

fn childMain(x: *ChildCtx) void {
    const a = std.heap.page_allocator;
    var c = Conn.init(x.t);
    childHandshake(&c, a, x.secret, "thread", x.features) catch |e| {
        x.err = e;
        return;
    };
    const f = c.readFrame(a) catch |e| {
        x.err = e;
        return;
    };
    defer a.free(f.payload);
    @memcpy(x.got[0..f.payload.len], f.payload);
    x.got_len = f.payload.len;
    c.writeFrame(a, .ready, 0, f.stream, "ready") catch |e| {
        x.err = e;
    };
}

test "isoproto: a sealed handshake and frames over a socket pair" {
    if (comptime on_win or builtin.os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fds = try testPair();
    var tp = try Transport.init(fds[0]);
    defer tp.deinit();
    var tc = try Transport.init(fds[1]);
    defer tc.deinit();
    const secret: [32]u8 = @splat(7);
    var x: ChildCtx = .{ .t = &tc, .secret = secret };
    const th = try std.Thread.spawn(.{}, childMain, .{&x});
    var c = Conn.init(&tp);
    const wel = try parentHandshake(&c, a, secret, &.{ "agent", "thread" }, false);
    defer a.free(wel.service);
    try std.testing.expectEqualStrings("thread", wel.service);
    try std.testing.expect(c.seal != null);
    try c.writeFrame(a, .start, 0, 2, "start the thread");
    const f = try c.readFrame(a);
    defer a.free(f.payload);
    th.join();
    try std.testing.expect(x.err == null);
    try std.testing.expectEqualStrings("start the thread", x.got[0..x.got_len]);
    try std.testing.expectEqual(Kind.ready, f.kind);
    try std.testing.expectEqual(@as(u32, 2), f.stream);
    try std.testing.expectEqualStrings("ready", f.payload);
}

test "isoproto: a wrong bootstrap secret fails the proof" {
    if (comptime on_win or builtin.os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fds = try testPair();
    var tp = try Transport.init(fds[0]);
    defer tp.deinit();
    var tc = try Transport.init(fds[1]);
    defer tc.deinit();
    var x: ChildCtx = .{ .t = &tc, .secret = @splat(1) };
    const th = try std.Thread.spawn(.{}, childMain, .{&x});
    var c = Conn.init(&tp);
    try std.testing.expectError(error.Auth, parentHandshake(&c, a, @splat(2), &.{"thread"}, false));
    tp.cancel();
    // The child waits for a frame that never comes: end its read.
    tc.cancel();
    th.join();
}

test "isoproto: a changed byte of a sealed frame fails its tag" {
    if (comptime on_win or builtin.os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fds = try testPair();
    var tp = try Transport.init(fds[0]);
    defer tp.deinit();
    var tc = try Transport.init(fds[1]);
    defer tc.deinit();
    var p = Conn.init(&tp);
    var q = Conn.init(&tc);
    const k: [32]u8 = @splat(3);
    p.seal = .{ .send_key = k, .recv_key = k };
    q.seal = .{ .send_key = k, .recv_key = k };
    try p.writeFrame(a, .send, 0, 4, "set x 1");
    const f = try q.readFrame(a);
    a.free(f.payload);
    // A frame of the right length with a changed byte.
    var raw: [header_len + 3 + tag_len]u8 = undefined;
    const h = Conn.header(6 + 3 + tag_len, .send, 0, 4);
    @memcpy(raw[0..header_len], &h);
    var tag: [tag_len]u8 = undefined;
    Aead.encrypt(raw[header_len..][0..3], &tag, "abc", &h, nonce(1), k);
    @memcpy(raw[header_len + 3 ..], &tag);
    raw[header_len] ^= 1;
    try tp.writeAll(&raw);
    try std.testing.expectError(error.Auth, q.readFrame(a));
}

test "isoproto: the limits of a frame, and the skip flag" {
    if (comptime on_win or builtin.os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fds = try testPair();
    var tp = try Transport.init(fds[0]);
    defer tp.deinit();
    var tc = try Transport.init(fds[1]);
    defer tc.deinit();
    var q = Conn.init(&tc);
    // An unknown kind with `skip` goes, and the next frame comes.
    try tp.writeAll(&Conn.header(6, @fromBackingInt(200), flag_skip, 0));
    var p = Conn.init(&tp);
    try p.writeFrame(a, .ready, 0, 1, "");
    const f = try q.readFrame(a);
    a.free(f.payload);
    try std.testing.expectEqual(Kind.ready, f.kind);
    // An unknown kind with no `skip` ends the connection.
    try tp.writeAll(&Conn.header(6, @fromBackingInt(201), 0, 0));
    try std.testing.expectError(error.Protocol, q.readFrame(a));
    // A length past the largest payload ends it before an allocation.
    try tp.writeAll(&Conn.header(max_payload + 7, .send, 0, 0));
    try std.testing.expectError(error.Protocol, q.readFrame(a));
    const big = try a.alloc(u8, max_payload + 1);
    defer a.free(big);
    try std.testing.expectError(error.Protocol, p.writeFrame(a, .send, 0, 0, big));
}

test "isoproto: the byte form keeps the kinds, and a deep list fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inner = try value.newList(a, &.{ .{ .int = -5 }, .{ .double = 2.5 }, .{ .str = "héllo" } });
    const v = try value.newList(a, &.{ inner, .{ .str = "" } });
    var out: std.ArrayList(u8) = .empty;
    const S = struct {
        fn strOf(_: void, _: Value) Allocator.Error![]const u8 {
            return "deep";
        }
    };
    try encodeValue(a, &out, v, 0, {}, S.strOf);
    var r: Reader = .{ .b = out.items };
    const back = try decodeValue(a, &r, 0);
    try r.done();
    const items = back.list.items();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    const in2 = items[0].list.items();
    try std.testing.expectEqual(@as(i64, -5), in2[0].int);
    try std.testing.expectEqual(@as(f64, 2.5), in2[1].double);
    try std.testing.expectEqualStrings("héllo", in2[2].str);
    // 300 nested lists from a hostile side.
    var deep: std.ArrayList(u8) = .empty;
    for (0..300) |_| try deep.appendSlice(a, &.{ 'l', 1, 0, 0, 0 });
    try deep.appendSlice(a, &.{ 'i', 0, 0, 0, 0, 0, 0, 0, 0 });
    var rd: Reader = .{ .b = deep.items };
    try std.testing.expectError(error.Protocol, decodeValue(a, &rd, 0));
    // Random bytes give a value or `error.Protocol`, and no crash.
    var prng = std.Random.DefaultPrng.init(209);
    var junk: [64]u8 = undefined;
    for (0..2000) |_| {
        prng.random().bytes(&junk);
        junk[0] = "idsl"[prng.random().uintLessThan(usize, 4)];
        var rj: Reader = .{ .b = &junk };
        _ = decodeValue(a, &rj, 0) catch |e| try std.testing.expect(e == error.Protocol);
    }
}
