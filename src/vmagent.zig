//! The host side of the protocol of the guest agent of `ztcl::vm`
//! (`docs/dev/vm-agent.md`): `exec` and `mount` over a connected vsock
//! descriptor. Each host of the plan (Virtualization.framework, KVM,
//! HCS) gives a descriptor of a connection to port 1024 and calls these.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const on_win = builtin.os.tag == .windows;
const posix = if (on_win) struct {} else sys.os;

pub const port: u32 = 1024;
pub const version: u16 = 1;
pub const max_payload = 1 << 20;

pub const t_hello = 0x01;
pub const t_exec = 0x10;
pub const t_mount = 0x11;
pub const t_ping = 0x13;
pub const t_started = 0x20;
pub const t_stdout = 0x21;
pub const t_stderr = 0x22;
pub const t_stdin = 0x23;
pub const t_exit = 0x25;
pub const t_ok = 0x30;
pub const t_error = 0x3f;

pub const Error = error{ Io, Closed, Timeout, Protocol, Version, Agent } || Allocator.Error;

pub const Hello = struct { version: u16, features: u32, boot_main: u64, boot_listen: u64 };

/// The `ERROR` frame of the agent, after `error.Agent`.
pub const AgentError = struct { errno: u32 = 0, message: [256]u8 = undefined, len: usize = 0 };

pub const Result = struct {
    code: i32,
    stdout: []u8,
    stderr: []u8,
};

const Frame = struct { kind: u8, payload: []u8 };

/// A connection: the descriptor, and the most milliseconds that one wait
/// for the agent takes. A program that writes nothing for that long
/// gives `error.Timeout`.
pub const Conn = struct {
    fd: i32,
    timeout_ms: i32,
    last_error: AgentError = .{},

    fn waitRead(c: *Conn) Error!void {
        if (comptime on_win) {
            // On Windows the descriptor is a socket of `sys`: its poll.
            var w = [1]sys.Want{.{ .fd = c.fd, .read = true }};
            sys.poll(std.heap.page_allocator, &w, c.timeout_ms);
            if (!w[0].can_read) return error.Timeout;
            return;
        }
        var fds = [1]posix.pollfd{.{ .fd = c.fd, .events = posix.POLL.IN, .revents = 0 }};
        const rc = posix.poll(&fds, 1, c.timeout_ms);
        if (posix.errno(rc) == .INTR) return;
        if (posix.errno(rc) != .SUCCESS) return error.Io;
        if (rc == 0) return error.Timeout;
    }

    fn readExact(c: *Conn, out: []u8) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            try c.waitRead();
            if (comptime on_win) {
                switch (sys.read(c.fd, out[off..])) {
                    .n => |n| {
                        if (n == 0) return error.Closed;
                        off += n;
                    },
                    .again => {},
                    .err => return error.Io,
                }
                continue;
            }
            const n = posix.read(c.fd, out[off..].ptr, out.len - off);
            switch (posix.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return error.Closed;
                    off += n;
                },
                .INTR, .AGAIN => {},
                else => return error.Io,
            }
        }
    }

    fn writeAll(c: *Conn, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            if (comptime on_win) {
                switch (sys.write(c.fd, bytes[off..])) {
                    .n => |n| off += n,
                    .again => {},
                    .err => return error.Closed,
                }
                continue;
            }
            const n = posix.write(c.fd, bytes[off..].ptr, bytes.len - off);
            switch (posix.errno(n)) {
                .SUCCESS => off += n,
                .INTR, .AGAIN => {},
                else => return error.Closed,
            }
        }
    }

    pub fn send(c: *Conn, kind: u8, payload: []const u8) Error!void {
        if (payload.len > max_payload) return error.Protocol;
        var head: [5]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], @intCast(payload.len + 1), .little);
        head[4] = kind;
        try c.writeAll(&head);
        try c.writeAll(payload);
    }

    fn read(c: *Conn, a: Allocator) Error!Frame {
        var head: [5]u8 = undefined;
        try c.readExact(&head);
        const len = std.mem.readInt(u32, head[0..4], .little);
        if (len == 0 or len > max_payload + 1) return error.Protocol;
        const p = try a.alloc(u8, len - 1);
        errdefer a.free(p);
        try c.readExact(p);
        return .{ .kind = head[4], .payload = p };
    }

    /// Keeps an `ERROR` frame in `last_error`.
    fn agentError(c: *Conn, p: []const u8) Error {
        c.last_error = .{};
        if (p.len >= 8) {
            c.last_error.errno = std.mem.readInt(u32, p[0..4], .little);
            const n = @min(std.mem.readInt(u32, p[4..8], .little), p.len - 8, 256);
            @memcpy(c.last_error.message[0..n], p[8..][0..n]);
            c.last_error.len = n;
        }
        return error.Agent;
    }

    /// Reads `HELLO`. An agent of another version gives `error.Version`.
    pub fn hello(c: *Conn, a: Allocator) Error!Hello {
        const f = try c.read(a);
        defer a.free(f.payload);
        if (f.kind != t_hello or f.payload.len < 22) return error.Protocol;
        const h: Hello = .{
            .version = std.mem.readInt(u16, f.payload[0..2], .little),
            .features = std.mem.readInt(u32, f.payload[2..6], .little),
            .boot_main = std.mem.readInt(u64, f.payload[6..14], .little),
            .boot_listen = std.mem.readInt(u64, f.payload[14..22], .little),
        };
        if (h.version != version) return error.Version;
        return h;
    }
};

fn putStr(a: Allocator, l: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(s.len))));
    try l.appendSlice(a, s);
}

fn putList(a: Allocator, l: *std.ArrayList(u8), items: []const []const u8) Allocator.Error!void {
    try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(items.len))));
    for (items) |s| try putStr(a, l, s);
}

/// Runs `argv` in the guest and gives its exit code and output. With
/// `stdin`, the program reads those bytes and then the end of its input.
/// Each output keeps at most `max_out` bytes.
pub fn exec(c: *Conn, a: Allocator, argv: []const []const u8, env: []const []const u8, cwd: []const u8, stdin: ?[]const u8, max_out: usize) Error!Result {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(a);
    try putList(a, &req, argv);
    try putList(a, &req, env);
    try putStr(a, &req, cwd);
    try req.append(a, if (stdin != null) 1 else 0);
    try c.send(t_exec, req.items);
    if (stdin) |data| {
        var off: usize = 0;
        while (off < data.len) : (off += max_payload) try c.send(t_stdin, data[off..@min(data.len, off + max_payload)]);
        try c.send(t_stdin, "");
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var err: std.ArrayList(u8) = .empty;
    errdefer err.deinit(a);
    while (true) {
        const f = try c.read(a);
        defer a.free(f.payload);
        switch (f.kind) {
            t_started => {},
            t_stdout => try out.appendSlice(a, f.payload[0..@min(f.payload.len, max_out -| out.items.len)]),
            t_stderr => try err.appendSlice(a, f.payload[0..@min(f.payload.len, max_out -| err.items.len)]),
            t_exit => {
                if (f.payload.len < 4) return error.Protocol;
                return .{
                    .code = std.mem.readInt(i32, f.payload[0..4], .little),
                    .stdout = try out.toOwnedSlice(a),
                    .stderr = try err.toOwnedSlice(a),
                };
            },
            t_error => return c.agentError(f.payload),
            else => return error.Protocol,
        }
    }
}

pub const Share = enum { virtiofs, nine_p };

/// Mounts the share `tag` at `path` in the guest.
pub fn mount(c: *Conn, a: Allocator, tag: []const u8, path: []const u8, read_only: bool, kind: Share) Error!void {
    var req: std.ArrayList(u8) = .empty;
    defer req.deinit(a);
    try putStr(a, &req, tag);
    try putStr(a, &req, path);
    try req.append(a, @as(u8, if (read_only) 1 else 0) | @as(u8, if (kind == .nine_p) 2 else 0));
    try c.send(t_mount, req.items);
    const f = try c.read(a);
    defer a.free(f.payload);
    switch (f.kind) {
        t_ok => return,
        t_error => return c.agentError(f.payload),
        else => return error.Protocol,
    }
}
