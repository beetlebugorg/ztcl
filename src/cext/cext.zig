//! The loader of Tcl C packages: the capability `cext` and `load`.
//!
//! A C package built against the stubs of Tcl 8.6 gets a `Tcl_Interp`
//! pointer from ztcl. That pointer is a `Shadow`: its first fields have
//! the layout of the start of `struct Interp` of `tclInt.h` (`result`,
//! `freeProc`, `errorLine`, `stubTable`), and `Tcl_InitStubs` reads
//! `stubTable`. The fields after them belong to ztcl.
//!
//! `load` opens the file with the dynamic loader of the host, looks up
//! `Pkg_Init`, and calls it with the shadow of the interpreter. The code
//! of the package runs with the rights of the process. It is outside the
//! compute limit, the memory limit, and the root folder, so `cext` is
//! not sandboxed. A slot of the stubs tables with no function records
//! its call in the shadow (`missing`), and the call into C then ends
//! with a Tcl error that names the slot.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const interp_mod = @import("../interp.zig");
const fsroot = @import("../fsroot.zig");
const stubs = @import("stubs.zig");
const obj = @import("obj.zig");
const native = @import("native.zig");
const Interp = interp_mod.Interp;
const value = @import("../value.zig");
const Value = value.Value;
const Error = interp_mod.Error;
const Cmd = interp_mod.Cmd;

/// The C functions of the host run here: Linux first, and macOS and
/// Windows use the same entry points of their loaders.
pub const supported = (@hasDecl(@import("build_options"), "cext") and @import("build_options").cext) and switch (builtin.os.tag) {
    .linux, .macos => builtin.link_libc,
    else => false,
};

/// C memory: the shadows and the strings that C code reads.
pub const gpa = std.heap.c_allocator;

pub const TCL_OK: c_int = 0;
pub const TCL_ERROR: c_int = 1;

pub const InitFn = *const fn (*Shadow) callconv(.c) c_int;

/// The call of a slot with no function.
pub const Missing = struct { kind: stubs.Kind, slot: usize };

/// The `Tcl_Interp` of a C package.
pub const Shadow = extern struct {
    /// The layout of the start of `struct Interp` of Tcl 8.6, and the
    /// result object of `obj.zig`.
    core: obj.Interp = .{ .stub_table = &stubs.public },
    // The fields of ztcl.
    it: *Interp,
    state: *State,
};

/// The state of ztcl for one shadow.
pub const State = struct {
    missing: ?Missing = null,
    /// The packages of `load` in this interpreter, by init name.
    loaded: std.StringHashMapUnmanaged(void) = .empty,
};

/// The shadow of the interpreter during a call into C code. A slot reads
/// it when the slot has no interp argument.
pub threadlocal var current: ?*Shadow = null;

/// The shadow of `it`. The first call makes it.
pub fn shadowOf(it: *Interp) Error!*Shadow {
    if (it.cext) |p| return @ptrCast(@alignCast(p));
    const st = try gpa.create(State);
    st.* = .{};
    const sh = try gpa.create(Shadow);
    sh.* = .{ .it = it, .state = st };
    sh.core.handle = try native.register(sh);
    it.cext = sh;
    return sh;
}

/// A function that `Interp.deinit` calls for each interp. The bridge of
/// C packages in WebAssembly (`src/wasm_cext.zig`) sets it, so a package
/// frees its interp of a child that goes.
pub var drop_hook: ?*const fn (*Interp) void = null;

/// Frees the shadow of `it`. `Interp.deinit` calls it.
pub fn drop(it: *Interp) void {
    const sh: *Shadow = @ptrCast(@alignCast(it.cext orelse return));
    @import("interps.zig").dropInterp(&sh.core);
    @import("hash.zig").dropAssoc(&sh.core);
    @import("host.zig").dropPkgs(&sh.core);
    @import("chan.zig").forgetInterp(&sh.core);
    native.unregister(sh.core.handle);
    freeKeys(&sh.state.loaded);
    gpa.destroy(sh.state);
    gpa.destroy(sh);
    it.cext = null;
}

fn freeKeys(m: anytype) void {
    var ki = m.keyIterator();
    while (ki.next()) |k| gpa.free(k.*);
    m.deinit(gpa);
}

/// Records a call of slot `i` of table `k`, which has no function. The
/// first call of a slot also writes a line to the standard error, as the
/// value 0 that the slot returns can stop the package before its call
/// returns to ztcl.
pub fn missing(k: stubs.Kind, i: usize) void {
    const nm = stubs.name(k, i) orelse "a reserved slot";
    const S = struct {
        var told = std.StaticBitSet(1024).empty;
        var lock: std.atomic.Mutex = .unlocked;
    };
    const bit = @as(usize, @backingInt(k)) * 256 + i;
    while (!S.lock.tryLock()) {}
    const first = bit < 1024 and !S.told.isSet(bit);
    if (bit < 1024) S.told.set(bit);
    S.lock.unlock();
    // The test of a missing slot writes no line. The Zig test runner
    // shows any text on the standard error under "failed command", with
    // no test name, also when each test passes.
    if (first and !builtin.is_test) std.debug.print("ztcl: a C package called {s} (slot {d} of the {s} stubs table), which ztcl does not have\n", .{ nm, i, k.label() });
    if (current) |sh| {
        if (sh.state.missing == null) sh.state.missing = .{ .kind = k, .slot = i };
    }
}

/// Runs `f` with `sh` as the current shadow. After the call, a call of
/// a slot with no function is an error.
pub fn callC(sh: *Shadow, comptime R: type, f: anytype, args: anytype) Error!R {
    const prev = current;
    current = sh;
    defer current = prev;
    @import("chan.zig").last = &sh.core;
    sh.state.missing = null;
    sh.it.result = Value.empty;
    obj.Tcl_ResetResult(&sh.core);
    const r = @call(.auto, f, args);
    if (sh.state.missing) |m| {
        sh.state.missing = null;
        return sh.it.failCode("TCL CEXT MISSING", "the C package called {s} (slot {d} of the {s} stubs table), which ztcl does not have", .{ stubs.name(m.kind, m.slot) orelse "a reserved slot", m.slot, m.kind.label() });
    }
    return r;
}

/// A string for C code that stays valid until the process ends. The
/// set keeps one copy of each text.
pub fn keep(text: []const u8) Error![*:0]const u8 {
    const S = struct {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        var lock: std.atomic.Mutex = .unlocked;
    };
    while (!S.lock.tryLock()) {}
    defer S.lock.unlock();
    if (S.set.getKey(text)) |k| return @ptrCast(k.ptr);
    const z = try gpa.dupeSentinel(u8, text, 0);
    try S.set.put(gpa, z, {});
    return z.ptr;
}

// ---- load ----

/// A package of `load` or `Tcl_StaticPackage` in this process. The file
/// stays open until the process ends. A static package has no file.
pub const Pkg = struct {
    path: []const u8,
    /// The prefix of the init function, such as "Sqlite".
    prefix: []const u8,
    handle: ?*anyopaque,
    init: ?InitFn,
};
pub var pkgs: std.ArrayList(Pkg) = .empty;
pub var pkgs_lock: std.atomic.Mutex = .unlocked;

pub fn lockPkgs() void {
    while (!pkgs_lock.tryLock()) {}
}

pub fn register(it: *Interp) std.mem.Allocator.Error!void {
    if (comptime !supported) return;
    try it.register("load", cmdLoad);
}

const usage = "load ?-global? ?-lazy? ?--? fileName ?packageName? ?interp?";

fn cmdLoad(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    var i: usize = 1;
    var global = false;
    while (i < argv.len) {
        const a = try it.str(argv[i]);
        if (a.len == 0 or a[0] != '-') break;
        i += 1;
        if (std.mem.eql(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "-global")) {
            global = true;
        } else if (!std.mem.eql(u8, a, "-lazy")) {
            return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -global, -lazy, or --", .{a});
        }
    }
    const rest = argv[i..];
    if (rest.len < 1 or rest.len > 3) return it.wrongArgs(usage);
    const file = try it.str(rest[0]);
    const name: []const u8 = if (rest.len >= 2) try it.str(rest[1]) else "";
    if (rest.len == 3 and (try it.str(rest[2])).len != 0) {
        return it.fail("load: the interp argument is not supported yet", .{});
    }
    if (file.len == 0 and name.len == 0) return it.fail("must specify either file name or package name", .{});
    const path: [:0]const u8 = if (file.len == 0) "" else try hostPath(it, file);
    const pkg = try findPkg(it, file, path, name, global);
    const sh = try shadowOf(it);
    if (sh.state.loaded.contains(pkg.prefix)) return Value.empty;
    const init = pkg.init orelse return it.failCode("TCL OPERATION LOAD", "package \"{s}\" has no init function", .{pkg.prefix});
    const rc = try callC(sh, c_int, init, .{sh});
    const res = try takeResult(sh);
    if (rc != TCL_OK) {
        it.result = res;
        return error.TclError;
    }
    try sh.state.loaded.put(gpa, try gpa.dupe(u8, pkg.prefix), {});
    return res;
}

/// The package of a file and a name, as Tcl matches them: the same file
/// with the same name or no name, or no file and the name of a package
/// of another file or of `Tcl_StaticPackage`. A new file opens and gets
/// its init function.
fn findPkg(it: *Interp, file: []const u8, path: [:0]const u8, name: []const u8, global: bool) Error!Pkg {
    lockPkgs();
    defer pkgs_lock.unlock();
    var default: ?Pkg = null;
    for (pkgs.items) |p| {
        const names = name.len != 0 and std.ascii.eqlIgnoreCase(p.prefix, name);
        const files = std.mem.eql(u8, p.path, path);
        if (files and (names or name.len == 0)) return p;
        if (names and path.len == 0) default = p;
        if (files and !names and path.len != 0) {
            return it.failCode("TCL OPERATION LOAD SPLITPERSONALITY", "file \"{s}\" is already loaded for package \"{s}\"", .{ path, p.prefix });
        }
    }
    if (path.len == 0) {
        return default orelse it.failCode("TCL OPERATION LOAD NOTSTATIC", "package \"{s}\" isn't loaded statically", .{name});
    }
    const prefix = try capital(if (name.len != 0) name else prefixOf(file));
    const sym = try std.fmt.allocPrintSentinel(it.alloc(), "{s}_Init", .{prefix}, 0);
    const h = std.c.dlopen(path.ptr, .{ .NOW = true, .GLOBAL = global }) orelse
        return it.fail("couldn't load file \"{s}\": {s}", .{ file, dlerr() });
    const f = std.c.dlsym(h, sym.ptr) orelse std.c.dlsym(h, (try std.fmt.allocPrintSentinel(it.alloc(), "_{s}", .{sym}, 0)).ptr) orelse {
        const msg = dlerr();
        _ = std.c.dlclose(h);
        return it.failCode(try std.fmt.allocPrint(it.alloc(), "TCL LOOKUP LOAD_SYMBOL {s}", .{sym}), "cannot find symbol \"{s}\": {s}", .{ sym, msg });
    };
    const p: Pkg = .{ .path = try gpa.dupe(u8, path), .prefix = prefix, .handle = h, .init = @ptrCast(@alignCast(f)) };
    try pkgs.append(gpa, p);
    return p;
}

/// The result of a call into C: the string of the `result` field when
/// the package wrote one there, else the text of the result object of
/// `obj.zig` when it is not empty, else the result of the interpreter. The interpreter and
/// the shadow then have the empty result again.
pub fn takeResult(sh: *Shadow) Error!Value {
    const legacy = std.mem.span(sh.core.result_dont_use);
    const r: Value = if (legacy.len != 0)
        .{ .str = try sh.it.alloc().dupe(u8, legacy) }
    else if (sh.core.result != null and obj.text(sh.core.result.?).len != 0)
        try fromObj(sh.it, sh.core.result.?)
    else
        sh.it.result;
    sh.core.result_dont_use = "";
    obj.Tcl_ResetResult(&sh.core);
    sh.it.result = Value.empty;
    return r;
}

// ---- The bridge of values ----
//
// A value of ztcl becomes a new `Tcl_Obj` at each call into C, and a
// `Tcl_Obj` becomes a value at each return. The kind stays: an int, a
// double, or a list with its elements. Text is in the modified UTF-8 of
// Tcl in C memory, where U+0000 is the two bytes C0 80. A `Tcl_Obj` of
// another type, such as a type of a package, becomes its text.

/// A new `Tcl_Obj` with no reference for `v`.
pub fn toObj(it: *Interp, v: Value) Error!*obj.Obj {
    return switch (v) {
        .int => |i| obj.Tcl_NewWideIntObj(i),
        .double => |d| obj.Tcl_NewDoubleObj(d),
        .list => |l| blk: {
            const o = obj.Tcl_NewListObj(0, null);
            for (l.items()) |e| _ = obj.Tcl_ListObjAppendElement(null, o, try toObj(it, e));
            break :blk o;
        },
        .str => |s| blk: {
            if (std.mem.indexOfScalar(u8, s, 0) == null) break :blk obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            for (s) |c| {
                if (c == 0) try out.appendSlice(gpa, &.{ 0xC0, 0x80 }) else try out.append(gpa, c);
            }
            break :blk obj.Tcl_NewStringObj(out.items.ptr, @intCast(out.items.len));
        },
    };
}

/// The value of `o`, in the memory of the interpreter.
pub fn fromObj(it: *Interp, o: *obj.Obj) Error!Value {
    if (obj.isInt(o)) return .{ .int = o.rep.wide };
    if (o.typePtr == &obj.double_type) return .{ .double = o.rep.double };
    if (o.typePtr == &obj.list_type) {
        const items = obj.listRep(o).items.items;
        const vals = try it.alloc().alloc(Value, items.len);
        for (items, vals) |e, *v| v.* = try fromObj(it, e);
        return value.newList(it.alloc(), vals);
    }
    const s = obj.text(o);
    const out = try it.alloc().alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == 0xC0 and i + 1 < s.len and s[i + 1] == 0x80) {
            out[n] = 0;
            i += 1;
        } else out[n] = s[i];
        n += 1;
    }
    return .{ .str = out[0..n] };
}

test "cext: the bridge keeps the kind of a value" {
    if (comptime !supported) return error.SkipZigTest;
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const l = try value.newList(it.alloc(), &.{ .{ .int = 7 }, .{ .double = 0.5 }, .{ .str = "a\x00b" } });
    const o = try toObj(&it, l);
    obj.incr(o);
    defer obj.decr(o);
    try std.testing.expectEqualStrings("7 0.5 a\xc0\x80b", obj.text(o));
    const back = try fromObj(&it, o);
    try std.testing.expect(back == .list);
    const items = back.list.items();
    try std.testing.expectEqual(@as(i64, 7), items[0].int);
    try std.testing.expectEqual(@as(f64, 0.5), items[1].double);
    try std.testing.expectEqualStrings("a\x00b", items[2].str);
}

/// The host path of the file of a script. The root folder mode has no
/// host path, and C code reaches the host anyway, so `load` needs the
/// host mode or no file capability.
fn hostPath(it: *Interp, file: []const u8) Error![:0]const u8 {
    if (it.fs.host) {
        if (try fsroot.normal(it, file)) |p| return it.alloc().dupeSentinel(u8, p, 0);
    } else if (it.fs.fd >= 0) {
        return it.fail("couldn't load file \"{s}\": load needs the host mode of the file capability", .{file});
    }
    return it.alloc().dupeSentinel(u8, file, 0);
}

/// The prefix of the init function from a file name, as Tcl 8.6 makes
/// it: the tail, with no "lib" at the start, up to the first character
/// that is not a letter or "_".
fn prefixOf(file: []const u8) []const u8 {
    var tail = std.fs.path.basename(file);
    if (std.mem.startsWith(u8, tail, "lib")) tail = tail[3..];
    var n: usize = 0;
    while (n < tail.len and (std.ascii.isAlphabetic(tail[n]) or tail[n] == '_' or tail[n] >= 0x80)) n += 1;
    return tail[0..n];
}

/// The prefix with the first letter in upper case and the others in
/// lower case, in C memory.
fn capital(prefix: []const u8) Error![]const u8 {
    const out = try gpa.dupe(u8, prefix);
    for (out, 0..) |*c, j| c.* = if (j == 0) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
    return out;
}

fn dlerr() []const u8 {
    return if (std.c.dlerror()) |e| std.mem.span(e) else "unknown error";
}

test "cext: prefixOf follows the rule of Tcl 8.6" {
    try std.testing.expectEqualStrings("sqlite", prefixOf("/a/libsqlite3.54.1.so"));
    try std.testing.expectEqualStrings("tdom", prefixOf("tdom0.9.so"));
    try std.testing.expectEqualStrings("z", prefixOf("/usr/lib/libz.so.1"));
}

test "cext: load needs the capability cext" {
    if (comptime !supported) return error.SkipZigTest;
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    try std.testing.expect(!it.commands.contains("load"));
    try it.allow(@backingInt(interp_mod.Capability.cext));
    try std.testing.expect(it.commands.contains("load"));
    try std.testing.expectError(error.TclError, it.eval("load /nonexistent/libnone.so"));
}

test "cext: a slot with no function makes the call an error" {
    if (comptime !supported) return error.SkipZigTest;
    // The first public slot with no function, if one is left.
    const slot = comptime blk: {
        @setEvalBranchQuota(100_000);
        for (0..stubs.len(.public)) |i| {
            if (stubs.name(.public, i) != null and !stubs.done(.public, i)) break :blk @as(?usize, i);
        }
        break :blk null;
    };
    if (slot == null) return error.SkipZigTest;
    var it: Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const sh = try shadowOf(&it);
    const f: *const fn () callconv(.c) usize = @ptrCast(@alignCast(stubs.public.slots[slot.?].?));
    try std.testing.expectError(error.TclError, callC(sh, usize, f, .{}));
    const want = try std.fmt.allocPrint(std.testing.allocator, "the C package called {s} (slot {d} of the public stubs table), which ztcl does not have", .{ stubs.name(.public, slot.?).?, slot.? });
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, try it.str(it.result));
}

test "cext: the tables have the layout of Tcl 8.6" {
    try std.testing.expectEqual(@as(usize, 16 + 8 * 691), @sizeOf(@TypeOf(stubs.public)));
    try std.testing.expectEqual(stubs.magic, stubs.public.magic);
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(obj.Interp, "stub_table") - 8);
}
