//! The marks of an assembly for `ztcl::disasm machine`: each mark says
//! that the machine code from its offset on belongs to one bytecode
//! instruction. Only a listing asks for marks, so a compile for a run
//! has none.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// The pc of code that belongs to no instruction: the entry, the exit,
/// and the shared parts.
pub const none = std.math.maxInt(u32);

pub const Mark = struct { at: u32, pc: u32 };

pub const Marks = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Mark) = .empty,

    pub fn note(m: *Marks, at: u32, pc: u32) void {
        m.list.append(m.a, .{ .at = at, .pc = pc }) catch {};
    }

    pub fn deinit(m: *Marks) void {
        m.list.deinit(m.a);
    }
};
