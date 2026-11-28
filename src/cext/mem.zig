//! The memory slots of the stubs table: `Tcl_Alloc` and its forms, the
//! debug forms of a build with no `TCL_MEM_DEBUG`, `Tcl_Panic`, and the
//! `Tcl_Preserve` list.
//!
//! The blocks come from the `malloc` of the C library, so a block of a
//! package and a block of ztcl for C code use one heap. A failed
//! allocation ends the process through `Tcl_Panic`, as in Tcl. The
//! `Attempt` forms return null.
//!
//! The `Tcl_Preserve` list keeps a count for each pointer. `Tcl_Release`
//! of the last count frees the pointer when `Tcl_EventuallyFree` came
//! before it. `Tcl_EventuallyFree` of a pointer with no count frees it
//! at once.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const va = @import("va.zig");
const VaList = va.VaList;
const VaArg = @import("obj.zig").VaArg;
const vaList = @import("obj.zig").vaList;

extern "c" fn vfprintf(f: *anyopaque, fmt: [*:0]const u8, ap: VaArg) c_int;
extern "c" fn fprintf(f: *anyopaque, fmt: [*:0]const u8, ...) c_int;
extern "c" fn fflush(f: ?*anyopaque) c_int;
/// The `stderr` of the C library. macOS names it `__stderrp`.
fn stderr() *anyopaque {
    const name = if (@import("builtin").os.tag.isDarwin()) "__stderrp" else "stderr";
    return @extern(**anyopaque, .{ .name = name }).*;
}

/// `TCL_DYNAMIC` of `tcl.h`: free the block with `Tcl_Free`.
const dynamic: usize = 3;

/// The proc of `Tcl_SetPanicProc`. It is variadic in C. On aarch64
/// Linux, Zig has no variadic type, and the call passes 8 words in x1 to
/// x7 and on the stack, the registers and the stack of a C variadic
/// call there.
pub const PanicProc = if (va.own) *const fn (fmt: [*:0]const u8, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) void else *const fn (fmt: [*:0]const u8, ...) callconv(.c) void;
pub const FreeProc = *const fn (?*anyopaque) callconv(.c) void;

var panic_proc: ?PanicProc = null;

fn grab(n: c_uint) ?[*]u8 {
    return @ptrCast(std.c.malloc(@max(n, 1)));
}

fn regrab(p: ?[*]u8, n: c_uint) ?[*]u8 {
    return @ptrCast(std.c.realloc(p, @max(n, 1)));
}

fn freeWith(cd: ?*anyopaque, proc: usize) void {
    if (proc == dynamic) {
        std.c.free(cd);
    } else {
        const f: FreeProc = @ptrFromInt(proc);
        f(cd);
    }
}

const Ref = struct { cd: ?*anyopaque, count: usize, must_free: bool = false, proc: usize = 0 };
var refs: std.ArrayList(Ref) = .empty;
var refs_lock: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!refs_lock.tryLock()) {}
}

fn findRef(cd: ?*anyopaque) ?usize {
    for (refs.items, 0..) |r, i| {
        if (r.cd == cd) return i;
    }
    return null;
}

/// Writes the message to the standard error and ends the process.
/// `Tcl_Panic` from Zig code, with the arguments of `fmt` in the tuple
/// `args`: integers and pointers.
pub fn panicf(fmt: [*:0]const u8, args: anytype) noreturn {
    if (!va.own) @call(.auto, slots.panicVariadic, .{fmt} ++ args);
    // A va_list of the words of `args` in the general area, as the
    // stub of `va.zig` makes for a call from C.
    var words: [8]u64 = @splat(0);
    inline for (args, 0..) |x, i| words[i] = switch (@typeInfo(@TypeOf(x))) {
        .pointer, .optional => @intFromPtr(x),
        .int, .comptime_int => @bitCast(@as(i64, @intCast(x))),
        else => @compileError("panicf takes integers and pointers"),
    };
    const base: [*]u8 = @ptrCast(&words);
    var ap: va.Aapcs64 = .{ .stack = base + 8 * args.len, .gr_top = base + 8 * args.len, .vr_top = base, .gr_offs = -8 * @as(i32, args.len), .vr_offs = 0 };
    panicVA(fmt, &ap);
}

fn panicVA(fmt: [*:0]const u8, ap: *VaList) callconv(.c) noreturn {
    if (panic_proc) |p| {
        // A va_list cannot go to a variadic function, so the proc gets
        // 8 words of arguments, as in Tcl.
        var w: [8]usize = undefined;
        for (&w) |*x| x.* = va.arg(ap, usize);
        p(fmt, w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7]);
    } else {
        _ = vfprintf(stderr(), fmt, if (VaArg == VaList) ap.* else ap);
        _ = fprintf(stderr(), "\n");
        _ = fflush(stderr());
    }
    std.c.abort();
}

pub const slots = struct {
    pub fn Tcl_Alloc(n: c_uint) callconv(.c) [*]u8 {
        return grab(n) orelse panicf("unable to alloc %u bytes", .{n});
    }

    pub fn Tcl_Free(p: ?[*]u8) callconv(.c) void {
        std.c.free(p);
    }

    pub fn Tcl_Realloc(p: ?[*]u8, n: c_uint) callconv(.c) [*]u8 {
        return regrab(p, n) orelse panicf("unable to realloc %u bytes", .{n});
    }

    pub fn Tcl_AttemptAlloc(n: c_uint) callconv(.c) ?[*]u8 {
        return grab(n);
    }

    pub fn Tcl_AttemptRealloc(p: ?[*]u8, n: c_uint) callconv(.c) ?[*]u8 {
        return regrab(p, n);
    }

    pub fn Tcl_DbCkalloc(n: c_uint, file: [*:0]const u8, line: c_int) callconv(.c) [*]u8 {
        return grab(n) orelse panicf("unable to alloc %u bytes, %s line %d", .{ n, file, line });
    }

    pub fn Tcl_DbCkfree(p: ?[*]u8, _: [*:0]const u8, _: c_int) callconv(.c) void {
        std.c.free(p);
    }

    pub fn Tcl_DbCkrealloc(p: ?[*]u8, n: c_uint, file: [*:0]const u8, line: c_int) callconv(.c) [*]u8 {
        return regrab(p, n) orelse panicf("unable to realloc %u bytes, %s line %d", .{ n, file, line });
    }

    pub fn Tcl_AttemptDbCkalloc(n: c_uint, _: [*:0]const u8, _: c_int) callconv(.c) ?[*]u8 {
        return grab(n);
    }

    pub fn Tcl_AttemptDbCkrealloc(p: ?[*]u8, n: c_uint, _: [*:0]const u8, _: c_int) callconv(.c) ?[*]u8 {
        return regrab(p, n);
    }

    /// With no `TCL_MEM_DEBUG`, Tcl writes no file and returns TCL_OK.
    pub fn Tcl_DumpActiveMemory(_: ?[*:0]const u8) callconv(.c) c_int {
        return 0;
    }

    pub fn Tcl_ValidateAllMemory(_: ?[*:0]const u8, _: c_int) callconv(.c) void {}

    pub fn Tcl_InitMemory(_: ?*anyopaque) callconv(.c) void {}

    pub const Tcl_Panic = if (va.own) va.Stub(1, "ztcl_va_Panic").f else panicVariadic;

    fn panicVariadic(fmt: [*:0]const u8, ...) callconv(.c) noreturn {
        var ap = @cVaStart();
        panicVA(fmt, &ap);
    }

    pub fn Tcl_PanicVA(fmt: [*:0]const u8, list: VaArg) callconv(.c) noreturn {
        var arg = list;
        panicVA(fmt, vaList(&arg));
    }

    pub fn Tcl_SetPanicProc(p: ?PanicProc) callconv(.c) void {
        panic_proc = p;
    }

    pub fn Tcl_Preserve(cd: ?*anyopaque) callconv(.c) void {
        lock();
        defer refs_lock.unlock();
        if (findRef(cd)) |i| {
            refs.items[i].count += 1;
            return;
        }
        refs.append(std.heap.c_allocator, .{ .cd = cd, .count = 1 }) catch panicf("unable to alloc %u bytes", .{@as(c_uint, @sizeOf(Ref))});
    }

    pub fn Tcl_Release(cd: ?*anyopaque) callconv(.c) void {
        lock();
        const i = findRef(cd) orelse {
            refs_lock.unlock();
            panicf("Tcl_Release couldn't find reference for %p", .{cd});
        };
        const r = &refs.items[i];
        r.count -= 1;
        if (r.count > 0) {
            refs_lock.unlock();
            return;
        }
        const done = refs.swapRemove(i);
        refs_lock.unlock();
        if (done.must_free) freeWith(done.cd, done.proc);
    }

    pub fn Tcl_EventuallyFree(cd: ?*anyopaque, proc: usize) callconv(.c) void {
        lock();
        if (findRef(cd)) |i| {
            const r = &refs.items[i];
            if (r.must_free) {
                refs_lock.unlock();
                panicf("Tcl_EventuallyFree called twice for %p", .{cd});
            }
            r.must_free = true;
            r.proc = proc;
            refs_lock.unlock();
            return;
        }
        refs_lock.unlock();
        freeWith(cd, proc);
    }
};

comptime {
    if (va.own) {
        va.exportBody(&slots.Tcl_PanicVA, "ztcl_va_Panic");
    }
}
