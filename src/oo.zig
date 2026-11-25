//! TclOO: `oo::class`, `oo::object`, `oo::define`, `oo::objdefine`,
//! `oo::copy`, `my`, `self`, `next`, and `nextto`.
//!
//! An object is a command, a namespace for its variables, and a class.
//! A class is an object with methods for its instances, superclasses,
//! and mixins. A method call builds a call chain:
//!
//! 1. The filters of the object and of its classes.
//! 2. The methods of the mixins of the object.
//! 3. The method of the object itself.
//! 4. The methods of the class: for each class, its mixins, the class,
//!    and then its superclasses in order. A method that the walk finds
//!    a second time moves to the later place.
//!
//! The first method of the chain runs, and `next` runs the one after
//! it. A method body is a proc that runs in the namespace of the
//! object. A stack of call records gives `self` and `next` the object
//! and the chain. A record matches a proc frame by its level.
//!
//! The state starts at the first use of an `oo::` command, so an
//! interpreter with no objects pays only for five command entries.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const cmds = @import("cmds.zig");
const ns_mod = @import("ns.zig");
const Value = value.Value;
const Interp = interp.Interp;
const Cmd = interp.Cmd;
const Error = interp.Error;

const Native = *const fn (it: *Interp, st: *State, call: *Call, args: []const Value) Error!Value;

const Method = struct {
    name: []const u8,
    kind: enum { none, proc, forward, native } = .none,
    params: Value = Value.empty,
    body: Value = Value.empty,
    proc: ?*interp.Proc = null,
    /// The variable list of the definer when the proc was made.
    stamp: u32 = 0,
    forward: []const Value = &.{},
    native: ?Native = null,
    /// The export flag, or null for the rule of the name.
    exported: ?bool = null,
    /// The class or the object that defines the method.
    owner: *Object,
};

const Methods = std.StringArrayHashMapUnmanaged(*Method);

const Class = struct {
    supers: std.ArrayList(*Object) = .empty,
    subs: std.ArrayList(*Object) = .empty,
    instances: std.ArrayList(*Object) = .empty,
    methods: Methods = .empty,
    mixins: std.ArrayList(*Object) = .empty,
    filters: std.ArrayList([]const u8) = .empty,
    vars: std.ArrayList([]const u8) = .empty,
    var_stamp: u32 = 1,
    ctor: ?*Method = null,
    dtor: ?*Method = null,
};

pub const Object = struct {
    /// The key of the command, with no leading `::`.
    name: []const u8,
    ns: []const u8,
    class: *Object,
    cls: ?*Class = null,
    methods: Methods = .empty,
    mixins: std.ArrayList(*Object) = .empty,
    filters: std.ArrayList([]const u8) = .empty,
    vars: std.ArrayList([]const u8) = .empty,
    var_stamp: u32 = 1,
    dead: bool = false,
    in_dtor: bool = false,
    /// True while a filter of the object runs. A call from the filter
    /// to the object has no filters.
    filtering: bool = false,
    id: u32,
};

const Link = struct { m: *Method, filter: bool = false };

const Call = struct {
    obj: *Object,
    chain: []const Link,
    at: usize,
    /// The words of the call and the count of words before the arguments.
    argv: []const Value,
    skip: usize,
    name: []const u8,
    /// The level of the proc frame of the method.
    level: u32 = 0,
    kind: enum { method, ctor, dtor } = .method,
    /// The record of the caller, for `self caller`.
    from: ?*Call = null,
};

pub const State = struct {
    next_id: u32 = 1,
    stack: std.ArrayList(*Call) = .empty,
    defs: std.ArrayList(Def) = .empty,
    object_class: *Object = undefined,
    class_class: *Object = undefined,
    all: std.ArrayList(*Object) = .empty,
};

const Def = struct {
    obj: *Object,
    on_object: bool,
    /// The namespace of the caller. A class name resolves there.
    from: []const u8 = "",
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn full(it: *Interp, o: *const Object) Error![]const u8 {
    return std.fmt.allocPrint(it.alloc(), "::{s}", .{o.name});
}

fn fullV(it: *Interp, o: *const Object) Error!Value {
    return .{ .str = try full(it, o) };
}

fn has(list: []const *Object, o: *const Object) bool {
    for (list) |x| if (x == o) return true;
    return false;
}

fn drop(list: *std.ArrayList(*Object), o: *const Object) void {
    for (list.items, 0..) |x, i| {
        if (x == o) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// ---- The state and the objects ----

fn state(it: *Interp) Error!*State {
    if (it.oo) |s| return @ptrCast(@alignCast(s));
    const a = it.alloc();
    const st = try a.create(State);
    st.* = .{};
    it.oo = st;
    // The two root classes name each other, so they start by hand.
    const obj = try a.create(Object);
    const cls = try a.create(Object);
    obj.* = .{ .name = "oo::object", .ns = "oo::Obj1", .class = cls, .id = 1 };
    cls.* = .{ .name = "oo::class", .ns = "oo::Obj2", .class = cls, .id = 2 };
    st.next_id = 3;
    obj.cls = try a.create(Class);
    obj.cls.?.* = .{};
    cls.cls = try a.create(Class);
    cls.cls.?.* = .{};
    try cls.cls.?.supers.append(a, obj);
    try obj.cls.?.subs.append(a, cls);
    try obj.cls.?.instances.append(a, cls);
    try cls.cls.?.instances.append(a, obj);
    st.object_class = obj;
    st.class_class = cls;
    try st.all.append(a, obj);
    try st.all.append(a, cls);
    for ([_]*Object{ obj, cls }) |o| {
        _ = try it.internNs(o.ns);
        try command(it, o.name, objCmd, o);
        try command(it, try std.fmt.allocPrint(a, "{s}::my", .{o.ns}), myCmd, o);
    }
    const om = &obj.cls.?.methods;
    try native(it, om, obj, "destroy", mDestroy, true);
    try native(it, om, obj, "eval", mEval, false);
    try native(it, om, obj, "unknown", mUnknown, false);
    try native(it, om, obj, "variable", mVariable, false);
    try native(it, om, obj, "varname", mVarname, false);
    try native(it, om, obj, "<cloned>", mCloned, false);
    const cm = &cls.cls.?.methods;
    try native(it, cm, cls, "create", mCreate, true);
    try native(it, cm, cls, "new", mNew, true);
    try native(it, cm, cls, "createWithNamespace", mCreateNs, false);
    const ctor = try a.create(Method);
    ctor.* = .{ .name = "<constructor>", .kind = .native, .native = mClassCtor, .owner = cls };
    cls.cls.?.ctor = ctor;
    _ = try it.internNs("oo::define");
    _ = try it.internNs("oo::objdefine");
    inline for (.{ "constructor", "deletemethod", "destructor", "export", "filter", "forward", "method", "mixin", "renamemethod", "self", "superclass", "unexport", "variable" }) |n| {
        try it.register("oo::define::" ++ n, defineCmd);
    }
    inline for (.{ "class", "deletemethod", "export", "filter", "forward", "method", "mixin", "renamemethod", "unexport", "variable" }) |n| {
        try it.register("oo::objdefine::" ++ n, defineCmd);
    }
    try it.register("oo::Link", cmdLink);
    try it.register("self", cmdSelf);
    try it.register("next", cmdNext);
    try it.register("nextto", cmdNextto);
    // A short form of a definition word goes to the unknown handler.
    try it.register("oo::UnknownDefinition", cmdUnknownDef);
    try it.ns_unknown.put(a, "oo::define", .{ .str = "::oo::UnknownDefinition" });
    try it.ns_unknown.put(a, "oo::objdefine", .{ .str = "::oo::UnknownDefinition" });
    _ = try it.internNs("oo::Helpers");
    try it.register("oo::Helpers::self", cmdSelf);
    try it.register("oo::Helpers::next", cmdNext);
    try it.register("oo::Helpers::nextto", cmdNextto);
    return st;
}

fn command(it: *Interp, key: []const u8, f: interp.NativeFn, o: *Object) Error!void {
    const c = try it.alloc().create(interp.Command);
    c.* = .{ .name = key, .impl = .{ .native = f }, .ctx = o };
    try it.commands.put(it.alloc(), key, c);
    it.epoch += 1;
}

fn native(it: *Interp, map: *Methods, owner: *Object, name: []const u8, f: Native, exported: bool) Error!void {
    const m = try it.alloc().create(Method);
    m.* = .{ .name = name, .kind = .native, .native = f, .exported = exported, .owner = owner };
    try map.put(it.alloc(), name, m);
}

/// The object of a command name, or null.
fn lookup(it: *Interp, word: []const u8) ?*Object {
    const c = it.findCommand(word) orelse return null;
    if (c.impl != .native or c.impl.native != objCmd) return null;
    const o: *Object = @ptrCast(@alignCast(c.ctx.?));
    return if (o.dead) null else o;
}

fn need(it: *Interp, v: Value) Error!*Object {
    const word = try it.str(v);
    return lookup(it, word) orelse it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP OBJECT {s}", .{word}), "{s} does not refer to an object", .{word});
}

fn needClass(it: *Interp, v: Value) Error!*Object {
    const word = try it.str(v);
    var found = lookup(it, word);
    if (found == null and !std.mem.startsWith(u8, word, "::")) {
        // Inside a definition, a name resolves in the namespace of
        // the caller of the definition.
        const st: *State = @ptrCast(@alignCast(it.oo.?));
        var i = st.defs.items.len;
        while (i > 0 and found == null) {
            i -= 1;
            const from = st.defs.items[i].from;
            found = lookup(it, try std.fmt.allocPrint(it.alloc(), "::{s}{s}{s}", .{ from, if (from.len > 0) "::" else "", word }));
        }
    }
    const o = found orelse return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CLASS {s}", .{word}), "class \"{s}\" does not exist", .{word});
    if (o.cls == null) return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP CLASS {s}", .{word}), "\"{s}\" is not a class", .{word});
    return o;
}

/// True when `c` is `top` or has it as an ancestor.
fn inherits(c: *const Object, top: *const Object) bool {
    if (c == top) return true;
    const cls = c.cls orelse return false;
    for (cls.supers.items) |s| if (inherits(s, top)) return true;
    for (cls.mixins.items) |s| if (inherits(s, top)) return true;
    return false;
}

fn isA(o: *const Object, c: *const Object) bool {
    if (inherits(o.class, c)) return true;
    for (o.mixins.items) |m| if (inherits(m, c)) return true;
    return false;
}

fn newObject(it: *Interp, st: *State, class: *Object, name_in: ?[]const u8, ns_in: ?[]const u8) Error!*Object {
    const a = it.alloc();
    const id = st.next_id;
    st.next_id += 1;
    const space = if (ns_in) |n| std.mem.trimStart(u8, n, ":") else try std.fmt.allocPrint(a, "oo::Obj{d}", .{id});
    if (ns_in != null and it.namespaces.contains(space)) return it.fail("can't create namespace \"{s}\": already exists", .{ns_in.?});
    const key = if (name_in) |n| try it.qualify(n) else space;
    if (name_in != null and it.commands.contains(key)) return it.failCode("TCL OO OVERWRITE_OBJECT", "can't create object \"{s}\": command already exists with that name", .{name_in.?});
    const o = try a.create(Object);
    o.* = .{ .name = key, .ns = try it.internNs(space), .class = class, .id = id };
    if (inherits(class, st.class_class)) {
        o.cls = try a.create(Class);
        o.cls.?.* = .{};
        try o.cls.?.supers.append(a, st.object_class);
        try st.object_class.cls.?.subs.append(a, o);
    }
    try class.cls.?.instances.append(a, o);
    try st.all.append(a, o);
    try command(it, key, objCmd, o);
    try command(it, try std.fmt.allocPrint(a, "{s}::my", .{o.ns}), myCmd, o);
    return o;
}

/// Ends an object: the destructors, the instances and subclasses of a
/// class, the namespace, and the command.
fn destroy(it: *Interp, st: *State, o: *Object, run_dtor: bool) Error!void {
    return destroyMode(it, st, o, run_dtor, false);
}

fn destroyMode(it: *Interp, st: *State, o: *Object, run_dtor: bool, explicit: bool) Error!void {
    if (o.dead or o.in_dtor) return;
    o.in_dtor = true;
    const a = it.alloc();
    var failure: ?Error = null;
    var fail_result: Value = Value.empty;
    var fail_info: std.ArrayList(u8) = .empty;
    var fail_code: Value = Value.empty;
    if (run_dtor) {
        var chain: std.ArrayList(Link) = .empty;
        try special(a, o, &chain, .dtor);
        if (chain.items.len > 0) {
            const words = try a.dupe(Value, &.{ try fullV(it, o), .{ .str = "destroy" } });
            var call: Call = .{ .obj = o, .chain = chain.items, .at = 0, .argv = words, .skip = 2, .name = "<destructor>", .kind = .dtor };
            const saved = it.result;
            _ = run(it, st, &call) catch |e| {
                if (e == error.OutOfMemory) return e;
                if (e == error.TclError and (it.step_limit == 0 or it.overLimit())) return e;
                if (explicit) {
                    failure = e;
                    fail_result = it.result;
                    fail_info = it.error_info;
                    fail_code = it.error_code;
                } else
                // An error of a destructor goes to the background handler.
                if (e == error.TclError and it.capabilities & @intFromEnum(interp.Capability.event) != 0) {
                    try it.finishError();
                    @import("event.zig").background(it, .{ .code = 1, .res = it.result, .error_info = it.last_info, .error_code = it.error_code }) catch {};
                }
            };
            if (failure == null) it.result = saved;
        }
    }
    o.dead = true;
    if (o.cls) |c| {
        while (c.instances.items.len > 0) {
            const x = c.instances.items[c.instances.items.len - 1];
            if (x == o or x.dead or x.in_dtor) {
                _ = c.instances.pop();
                continue;
            }
            try destroy(it, st, x, true);
        }
        while (c.subs.items.len > 0) {
            const x = c.subs.items[c.subs.items.len - 1];
            if (x.dead or x.in_dtor) {
                _ = c.subs.pop();
                continue;
            }
            try destroy(it, st, x, true);
        }
        for (c.supers.items) |s| if (s.cls) |sc| drop(&sc.subs, o);
        // The objects that mix the class in lose it.
        var k: usize = 0;
        while (k < st.all.items.len) {
            const x = st.all.items[k];
            if (x.cls) |xc| drop(&xc.mixins, o);
            if (has(x.mixins.items, o) and !x.dead and !x.in_dtor) {
                drop(&x.mixins, o);
                try destroy(it, st, x, true);
                k = 0;
                continue;
            }
            k += 1;
        }
    }
    // The drops below and the restarts of the callers each scan the
    // list of all objects.
    try cmds.chargeEntries(it, st.all.items.len);
    if (o.class.cls) |cc| drop(&cc.instances, o);
    drop(&st.all, o);
    // The commands can have new names after a `rename`.
    while (true) {
        try cmds.chargeEntries(it, it.commands.count());
        var hit: ?[]const u8 = null;
        var iter = it.commands.iterator();
        while (iter.next()) |e| {
            const c = e.value_ptr.*;
            if (c.impl == .native and (c.impl.native == objCmd or c.impl.native == myCmd) and c.ctx == @as(?*anyopaque, o)) hit = e.key_ptr.*;
        }
        if (hit) |k| _ = it.commands.remove(k) else break;
    }
    it.epoch += 1;
    const words = try a.dupe(Value, &.{ .{ .str = "namespace" }, .{ .str = "delete" }, .{ .str = try std.fmt.allocPrint(a, "::{s}", .{o.ns}) } });
    const saved = it.result;
    if (it.namespaces.contains(o.ns)) _ = it.callWords(words) catch |e| {
        if (e == error.OutOfMemory) return e;
    };
    it.result = saved;
    if (failure) |e| {
        it.result = fail_result;
        it.error_info = fail_info;
        it.error_code = fail_code;
        return e;
    }
}

/// Ends the objects of a namespace that goes away: an object with this
/// namespace, and each object with a command below it.
pub fn namespaceGone(it: *Interp, space: []const u8, prefix: []const u8) Error!void {
    const st: *State = @ptrCast(@alignCast(it.oo orelse return));
    var i: usize = 0;
    while (i < st.all.items.len) {
        const o = st.all.items[i];
        const inside = eql(o.ns, space) or std.mem.startsWith(u8, o.ns, prefix) or std.mem.startsWith(u8, o.name, prefix);
        if (inside and !o.dead and !o.in_dtor and o != st.object_class and o != st.class_class) {
            try destroy(it, st, o, true);
            i = 0;
            continue;
        }
        i += 1;
    }
}

/// Called when a command of an object goes away through `rename`.
pub fn commandGone(it: *Interp, c: *interp.Command) void {
    if (c.impl != .native or c.impl.native != objCmd) return;
    const st: *State = @ptrCast(@alignCast(it.oo orelse return));
    const o: *Object = @ptrCast(@alignCast(c.ctx.?));
    destroy(it, st, o, true) catch {};
}

// ---- The call chain ----

fn addLink(a: std.mem.Allocator, out: *std.ArrayList(Link), m: *Method, filter: bool) Error!void {
    if (!filter) {
        for (out.items, 0..) |l, i| {
            if (l.m == m and !l.filter) {
                _ = out.orderedRemove(i);
                break;
            }
        }
    }
    try out.append(a, .{ .m = m, .filter = filter });
}

/// Adds the methods of a class and its ancestors. `part` 0 adds the
/// mixins and the classes, 1 only the mixins of the classes, and 2
/// only the classes.
fn classLinks(a: std.mem.Allocator, c: *Object, name: []const u8, out: *std.ArrayList(Link), filter: bool, depth: u32, part: u8) Error!void {
    const cls = c.cls orelse return;
    if (depth > 64) return;
    if (part != 2) for (cls.mixins.items) |m| try classLinks(a, m, name, out, filter, depth + 1, 0);
    if (part != 1) if (cls.methods.get(name)) |m| {
        if (m.kind != .none) try addLink(a, out, m, filter);
    };
    for (cls.supers.items) |s| try classLinks(a, s, name, out, filter, depth + 1, part);
}

fn methodLinks(a: std.mem.Allocator, o: *Object, name: []const u8, out: *std.ArrayList(Link), filter: bool) Error!void {
    for (o.mixins.items) |m| try classLinks(a, m, name, out, filter, 0, 0);
    try classLinks(a, o.class, name, out, filter, 0, 1);
    if (o.methods.get(name)) |m| {
        if (m.kind != .none) try addLink(a, out, m, filter);
    }
    try classLinks(a, o.class, name, out, filter, 0, 2);
}

fn classFilters(a: std.mem.Allocator, c: *Object, out: *std.ArrayList([]const u8), depth: u32) Error!void {
    const cls = c.cls orelse return;
    if (depth > 64) return;
    for (cls.mixins.items) |m| try classFilters(a, m, out, depth + 1);
    for (cls.filters.items) |f| try out.append(a, f);
    for (cls.supers.items) |s| try classFilters(a, s, out, depth + 1);
}

/// The chain of a method call: the filters, then the methods.
fn chainOf(a: std.mem.Allocator, o: *Object, name: []const u8, out: *std.ArrayList(Link)) Error!void {
    var filters: std.ArrayList([]const u8) = .empty;
    if (!o.filtering) for (o.mixins.items) |m| try classFilters(a, m, &filters, 0);
    if (!o.filtering) {
        for (o.filters.items) |f| try filters.append(a, f);
        try classFilters(a, o.class, &filters, 0);
    }
    var seen: std.ArrayList([]const u8) = .empty;
    for (filters.items) |f| {
        var dup = false;
        for (seen.items) |s| {
            if (eql(s, f)) dup = true;
        }
        if (dup) continue;
        try seen.append(a, f);
        try methodLinks(a, o, f, out, true);
    }
    try methodLinks(a, o, name, out, false);
}

fn specialOf(c: *Class, kind: @FieldType(Call, "kind")) ?*Method {
    return if (kind == .ctor) c.ctor else c.dtor;
}

fn specialClass(a: std.mem.Allocator, c: *Object, out: *std.ArrayList(Link), kind: @FieldType(Call, "kind"), depth: u32) Error!void {
    const cls = c.cls orelse return;
    if (depth > 64) return;
    for (cls.mixins.items) |m| try specialClass(a, m, out, kind, depth + 1);
    if (specialOf(cls, kind)) |m| try addLink(a, out, m, false);
    for (cls.supers.items) |s| try specialClass(a, s, out, kind, depth + 1);
}

/// The chain of the constructors or of the destructors of an object.
fn special(a: std.mem.Allocator, o: *Object, out: *std.ArrayList(Link), kind: @FieldType(Call, "kind")) Error!void {
    for (o.mixins.items) |m| try specialClass(a, m, out, kind, 0);
    try specialClass(a, o.class, out, kind, 0);
}

fn exportedClass(c: *Object, name: []const u8, depth: u32) ?bool {
    const cls = c.cls orelse return null;
    if (depth > 64) return null;
    for (cls.mixins.items) |m| if (exportedClass(m, name, depth + 1)) |b| return b;
    if (cls.methods.get(name)) |m| if (m.exported) |b| return b;
    for (cls.supers.items) |s| if (exportedClass(s, name, depth + 1)) |b| return b;
    return null;
}

fn isPublic(o: *Object, name: []const u8) bool {
    if (o.methods.get(name)) |m| if (m.exported) |b| return b;
    for (o.mixins.items) |m| if (exportedClass(m, name, 0)) |b| return b;
    if (exportedClass(o.class, name, 0)) |b| return b;
    return name.len > 0 and std.ascii.isLower(name[0]);
}

fn classNames(a: std.mem.Allocator, c: *Object, out: *std.StringArrayHashMapUnmanaged(void), depth: u32) Error!void {
    const cls = c.cls orelse return;
    if (depth > 64) return;
    for (cls.mixins.items) |m| try classNames(a, m, out, depth + 1);
    for (cls.methods.keys(), cls.methods.values()) |k, m| {
        if (m.kind != .none) try out.put(a, k, {});
    }
    for (cls.supers.items) |s| try classNames(a, s, out, depth + 1);
}

/// The method names of an object, sorted. `private` adds the names
/// that are not exported.
fn methodNames(it: *Interp, o: *Object, all: bool, private: bool) Error![]const []const u8 {
    const a = it.alloc();
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (o.methods.keys(), o.methods.values()) |k, m| {
        if (m.kind != .none) try set.put(a, k, {});
    }
    if (all) {
        for (o.mixins.items) |m| try classNames(a, m, &set, 0);
        try classNames(a, o.class, &set, 0);
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (set.keys()) |k| {
        if (private or isPublic(o, k)) try out.append(a, k);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return out.items;
}

// ---- Calls ----

fn definerVars(m: *const Method) struct { []const []const u8, u32 } {
    const o = m.owner;
    // A method of a class uses the variables of the class. A method of
    // one object uses the variables of the object.
    if (o.cls) |c| {
        if (c.methods.get(m.name) == m or c.ctor == m or c.dtor == m) return .{ c.vars.items, c.var_stamp };
    }
    return .{ o.vars.items, o.var_stamp };
}

fn procOf(it: *Interp, m: *Method) Error!*interp.Proc {
    const vars, const stamp = definerVars(m);
    if (m.proc) |p| if (m.stamp == stamp) return p;
    const a = it.alloc();
    var body = m.body;
    if (vars.len > 0) {
        // The declared variables link at the start of the body, on the
        // first line, so the line numbers of the body stay.
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, "::oo::Link");
        for (vars) |v| {
            try text.append(a, ' ');
            try value.appendElement(a, &text, v, true);
        }
        try text.append(a, ';');
        try text.appendSlice(a, try it.str(m.body));
        body = .{ .str = text.items };
    }
    const p = try cmds.makeProc(it, m.params, body);
    m.proc = p;
    m.stamp = stamp;
    return p;
}

fn usage(it: *Interp, call: *const Call, p: *const interp.Proc) Error {
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "wrong # args: should be \"");
    for (call.argv[0..call.skip], 0..) |w, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, try it.str(w));
    }
    for (p.params) |prm| {
        if (prm.default != null) try out.print(a, " ?{s}?", .{prm.name}) else try out.print(a, " {s}", .{prm.name});
    }
    if (p.has_args) try out.appendSlice(a, " ?arg ...?");
    try out.append(a, '"');
    it.result = .{ .str = out.items };
    it.error_code = .{ .str = "TCL WRONGARGS" };
    return error.TclError;
}

/// Runs the link `call.at` of a chain.
fn run(it: *Interp, st: *State, call: *Call) Error!Value {
    const a = it.alloc();
    const m = call.chain[call.at].m;
    const args = call.argv[call.skip..];
    call.from = if (st.stack.items.len > 0) st.stack.items[st.stack.items.len - 1] else null;
    try st.stack.append(a, call);
    defer _ = st.stack.pop();
    const was_filtering = call.obj.filtering;
    if (call.chain[call.at].filter) {
        call.obj.filtering = true;
    } else if (call.at > 0 and call.chain[call.at - 1].filter) {
        // The method after the last filter runs with filters again.
        call.obj.filtering = false;
    }
    defer call.obj.filtering = was_filtering;
    switch (m.kind) {
        .none => return Value.empty,
        // A native method or a forward keeps values in native frames, so
        // a proc body that it runs is not clean (see beginProcBody).
        .native => {
            it.gc_direct = 0;
            return m.native.?(it, st, call, args);
        },
        .forward => {
            it.gc_direct = 0;
            const words = try a.alloc(Value, m.forward.len + args.len);
            @memcpy(words[0..m.forward.len], m.forward);
            @memcpy(words[m.forward.len..], args);
            // The target of a forward resolves in the namespace of the object.
            const saved = it.ns;
            it.ns = call.obj.ns;
            defer it.ns = saved;
            return it.callWords(words);
        },
        .proc => {
            const p = try procOf(it, m);
            var required: usize = 0;
            for (p.params) |prm| {
                if (prm.default == null) required += 1;
            }
            // A parameter with no default after one with a default
            // needs a value too.
            var last_required: usize = 0;
            for (p.params, 0..) |prm, i| {
                if (prm.default == null) last_required = i + 1;
            }
            if (args.len < last_required or (args.len > p.params.len and !p.has_args)) return usage(it, call, p);
            p.ns = call.obj.ns;
            call.level = it.frame.level + 1;
            // `st.stack` names this record, and its fields stay in use.
            const mark = try it.beginProcBody(call.argv, &.{ @intFromPtr(call.obj), @intFromPtr(call.chain.ptr), @intFromPtr(call.name.ptr), @intFromPtr(m), @intFromPtr(p) });
            defer it.endProcBody(mark);
            return it.callMethod(p, call.argv, call.skip) catch |e| {
                if (e == error.TclError and it.in_error) rewriteTrace(it, call, m) catch {};
                return e;
            };
        },
    }
}

/// Changes the last `(procedure ...)` line of the error trace to the
/// form of a method.
fn rewriteTrace(it: *Interp, call: *const Call, m: *const Method) Error!void {
    const text = it.error_info.items;
    const mark = "\n    (procedure \"";
    const at = std.mem.lastIndexOf(u8, text, mark) orelse return;
    const rest = text[at + mark.len ..];
    const q = std.mem.indexOf(u8, rest, "\" line ") orelse return;
    if (std.mem.indexOfScalar(u8, rest[q..], '\n') != null) return;
    const line = rest[q + 7 ..];
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text[0..at]);
    const owner = try full(it, m.owner);
    const of_class = if (m.owner.cls) |c| (c.methods.get(m.name) == m or c.ctor == m or c.dtor == m) else false;
    switch (call.kind) {
        .ctor => try out.print(a, "\n    (class \"{s}\" constructor line {s}", .{ owner, line }),
        .dtor => try out.print(a, "\n    (class \"{s}\" destructor line {s}", .{ owner, line }),
        .method => if (of_class) {
            try out.print(a, "\n    (class \"{s}\" method \"{s}\" line {s}", .{ owner, m.name, line });
        } else try out.print(a, "\n    (object \"{s}\" method \"{s}\" line {s}", .{ owner, m.name, line }),
    }
    it.error_info = out;
}

/// Calls a method of an object. `argv[skip - 1]` is the method name.
fn invoke(it: *Interp, st: *State, o: *Object, argv: []const Value, skip: usize, public_only: bool) Error!Value {
    const a = it.alloc();
    const name = try it.str(argv[skip - 1]);
    var chain: std.ArrayList(Link) = .empty;
    const visible = !public_only or isPublic(o, name);
    if (visible) try chainOf(a, o, name, &chain);
    var real = false;
    for (chain.items) |l| {
        if (!l.filter) real = true;
    }
    if (!real) {
        // The `unknown` method gets the name and the arguments.
        chain = .empty;
        try chainOf(a, o, "unknown", &chain);
        var call: Call = .{ .obj = o, .chain = chain.items, .at = 0, .argv = argv, .skip = skip - 1, .name = "unknown" };
        if (chain.items.len == 0) return mUnknown(it, st, &call, argv[skip - 1 ..]);
        return run(it, st, &call);
    }
    var call: Call = .{ .obj = o, .chain = chain.items, .at = 0, .argv = argv, .skip = skip, .name = name };
    return run(it, st, &call);
}

pub fn objCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const o: *Object = @ptrCast(@alignCast(self.ctx.?));
    if (argv.len < 2) {
        // A call with no method name goes to a scripted `unknown`.
        var chain: std.ArrayList(Link) = .empty;
        try chainOf(it.alloc(), o, "unknown", &chain);
        if (chain.items.len == 0 or chain.items[0].m.kind == .native) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} method ?arg ...?\"", .{try it.str(argv[0])});
        var call: Call = .{ .obj = o, .chain = chain.items, .at = 0, .argv = argv, .skip = 1, .name = "unknown" };
        return run(it, st, &call);
    }
    return invoke(it, st, o, argv, 2, true);
}

fn myCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    const self = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    const o: *Object = @ptrCast(@alignCast(self.ctx.?));
    if (argv.len < 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} method ?arg ...?\"", .{try it.str(argv[0])});
    return invoke(it, st, o, argv, 2, false);
}

/// The record of the method that runs in the current frame.
fn current(it: *Interp, st: *State) ?*Call {
    var i = st.stack.items.len;
    while (i > 0) {
        i -= 1;
        const c = st.stack.items[i];
        if (c.level == it.frame.level and c.chain[c.at].m.kind == .proc) return c;
        if (c.level != 0 and c.level < it.frame.level) return null;
    }
    return null;
}

fn cmdNext(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    const c = current(it, st) orelse return it.failCode("TCL OO CONTEXT_REQUIRED", "next may only be called from inside a method", .{});
    return nextAt(it, st, c, c.at + 1, argv[1..]);
}

fn nextAt(it: *Interp, st: *State, c: *Call, at: usize, args: []const Value) Error!Value {
    if (at >= c.chain.len) {
        if (c.kind != .method) return Value.empty;
        return it.failCode("TCL OO NOTHING_NEXT", "no next {s} implementation", .{"method"});
    }
    const a = it.alloc();
    const words = try a.alloc(Value, c.skip + args.len);
    @memcpy(words[0..c.skip], c.argv[0..c.skip]);
    @memcpy(words[c.skip..], args);
    var call: Call = .{ .obj = c.obj, .chain = c.chain, .at = at, .argv = words, .skip = c.skip, .name = c.name, .kind = c.kind };
    // The next method runs at the level of this method, so `uplevel 1`
    // and `upvar 1` reach the caller of the first method.
    const frame = it.frame;
    const space = it.ns;
    if (frame.parent) |p| {
        it.frame = p;
        it.ns = p.space;
    }
    defer {
        it.frame = frame;
        it.ns = space;
    }
    return run(it, st, &call);
}

fn cmdNextto(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    const c = current(it, st) orelse return it.failCode("TCL OO CONTEXT_REQUIRED", "nextto may only be called from inside a method", .{});
    if (argv.len < 2) return it.wrongArgs("nextto class ?arg...?");
    const cls = try needClass(it, argv[1]);
    var i = c.at + 1;
    while (i < c.chain.len) : (i += 1) {
        if (c.chain[i].m.owner == cls and !c.chain[i].filter) return nextAt(it, st, c, i, argv[2..]);
    }
    i = 0;
    while (i <= c.at and i < c.chain.len) : (i += 1) {
        if (c.chain[i].m.owner == cls) return it.failCode("TCL OO CLASS_NOT_REACHABLE", "method implementation by \"{s}\" not reachable from here", .{try it.str(argv[1])});
    }
    return it.failCode("TCL OO CLASS_NOT_THERE", "method has no non-filter implementation by \"{s}\"", .{try it.str(argv[1])});
}

fn cmdSelf(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    const c = current(it, st) orelse return it.failCode("TCL OO CONTEXT_REQUIRED", "self may only be called from inside a method", .{});
    const a = it.alloc();
    if (argv.len > 2) return it.wrongArgs("self subcommand");
    const sub = if (argv.len == 2) try it.str(argv[1]) else "object";
    const subs = [_][]const u8{ "call", "caller", "class", "filter", "method", "namespace", "next", "object", "target" };
    var word: ?[]const u8 = null;
    for (subs) |s| {
        if (eql(s, sub)) word = s;
    }
    if (word == null) {
        for (subs) |s| {
            if (sub.len > 0 and std.mem.startsWith(u8, s, sub)) {
                if (word != null) return it.failCode("TCL LOOKUP INDEX subcommand", "ambiguous subcommand \"{s}\": must be call, caller, class, filter, method, namespace, next, object, or target", .{sub});
                word = s;
            }
        }
    }
    const w = word orelse return it.failCode("TCL LOOKUP INDEX subcommand", "bad subcommand \"{s}\": must be call, caller, class, filter, method, namespace, next, object, or target", .{sub});
    const m = c.chain[c.at].m;
    if (eql(w, "object")) return fullV(it, c.obj);
    if (eql(w, "namespace")) return .{ .str = try std.fmt.allocPrint(a, "::{s}", .{c.obj.ns}) };
    if (eql(w, "method")) return .{ .str = if (c.kind == .ctor) "<constructor>" else if (c.kind == .dtor) "<destructor>" else m.name };
    if (eql(w, "class")) {
        const of_class = if (m.owner.cls) |cl| (cl.methods.get(m.name) == m or cl.ctor == m or cl.dtor == m) else false;
        if (!of_class) return it.failCode("TCL OO UNMATCHED_CONTEXT", "method not defined by a class", .{});
        return fullV(it, m.owner);
    }
    if (eql(w, "next")) {
        if (c.at + 1 >= c.chain.len) return Value.empty;
        const n = c.chain[c.at + 1].m;
        return value.newList(a, &.{ try fullV(it, n.owner), .{ .str = if (c.kind == .ctor) "<constructor>" else if (c.kind == .dtor) "<destructor>" else n.name } });
    }
    if (eql(w, "filter")) {
        if (!c.chain[c.at].filter) return it.failCode("TCL OO UNMATCHED_CONTEXT", "not inside a filtering context", .{});
        const of_class = if (m.owner.cls) |cl| cl.methods.get(m.name) == m else false;
        return value.newList(a, &.{ try fullV(it, m.owner), .{ .str = if (of_class) "class" else "object" }, .{ .str = m.name } });
    }
    if (eql(w, "target")) {
        if (!c.chain[c.at].filter) return it.failCode("TCL OO UNMATCHED_CONTEXT", "not inside a filtering context", .{});
        var i = c.at;
        while (i < c.chain.len and c.chain[i].filter) i += 1;
        if (i >= c.chain.len) return Value.empty;
        return value.newList(a, &.{ try fullV(it, c.chain[i].m.owner), .{ .str = c.chain[i].m.name } });
    }
    if (eql(w, "caller")) {
        const from = c.from orelse return it.failCode("TCL OO CONTEXT_REQUIRED", "caller is not an object", .{});
        const fm = from.chain[from.at].m;
        return value.newList(a, &.{ try fullV(it, fm.owner), try fullV(it, from.obj), .{ .str = if (from.kind == .ctor) "<constructor>" else if (from.kind == .dtor) "<destructor>" else fm.name } });
    }
    // call
    return value.newList(a, &.{ try callList(it, c.obj, c.chain, c.name, eql(c.name, "unknown") and c.skip < 2), .{ .int = @intCast(c.at) } });
}

fn callList(it: *Interp, o: *Object, chain: []const Link, name: []const u8, unknown: bool) Error!Value {
    const a = it.alloc();
    var out: std.ArrayList(Value) = .empty;
    for (chain) |l| {
        const m = l.m;
        const of_class = if (m.owner.cls) |cl| cl.methods.get(m.name) == m else false;
        const kind: []const u8 = if (l.filter) "filter" else if (unknown) "unknown" else "method";
        _ = name;
        const where: Value = if (of_class) try fullV(it, m.owner) else .{ .str = "object" };
        const impl: []const u8 = switch (m.kind) {
            .proc => "method",
            .forward => "forward",
            else => "core method: \"" ++ "",
        };
        var impl_v: Value = .{ .str = impl };
        if (m.kind == .native) impl_v = .{ .str = try std.fmt.allocPrint(a, "core method: \"{s}\"", .{m.name}) };
        _ = o;
        try out.append(a, try value.newList(a, &.{ .{ .str = kind }, .{ .str = m.name }, where, impl_v }));
    }
    return value.wrapList(a, out.items);
}

/// `::oo::Link name ...`: links the declared variables of a method to
/// the variables of the object.
fn cmdLink(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const a = it.alloc();
    for (argv[1..]) |v| {
        const name = try it.str(v);
        const target = try it.globalVar(try std.fmt.allocPrint(a, "{s}::{s}", .{ it.ns, name }));
        it.linkVar(name, target) catch |e| {
            if (e == error.OutOfMemory) return e;
        };
    }
    return Value.empty;
}

// ---- The methods of oo::object and oo::class ----

fn mDestroy(it: *Interp, st: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len != 0) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} destroy\"", .{try it.str(call.argv[0])});
    try destroyMode(it, st, call.obj, true, true);
    return Value.empty;
}

fn mEval(it: *Interp, _: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len == 0) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} eval arg ?arg ...?\"", .{try it.str(call.argv[0])});
    const a = it.alloc();
    const words = try a.alloc(Value, args.len + 3);
    words[0] = .{ .str = "namespace" };
    words[1] = .{ .str = "eval" };
    words[2] = .{ .str = try std.fmt.allocPrint(a, "::{s}", .{call.obj.ns}) };
    @memcpy(words[3..], args);
    return it.callWords(words) catch |e| {
        if (e == error.TclError and it.in_error) retitle(it, "in \"{s} eval\" script", .{try it.str(call.argv[0])});
        return e;
    };
}

fn mUnknown(it: *Interp, _: *State, call: *Call, args: []const Value) Error!Value {
    const a = it.alloc();
    const o = call.obj;
    if (args.len == 0) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} method ?arg ...?\"", .{try it.str(call.argv[0])});
    const name = try it.str(args[0]);
    const public = !eql(tail(try it.str(call.argv[0])), "my");
    const names = try methodNames(it, o, true, !public);
    const code = try std.fmt.allocPrint(a, "TCL LOOKUP METHOD {s}", .{name});
    if (names.len == 0) return it.failCode(code, "object \"{s}\" has no visible methods", .{try full(it, o)});
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "unknown method \"{s}\": must be ", .{name});
    for (names, 0..) |n, i| {
        if (i > 0 and i < names.len - 1) try out.appendSlice(a, ", ");
        if (i > 0 and i == names.len - 1) try out.appendSlice(a, " or ");
        try out.appendSlice(a, n);
    }
    it.result = .{ .str = out.items };
    it.error_code = .{ .str = code };
    return error.TclError;
}

fn tail(name: []const u8) []const u8 {
    return ns_mod.tail(name);
}

fn mVariable(it: *Interp, _: *State, call: *Call, args: []const Value) Error!Value {
    const a = it.alloc();
    for (args) |v| {
        const name = try it.str(v);
        if (std.mem.indexOf(u8, name, "::") != null) return it.failCode("TCL LOOKUP UNKNOWN_VAR", "variable name \"{s}\" illegal: must not contain namespace separator", .{name});
        const target = try it.globalVar(try std.fmt.allocPrint(a, "{s}::{s}", .{ call.obj.ns, name }));
        try it.linkVar(name, target);
    }
    return Value.empty;
}

fn mVarname(it: *Interp, _: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len != 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} varname varName\"", .{try it.str(call.argv[0])});
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "::{s}::{s}", .{ call.obj.ns, try it.str(args[0]) }) };
}

/// `<cloned> source`: copies the variables and the procs of the
/// source object into the new object.
fn mCloned(it: *Interp, _: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len != 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} <cloned> originObject\"", .{try it.str(call.argv[0])});
    const src = try need(it, args[0]);
    const script = try std.fmt.allocPrint(it.alloc(),
        \\foreach v {s} {{
        \\    set t ::{s}::$v
        \\    set v ::{s}::$v
        \\    if {{[array exists $v]}} {{ array set $t [array get $v] }} elseif {{[info exists $v]}} {{ set $t [set $v] }}
        \\}}
        \\foreach p [info procs ::{s}::*] {{
        \\    set a {{}}
        \\    foreach x [info args $p] {{ if {{[info default $p $x d]}} {{ lappend a [list $x $d] }} else {{ lappend a [list $x] }} }}
        \\    proc ::{s}::[namespace tail $p] $a [info body $p]
        \\}}
    , .{ try it.str(try value.newList(it.alloc(), &.{try value.newList(it.alloc(), try nsVars(it, src.ns))})), call.obj.ns, src.ns, src.ns, call.obj.ns });
    _ = try it.eval(script);
    return Value.empty;
}

/// The names of the variables of a namespace that have a value.
fn nsVars(it: *Interp, space: []const u8) Error![]const Value {
    const a = it.alloc();
    const prefix = try std.fmt.allocPrint(a, "{s}::", .{space});
    var out: std.ArrayList(Value) = .empty;
    try cmds.chargeEntries(it, it.global.vars.items.len);
    for (it.global.vars.items) |e| {
        if (!std.mem.startsWith(u8, e.name, prefix)) continue;
        const t = e.name[prefix.len..];
        if (std.mem.indexOf(u8, t, "::") != null) continue;
        if (e.cell.target().v == .undef) continue;
        try out.append(a, .{ .str = t });
    }
    return out.items;
}

fn construct(it: *Interp, st: *State, class: *Object, name: ?[]const u8, space: ?[]const u8, argv: []const Value, skip: usize) Error!Value {
    const a = it.alloc();
    if (class.cls == null) return it.fail("\"{s}\" is not a class", .{try full(it, class)});
    const o = try newObject(it, st, class, name, space);
    var chain: std.ArrayList(Link) = .empty;
    try special(a, o, &chain, .ctor);
    if (chain.items.len > 0) {
        var call: Call = .{ .obj = o, .chain = chain.items, .at = 0, .argv = argv, .skip = skip, .name = "<constructor>", .kind = .ctor };
        _ = run(it, st, &call) catch |e| {
            if (e == error.OutOfMemory) return e;
            const res = it.result;
            const code = it.error_code;
            const info = it.error_info;
            const in_error = it.in_error;
            destroy(it, st, o, true) catch {};
            it.result = res;
            it.error_code = code;
            it.error_info = info;
            it.in_error = in_error;
            return e;
        };
    }
    if (o.dead) return it.failCode("TCL OO STILLBORN", "object deleted in constructor", .{});
    return fullV(it, o);
}

fn mNew(it: *Interp, st: *State, call: *Call, _: []const Value) Error!Value {
    return construct(it, st, call.obj, null, null, call.argv, call.skip);
}

fn mCreate(it: *Interp, st: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len < 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} create objectName ?arg ...?\"", .{try it.str(call.argv[0])});
    const name = try it.str(args[0]);
    if (name.len == 0) return it.failCode("TCL OO EMPTY_NAME", "object name must not be empty", .{});
    return construct(it, st, call.obj, name, null, call.argv, call.skip + 1);
}

fn mCreateNs(it: *Interp, st: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len < 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} createWithNamespace objectName namespaceName ?arg ...?\"", .{try it.str(call.argv[0])});
    const name = try it.str(args[0]);
    const space = try it.str(args[1]);
    if (name.len == 0) return it.failCode("TCL OO EMPTY_NAME", "object name must not be empty", .{});
    if (space.len == 0) return it.failCode("TCL OO EMPTY_NAME", "namespace name must not be empty", .{});
    return construct(it, st, call.obj, name, space, call.argv, call.skip + 2);
}

/// The constructor of `oo::class`: runs a definition script.
fn mClassCtor(it: *Interp, st: *State, call: *Call, args: []const Value) Error!Value {
    if (args.len > 1) {
        const a = it.alloc();
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "wrong # args: should be \"");
        for (call.argv[0..call.skip], 0..) |w, i| {
            if (i > 0) try out.append(a, ' ');
            try out.appendSlice(a, try it.str(w));
        }
        try out.appendSlice(a, " ?definitionScript?\"");
        it.result = .{ .str = out.items };
        it.error_code = .{ .str = "TCL WRONGARGS" };
        return error.TclError;
    }
    if (args.len == 1) _ = try defineScript(it, st, call.obj, false, args[0]);
    return Value.empty;
}

// ---- Definitions ----

/// Changes the last `(in namespace eval ...` line of the error trace.
fn retitle(it: *Interp, comptime fmt: []const u8, args: anytype) void {
    const text = it.error_info.items;
    const mark = "\n    (in namespace eval \"";
    const at = std.mem.lastIndexOf(u8, text, mark) orelse return;
    const rest = text[at..];
    const q = std.mem.indexOf(u8, rest, " script line ") orelse return;
    if (std.mem.indexOfScalar(u8, rest[1..], '\n') != null) return;
    const line = rest[q + 13 ..];
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(it.alloc(), text[0..at]) catch return;
    out.appendSlice(it.alloc(), "\n    (") catch return;
    out.print(it.alloc(), fmt, args) catch return;
    out.print(it.alloc(), " line {s}", .{line}) catch return;
    it.error_info = out;
}

fn defineScript(it: *Interp, st: *State, o: *Object, on_object: bool, script: Value) Error!Value {
    const a = it.alloc();
    const from = if (std.mem.startsWith(u8, it.ns, "oo::define") or std.mem.startsWith(u8, it.ns, "oo::objdefine") or std.mem.startsWith(u8, it.ns, "oo::Obj")) ns_mod.qualifiers(o.name) else it.ns;
    try st.defs.append(a, .{ .obj = o, .on_object = on_object, .from = from });
    defer _ = st.defs.pop();
    const space: []const u8 = if (on_object) "::oo::objdefine" else "::oo::define";
    const words = try a.dupe(Value, &.{ .{ .str = "namespace" }, .{ .str = "eval" }, .{ .str = space }, script });
    return it.callWords(words) catch |e| {
        if (e == error.TclError and it.in_error) retitle(it, "in definition script for {s} \"{s}\"", .{ if (on_object) "object" else "class", try full(it, o) });
        return e;
    };
}

fn cmdDefine(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    const on_object = eql(tail(try it.str(argv[0])), "objdefine");
    if (argv.len < 3) {
        if (on_object) return it.wrongArgs("oo::objdefine objectName arg ?arg ...?");
        return it.wrongArgs("oo::define className arg ?arg ...?");
    }
    const o = try need(it, argv[1]);
    if (!on_object and o.cls == null) return it.failCode("TCL OO MONKEY_BUSINESS", "attempt to misuse API", .{});
    if (argv.len == 3) {
        return defineScript(it, st, o, on_object, argv[2]);
    }
    try st.defs.append(it.alloc(), .{ .obj = o, .on_object = on_object, .from = it.ns });
    defer _ = st.defs.pop();
    // A word that is no definition command runs as a command of the
    // definition namespace.
    var known = false;
    for (if (on_object) &objdefine_subs else &define_subs) |n| {
        const w = try it.str(argv[2]);
        if (w.len > 0 and std.mem.startsWith(u8, n, w)) known = true;
    }
    if (!known) {
        const a = it.alloc();
        const run_words = try a.dupe(Value, &.{ .{ .str = "namespace" }, .{ .str = "eval" }, .{ .str = if (on_object) "::oo::objdefine" else "::oo::define" }, try value.newList(a, argv[2..]) });
        return it.callWords(run_words);
    }
    // The usage text of an error starts with the words of this call.
    const words = try it.alloc().dupe(Value, argv[2..]);
    words[0] = .{ .str = try std.fmt.allocPrint(it.alloc(), "{s} {s} {s}", .{ try it.str(argv[0]), try it.str(argv[1]), try it.str(argv[2]) }) };
    return defineOne(it, st, try it.str(argv[2]), words);
}

fn defineCmd(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    if (st.defs.items.len == 0) return it.failCode("TCL OO MONKEY_BUSINESS", "this command may only be called from within the context of an ::oo::define or ::oo::objdefine command", .{});
    const word = try it.str(argv[0]);
    const on_object = st.defs.items[st.defs.items.len - 1].on_object;
    if (std.mem.indexOf(u8, word, if (on_object) "oo::define::" else "oo::objdefine::") != null) return it.failCode("TCL OO MONKEY_BUSINESS", "attempt to misuse API", .{});
    return defineOne(it, st, tail(word), argv);
}

fn cmdUnknownDef(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    if (argv.len < 2) return it.wrongArgs("oo::UnknownDefinition what ?arg ...?");
    const word = try it.str(argv[1]);
    if (st.defs.items.len == 0) return it.failCode("TCL LOOKUP COMMAND", "invalid command name \"{s}\"", .{word});
    return defineOne(it, st, word, argv[1..]);
}

const define_subs = [_][]const u8{ "constructor", "deletemethod", "destructor", "export", "filter", "forward", "method", "mixin", "renamemethod", "self", "superclass", "unexport", "variable" };
const objdefine_subs = [_][]const u8{ "class", "deletemethod", "export", "filter", "forward", "method", "mixin", "renamemethod", "unexport", "variable" };

/// The slot operation of a word: -append, -clear, or -set.
fn slotOp(word: []const u8) ?u8 {
    if (eql(word, "-append")) return 'a';
    if (eql(word, "-clear")) return 'c';
    if (eql(word, "-set")) return 's';
    return null;
}

fn defineOne(it: *Interp, st: *State, sub_in: []const u8, argv: []const Value) Error!Value {
    const a = it.alloc();
    const def = st.defs.items[st.defs.items.len - 1];
    const o = def.obj;
    const table: []const []const u8 = if (def.on_object) &objdefine_subs else &define_subs;
    var sub: ?[]const u8 = null;
    for (table) |s| {
        if (eql(s, sub_in)) sub = s;
    }
    if (sub == null) {
        var hits: usize = 0;
        for (table) |s| {
            if (sub_in.len > 0 and std.mem.startsWith(u8, s, sub_in)) {
                sub = s;
                hits += 1;
            }
        }
        if (hits != 1) return it.failCode("TCL LOOKUP COMMAND", "invalid command name \"{s}\"", .{sub_in});
    }
    const s = sub.?;
    const args = argv[1..];
    if (!def.on_object and o.cls == null) return it.failCode("TCL OO MONKEY_BUSINESS", "attempt to misuse API", .{});
    const methods: *Methods = if (def.on_object) &o.methods else &o.cls.?.methods;
    if (eql(s, "method")) {
        if (args.len != 3) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} name args body\"", .{try it.str(argv[0])});
        const name = try it.str(args[0]);
        // The parameter list is checked now.
        _ = try cmds.makeProc(it, args[1], args[2]);
        const m = try a.create(Method);
        m.* = .{ .name = try a.dupe(u8, name), .kind = .proc, .params = args[1], .body = args[2], .owner = o };
        try methods.put(a, m.name, m);
        return Value.empty;
    }
    if (eql(s, "forward")) {
        if (args.len < 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} name cmdName ?arg ...?\"", .{try it.str(argv[0])});
        const name = try it.str(args[0]);
        const m = try a.create(Method);
        m.* = .{ .name = try a.dupe(u8, name), .kind = .forward, .forward = try a.dupe(Value, args[1..]), .owner = o };
        try methods.put(a, m.name, m);
        return Value.empty;
    }
    if (eql(s, "constructor") or eql(s, "destructor")) {
        const is_ctor = eql(s, "constructor");
        if (is_ctor and args.len != 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} arguments body\"", .{try it.str(argv[0])});
        if (!is_ctor and args.len != 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} body\"", .{try it.str(argv[0])});
        const body = args[args.len - 1];
        const slot = if (is_ctor) &o.cls.?.ctor else &o.cls.?.dtor;
        if ((try it.str(body)).len == 0) {
            slot.* = null;
            return Value.empty;
        }
        const params: Value = if (is_ctor) args[0] else Value.empty;
        _ = try cmds.makeProc(it, params, body);
        const m = try a.create(Method);
        m.* = .{ .name = if (is_ctor) "<constructor>" else "<destructor>", .kind = .proc, .params = params, .body = body, .owner = o };
        slot.* = m;
        return Value.empty;
    }
    if (eql(s, "export") or eql(s, "unexport")) {
        for (args) |v| {
            const name = try it.str(v);
            if (methods.get(name)) |m| {
                m.exported = eql(s, "export");
            } else {
                const m = try a.create(Method);
                m.* = .{ .name = try a.dupe(u8, name), .owner = o, .exported = eql(s, "export") };
                try methods.put(a, m.name, m);
            }
        }
        return Value.empty;
    }
    if (eql(s, "deletemethod")) {
        if (args.len < 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} name ?name ...?\"", .{try it.str(argv[0])});
        for (args) |v| {
            const name = try it.str(v);
            const m = methods.get(name);
            if (m == null or m.?.kind == .none) return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP METHOD {s}", .{name}), "method {s} does not exist", .{name});
            _ = methods.orderedRemove(name);
        }
        return Value.empty;
    }
    if (eql(s, "renamemethod")) {
        if (args.len != 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} oldName newName\"", .{try it.str(argv[0])});
        const from = try it.str(args[0]);
        const to = try it.str(args[1]);
        const m = methods.get(from);
        if (m == null or m.?.kind == .none) return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP METHOD {s}", .{from}), "method {s} does not exist", .{from});
        if (methods.get(to)) |x| {
            if (x.kind != .none) return it.failCode("TCL OO RENAME_OVER", "method called {s} already exists", .{to});
        }
        _ = methods.orderedRemove(from);
        m.?.name = try a.dupe(u8, to);
        try methods.put(a, m.?.name, m.?);
        return Value.empty;
    }
    if (eql(s, "variable") or eql(s, "filter")) {
        const is_var = eql(s, "variable");
        const list: *std.ArrayList([]const u8) = if (is_var)
            (if (def.on_object) &o.vars else &o.cls.?.vars)
        else
            (if (def.on_object) &o.filters else &o.cls.?.filters);
        var rest = args;
        var op: u8 = 'a';
        if (!is_var) op = 's';
        if (rest.len > 0) if (slotOp(try it.str(rest[0]))) |x| {
            op = x;
            rest = rest[1..];
        };
        if (op == 'c' and rest.len != 0) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} -clear\"", .{try it.str(argv[0])});
        if (is_var) {
            for (rest) |v| {
                const name = try it.str(v);
                if (std.mem.indexOf(u8, name, "::") != null) return it.failCode("TCL OO BAD_DECLVAR", "invalid declared variable name \"{s}\": must not {s}", .{ name, "contain namespace separators" });
                if (Interp.splitName(name)[1] != null) return it.failCode("TCL OO BAD_DECLVAR", "invalid declared variable name \"{s}\": must not {s}", .{ name, "refer to an array element" });
            }
        }
        if (op != 'a') list.* = .empty;
        for (rest) |v| {
            const name = try it.str(v);
            var dup = false;
            for (list.items) |x| {
                if (eql(x, name)) dup = true;
            }
            if (!dup) try list.append(a, try a.dupe(u8, name));
        }
        if (is_var) {
            if (def.on_object) o.var_stamp += 1 else o.cls.?.var_stamp += 1;
        }
        return Value.empty;
    }
    if (eql(s, "mixin") or eql(s, "superclass")) {
        const is_mixin = eql(s, "mixin");
        var rest = args;
        var op: u8 = 's';
        if (rest.len > 0) if (slotOp(try it.str(rest[0]))) |x| {
            op = x;
            rest = rest[1..];
        };
        var found: std.ArrayList(*Object) = .empty;
        for (rest) |v| {
            const c = try needClass(it, v);
            if (has(found.items, c)) {
                if (is_mixin) continue;
                return it.failCode("TCL OO REPETITIOUS", "class should only be a direct superclass once", .{});
            }
            if (!is_mixin and inherits(c, o)) return it.failCode("TCL OO CIRCULARITY", "attempt to form circular dependency graph", .{});
            if (is_mixin and !def.on_object and c == o) return it.failCode("TCL OO SELF_MIXIN", "may not mix a class into itself", .{});
            try found.append(a, c);
        }
        if (is_mixin) {
            const list = if (def.on_object) &o.mixins else &o.cls.?.mixins;
            if (op != 'a') list.* = .empty;
            for (found.items) |c| {
                if (!has(list.items, c)) try list.append(a, c);
            }
            return Value.empty;
        }
        const cls = o.cls.?;
        if (o == st.object_class) return it.failCode("TCL OO MONKEY_BUSINESS", "may not modify the superclass of the root object", .{});
        if (op == 'a') {
            for (cls.supers.items) |x| {
                if (has(found.items, x)) return it.failCode("TCL OO REPETITIOUS", "class should only be a direct superclass once", .{});
            }
        } else {
            for (cls.supers.items) |x| if (x.cls) |xc| drop(&xc.subs, o);
            cls.supers = .empty;
        }
        if (found.items.len == 0 and op != 'a') try found.append(a, st.object_class);
        for (found.items) |c| {
            try cls.supers.append(a, c);
            try c.cls.?.subs.append(a, o);
        }
        return Value.empty;
    }
    if (eql(s, "self")) {
        // `self` with words defines on the class as an object.
        if (args.len == 0) return fullV(it, o);
        try st.defs.append(a, .{ .obj = o, .on_object = true });
        defer _ = st.defs.pop();
        if (args.len == 1) {
            const words = try a.dupe(Value, &.{ .{ .str = "namespace" }, .{ .str = "eval" }, .{ .str = "::oo::objdefine" }, args[0] });
            return it.callWords(words);
        }
        return defineOne(it, st, try it.str(args[0]), args);
    }
    // class
    if (args.len != 1) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} className\"", .{try it.str(argv[0])});
    const c = try needClass(it, args[0]);
    if (o == st.object_class) return it.failCode("TCL OO MONKEY_BUSINESS", "may not modify the class of the root object class", .{});
    if (o == st.class_class) return it.failCode("TCL OO MONKEY_BUSINESS", "may not modify the class of the class of classes", .{});
    if (c == o) return it.failCode("TCL OO MONKEY_BUSINESS", "may not change classes into an instance of themselves", .{});
    const class_like = inherits(c, st.class_class);
    if (o.cls != null and !class_like) {
        // The object stops being a class: its instances and its
        // subclasses end.
        const old = o.cls.?;
        while (old.instances.items.len > 0) {
            const x = old.instances.pop().?;
            if (x != o) try destroy(it, st, x, true);
        }
        while (old.subs.items.len > 0) try destroy(it, st, old.subs.pop().?, true);
        for (old.supers.items) |x| if (x.cls) |xc| drop(&xc.subs, o);
        o.cls = null;
    } else if (o.cls == null and class_like) {
        o.cls = try a.create(Class);
        o.cls.?.* = .{};
        try o.cls.?.supers.append(a, st.object_class);
        try st.object_class.cls.?.subs.append(a, o);
    }
    drop(&o.class.cls.?.instances, o);
    o.class = c;
    try c.cls.?.instances.append(a, o);
    return Value.empty;
}

fn cmdCopy(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    const st = try state(it);
    if (argv.len < 2 or argv.len > 4) return it.wrongArgs("oo::copy sourceName ?targetName? ?targetNamespace?");
    const a = it.alloc();
    const src = try need(it, argv[1]);
    if (src == st.object_class or src == st.class_class) return it.failCode("TCL OO BAD_COPY", "may not clone the class of {s}", .{if (src == st.class_class) "classes" else "objects"});
    var name: ?[]const u8 = null;
    if (argv.len == 3 and (try it.str(argv[2])).len > 0) name = try it.str(argv[2]);
    var space: ?[]const u8 = null;
    if (argv.len == 4 and (try it.str(argv[3])).len > 0) {
        space = try it.str(argv[3]);
        if (it.namespaces.contains(std.mem.trimStart(u8, try it.qualify(space.?), ":"))) return it.failCode("TCL OO NAMESPACE_EXISTS", "{s} refers to an existing namespace", .{space.?});
    }
    const o = try newObject(it, st, src.class, name, if (space) |sp| try it.qualify(sp) else null);
    for (src.methods.keys(), src.methods.values()) |k, m| {
        const c = try a.create(Method);
        c.* = m.*;
        c.owner = o;
        c.proc = null;
        try o.methods.put(a, k, c);
    }
    try o.mixins.appendSlice(a, src.mixins.items);
    try o.filters.appendSlice(a, src.filters.items);
    try o.vars.appendSlice(a, src.vars.items);
    if (src.cls) |sc| {
        const oc = o.cls.?;
        for (oc.supers.items) |x| if (x.cls) |xc| drop(&xc.subs, o);
        oc.supers = .empty;
        for (sc.supers.items) |x| {
            try oc.supers.append(a, x);
            try x.cls.?.subs.append(a, o);
        }
        for (sc.methods.keys(), sc.methods.values()) |k, m| {
            const c = try a.create(Method);
            c.* = m.*;
            c.owner = o;
            c.proc = null;
            try oc.methods.put(a, k, c);
        }
        try oc.mixins.appendSlice(a, sc.mixins.items);
        try oc.filters.appendSlice(a, sc.filters.items);
        try oc.vars.appendSlice(a, sc.vars.items);
        inline for (.{ "ctor", "dtor" }) |f| {
            if (@field(sc, f)) |m| {
                const c = try a.create(Method);
                c.* = m.*;
                c.owner = o;
                c.proc = null;
                @field(oc, f) = c;
            }
        }
    }
    // The method `<cloned>` copies the variables and the procs.
    const words = try a.dupe(Value, &.{ try fullV(it, o), .{ .str = "<cloned>" }, try fullV(it, src) });
    _ = invoke(it, st, o, words, 2, false) catch |e| {
        if (e == error.OutOfMemory) return e;
        const res = it.result;
        destroy(it, st, o, false) catch {};
        it.result = res;
        return e;
    };
    return fullV(it, o);
}

// ---- info object and info class ----

fn objNames(it: *Interp, list: []const *Object) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    for (list) |o| try out.append(it.alloc(), try fullV(it, o));
    return value.wrapList(it.alloc(), out.items);
}

fn strings(it: *Interp, list: []const []const u8) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    for (list) |s| try out.append(it.alloc(), .{ .str = s });
    return value.wrapList(it.alloc(), out.items);
}

fn pick(it: *Interp, word: []const u8, table: []const []const u8) Error![]const u8 {
    for (table) |s| {
        if (eql(s, word)) return s;
    }
    var hit: ?[]const u8 = null;
    var count: usize = 0;
    for (table) |s| {
        if (word.len > 0 and std.mem.startsWith(u8, s, word)) {
            hit = s;
            count += 1;
        }
    }
    if (count == 1) return hit.?;
    const a = it.alloc();
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "unknown or ambiguous subcommand \"{s}\": must be ", .{word});
    for (table, 0..) |s, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        if (i == table.len - 1) try out.appendSlice(a, "or ");
        try out.appendSlice(a, s);
    }
    it.result = .{ .str = out.items };
    it.error_code = .{ .str = "TCL LOOKUP SUBCOMMAND" };
    return error.TclError;
}

fn methodInfo(it: *Interp, map: *Methods, what: []const u8, name: []const u8, usage_text: []const u8, args: []const Value) Error!Value {
    const a = it.alloc();
    if (args.len != 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s}\"", .{usage_text});
    const m = map.get(name);
    if (m == null or m.?.kind == .none) return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP METHOD {s}", .{name}), "unknown method \"{s}\"", .{name});
    if (eql(what, "methodtype")) return .{ .str = switch (m.?.kind) {
        .proc => "method",
        .forward => "forward",
        else => "core method: \"" ++ "",
    } };
    if (eql(what, "definition")) {
        if (m.?.kind != .proc) return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP METHOD {s}", .{name}), "definition not available for this kind of method", .{});
        return value.newList(a, &.{ m.?.params, m.?.body });
    }
    if (m.?.kind != .forward) return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP METHOD {s}", .{name}), "prefix argument list not available for this kind of method", .{});
    return value.newList(a, m.?.forward);
}

fn methodList(it: *Interp, o: *Object, map: *Methods, class_side: bool, opts: []const Value) Error!Value {
    const a = it.alloc();
    var all = false;
    var private = false;
    for (opts) |v| {
        const w = try it.str(v);
        if (eql(w, "-all")) {
            all = true;
        } else if (eql(w, "-private")) {
            private = true;
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -all or -private", .{w});
    }
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (class_side) {
        if (all) try classNames(a, o, &set, 0) else for (map.keys(), map.values()) |k, m| {
            if (m.kind != .none) try set.put(a, k, {});
        }
        var out: std.ArrayList(Value) = .empty;
        for (set.keys()) |k| {
            const public = exportedClass(o, k, 0) orelse (k.len > 0 and std.ascii.isLower(k[0]));
            if (private or public) try out.append(a, .{ .str = k });
        }
        return value.wrapList(a, out.items);
    }
    return strings(it, try methodNames(it, o, all, private));
}

pub fn infoObject(it: *Interp, argv: []const Value) Error!Value {
    const st = try state(it);
    const a = it.alloc();
    if (argv.len < 3) return it.wrongArgs("info object subcommand ?arg ...?");
    const subs = [_][]const u8{ "call", "class", "definition", "filters", "forward", "isa", "methods", "methodtype", "mixins", "namespace", "variables", "vars" };
    const s = try pick(it, try it.str(argv[2]), &subs);
    const args = argv[3..];
    if (args.len == 0) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"info object {s} objName{s}\"", .{ s, if (eql(s, "call")) " methodName" else " ?arg ...?" });
    if (eql(s, "isa")) {
        if (args.len < 2) return it.wrongArgs("info object isa category objName ?arg ...?");
        const cats = [_][]const u8{ "class", "metaclass", "mixin", "object", "typeof" };
        const cat = try pick(it, try it.str(args[0]), &cats);
        const o = lookup(it, try it.str(args[1]));
        if (eql(cat, "object")) {
            if (args.len != 2) return it.wrongArgs("info object isa object objName");
            return .{ .int = @intFromBool(o != null) };
        }
        if (eql(cat, "class") or eql(cat, "metaclass")) {
            if (args.len != 2) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"info object isa {s} objName\"", .{cat});
            const x = o orelse return .{ .int = 0 };
            if (eql(cat, "class")) return .{ .int = @intFromBool(x.cls != null) };
            return .{ .int = @intFromBool(x.cls != null and inherits(x, st.class_class)) };
        }
        if (args.len != 3) return it.failCode("TCL WRONGARGS", "wrong # args: should be \"info object isa {s} objName className\"", .{cat});
        const x = o orelse return .{ .int = 0 };
        const c = lookup(it, try it.str(args[2])) orelse return .{ .int = 0 };
        if (c.cls == null) return .{ .int = 0 };
        if (eql(cat, "mixin")) return .{ .int = @intFromBool(has(x.mixins.items, c)) };
        return .{ .int = @intFromBool(isA(x, c)) };
    }
    if (eql(s, "call") and args.len != 2) return it.wrongArgs("info object call objName methodName");
    const o = try need(it, args[0]);
    if (eql(s, "class")) {
        if (args.len == 1) return fullV(it, o.class);
        if (args.len != 2) return it.wrongArgs("info object class objName ?className?");
        const c = try needClass(it, args[1]);
        return .{ .int = @intFromBool(isA(o, c)) };
    }
    if (eql(s, "namespace")) return .{ .str = try std.fmt.allocPrint(a, "::{s}", .{o.ns}) };
    if (eql(s, "mixins")) return objNames(it, o.mixins.items);
    if (eql(s, "filters")) return strings(it, o.filters.items);
    if (eql(s, "variables")) return strings(it, o.vars.items);
    if (eql(s, "methods")) return methodList(it, o, &o.methods, false, args[1..]);
    if (eql(s, "vars")) {
        const pat: []const u8 = if (args.len > 1) try it.str(args[1]) else "*";
        var out: std.ArrayList(Value) = .empty;
        for (try nsVars(it, o.ns)) |v| {
            if (cmds.globMatch(pat, v.str, false)) try out.append(a, v);
        }
        return value.wrapList(a, out.items);
    }
    if (eql(s, "call")) {
        var chain: std.ArrayList(Link) = .empty;
        var name = try it.str(args[1]);
        try chainOf(a, o, name, &chain);
        var real = false;
        for (chain.items) |l| {
            if (!l.filter) real = true;
        }
        if (!real) {
            chain = .empty;
            try chainOf(a, o, "unknown", &chain);
            name = "unknown";
        }
        return callList(it, o, chain.items, name, !real);
    }
    const name: []const u8 = if (args.len > 1) try it.str(args[1]) else "";
    return methodInfo(it, &o.methods, s, name, try std.fmt.allocPrint(a, "info object {s} objName methodName", .{s}), args);
}

pub fn infoClass(it: *Interp, argv: []const Value) Error!Value {
    _ = try state(it);
    const a = it.alloc();
    if (argv.len < 4) return it.wrongArgs("info class subcommand ?arg ...?");
    const subs = [_][]const u8{ "call", "constructor", "definition", "destructor", "filters", "forward", "instances", "methods", "methodtype", "mixins", "subclasses", "superclasses", "variables" };
    const s = try pick(it, try it.str(argv[2]), &subs);
    const args = argv[3..];
    const o = lookup(it, try it.str(args[0])) orelse return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP OBJECT {s}", .{try it.str(args[0])}), "{s} does not refer to an object", .{try it.str(args[0])});
    const cls = o.cls orelse return it.failCode(try std.fmt.allocPrint(a, "TCL LOOKUP CLASS {s}", .{try it.str(args[0])}), "\"{s}\" is not a class", .{try it.str(args[0])});
    if (eql(s, "superclasses")) return objNames(it, cls.supers.items);
    if (eql(s, "mixins")) return objNames(it, cls.mixins.items);
    if (eql(s, "filters")) return strings(it, cls.filters.items);
    if (eql(s, "variables")) return strings(it, cls.vars.items);
    if (eql(s, "subclasses") or eql(s, "instances")) {
        const list = if (eql(s, "instances")) cls.instances.items else cls.subs.items;
        var out: std.ArrayList(Value) = .empty;
        for (list) |x| {
            if (x.dead) continue;
            const n = try full(it, x);
            if (args.len > 1 and !cmds.globMatch(try it.str(args[1]), n, false)) continue;
            try out.append(a, .{ .str = n });
        }
        return value.wrapList(a, out.items);
    }
    if (eql(s, "methods")) return methodList(it, o, &cls.methods, true, args[1..]);
    if (eql(s, "constructor")) {
        const m = cls.ctor orelse return Value.empty;
        if (m.kind != .proc) return it.failCode("TCL OO METHOD_TYPE", "definition not available for this kind of method", .{});
        return value.newList(a, &.{ m.params, m.body });
    }
    if (eql(s, "destructor")) {
        const m = cls.dtor orelse return Value.empty;
        return value.newList(a, &.{ Value.empty, m.body });
    }
    if (eql(s, "call")) {
        if (args.len != 2) return it.wrongArgs("info class call className methodName");
        var chain: std.ArrayList(Link) = .empty;
        const name = try it.str(args[1]);
        var filters: std.ArrayList([]const u8) = .empty;
        try classFilters(a, o, &filters, 0);
        for (filters.items) |f| try classLinks(a, o, f, &chain, true, 0, 0);
        const before = chain.items.len;
        try classLinks(a, o, name, &chain, false, 0, 0);
        if (chain.items.len == before) {
            try classLinks(a, o, "unknown", &chain, false, 0, 0);
            return callList(it, o, chain.items, "unknown", true);
        }
        return callList(it, o, chain.items, name, false);
    }
    const name: []const u8 = if (args.len > 1) try it.str(args[1]) else "";
    return methodInfo(it, &cls.methods, s, name, try std.fmt.allocPrint(a, "info class {s} className methodName", .{s}), args);
}

/// The first use of an object command makes the state.
fn rootCmd(it: *Interp, argv: []const Value, cmd: ?*Cmd) Error!Value {
    _ = try state(it);
    const c = it.findCommand(try it.str(argv[0])) orelse return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    if (c.impl == .native and c.impl.native == rootCmd) return it.fail("invalid command name \"{s}\"", .{try it.str(argv[0])});
    return it.call(c, argv, cmd);
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    try it.register("oo::class", rootCmd);
    try it.register("oo::object", rootCmd);
    try it.register("oo::define", cmdDefine);
    try it.register("oo::objdefine", cmdDefine);
    try it.register("oo::copy", cmdCopy);
}
