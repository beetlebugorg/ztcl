//! The JIT tier of the wasm engine on x86-64 (System V: Linux and macOS).
//!
//! The compiler reads the internal code of `module.zig` once for each
//! module and writes the machine code of all its functions into one
//! buffer, which goes into the executable region of `src/jit/mem.zig`
//! (W^X: the pages are writable or executable, never both). The code
//! keeps the frame layout of the interpreter: the locals and the
//! operands are the 64-bit slots of `Store.stack`, and `heights` of the
//! module gives the slot of each operand, so the JIT and the interpreter
//! read and write the same slots. A wasm call to a function of the same
//! instance is a native `call`. A call to an import, an instruction that
//! the compiler does not write itself, and the slow paths go to helper
//! functions in Zig, and these run the code of `exec.zig` (`simple`), so
//! the two tiers give the same results, the same traps, and the same
//! NaN bits.
//!
//! Exact limits: a function uses one compute unit at its entry, as the
//! interpreter does at a call, and a `tick` at each loop start uses one
//! more. The depth of calls has the maximum of the interpreter, checked
//! at the same point. A memory access checks its bounds against the
//! length of the memory before the access.
//!
//! Registers: rbx holds the `Ctx` of the run, r12 the address of the
//! frame, r15 the offset of the frame in the stack (the stack can move
//! when it grows), r13 and r14 the address and the length of memory 0.
//! A trap restores the stack pointer of the entry and returns a code.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const x64 = @import("../jit/x64.zig");
const jmem = @import("../jit/mem.zig");
const mod = @import("module.zig");
const exec = @import("exec.zig");

const Asm = x64.Asm;
const Reg = x64.Reg;
const Mem = x64.Mem;
const Label = x64.Label;

pub const supported = builtin.cpu.arch == .x86_64 and (builtin.os.tag == .linux or builtin.os.tag == .macos);

pub const Ctx = extern struct {
    st_base: u64 = 0,
    st_end: u64 = 0,
    mem_base: u64 = 0,
    mem_len: u64 = 0,
    units: u64 = 0,
    depth: u64 = 0,
    max_depth: u64 = 0,
    saved_rsp: u64 = 0,
    rsp_limit: u64 = 0,
    frame_off: u64 = 0,
    store: u64 = 0,
    inst: u64 = 0,
    globals: u64 = 0,
};

const off = struct {
    const st_base = @offsetOf(Ctx, "st_base");
    const st_end = @offsetOf(Ctx, "st_end");
    const mem_base = @offsetOf(Ctx, "mem_base");
    const mem_len = @offsetOf(Ctx, "mem_len");
    const units = @offsetOf(Ctx, "units");
    const depth = @offsetOf(Ctx, "depth");
    const max_depth = @offsetOf(Ctx, "max_depth");
    const saved_rsp = @offsetOf(Ctx, "saved_rsp");
    const rsp_limit = @offsetOf(Ctx, "rsp_limit");
    const frame_off = @offsetOf(Ctx, "frame_off");
    const globals = @offsetOf(Ctx, "globals");
};

/// The code of one module.
pub const Code = struct {
    entry: *const fn (ctx: *Ctx, f: usize) callconv(.c) u64,
    funcs: []usize,
};

// ---- Trap codes ----

const traps = [_]anyerror{
    error.Unreachable,          error.DivByZero,        error.IntOverflow,      error.InvalidConversion,
    error.OutOfBoundsMemory,    error.OutOfBoundsTable, error.UndefinedElement, error.UninitializedElement,
    error.IndirectCallMismatch, error.StackExhausted,   error.ComputeLimit,     error.InstanceDeleted,
    error.Exit,                 error.OutOfMemory,      error.HostError,
};

fn codeOf(e: anyerror) u64 {
    for (traps, 0..) |t, i| if (t == e) return i + 1;
    return 15;
}

fn errorOf(code: u64) exec.Error {
    return switch (code) {
        1 => error.Unreachable,
        2 => error.DivByZero,
        3 => error.IntOverflow,
        4 => error.InvalidConversion,
        5 => error.OutOfBoundsMemory,
        6 => error.OutOfBoundsTable,
        7 => error.UndefinedElement,
        8 => error.UninitializedElement,
        9 => error.IndirectCallMismatch,
        10 => error.StackExhausted,
        11 => error.ComputeLimit,
        12 => error.InstanceDeleted,
        13 => error.Exit,
        14 => error.OutOfMemory,
        else => error.HostError,
    };
}

const T = struct {
    const unreachable_ = 1;
    const oob = 5;
    const stack = 10;
    const compute = 11;
};

// ---- Helpers ----

fn storeOf(c: *Ctx) *exec.Store {
    return @ptrFromInt(c.store);
}

fn instOf(c: *Ctx) *exec.Instance {
    return @ptrFromInt(c.inst);
}

/// Copies the state that a helper can change back into the context.
fn refresh(c: *Ctx) void {
    const s = storeOf(c);
    c.st_base = @intFromPtr(s.stack.ptr);
    c.st_end = @intFromPtr(s.stack.ptr + s.stack.len);
    const inst = instOf(c);
    if (inst.mems.len > 0) {
        c.mem_base = @intFromPtr(inst.mems[0].bytes.ptr);
        c.mem_len = inst.mems[0].bytes.len;
    }
}

/// Runs one instruction of `exec.simple` on the slots of the frame.
fn hSimple(c: *Ctx, frame_off: u64, ins: *const mod.Ins, h: u64) callconv(.c) u64 {
    const s = storeOf(c);
    const fp: usize = @intCast(frame_off / 8);
    defer refresh(c);
    _ = exec.simple(s, instOf(c), s.stack.ptr, fp, fp + @as(usize, @intCast(h)), ins.*) catch |e| return codeOf(e);
    return 0;
}

/// Makes room for `need` slots from the frame.
fn hGrow(c: *Ctx, frame_off: u64, need: u64) callconv(.c) u64 {
    const s = storeOf(c);
    defer refresh(c);
    s.ensureStack(@intCast(frame_off / 8 + need)) catch |e| return codeOf(e);
    return 0;
}

/// Calls an imported function, as the interpreter does.
fn hCall(c: *Ctx, frame_off: u64, ins: *const mod.Ins, h: u64) callconv(.c) u64 {
    const s = storeOf(c);
    defer refresh(c);
    const addr = instOf(c).funcs[ins.a];
    callOther(s, addr, @intCast(frame_off / 8 + h)) catch |e| return codeOf(e);
    return 0;
}

/// A call of the function `addr` with its arguments below `top`, through
/// the store. The results go where the arguments were.
fn callOther(s: *exec.Store, addr: u32, top: usize) exec.Error!void {
    const f = &s.funcs.items[addr];
    const np = f.type.params.len;
    const nr = f.type.results.len;
    var abuf: [16]u64 = undefined;
    var rbuf: [16]u64 = undefined;
    const args = if (np <= 16) abuf[0..np] else try s.gpa.alloc(u64, np);
    defer if (np > 16) s.gpa.free(args);
    const res = if (nr <= 16) rbuf[0..nr] else try s.gpa.alloc(u64, nr);
    defer if (nr > 16) s.gpa.free(res);
    @memcpy(args, s.stack[top - np .. top]);
    const saved = s.sp;
    s.sp = top - np;
    defer s.sp = saved;
    switch (f.kind) {
        .host => |hf| {
            try s.tickPub();
            try hf.call(hf.ctx, s, args, res);
        },
        .wasm => try s.invoke(addr, args, res),
    }
    try s.ensureStack(top - np + nr);
    @memcpy(s.stack[top - np .. top - np + nr], res);
}

/// `call_indirect`: gives 0 after a call through the store, a trap code
/// below 64, or the address of the code of a function of this instance.
fn hIndirect(c: *Ctx, frame_off: u64, ins: *const mod.Ins, h: u64) callconv(.c) u64 {
    const s = storeOf(c);
    defer refresh(c);
    const inst = instOf(c);
    const top: usize = @intCast(frame_off / 8 + h);
    const i: u32 = @truncate(s.stack[top - 1]);
    const tab = inst.tables[@intCast(ins.b)];
    if (i >= tab.refs.items.len) return codeOf(error.UndefinedElement);
    const r = tab.refs.items[i];
    if (r == 0) return codeOf(error.UninitializedElement);
    const callee: u32 = @intCast(r - 1);
    const f = &s.funcs.items[callee];
    if (!f.type.eql(inst.module.types[ins.a])) return codeOf(error.IndirectCallMismatch);
    if (f.kind == .wasm and f.kind.wasm.inst == inst) {
        const code: *const Code = @ptrCast(@alignCast(inst.module.jit.?));
        const idx = (@intFromPtr(f.kind.wasm.func) - @intFromPtr(inst.module.funcs.ptr)) / @sizeOf(mod.Func);
        return code.funcs[idx];
    }
    if (f.kind == .wasm and f.kind.wasm.inst.dead) return codeOf(error.InstanceDeleted);
    callOther(s, callee, top - 1) catch |e| return codeOf(e);
    return 0;
}

// ---- The compiler ----

const Compiler = struct {
    s: Asm,
    m: *const mod.Module,
    f: *const mod.Func = undefined,
    func_labels: []Label,
    trap_labels: [16]Label = undefined,
    trap_rax: Label = undefined,
    exit: Label = undefined,
    /// A label for each instruction that is a branch target, or null.
    targets: []?Label = &.{},
    tables: std.ArrayList(struct { at: u32, cases: []Label }) = .empty,
    a: std.mem.Allocator,

    fn slot(h: i64) Mem {
        return .{ .base = .r12, .disp = @intCast(8 * h) };
    }

    fn ctxAt(o: usize) Mem {
        return .{ .base = .rbx, .disp = @intCast(o) };
    }

    /// The state after a helper or a call: the frame, the memory, and the
    /// trap check of rax.
    fn reload(k: *Compiler) !void {
        try k.s.movRM(.r12, ctxAt(off.st_base));
        try k.s.aluRR(.add, .r12, .r15);
        try k.s.movRM(.r13, ctxAt(off.mem_base));
        try k.s.movRM(.r14, ctxAt(off.mem_len));
    }

    fn callHelper(k: *Compiler, f: usize, ins: ?*const mod.Ins, h: u64) !void {
        try k.s.movRR(.rdi, .rbx);
        try k.s.movRR(.rsi, .r15);
        if (ins) |p| try k.s.movRI64(.rdx, @intFromPtr(p)) else try k.s.movRI64(.rdx, h);
        try k.s.movRI64(.rcx, h);
        try k.s.movRI64(.rax, f);
        try k.s.callR(.rax);
        try k.reload();
    }

    fn checkRax(k: *Compiler) !void {
        try k.s.aluRR(.@"or", .rax, .rax);
        try k.s.jcc(.ne, k.trap_rax);
    }

    fn label(k: *Compiler, pc: u32) Label {
        return k.targets[pc].?;
    }

    /// Moves `arity` slots from below `h` to `height`.
    fn moveValues(k: *Compiler, h: i64, arity: i64, height: i64) !void {
        if (h - arity == height) return;
        var i: i64 = 0;
        while (i < arity) : (i += 1) {
            try k.s.movRM(.rax, slot(h - arity + i));
            try k.s.movMR(slot(height + i), .rax);
        }
    }

    fn tick(k: *Compiler) !void {
        try k.s.movRM(.rax, ctxAt(off.units));
        try k.s.aluMI(.sub, .{ .base = .rax }, 1);
        try k.s.jcc(.b, k.trap_labels[T.compute]);
    }

    fn function(k: *Compiler, idx: usize) !void {
        const f = &k.m.funcs[idx];
        k.f = f;
        k.s.bind(k.func_labels[idx]);
        // Labels of the branch targets.
        k.targets = try k.a.alloc(?Label, f.code.len + 1);
        @memset(k.targets, null);
        for (f.code) |ins| switch (ins.op) {
            mod.op.br, mod.op.br_if, mod.op.jz, mod.op.jmp => k.targets[ins.a] = k.targets[ins.a] orelse try k.s.newLabel(),
            else => {},
        };
        for (f.targets) |t| k.targets[t.pc] = k.targets[t.pc] orelse try k.s.newLabel();

        try k.s.aluRI(.sub, .rsp, 8);
        try k.tick();
        // The depth: the interpreter traps when the callers fill the frames.
        try k.s.movRM(.rax, ctxAt(off.depth));
        try k.s.aluRM(.cmp, .rax, ctxAt(off.max_depth));
        try k.s.jcc(.a, k.trap_labels[T.stack]);
        try k.s.incM(ctxAt(off.depth));
        try k.s.aluRM(.cmp, .rsp, ctxAt(off.rsp_limit));
        try k.s.jcc(.b, k.trap_labels[T.stack]);
        // Room on the value stack.
        const ok = try k.s.newLabel();
        try k.s.lea(.rax, slot(f.max_height));
        try k.s.aluRM(.cmp, .rax, ctxAt(off.st_end));
        try k.s.jcc(.be, ok);
        try k.callHelper(@intFromPtr(&hGrow), null, f.max_height);
        try k.checkRax();
        k.s.bind(ok);
        // The declared locals are zero.
        const n = f.nlocals - f.nparams;
        if (n > 0) {
            if (n <= 16) {
                try k.s.aluRR(.xor, .rax, .rax);
                var i: u32 = 0;
                while (i < n) : (i += 1) try k.s.movMR(slot(f.nparams + i), .rax);
            } else {
                try k.s.lea(.rdi, slot(f.nparams));
                try k.s.movRI64(.rcx, n);
                try k.s.aluRR(.xor, .rax, .rax);
                try k.s.raw(&.{ 0xF3, 0x48, 0xAB });
            }
        }
        for (f.code, 0..) |*ins, pc| {
            if (k.targets[pc]) |l| k.s.bind(l);
            try k.instruction(ins, f.heights[pc]);
        }
        if (k.targets[f.code.len]) |l| k.s.bind(l);
    }

    fn instruction(k: *Compiler, ins: *const mod.Ins, h: u32) !void {
        const s = &k.s;
        const hi: i64 = h;
        switch (ins.op) {
            0x00 => try s.jmp(k.trap_labels[T.unreachable_]),
            mod.op.tick => try k.tick(),
            mod.op.br => {
                try k.moveValues(hi, @intCast(ins.b >> 32), @as(u32, @truncate(ins.b)));
                try s.jmp(k.label(ins.a));
            },
            mod.op.br_if => {
                const skip = try s.newLabel();
                try s.movRM32(.rax, slot(hi - 1));
                try s.testRR32(.rax, .rax);
                try s.jcc(.e, skip);
                try k.moveValues(hi - 1, @intCast(ins.b >> 32), @as(u32, @truncate(ins.b)));
                try s.jmp(k.label(ins.a));
                s.bind(skip);
            },
            mod.op.jz => {
                try s.movRM32(.rax, slot(hi - 1));
                try s.testRR32(.rax, .rax);
                try s.jcc(.e, k.label(ins.a));
            },
            mod.op.jmp => try s.jmp(k.label(ins.a)),
            mod.op.br_table => {
                const n: u32 = @intCast(ins.b);
                const cases = try k.a.alloc(Label, n);
                for (cases) |*l| l.* = try s.newLabel();
                const table = try s.newLabel();
                try s.movRM32(.rax, slot(hi - 1));
                try s.movRI32(.rcx, @intCast(n - 1));
                try s.aluRR(.cmp, .rax, .rcx);
                try s.insR(null, false, &.{ 0x0F, 0x47 }, 0, .rcx); // cmova eax, ecx
                try s.leaRip(.rcx, table);
                try s.raw(&.{ 0x48, 0x63, 0x04, 0x81 }); // movsxd rax, [rcx + rax*4]
                try s.aluRR(.add, .rax, .rcx);
                try s.jmpR(.rax);
                s.bind(table);
                try k.tables.append(k.a, .{ .at = s.here(), .cases = cases });
                var i: u32 = 0;
                while (i < n) : (i += 1) try s.raw(&.{ 0, 0, 0, 0 });
                for (cases, 0..) |l, j| {
                    const t = k.f.targets[ins.a + j];
                    s.bind(l);
                    try k.moveValues(hi - 1, t.arity, t.height);
                    try s.jmp(k.label(t.pc));
                }
            },
            mod.op.ret => {
                const n: i64 = k.f.nresults;
                var i: i64 = 0;
                if (hi - n != 0) while (i < n) : (i += 1) {
                    try s.movRM(.rax, slot(hi - n + i));
                    try s.movMR(slot(i), .rax);
                };
                try s.decM(ctxAt(off.depth));
                try s.aluRI(.add, .rsp, 8);
                try s.ret();
            },
            0x10 => {
                if (ins.a < k.m.import_funcs) {
                    try k.callHelper(@intFromPtr(&hCall), ins, h);
                    try k.checkRax();
                    return;
                }
                const callee = &k.m.funcs[ins.a - k.m.import_funcs];
                try k.directCall(hi - callee.nparams, null, k.func_labels[ins.a - k.m.import_funcs]);
            },
            0x11 => {
                const np: i64 = @intCast(k.m.types[ins.a].params.len);
                try k.callHelper(@intFromPtr(&hIndirect), ins, h);
                const done = try s.newLabel();
                const direct = try s.newLabel();
                try s.aluRI(.cmp, .rax, 64);
                try s.jcc(.ae, direct);
                try k.checkRax();
                try s.jmp(done);
                s.bind(direct);
                try k.directCall(hi - 1 - np, .rax, null);
                s.bind(done);
            },
            0x1a => {},
            0x1b => {
                const keep = try s.newLabel();
                try s.movRM32(.rax, slot(hi - 1));
                try s.testRR32(.rax, .rax);
                try s.jcc(.ne, keep);
                try s.movRM(.rax, slot(hi - 2));
                try s.movMR(slot(hi - 3), .rax);
                s.bind(keep);
            },
            0x20 => {
                try s.movRM(.rax, slot(ins.a));
                try s.movMR(slot(hi), .rax);
            },
            0x21, 0x22 => {
                try s.movRM(.rax, slot(hi - 1));
                try s.movMR(slot(ins.a), .rax);
            },
            0x23, 0x24 => {
                try s.movRM(.rcx, ctxAt(off.globals));
                try s.movRM(.rcx, .{ .base = .rcx, .disp = @intCast(8 * @as(i64, ins.a)) });
                const val: Mem = .{ .base = .rcx, .disp = @offsetOf(exec.Global, "val") };
                if (ins.op == 0x23) {
                    try s.movRM(.rax, val);
                    try s.movMR(slot(hi), .rax);
                } else {
                    try s.movRM(.rax, slot(hi - 1));
                    try s.movMR(val, .rax);
                }
            },
            0x28...0x35 => try k.load(ins, hi),
            0x36...0x3e => try k.store(ins, hi),
            0x41, 0x42 => {
                const v: u64 = ins.b;
                if (v <= 0x7fff_ffff) {
                    try s.movMI(slot(hi), @intCast(v));
                } else {
                    try s.movRI64(.rax, v);
                    try s.movMR(slot(hi), .rax);
                }
            },
            0x45 => {
                try s.aluMI32(.cmp, slot(hi - 1), 0);
                try k.setBool(.e, hi - 1);
            },
            0x50 => {
                try s.aluMI(.cmp, slot(hi - 1), 0);
                try k.setBool(.e, hi - 1);
            },
            0x46...0x4f, 0x51...0x5a => {
                const wide = ins.op >= 0x51;
                const i = ins.op - @as(u16, if (wide) 0x51 else 0x46);
                const conds = [_]x64.Cond{ .e, .ne, .l, .b, .g, .a, .le, .be, .ge, .ae };
                if (wide) {
                    try s.movRM(.rax, slot(hi - 2));
                    try s.aluRM(.cmp, .rax, slot(hi - 1));
                } else {
                    try s.movRM32(.rax, slot(hi - 2));
                    try s.aluRM32(.cmp, .rax, slot(hi - 1));
                }
                try k.setBool(conds[i], hi - 2);
            },
            0x6a, 0x6b, 0x71, 0x72, 0x73, 0x7c, 0x7d, 0x83, 0x84, 0x85 => {
                const wide = ins.op >= 0x7c;
                const alu: x64.Alu = switch (ins.op) {
                    0x6a, 0x7c => .add,
                    0x6b, 0x7d => .sub,
                    0x71, 0x83 => .@"and",
                    0x72, 0x84 => .@"or",
                    else => .xor,
                };
                if (wide) {
                    try s.movRM(.rax, slot(hi - 2));
                    try s.aluRM(alu, .rax, slot(hi - 1));
                } else {
                    try s.movRM32(.rax, slot(hi - 2));
                    try s.aluRM32(alu, .rax, slot(hi - 1));
                }
                try s.movMR(slot(hi - 2), .rax);
            },
            0x6c, 0x7e => {
                const wide = ins.op == 0x7e;
                try s.movRM(.rax, slot(hi - 2));
                try s.insM(null, wide, &.{ 0x0F, 0xAF }, 0, slot(hi - 1));
                if (!wide) try s.movRR32(.rax, .rax);
                try s.movMR(slot(hi - 2), .rax);
            },
            0x74, 0x75, 0x76, 0x77, 0x78, 0x86, 0x87, 0x88, 0x89, 0x8a => {
                const wide = ins.op >= 0x86;
                const ext: u4 = switch (ins.op) {
                    0x74, 0x86 => 4,
                    0x75, 0x87 => 7,
                    0x76, 0x88 => 5,
                    0x77, 0x89 => 0,
                    else => 1,
                };
                try s.movRM(.rcx, slot(hi - 1));
                try s.movRM(.rax, slot(hi - 2));
                try s.insR(null, wide, &.{0xD3}, ext, .rax);
                if (!wide) try s.movRR32(.rax, .rax);
                try s.movMR(slot(hi - 2), .rax);
            },
            0xa0, 0xa1, 0xa2, 0xa3 => {
                const o: x64.Asm.Sse = switch (ins.op) {
                    0xa0 => .addsd,
                    0xa1 => .subsd,
                    0xa2 => .mulsd,
                    else => .divsd,
                };
                try s.movsdXM(.xmm0, slot(hi - 2));
                try s.movsdXM(.xmm1, slot(hi - 1));
                try s.sse(o, .xmm0, .xmm1);
                try s.movsdMX(slot(hi - 2), .xmm0);
            },
            else => {
                try k.callHelper(@intFromPtr(&hSimple), ins, h);
                try k.checkRax();
            },
        }
    }

    fn setBool(k: *Compiler, c: x64.Cond, at: i64) !void {
        try k.s.setcc(c, .rax);
        try k.s.movzxRR8(.rax, .rax);
        try k.s.movMR(slot(at), .rax);
    }

    /// The address of an access of `n` bytes in rax, after the bounds check.
    fn address(k: *Compiler, ins: *const mod.Ins, at: i64, n: u32) !bool {
        const end = @as(u64, ins.a) + n;
        if (end > 0x7fff_ffff) return false;
        try k.s.movRM32(.rax, slot(at));
        try k.s.lea(.rcx, .{ .base = .rax, .disp = @intCast(end) });
        try k.s.aluRR(.cmp, .rcx, .r14);
        try k.s.jcc(.a, k.trap_labels[T.oob]);
        try k.s.aluRR(.add, .rax, .r13);
        return true;
    }

    fn load(k: *Compiler, ins: *const mod.Ins, hi: i64) !void {
        const n: u32 = switch (ins.op) {
            0x28, 0x2a, 0x34, 0x35 => 4,
            0x29, 0x2b => 8,
            0x2c, 0x2d, 0x30, 0x31 => 1,
            else => 2,
        };
        if (!try k.address(ins, hi - 1, n)) {
            try k.callHelper(@intFromPtr(&hSimple), ins, @intCast(hi));
            return k.checkRax();
        }
        const m: Mem = .{ .base = .rax, .disp = @intCast(ins.a) };
        const s = &k.s;
        switch (ins.op) {
            0x28, 0x2a, 0x35 => try s.insM(null, false, &.{0x8B}, 0, m),
            0x29, 0x2b => try s.insM(null, true, &.{0x8B}, 0, m),
            0x2c => try s.insM(null, false, &.{ 0x0F, 0xBE }, 0, m),
            0x2d, 0x31 => try s.insM(null, false, &.{ 0x0F, 0xB6 }, 0, m),
            0x2e => try s.insM(null, false, &.{ 0x0F, 0xBF }, 0, m),
            0x2f, 0x33 => try s.insM(null, false, &.{ 0x0F, 0xB7 }, 0, m),
            0x30 => try s.insM(null, true, &.{ 0x0F, 0xBE }, 0, m),
            0x32 => try s.insM(null, true, &.{ 0x0F, 0xBF }, 0, m),
            0x34 => try s.insM(null, true, &.{0x63}, 0, m),
            else => unreachable,
        }
        try s.movMR(slot(hi - 1), .rax);
    }

    fn store(k: *Compiler, ins: *const mod.Ins, hi: i64) !void {
        const n: u32 = switch (ins.op) {
            0x36, 0x38, 0x3e => 4,
            0x37, 0x39 => 8,
            0x3a, 0x3c => 1,
            else => 2,
        };
        if (!try k.address(ins, hi - 2, n)) {
            try k.callHelper(@intFromPtr(&hSimple), ins, @intCast(hi));
            return k.checkRax();
        }
        const m: Mem = .{ .base = .rax, .disp = @intCast(ins.a) };
        const s = &k.s;
        try s.movRM(.rcx, slot(hi - 1));
        switch (n) {
            4 => try s.insM(null, false, &.{0x89}, 1, m),
            8 => try s.insM(null, true, &.{0x89}, 1, m),
            1 => try s.insM(null, false, &.{0x88}, 1, m),
            else => try s.insM(0x66, false, &.{0x89}, 1, m),
        }
    }

    /// A call with the arguments from slot `base`: to a label, or to the
    /// address in a register.
    fn directCall(k: *Compiler, base: i64, reg: ?Reg, l: ?Label) !void {
        const s = &k.s;
        try s.push(.r15);
        try s.aluRI(.sub, .rsp, 8);
        try s.aluRI(.add, .r15, @intCast(8 * base));
        try s.lea(.r12, slot(base));
        if (reg) |r| try s.callR(r) else try s.callL(l.?);
        try s.aluRI(.add, .rsp, 8);
        try s.pop(.r15);
        try k.reload();
    }

    fn stubs(k: *Compiler) !void {
        const s = &k.s;
        for (&k.trap_labels, 0..) |l, code| {
            s.bind(l);
            if (code == T.compute) {
                // The count wrapped below zero: it is zero.
                try s.movRM(.rax, ctxAt(off.units));
                try s.movMI(.{ .base = .rax }, 0);
            }
            try s.movRI32(.rax, @intCast(code));
            try s.jmp(k.trap_rax);
        }
        s.bind(k.trap_rax);
        try s.movRM(.rsp, ctxAt(off.saved_rsp));
        try s.jmp(k.exit);
    }
};

/// Compiles all functions of `m`. Gives null when the region is full.
pub fn compile(gpa: std.mem.Allocator, m: *const mod.Module) !?*Code {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var k: Compiler = .{ .s = Asm.init(a), .m = m, .func_labels = try a.alloc(Label, m.funcs.len), .a = a };
    for (k.func_labels) |*l| l.* = try k.s.newLabel();
    for (&k.trap_labels) |*l| l.* = try k.s.newLabel();
    k.trap_rax = try k.s.newLabel();
    k.exit = try k.s.newLabel();
    const s = &k.s;
    // The entry: entry(ctx, code).
    for ([_]Reg{ .rbx, .rbp, .r12, .r13, .r14, .r15 }) |r| try s.push(r);
    try s.aluRI(.sub, .rsp, 8);
    try s.movRR(.rbx, .rdi);
    try s.movMR(Compiler.ctxAt(off.saved_rsp), .rsp);
    try s.movRM(.r15, Compiler.ctxAt(off.frame_off));
    try k.reload();
    try s.callR(.rsi);
    try s.aluRR(.xor, .rax, .rax);
    s.bind(k.exit);
    try s.aluRI(.add, .rsp, 8);
    for ([_]Reg{ .r15, .r14, .r13, .r12, .rbp, .rbx }) |r| try s.pop(r);
    try s.ret();
    for (m.funcs, 0..) |_, i| try k.function(i);
    try k.stubs();
    try s.finish();
    // The jump tables: the offset of each case from the table.
    for (k.tables.items) |t| {
        for (t.cases, 0..) |l, j| {
            const rel: i32 = @intCast(@as(i64, s.labelPos(l)) - t.at);
            std.mem.writeInt(i32, s.buf.items[t.at + 4 * j ..][0..4], rel, .little);
        }
    }
    const placed = region().append(s.bytes()) orelse return null;
    const base = @intFromPtr(placed.ptr);
    const code = try gpa.create(Code);
    errdefer gpa.destroy(code);
    code.funcs = try gpa.alloc(usize, m.funcs.len);
    for (code.funcs, k.func_labels) |*f, l| f.* = base + s.labelPos(l);
    code.entry = @ptrFromInt(base);
    return code;
}

var the_region: ?jmem.Region = null;
var region_mutex: std.atomic.Mutex = .unlocked;
var dead_region: jmem.Region = undefined;

/// The executable region of the wasm JIT, for the process: 1 GiB of
/// address space, which the code fills page by page.
fn region() *jmem.Region {
    if (the_region == null) the_region = jmem.Region.init(1 << 30);
    return if (the_region) |*r| r else &dead_region;
}

pub fn lock() void {
    while (!region_mutex.tryLock()) {}
}

pub fn unlock() void {
    region_mutex.unlock();
}

pub fn freeCode(gpa: std.mem.Allocator, c: *Code) void {
    gpa.free(c.funcs);
    gpa.destroy(c);
}

/// Runs function `idx` of the module of `inst` in the JIT code. The
/// arguments are on top of the stack, and the results replace them.
pub fn run(s: *exec.Store, code: *const Code, inst: *exec.Instance, idx: usize) exec.Error!void {
    const f = &inst.module.funcs[idx];
    var ctx: Ctx = .{
        .units = @intFromPtr(s.units),
        .max_depth = s.max_frames,
        .store = @intFromPtr(s),
        .inst = @intFromPtr(inst),
        .globals = @intFromPtr(inst.globals.ptr),
        .frame_off = (s.sp - f.nparams) * 8,
    };
    // The native stack: the frames of the JIT use 32 bytes for each call,
    // so the maximum of frames needs 640,000 bytes. Nested runs share the
    // limit of the outermost run.
    const here = @frameAddress();
    const outer = s.jit_rsp_limit == 0;
    if (outer) s.jit_rsp_limit = here -| (1 << 20);
    defer if (outer) {
        s.jit_rsp_limit = 0;
    };
    ctx.rsp_limit = s.jit_rsp_limit;
    refresh(&ctx);
    const rc = code.entry(&ctx, code.funcs[idx]);
    if (rc != 0) return errorOf(rc);
    s.sp = @intCast(ctx.frame_off / 8 + f.nresults);
}
