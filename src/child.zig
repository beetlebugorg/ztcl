//! The optional `interp` command (capability `interp`).
//!
//! A child interpreter has its own commands and variables. Its memory
//! comes through the counter of its parent, so the memory limit of the
//! parent also counts the child. A call into a child takes the step
//! limit, the nesting counts, and the native stack base of the caller,
//! and gives the step limit back, so a chain of interpreters has the
//! same bounds as one interpreter. A child has at most the capabilities
//! of its parent. A safe child has none.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

pub const Child = struct {
    name: []const u8,
    it: *Interp,
};

const Alias = struct {
    target: *Interp,
    words: []const Value,
    source_name: []const u8,
    prefix: Value,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A copy of a value in the arena of another interpreter.
fn carry(from: *Interp, to: *Interp, v: Value) Error!Value {
    return .{ .str = try to.alloc().dupe(u8, try from.str(v)) };
}

const Saved = struct { depth: u32, nest: u32, base: usize, native: usize, limit: usize, scope: u32 };

pub fn enter(from: *Interp, to: *Interp) Saved {
    const s: Saved = .{ .depth = to.depth, .nest = to.nest, .base = to.native_base, .native = to.max_native, .limit = to.mem_limit, .scope = to.gc_scope };
    to.active += 1;
    to.step_limit = from.step_limit;
    to.depth += from.depth;
    to.nest += from.nest + 1;
    to.native_base = from.native_base;
    to.max_native = from.max_native;
    to.gc_scope = from.gc_scope;
    to.heap.roots_ctx = to;
    // A child counts in its parent, so the room of the child is the
    // limit of the parent less the rest of the memory of the parent.
    if (to.parent == from) to.mem_limit = @min(to.mem_limit, from.mem_limit -| (from.memUsed() -| to.memUsed()));
    return s;
}

pub fn leave(from: *Interp, to: *Interp, s: Saved) void {
    from.step_limit = to.step_limit;
    to.depth = s.depth;
    to.nest = s.nest;
    to.native_base = s.base;
    to.max_native = s.native;
    to.mem_limit = s.limit;
    to.gc_scope = s.scope;
    to.heap.roots_ctx = from;
    value.precision = from.precision;
    to.active -= 1;
    reap(to);
}

/// Gives the error of `to` to `from`.
pub fn passError(from: *Interp, to: *Interp, e: Error) Error {
    if (e == error.OutOfMemory) return e;
    from.result = carry(to, from, to.result) catch return error.OutOfMemory;
    from.error_code = carry(to, from, to.error_code) catch return error.OutOfMemory;
    if (e == error.TclError) {
        const info = to.getVarPlain("::errorInfo") catch to.result;
        const text = carry(to, from, info) catch return error.OutOfMemory;
        from.in_error = true;
        from.error_info = .empty;
        from.error_info.appendSlice(from.alloc(), text.str) catch return error.OutOfMemory;
    }
    if (e == error.TclCustom) from.custom_code = to.custom_code;
    if (e == error.TclReturn) {
        from.ret_code = to.ret_code;
        from.ret_level = to.ret_level;
    }
    return e;
}

/// Finds an interpreter by a path relative to `it`.
fn resolve(it: *Interp, path: Value) Error!*Interp {
    var cur = it;
    for (try it.list(path)) |w| {
        const name = try it.str(w);
        const c = cur.children.get(name) orelse
            return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP INTERP {s}", .{try it.str(path)}), "could not find interpreter \"{s}\"", .{try it.str(path)});
        cur = c.it;
    }
    return cur;
}

fn create(it: *Interp, name: []const u8, safe: bool) Error!*Interp {
    const a = it.alloc();
    const raw = it.heap.backing;
    const child = raw.create(Interp) catch return error.OutOfMemory;
    child.initChild(it) catch {
        raw.destroy(child);
        return error.OutOfMemory;
    };
    child.parent = it;
    child.is_safe = safe or it.is_safe;
    child.mem_limit = it.mem_limit;
    child.step_limit = it.step_limit;
    child.output = it.output;
    child.user = it.user;
    child.noise_seed = it.noise_seed;
    child.clock_host = it.clock_host;
    child.event_host = it.event_host;
    child.launch_host = it.launch_host;
    child.registry_allow = it.registry_allow;
    child.exec_host = it.exec_host;
    // A child has the network policy of its parent. No command of a
    // script changes it.
    child.net = it.net;
    // A child has the JIT only when its parent has it.
    @import("jit.zig").inherit(child, it);
    if (!child.is_safe) {
        // A child shares the jail of its parent through its own descriptor.
        if (comptime @import("fsroot.zig").supported) {
            try @import("fsroot.zig").shareRoot(it, child);
            child.fs.cwd = try child.alloc().dupe(u8, it.fs.cwd);
            child.fs.path = try child.alloc().dupe(u8, it.fs.path);
        }
        // A child has no `thread` capability: a thread has one
        // interpreter that gets its messages.
        const no_thread = ~@as(u32, @intFromEnum(interp.Capability.thread));
        try child.allow((if (child.fs_ok()) it.capabilities else it.capabilities & ~@as(u32, 8 | 16)) & no_thread);
    }
    // A safe child has the event loop of its parent. A timer reaches
    // no host data.
    if (child.is_safe) try child.allow(it.capabilities & @intFromEnum(interp.Capability.event));
    const c = try a.create(Child);
    c.* = .{ .name = try a.dupe(u8, name), .it = child };
    try it.children.put(a, c.name, c);
    const cmd = try a.create(interp.Command);
    cmd.* = .{ .name = c.name, .impl = .{ .native = childCmd }, .ctx = c };
    try it.commands.put(a, c.name, cmd);
    it.epoch += 1;
    return child;
}

fn inTree(top: *const Interp, x: *const Interp) bool {
    var cur: ?*const Interp = x;
    while (cur) |c| : (cur = c.parent) {
        if (c == top) return true;
    }
    return false;
}

/// Removes each alias in the tree under `at` that goes into `gone`.
/// The count of commands of each interpreter in the tree under `at`.
fn treeCommands(at: *const Interp) usize {
    var n: usize = at.commands.count();
    var kids = at.children.valueIterator();
    while (kids.next()) |c| n +|= treeCommands(c.*.it);
    return n;
}

fn dropAliases(at: *Interp, gone: *const Interp) void {
    var keys: std.ArrayList([]const u8) = .empty;
    var iter = at.commands.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.*.impl == .native and e.value_ptr.*.impl.native == &aliasCall) {
            const al: *Alias = @ptrCast(@alignCast(e.value_ptr.*.ctx.?));
            if (inTree(gone, al.target)) keys.append(at.alloc(), e.key_ptr.*) catch {};
        }
    }
    for (keys.items) |k| _ = at.commands.remove(k);
    if (keys.items.len > 0) at.epoch += 1;
    var kids = at.children.valueIterator();
    while (kids.next()) |c| {
        if (c.*.it != gone) dropAliases(c.*.it, gone);
    }
}

/// True when code of the interpreter or of a descendant is running.
fn busy(x: *const Interp) bool {
    if (x.active != 0) return true;
    var kids = x.children.valueIterator();
    while (kids.next()) |c| {
        if (busy(c.*.it)) return true;
    }
    return false;
}

fn release(x: *Interp) void {
    const owner = x.parent.?;
    x.deinit();
    var root = owner;
    while (root.parent) |p| root = p;
    for (root.kids.items, 0..) |k, i| {
        if (k == x) {
            _ = root.kids.swapRemove(i);
            break;
        }
    }
    owner.heap.backing.destroy(x);
}

/// Frees the topmost deleted interpreter above `x` when nothing in it
/// runs. A delete from inside a running interpreter ends here.
fn reap(x: *Interp) void {
    var top: ?*Interp = null;
    var cur: ?*Interp = x;
    while (cur) |c| : (cur = c.parent) {
        if (c.doomed) top = c;
    }
    if (top) |t| {
        if (!busy(t)) release(t);
    }
}

/// Removes a child and frees it, or frees it later when it is running.
pub fn destroy(it: *Interp, name: []const u8) void {
    const kv = it.children.fetchRemove(name) orelse return;
    const child = kv.value.it;
    _ = it.commands.remove(name);
    it.epoch += 1;
    var root = it;
    while (root.parent) |p| root = p;
    dropAliases(root, child);
    @import("event.zig").forget(child);
    if (busy(child)) {
        child.doomed = true;
        return;
    }
    release(child);
}

/// Frees all children, for `deinit` and `reset`.
pub fn destroyAll(it: *Interp) void {
    while (it.children.count() > 0) {
        var iter = it.children.keyIterator();
        const k = iter.next().?.*;
        destroy(it, k);
    }
}

fn evalIn(it: *Interp, target: *Interp, words: []const Value) Error!Value {
    const a = target.alloc();
    var text: std.ArrayList(u8) = .empty;
    for (words, 0..) |v, i| {
        if (i > 0) try text.append(a, ' ');
        try text.appendSlice(a, try it.str(v));
    }
    if (target == it) return it.evalScript(try it.compile(text.items));
    const s = enter(it, target);
    const r = target.eval(text.items);
    const out = if (r) |v| carry(target, it, v) else |e| passErrorAfter(it, target, e);
    leave(it, target, s);
    return out;
}

fn passErrorAfter(from: *Interp, to: *Interp, e: Error) Error!Value {
    return passError(from, to, e);
}

fn aliasCall(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const al: *Alias = @ptrCast(@alignCast(self.ctx.?));
    try it.checkNative();
    if (it.nest >= it.max_nest) return it.fail("too many nested evaluations (infinite loop?)", .{});
    if (al.target == it) {
        it.nest += 1;
        defer it.nest -= 1;
        const words = try it.alloc().alloc(Value, al.words.len + argv.len - 1);
        @memcpy(words[0..al.words.len], al.words);
        @memcpy(words[al.words.len..], argv[1..]);
        return it.callWords(words);
    }
    const t = al.target;
    const words = try t.alloc().alloc(Value, al.words.len + argv.len - 1);
    @memcpy(words[0..al.words.len], al.words);
    for (argv[1..], words[al.words.len..]) |v, *o| o.* = try carry(it, t, v);
    const s = enter(it, t);
    const r = t.callWords(words);
    const out = if (r) |v| carry(t, it, v) else |e| blk: {
        if (e == error.TclError) t.finishError() catch {};
        break :blk passErrorAfter(it, t, e);
    };
    leave(it, t, s);
    return out;
}

fn makeAlias(it: *Interp, src: *Interp, src_name: []const u8, target: *Interp, words: []const Value) Error!Value {
    const a = src.alloc();
    const copy = try target.alloc().alloc(Value, words.len);
    for (words, copy) |v, *o| o.* = try carry(it, target, v);
    const al = try a.create(Alias);
    const name = try src.qualify(src_name);
    al.* = .{ .target = target, .words = copy, .source_name = name, .prefix = try value.newList(a, blk: {
        const tmp = try a.alloc(Value, words.len);
        for (words, tmp) |v, *o| o.* = try carry(it, src, v);
        break :blk tmp;
    }) };
    const cmd = try a.create(interp.Command);
    cmd.* = .{ .name = name, .impl = .{ .native = aliasCall }, .ctx = al };
    try src.commands.put(a, name, cmd);
    src.epoch += 1;
    return .{ .str = try it.alloc().dupe(u8, src_name) };
}

fn aliasInfo(it: *Interp, src: *Interp, name: []const u8) Error!Value {
    const c = src.findCommand(name) orelse return it.fail("alias \"{s}\" not found", .{name});
    if (c.impl != .native or c.impl.native != &aliasCall) return it.fail("alias \"{s}\" not found", .{name});
    const al: *Alias = @ptrCast(@alignCast(c.ctx.?));
    return carry(src, it, al.prefix);
}

fn aliasNames(it: *Interp, src: *Interp) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    try cmds.chargeEntries(it, src.commands.count());
    var iter = src.commands.iterator();
    while (iter.next()) |e| {
        if (e.value_ptr.*.impl == .native and e.value_ptr.*.impl.native == &aliasCall) {
            try out.append(it.alloc(), .{ .str = try it.alloc().dupe(u8, e.key_ptr.*) });
        }
    }
    return value.wrapList(it.alloc(), out.items);
}

fn hideCmd(it: *Interp, target: *Interp, name: []const u8, as: []const u8) Error!Value {
    const kv = target.commands.fetchRemove(name) orelse return it.fail("unknown command \"{s}\"", .{name});
    try target.hidden.put(target.alloc(), try target.alloc().dupe(u8, as), kv.value);
    target.epoch += 1;
    return Value.empty;
}

fn exposeCmd(it: *Interp, target: *Interp, name: []const u8, as: []const u8) Error!Value {
    const kv = target.hidden.fetchRemove(name) orelse return it.fail("unknown hidden command \"{s}\"", .{name});
    try target.commands.put(target.alloc(), try target.alloc().dupe(u8, as), kv.value);
    target.epoch += 1;
    return Value.empty;
}

fn hiddenNames(it: *Interp, target: *Interp) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    var iter = target.hidden.keyIterator();
    while (iter.next()) |k| try out.append(it.alloc(), .{ .str = try it.alloc().dupe(u8, k.*) });
    return value.wrapList(it.alloc(), out.items);
}

fn invokeHidden(it: *Interp, target: *Interp, words: []const Value) Error!Value {
    if (words.len == 0) return it.wrongArgs("interp invokehidden path ?-option ...? hiddenCmdName ?arg ...?");
    const name = try it.str(words[0]);
    const c = target.hidden.get(name) orelse return it.fail("unknown hidden command \"{s}\"", .{name});
    const argv = try target.alloc().alloc(Value, words.len);
    for (words, argv) |v, *o| o.* = try carry(it, target, v);
    if (target == it) return it.call(c, argv, null);
    const s = enter(it, target);
    const r = target.call(c, argv, null);
    const out = if (r) |v| carry(target, it, v) else |e| blk: {
        if (e == error.TclError) target.finishError() catch {};
        break :blk passErrorAfter(it, target, e);
    };
    leave(it, target, s);
    return out;
}

/// The subcommands that a path and the command of a child have.
fn common(it: *Interp, target: *Interp, sub: []const u8, args: []const Value) Error!?Value {
    if (eql(sub, "eval")) {
        if (args.len < 1) return it.wrongArgs("interp eval path arg ?arg ...?");
        return try evalIn(it, target, args);
    }
    if (eql(sub, "issafe")) return .{ .int = @intFromBool(target.is_safe) };
    if (eql(sub, "aliases")) return try aliasNames(it, target);
    if (eql(sub, "hidden")) return try hiddenNames(it, target);
    if (eql(sub, "hide")) {
        if (args.len < 1 or args.len > 2) return it.wrongArgs("interp hide path cmdName ?hiddenCmdName?");
        const n = try it.str(args[0]);
        return try hideCmd(it, target, n, if (args.len == 2) try it.str(args[1]) else n);
    }
    if (eql(sub, "expose")) {
        if (args.len < 1 or args.len > 2) return it.wrongArgs("interp expose path hiddenCmdName ?cmdName?");
        const n = try it.str(args[0]);
        return try exposeCmd(it, target, n, if (args.len == 2) try it.str(args[1]) else n);
    }
    if (eql(sub, "invokehidden")) return try invokeHidden(it, target, args);
    if (eql(sub, "recursionlimit")) {
        if (args.len > 1) return it.wrongArgs("interp recursionlimit path ?newlimit?");
        if (args.len == 1) {
            const n = try it.int(args[0]);
            if (n <= 0) return it.fail("recursion limit must be > 0", .{});
            if (n > 600) return it.fail("the recursion limit of this interpreter is 600", .{});
            target.max_depth = @intCast(n);
        }
        return .{ .int = target.max_depth };
    }
    if (eql(sub, "bgerror")) {
        if (args.len > 1) return it.wrongArgs("interp bgerror path ?cmdPrefix?");
        if (args.len == 1) {
            const l = try it.list(args[0]);
            if (l.len == 0) return it.fail("cmdPrefix must be list of length >= 1", .{});
            const text = try it.str(args[0]);
            target.bg_handler = if (eql(text, "::tcl::Bgerror")) null else try target.alloc().dupe(u8, text);
        }
        return .{ .str = try it.alloc().dupe(u8, target.bg_handler orelse "::tcl::Bgerror") };
    }
    if (eql(sub, "marktrusted")) {
        if (it.is_safe) return it.fail("permission denied: safe interpreter cannot mark trusted", .{});
        target.is_safe = false;
        return Value.empty;
    }
    return null;
}

fn childCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} cmd ?arg ...?\"", .{try it.str(argv[0])});
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name", .{});
    const c: *Child = @ptrCast(@alignCast(self.ctx.?));
    const sub = try it.str(argv[1]);
    if (eql(sub, "alias")) {
        if (argv.len < 3) return it.wrongArgs("interp alias childPath childCmd ?targetPath targetCmd arg ...?");
        const name = try it.str(argv[2]);
        if (argv.len == 3) return aliasInfo(it, c.it, name);
        if (argv.len == 4 and (try it.str(argv[3])).len == 0) {
            _ = c.it.commands.remove(try c.it.qualify(name));
            c.it.epoch += 1;
            return Value.empty;
        }
        return makeAlias(it, c.it, name, it, argv[3..]);
    }
    if (try common(it, c.it, sub, argv[2..])) |v| return v;
    return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be alias, aliases, eval, expose, hide, hidden, invokehidden, issafe, marktrusted, or recursionlimit", .{sub});
}

pub fn cmdInterp(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("interp cmd ?arg ...?");
    const a = it.alloc();
    const word = try it.str(argv[1]);
    const names = [_][]const u8{ "alias", "aliases", "bgerror", "children", "create", "delete", "eval", "exists", "expose", "hide", "hidden", "invokehidden", "issafe", "marktrusted", "recursionlimit", "slaves", "target" };
    var sub: []const u8 = word;
    var hits: usize = 0;
    for (names) |n| {
        if (eql(n, word)) {
            sub = n;
            hits = 1;
            break;
        }
        if (word.len > 0 and std.mem.startsWith(u8, n, word)) {
            sub = n;
            hits += 1;
        }
    }
    if (hits != 1) return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be alias, aliases, children, create, delete, eval, exists, expose, hide, hidden, invokehidden, issafe, marktrusted, recursionlimit, slaves, or target", .{word});
    const args = argv[2..];
    if (eql(sub, "create")) {
        var safe = false;
        var path: ?Value = null;
        var k: usize = 0;
        var end_opts = false;
        while (k < args.len) : (k += 1) {
            const o = try it.str(args[k]);
            if (!end_opts and o.len > 0 and o[0] == '-') {
                if (eql(o, "-safe")) {
                    safe = true;
                    continue;
                }
                if (eql(o, "--")) {
                    end_opts = true;
                    continue;
                }
                return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -safe or --", .{o});
            }
            if (path != null) return it.wrongArgs("interp create ?-safe? ?--? ?path?");
            path = args[k];
        }
        const i: usize = 0;
        var one: [1]Value = undefined;
        if (path) |p| one[0] = p;
        const path_args: []const Value = if (path != null) one[0..1] else one[0..0];
        var parent = it;
        var name: []const u8 = undefined;
        if (i < path_args.len) {
            const parts = try it.list(path_args[i]);
            if (parts.len == 0) return it.fail("cannot create an interpreter with an empty path", .{});
            for (parts[0 .. parts.len - 1]) |w| {
                const c = parent.children.get(try it.str(w)) orelse return it.fail("could not find interpreter \"{s}\"", .{try it.str(path_args[i])});
                parent = c.it;
            }
            name = try it.str(parts[parts.len - 1]);
            if (parent.children.contains(name)) return it.fail("interpreter named \"{s}\" already exists, cannot create", .{name});
        } else {
            var n: u32 = 0;
            while (true) : (n += 1) {
                name = try std.fmt.allocPrint(a, "interp{d}", .{n});
                if (!parent.children.contains(name) and !parent.commands.contains(name)) break;
            }
        }
        _ = try create(parent, name, safe);
        return if (i < path_args.len) path_args[i] else .{ .str = name };
    }
    if (eql(sub, "delete")) {
        for (args) |v| {
            const parts = try it.list(v);
            if (parts.len == 0) return it.fail("cannot delete the current interpreter", .{});
            var parent = it;
            for (parts[0 .. parts.len - 1]) |w| {
                const c = parent.children.get(try it.str(w)) orelse return it.fail("could not find interpreter \"{s}\"", .{try it.str(v)});
                parent = c.it;
            }
            const name = try it.str(parts[parts.len - 1]);
            if (!parent.children.contains(name)) return it.fail("could not find interpreter \"{s}\"", .{try it.str(v)});
            // The delete scans the command table of each interpreter of
            // the tree for aliases.
            var root = it;
            while (root.parent) |p| root = p;
            try cmds.chargeEntries(it, treeCommands(root));
            destroy(parent, name);
        }
        return Value.empty;
    }
    if (eql(sub, "exists")) {
        if (args.len > 1) return it.wrongArgs("interp exists ?path?");
        if (args.len == 0) return .{ .int = 1 };
        var cur = it;
        for (try it.list(args[0])) |w| {
            const c = cur.children.get(try it.str(w)) orelse return .{ .int = 0 };
            cur = c.it;
        }
        return .{ .int = 1 };
    }
    if (eql(sub, "children") or eql(sub, "slaves")) {
        if (args.len > 1) return it.wrongArgs("interp children ?path?");
        const t = if (args.len == 1) try resolve(it, args[0]) else it;
        var out: std.ArrayList(Value) = .empty;
        var iter = t.children.keyIterator();
        while (iter.next()) |k| try out.append(a, .{ .str = try a.dupe(u8, k.*) });
        return value.wrapList(a, out.items);
    }
    if (eql(sub, "alias")) {
        if (args.len < 2) return it.wrongArgs("interp alias childPath childCmd ?targetPath targetCmd arg ...?");
        const src = try resolve(it, args[0]);
        const name = try it.str(args[1]);
        if (args.len == 2) return aliasInfo(it, src, name);
        if (args.len == 3) {
            if ((try it.str(args[2])).len != 0) return it.wrongArgs("interp alias childPath childCmd ?targetPath targetCmd arg ...?");
            _ = src.commands.remove(try src.qualify(name));
            src.epoch += 1;
            return Value.empty;
        }
        const target = try resolve(it, args[2]);
        return makeAlias(it, src, name, target, args[3..]);
    }
    if (eql(sub, "target")) {
        if (args.len != 2) return it.wrongArgs("interp target path alias");
        const src = try resolve(it, args[0]);
        const name = try it.str(args[1]);
        const c = src.findCommand(name) orelse return it.fail("alias \"{s}\" in path \"{s}\" not found", .{ name, try it.str(args[0]) });
        if (c.impl != .native or c.impl.native != &aliasCall) return it.fail("alias \"{s}\" in path \"{s}\" not found", .{ name, try it.str(args[0]) });
        const al: *Alias = @ptrCast(@alignCast(c.ctx.?));
        if (al.target == src) return Value.empty;
        var cur = src.parent;
        var path: std.ArrayList(Value) = .empty;
        _ = &path;
        while (cur) |p| : (cur = p.parent) {
            if (p == al.target) return Value.empty;
        }
        return it.fail("target interpreter for alias \"{s}\" in path \"{s}\" is not my descendant", .{ name, try it.str(args[0]) });
    }
    const path = if (args.len > 0) args[0] else Value.empty;
    const rest = if (args.len > 0) args[1..] else args;
    const t = try resolve(it, path);
    if (try common(it, t, sub, rest)) |v| return v;
    return it.fail("interp {s} is not available", .{sub});
}
