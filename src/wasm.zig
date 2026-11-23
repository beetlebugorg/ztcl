//! The WebAssembly interface of ztcl: a small C ABI over `Interp`.
//!
//! The host calls `ztcl_alloc`, writes the script into the memory, and
//! calls `ztcl_eval`. See docs/embedding.md for an example.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");

const gpa = std.heap.wasm_allocator;

const Handle = struct {
    it: ztcl.Interp,
    out: std.ArrayList(u8) = .empty,
    result: []const u8 = "",
};

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const h: *Handle = @ptrCast(@alignCast(ctx.?));
    h.out.appendSlice(gpa, bytes) catch {};
}

export fn ztcl_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn ztcl_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Makes an interpreter with a memory limit of 2 GiB and no fuel limit.
export fn ztcl_new() ?*Handle {
    const h = gpa.create(Handle) catch return null;
    h.* = .{ .it = undefined };
    h.it.init(gpa) catch {
        gpa.destroy(h);
        return null;
    };
    h.it.output = .{ .ctx = h, .write = write };
    h.it.mem_limit = 2 << 30;
    return h;
}

export fn ztcl_delete(h: *Handle) void {
    h.out.deinit(gpa);
    h.it.deinit();
    gpa.destroy(h);
}

/// Sets the steps that the next scripts can use.
export fn ztcl_set_fuel(h: *Handle, fuel: u64) void {
    h.it.fuel = fuel;
}

export fn ztcl_set_mem_limit(h: *Handle, bytes: usize) void {
    h.it.mem_limit = bytes;
}

/// Runs a script. Returns 0 on success and 1 on an error. The result
/// or the error message stays valid until the next call.
export fn ztcl_eval(h: *Handle, ptr: [*]const u8, len: usize) i32 {
    if (h.it.eval(ptr[0..len])) |v| {
        h.result = h.it.str(v) catch "out of memory";
        return 0;
    } else |e| {
        h.result = if (e == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(e);
        return 1;
    }
}

export fn ztcl_result_ptr(h: *Handle) [*]const u8 {
    return h.result.ptr;
}

export fn ztcl_result_len(h: *Handle) usize {
    return h.result.len;
}

export fn ztcl_output_ptr(h: *Handle) [*]const u8 {
    return h.out.items.ptr;
}

export fn ztcl_output_len(h: *Handle) usize {
    return h.out.items.len;
}

export fn ztcl_output_clear(h: *Handle) void {
    h.out.clearRetainingCapacity();
}
