//! The guest memory and the split virtqueue of virtio 1.2 (section 2.7),
//! for the devices of `ztcl::vm` on each hypervisor that gives the guest
//! its devices on virtio-mmio (KVM, the Windows Hypervisor Platform).
//!
//! The guest is not trusted: each address and length that the guest
//! gives goes through `Mem.slice`, which checks it against the guest
//! memory. A ring index wraps at 2^16, and a slot is the index modulo
//! the queue size.
//!
//! SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub const Mem = struct {
    base: [*]u8,
    size: u64,

    /// The bytes at a guest address, or null if a byte is outside the
    /// memory.
    pub fn slice(m: Mem, gpa: u64, len: u64) ?[]u8 {
        if (gpa > m.size or len > m.size - gpa) return null;
        return m.base[@intCast(gpa)..@intCast(gpa + len)];
    }

    pub fn ptr(m: Mem, comptime T: type, gpa: u64) ?*align(1) T {
        const s = m.slice(gpa, @sizeOf(T)) orelse return null;
        return @ptrCast(s.ptr);
    }

    pub fn put(m: Mem, comptime T: type, gpa: u64, v: T) void {
        std.mem.writeInt(T, m.base[@intCast(gpa)..][0..@sizeOf(T)], v, .little);
    }
};

pub const desc_f_next = 1;
pub const desc_f_write = 2;
pub const max_queue = 256;

pub const Queue = struct {
    num: u32 = 0,
    ready: bool = false,
    desc: u64 = 0,
    avail: u64 = 0,
    used: u64 = 0,
    last_avail: u16 = 0,

    const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };

    /// The index of the next chain that the driver made available, or
    /// null when there is none.
    pub fn next(q: *Queue, m: Mem) ?u16 {
        if (!q.ready or q.num == 0) return null;
        const idx_p = m.ptr(u16, q.avail + 2) orelse return null;
        const idx = @atomicLoad(u16, @as(*u16, @ptrCast(@alignCast(idx_p))), .acquire);
        if (idx == q.last_avail) return null;
        const slot = q.avail + 4 + 2 * @as(u64, q.last_avail % q.num);
        const head = (m.ptr(u16, slot) orelse return null).*;
        q.last_avail +%= 1;
        return head;
    }

    pub fn descAt(q: *Queue, m: Mem, i: u16) ?Desc {
        if (i >= q.num) return null;
        const d = m.ptr(Desc, q.desc + 16 * @as(u64, i)) orelse return null;
        return d.*;
    }

    /// Puts a chain in the used ring with `len` bytes written.
    pub fn putUsed(q: *Queue, m: Mem, head: u16, len: u32) void {
        const idx_p = m.ptr(u16, q.used + 2) orelse return;
        const idx: *u16 = @ptrCast(@alignCast(idx_p));
        const cur = idx.*;
        const elem = q.used + 4 + 8 * @as(u64, cur % q.num);
        if (m.slice(elem, 8) == null) return;
        m.put(u32, elem, head);
        m.put(u32, elem + 4, len);
        @atomicStore(u16, idx, cur +% 1, .release);
    }

    /// Checks that the rings fit in the guest memory, when the driver
    /// sets the queue ready.
    pub fn valid(q: *const Queue, m: Mem) bool {
        if (q.num == 0 or q.num > max_queue) return false;
        return m.slice(q.desc, 16 * @as(u64, q.num)) != null and
            m.slice(q.avail, 6 + 2 * @as(u64, q.num)) != null and
            m.slice(q.used, 6 + 8 * @as(u64, q.num)) != null;
    }
};

/// A chain of descriptors as host slices: the readable part, then the
/// writable part.
pub const Chain = struct {
    /// A chain has at most one descriptor for each entry of its queue
    /// (virtio 1.2, 2.7.13), so a longer walk has a loop. With 64, a 9p
    /// request of msize 262,144 (64 pages and the headers) did not fit:
    /// the device answered with no bytes, and the request of the guest
    /// waited forever.
    pub const max = max_queue;
    bufs: [max][]u8 = undefined,
    writable: [max]bool = undefined,
    n: usize = 0,

    /// The chain at `head`, or null when it is malformed: a descriptor
    /// outside the guest memory or the queue, or a loop.
    pub fn read(q: *Queue, m: Mem, head: u16) ?Chain {
        var c: Chain = .{};
        var i = head;
        while (c.n < max) {
            const d = q.descAt(m, i) orelse return null;
            c.bufs[c.n] = m.slice(d.addr, d.len) orelse return null;
            c.writable[c.n] = d.flags & desc_f_write != 0;
            c.n += 1;
            if (d.flags & desc_f_next == 0) return c;
            i = d.next;
        }
        return null;
    }
};

test "virtio: a guest address outside the memory" {
    var buf: [4096]u8 = undefined;
    const mem: Mem = .{ .base = &buf, .size = buf.len };
    try std.testing.expect(mem.slice(4000, 96) != null);
    try std.testing.expect(mem.slice(4000, 97) == null);
    try std.testing.expect(mem.slice(std.math.maxInt(u64), 2) == null);
}
