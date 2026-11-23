//! `coroutine`, `yield`, `yieldto`, and `tailcall`.
//!
//! The evaluator is recursive, so a coroutine has its own native stack.
//! A small assembly routine saves the callee-saved registers on one
//! stack and restores them from another. Each coroutine also has its
//! own word stack, frame chain, and nesting counts. The resumer swaps
//! these fields of the interpreter around each switch.
//!
//! A native stack has a fixed size. `max_native` is half of it while a
//! coroutine runs, so the parser and `expr` have room below the check.
//! The stacks come from the arena, so the memory limit counts them.
//!
//! The switch exists for x86-64 Linux and arm64 macOS. On other targets,
//! including WebAssembly, `coroutine` gives an error.
//!
//! `tailcall` ends the proc with a private return code. The proc call
//! runs the new command after the frame is gone, in a loop, so a chain
//! of tail calls uses no native stack.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp = @import("interp.zig");
const value = @import("value.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

const on_arm = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;
const on_x86 = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;
pub const supported = on_arm or on_x86;

const stack_size: usize = if (builtin.mode == .Debug) 16 << 20 else 1 << 20;

/// The return code of a pending `tailcall`.
pub const tail_code: u32 = 0x7fff_fff0;

const Saved = struct {
    frame: *interp.Frame,
    ns: []const u8,
    chunks: std.ArrayList([]Value) = .empty,
    chunk: usize = 0,
    top: usize = 0,
    nest: u32 = 1,
    native_base: usize,
    max_native: usize,
    word_chunk: usize = 1024,
};

pub const Coro = struct {
    name: []const u8,
    stack: []u8,
    sp: usize = 0,
    caller_sp: usize = 0,
    saved: Saved,
    /// The depth of the frames of the coroutine.
    depth: u32 = 0,
    words: []const Value,
    /// A value that goes in or out at a switch.
    transfer: Value = Value.empty,
    /// The end of the body.
    failure: ?Error = null,
    done: bool = false,
    running: bool = false,
    killing: bool = false,
    deleted: bool = false,
    /// The command that `yieldto` runs in the resumer.
    yield_words: ?[]const Value = null,
    /// True when the next resume takes any count of arguments.
    many_args: bool = false,
    prev: ?*Coro = null,
    it: *Interp,
};

// `ztcl_coro_swap(from, to)` saves the registers, stores the stack
// pointer in `from.*`, and continues on the stack `to`. On a new stack,
// `ztcl_coro_start` calls the function in `rbp` with the value in `rbx`
// on x86-64, and the function in `x20` with the value in `x19` on arm64.
// Both are exported, so the compiler cannot inline them. The arm64 frame
// is 160 bytes, so the stack pointer stays 16-byte aligned. It holds x19
// to x28, x29, x30, and d8 to d15. The routines do not touch x18, which
// macOS reserves.
fn swapAsm() callconv(.naked) void {
    if (on_arm) asm volatile (
        \\ sub sp, sp, #160
        \\ stp x19, x20, [sp, #0]
        \\ stp x21, x22, [sp, #16]
        \\ stp x23, x24, [sp, #32]
        \\ stp x25, x26, [sp, #48]
        \\ stp x27, x28, [sp, #64]
        \\ stp x29, x30, [sp, #80]
        \\ stp d8, d9, [sp, #96]
        \\ stp d10, d11, [sp, #112]
        \\ stp d12, d13, [sp, #128]
        \\ stp d14, d15, [sp, #144]
        \\ mov x9, sp
        \\ str x9, [x0]
        \\ mov sp, x1
        \\ ldp x19, x20, [sp, #0]
        \\ ldp x21, x22, [sp, #16]
        \\ ldp x23, x24, [sp, #32]
        \\ ldp x25, x26, [sp, #48]
        \\ ldp x27, x28, [sp, #64]
        \\ ldp x29, x30, [sp, #80]
        \\ ldp d8, d9, [sp, #96]
        \\ ldp d10, d11, [sp, #112]
        \\ ldp d12, d13, [sp, #128]
        \\ ldp d14, d15, [sp, #144]
        \\ add sp, sp, #160
        \\ ret
    ) else asm volatile (
        \\ pushq %%rbp
        \\ pushq %%rbx
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\ movq %%rsp, (%%rdi)
        \\ movq %%rsi, %%rsp
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%rbx
        \\ popq %%rbp
        \\ retq
    );
}

fn startAsm() callconv(.naked) void {
    if (on_arm) asm volatile (
        \\ mov x0, x19
        \\ blr x20
        \\ brk #1
    ) else asm volatile (
        \\ movq %%rbx, %%rdi
        \\ callq *%%rbp
        \\ ud2
    );
}

comptime {
    if (supported) {
        @export(&swapAsm, .{ .name = "ztcl_coro_swap", .visibility = .hidden });
        @export(&startAsm, .{ .name = "ztcl_coro_start", .visibility = .hidden });
    }
}

extern fn ztcl_coro_swap(from: *usize, to: usize) callconv(.c) void;
extern fn ztcl_coro_start() callconv(.c) void;

fn swap(from: *usize, to: usize) void {
    if (supported) ztcl_coro_swap(from, to) else unreachable;
}

fn entry(c: *Coro) callconv(.c) noreturn {
    const it = c.it;
    if (it.callWords(c.words)) |v| {
        c.transfer = v;
    } else |e| {
        if (e == error.TclReturn and it.ret_code == .ok) {
            it.ret_level = 1;
            c.transfer = it.result;
        } else {
            c.failure = e;
            c.transfer = it.result;
        }
    }
    c.done = true;
    swap(&c.sp, c.caller_sp);
    unreachable;
}

fn exchange(it: *Interp, s: *Saved) void {
    std.mem.swap(*interp.Frame, &it.frame, &s.frame);
    std.mem.swap([]const u8, &it.ns, &s.ns);
    std.mem.swap(std.ArrayList([]Value), &it.chunks, &s.chunks);
    std.mem.swap(usize, &it.chunk, &s.chunk);
    std.mem.swap(usize, &it.top, &s.top);
    std.mem.swap(u32, &it.nest, &s.nest);
    std.mem.swap(usize, &it.native_base, &s.native_base);
    std.mem.swap(usize, &it.max_native, &s.max_native);
    std.mem.swap(usize, &it.word_chunk, &s.word_chunk);
}

/// Runs the coroutine until it yields or ends.
fn enter(it: *Interp, c: *Coro) void {
    c.prev = it.coro;
    c.running = true;
    it.coro = c;
    const outer = it.depth;
    it.depth += c.depth;
    exchange(it, &c.saved);
    swap(&c.caller_sp, c.sp);
    exchange(it, &c.saved);
    c.depth = it.depth - outer;
    it.depth = outer;
    it.coro = c.prev;
    c.running = false;
}

fn finish(it: *Interp, c: *Coro) void {
    if (!c.deleted) {
        if (it.commands.get(c.name)) |cmd| {
            if (cmd.ctx == @as(?*anyopaque, c)) _ = it.commands.remove(c.name);
        }
        it.epoch += 1;
    }
    it.coro_count -= 1;
    it.coro_stacks.append(it.alloc(), c.stack) catch {};
}

/// Gives the outcome of a switch to the resumer.
fn outcome(it: *Interp, c: *Coro) Error!Value {
    if (c.done) {
        finish(it, c);
        const out = c.transfer;
        if (c.failure) |e| {
            it.result = out;
            return e;
        }
        return out;
    }
    if (c.yield_words) |words| {
        c.yield_words = null;
        return it.callWords(words);
    }
    return c.transfer;
}

fn resumeCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const c: *Coro = @ptrCast(@alignCast(self.ctx.?));
    if (c.running) return it.failCode("TCL COROUTINE BUSY", "coroutine \"{s}\" is already running", .{try it.str(argv[0])});
    if (c.many_args) {
        c.transfer = try value.newList(it.alloc(), argv[1..]);
    } else {
        if (argv.len > 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} ?arg?\"", .{try it.str(argv[0])});
        c.transfer = if (argv.len == 2) argv[1] else Value.empty;
    }
    enter(it, c);
    return outcome(it, c);
}

/// Ends a suspended coroutine whose command goes away.
pub fn commandGone(it: *Interp, command: *interp.Command) void {
    if (command.impl != .native or command.impl.native != &resumeCmd) return;
    const c: *Coro = @ptrCast(@alignCast(command.ctx.?));
    c.deleted = true;
    if (c.running or c.done) return;
    const saved = it.result;
    c.killing = true;
    enter(it, c);
    if (c.done) finish(it, c);
    it.in_error = false;
    it.error_info = .empty;
    it.result = saved;
}

/// True when a kill unwinds the current coroutine: `catch` cannot stop it.
pub fn unwinding(it: *const Interp) bool {
    const c = it.coro orelse return false;
    return c.killing;
}

fn cmdCoroutine(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 3) return it.wrongArgs("coroutine name cmd ?arg ...?");
    if (!supported) return it.fail("coroutine is not available on this target", .{});
    const a = it.alloc();
    const given = try it.str(argv[1]);
    const name = try it.qualify(given);
    // A new coroutine replaces a command of the same name.
    if (it.commands.fetchRemove(name)) |old| {
        it.epoch += 1;
        commandGone(it, old.value);
    }
    const stack = it.coro_stacks.pop() orelse try a.alignedAlloc(u8, .@"16", stack_size);
    const c = try a.create(Coro);
    c.* = .{
        .name = name,
        .stack = stack,
        .it = it,
        .words = try a.dupe(Value, argv[2..]),
        .saved = .{
            .frame = &it.global,
            .ns = "",
            .native_base = @intFromPtr(stack.ptr) + stack.len,
            .max_native = stack.len / 2,
        },
    };
    // The first switch restores the registers of this frame and returns
    // to the trampoline.
    const top = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 16) - 16;
    if (on_arm) {
        const slots: [*]usize = @ptrFromInt(top - 160);
        @memset(slots[0..20], 0);
        slots[0] = @intFromPtr(c); // x19
        slots[1] = @intFromPtr(&entry); // x20
        slots[11] = @intFromPtr(&ztcl_coro_start); // x30
        c.sp = top - 160;
    } else {
        const slots: [*]usize = @ptrFromInt(top - 56);
        @memset(slots[0..8], 0);
        slots[4] = @intFromPtr(c);
        slots[5] = @intFromPtr(&entry);
        slots[6] = if (supported) @intFromPtr(&ztcl_coro_start) else 0;
        c.sp = top - 56;
    }
    const command = try a.create(interp.Command);
    command.* = .{ .name = name, .impl = .{ .native = resumeCmd }, .ctx = c };
    try it.commands.put(a, name, command);
    it.epoch += 1;
    it.coro_count += 1;
    enter(it, c);
    return outcome(it, c);
}

fn suspendHere(it: *Interp, c: *Coro) Error!Value {
    swap(&c.sp, c.caller_sp);
    if (c.killing) return it.fail("coroutine deleted", .{});
    return c.transfer;
}

fn cmdYield(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len > 2) return it.wrongArgs("yield ?returnValue?");
    const c = it.coro orelse return it.failCode("TCL COROUTINE ILLEGAL_YIELD", "yield can only be called in a coroutine", .{});
    c.transfer = if (argv.len == 2) argv[1] else Value.empty;
    c.many_args = false;
    return suspendHere(it, c);
}

fn cmdYieldTo(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("yieldto command ?arg ...?");
    const c = it.coro orelse return it.failCode("TCL COROUTINE ILLEGAL_YIELD", "yieldto can only be called in a coroutine", .{});
    const words = try it.alloc().dupe(Value, argv[1..]);
    words[0] = try qualified(it, words[0]);
    c.yield_words = words;
    c.many_args = true;
    return suspendHere(it, c);
}

/// A command word that names the command in the current namespace.
fn qualified(it: *Interp, v: Value) Error!Value {
    const name = try it.str(v);
    const key = it.commandKey(name) orelse return v;
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "::{s}", .{key}) };
}

fn cmdTailcall(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("tailcall command ?arg ...?");
    if (it.frame == &it.global or it.frame.ns != null) {
        return it.failCode("TCL TAILCALL ILLEGAL", "tailcall can only be called from a proc, lambda or method", .{});
    }
    const words = try it.alloc().dupe(Value, argv[1..]);
    words[0] = try qualified(it, words[0]);
    it.tail_words = words;
    it.ret_code = @enumFromInt(tail_code);
    it.ret_level = 1;
    it.result = Value.empty;
    return error.TclReturn;
}

/// The name of the running coroutine, for `info coroutine`.
pub fn current(it: *Interp) Error!Value {
    const c = it.coro orelse return Value.empty;
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "::{s}", .{c.name}) };
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("coroutine", cmdCoroutine);
    try it.register("yield", cmdYield);
    try it.register("yieldto", cmdYieldTo);
    try it.register("tailcall", cmdTailcall);
}
