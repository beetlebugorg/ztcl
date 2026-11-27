//! The slots of the area namespaces of the stubs table of Tcl 8.6:
//! namespaces, exports and imports, the unknown handler, and ensembles.
//! The native path (`stubs.zig`) and the WebAssembly path
//! (`wasm_stubs.zig`) use this one file.
//!
//! A `Tcl_Namespace` is a record of this file with the layout of tcl.h
//! (`name`, `fullName`, `clientData`, `deleteProc`, `parentPtr`), one for
//! each full name of an interp. Each slot evaluates `namespace` of ztcl
//! in the namespace of the record. A lookup runs `namespace exists`
//! first, so it makes no namespace. The delete proc of a namespace runs
//! at `Tcl_DeleteNamespace` and when the interp goes. A delete by a
//! script of ztcl does not run it, because ztcl tells a package of no
//! delete of a namespace. An ensemble is a command token of
//! `interps.zig`, and its slots use `namespace ensemble configure`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const obj = @import("obj.zig");
const host = @import("host.zig");
const regexp = @import("regexp.zig");
const interps = @import("interps.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const Command = host.Command;
const OK = obj.OK;
const ERROR = obj.ERROR;
const gpa = std.heap.c_allocator;
const panicText = obj.panicText;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

const GLOBAL_ONLY: c_int = 1;
const LEAVE_ERR_MSG: c_int = 0x200;
const ENSEMBLE_PREFIX: c_int = 2;

fn oom() noreturn {
    panicText("out of memory");
}

pub const DeleteProc = *const fn (?*anyopaque) callconv(.c) void;

/// `Tcl_Namespace` of tcl.h, and the fields of this file.
pub const Namespace = extern struct {
    name: [*:0]u8,
    full_name: [*:0]u8,
    client_data: ?*anyopaque = null,
    delete_proc: ?DeleteProc = null,
    parent: ?*Namespace = null,
    ip: *Interp,
    live: bool = true,
};

threadlocal var records: std.ArrayList(*Namespace) = .empty;

fn text(s: []const u8) *Obj {
    return obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
}

fn push(list: *std.ArrayList(*Obj), o: *Obj) void {
    obj.incr(o);
    list.append(gpa, o) catch oom();
}

fn word(list: *std.ArrayList(*Obj), s: []const u8) void {
    push(list, text(s));
}

fn freeWords(list: *std.ArrayList(*Obj)) void {
    for (list.items) |o| obj.decr(o);
    list.deinit(gpa);
}

/// Evaluates the words of `list` in namespace `ns`, or in the current
/// namespace for null, and frees them. Gives the result with a
/// reference, or null after an error, with the message in the result of
/// `ip` when `keep_err`.
fn run(ip: *Interp, ns: ?*Namespace, list: *std.ArrayList(*Obj), keep_err: bool) ?*Obj {
    var words = list.*;
    var outer: std.ArrayList(*Obj) = .empty;
    if (ns) |n| {
        word(&outer, "::namespace");
        word(&outer, "eval");
        word(&outer, std.mem.span(n.full_name));
        push(&outer, obj.Tcl_NewListObj(@intCast(words.items.len), words.items.ptr));
        freeWords(&words);
        words = outer;
    }
    const saved = obj.result(ip);
    obj.incr(saved);
    defer obj.decr(saved);
    var r: ?*Obj = null;
    if (regexp.run(ip, &words, &r) != OK) {
        if (!keep_err) obj.Tcl_SetObjResult(ip, saved);
        return null;
    }
    list.* = .empty;
    return r;
}

/// `run` for a slot that gives a code: the result of `ip` is the result
/// or the message.
fn runCode(ip: *Interp, ns: ?*Namespace, list: *std.ArrayList(*Obj)) c_int {
    const r = run(ip, ns, list, true) orelse return ERROR;
    obj.Tcl_SetObjResult(ip, r);
    obj.decr(r);
    return OK;
}

fn fail(ip: *Interp, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch oom();
    defer gpa.free(msg);
    obj.setResultText(ip, msg);
}

/// The record of namespace `full` of `ip`, made on the first call.
fn record(ip: *Interp, full: []const u8) *Namespace {
    for (records.items) |n| {
        if (n.live and n.ip == ip and std.mem.eql(u8, std.mem.span(n.full_name), full)) return n;
    }
    const tail = if (std.mem.lastIndexOf(u8, full, "::")) |i| full[i + 2 ..] else full;
    const n = gpa.create(Namespace) catch oom();
    n.* = .{
        .name = (gpa.dupeSentinel(u8, if (std.mem.eql(u8, full, "::")) "" else tail, 0) catch oom()).ptr,
        .full_name = (gpa.dupeSentinel(u8, full, 0) catch oom()).ptr,
        .ip = ip,
    };
    if (!std.mem.eql(u8, full, "::")) {
        const head = full[0 .. full.len - tail.len - 2];
        n.parent = record(ip, if (head.len == 0) "::" else head);
    }
    records.append(gpa, n) catch oom();
    return n;
}

/// The full name of namespace `name` from namespace `ctx`, or null when
/// it does not exist.
fn lookup(ip: *Interp, name: []const u8, ctx: ?*Namespace, global: bool) ?*Namespace {
    // apply {{n} {...} CTX} NAME: the body runs in the namespace CTX.
    var lam: std.ArrayList(*Obj) = .empty;
    defer freeWords(&lam);
    word(&lam, "n");
    word(&lam, "if {[::namespace exists $n]} {::namespace eval $n {::namespace current}}");
    if (global) word(&lam, "::") else if (ctx) |c| word(&lam, std.mem.span(c.full_name));
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::apply");
    push(&list, obj.Tcl_NewListObj(@intCast(lam.items.len), lam.items.ptr));
    word(&list, name);
    const r = run(ip, null, &list, false) orelse return null;
    defer obj.decr(r);
    const full = obj.text(r);
    if (full.len == 0) return null;
    return record(ip, full);
}

pub fn Tcl_FindNamespace(ip: *Interp, name: [*:0]const u8, ctx: ?*Namespace, flags: c_int) callconv(.c) ?*Namespace {
    const n = std.mem.span(name);
    if (lookup(ip, n, ctx, flags & GLOBAL_ONLY != 0)) |ns| return ns;
    if (flags & LEAVE_ERR_MSG != 0) fail(ip, "unknown namespace \"{s}\"", .{n});
    return null;
}

pub fn Tcl_GetCurrentNamespace(ip: *Interp) callconv(.c) *Namespace {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "current");
    const r = run(ip, null, &list, false) orelse return record(ip, "::");
    defer obj.decr(r);
    return record(ip, obj.text(r));
}

pub fn Tcl_GetGlobalNamespace(ip: *Interp) callconv(.c) *Namespace {
    return record(ip, "::");
}

pub fn Tcl_CreateNamespace(ip: *Interp, name: [*:0]const u8, cd: ?*anyopaque, delete: ?DeleteProc) callconv(.c) ?*Namespace {
    const n = std.mem.span(name);
    if (lookup(ip, n, null, false)) |old| {
        // `namespace exists` also finds a namespace of the global
        // namespace from another one, so the full name decides.
        const want = if (std.mem.startsWith(u8, n, "::")) n else "";
        if (want.len == 0 or std.mem.eql(u8, std.mem.span(old.full_name), want)) {
            fail(ip, "can't create namespace \"{s}\": already exists", .{n});
            return null;
        }
    }
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "eval");
    word(&list, n);
    word(&list, "::namespace current");
    const r = run(ip, null, &list, true) orelse return null;
    defer obj.decr(r);
    const ns = record(ip, obj.text(r));
    ns.client_data = cd;
    ns.delete_proc = delete;
    return ns;
}

/// Runs the delete proc of `ns` once.
fn forget(ns: *Namespace) void {
    if (!ns.live) return;
    ns.live = false;
    if (ns.delete_proc) |d| d(ns.client_data);
}

pub fn Tcl_DeleteNamespace(ns: *Namespace) callconv(.c) void {
    if (!ns.live) return;
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "delete");
    word(&list, std.mem.span(ns.full_name));
    if (run(ns.ip, null, &list, false)) |o| obj.decr(o);
    // The children go with it.
    const full = std.mem.span(ns.full_name);
    for (records.items) |c| {
        if (c != ns and c.live and c.ip == ns.ip and std.mem.startsWith(u8, std.mem.span(c.full_name), full) and std.mem.startsWith(u8, std.mem.span(c.full_name)[full.len..], "::")) forget(c);
    }
    forget(ns);
}

pub fn Tcl_Export(ip: *Interp, ns: ?*Namespace, pattern: [*:0]const u8, reset: c_int) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "export");
    if (reset != 0) word(&list, "-clear");
    word(&list, std.mem.span(pattern));
    const r = run(ip, ns, &list, true) orelse return ERROR;
    obj.decr(r);
    return OK;
}

pub fn Tcl_AppendExportList(ip: *Interp, ns: ?*Namespace, out: *Obj) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "export");
    const r = run(ip, ns, &list, true) orelse return ERROR;
    defer obj.decr(r);
    var n: c_int = 0;
    var items: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(ip, r, &n, &items) != OK) return ERROR;
    for (items[0..@intCast(n)]) |e| {
        if (obj.Tcl_ListObjAppendElement(ip, out, e) != OK) return ERROR;
    }
    return OK;
}

pub fn Tcl_Import(ip: *Interp, ns: ?*Namespace, pattern: [*:0]const u8, force: c_int) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "import");
    if (force != 0) word(&list, "-force");
    word(&list, std.mem.span(pattern));
    const r = run(ip, ns, &list, true) orelse return ERROR;
    obj.decr(r);
    return OK;
}

pub fn Tcl_ForgetImport(ip: *Interp, ns: ?*Namespace, pattern: [*:0]const u8) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "forget");
    word(&list, std.mem.span(pattern));
    const r = run(ip, ns, &list, true) orelse return ERROR;
    obj.decr(r);
    return OK;
}

pub fn Tcl_GetNamespaceUnknownHandler(ip: *Interp, ns: ?*Namespace) callconv(.c) ?*Obj {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "unknown");
    const r = run(ip, ns, &list, false) orelse return null;
    // No handler gives null, as in Tcl.
    if (obj.text(r).len == 0) {
        obj.decr(r);
        return null;
    }
    // The caller gets the object with no reference.
    r.refCount -= 1;
    return r;
}

pub fn Tcl_SetNamespaceUnknownHandler(ip: *Interp, ns: ?*Namespace, handler: ?*Obj) callconv(.c) c_int {
    var list: std.ArrayList(*Obj) = .empty;
    word(&list, "::namespace");
    word(&list, "unknown");
    if (handler) |h| push(&list, h) else word(&list, "");
    const r = run(ip, ns, &list, true) orelse return ERROR;
    obj.decr(r);
    return OK;
}

/// Frees the records of `ip`, and runs the delete procs of the live
/// ones, the newest first. The free of the interp calls it.
pub fn dropInterp(ip: *Interp) void {
    var i = records.items.len;
    while (i > 0) {
        i -= 1;
        if (records.items[i].ip == ip) forget(records.items[i]);
    }
    i = records.items.len;
    while (i > 0) {
        i -= 1;
        const n = records.items[i];
        if (n.ip != ip) continue;
        _ = records.orderedRemove(i);
        gpa.free(std.mem.span(n.name));
        gpa.free(std.mem.span(n.full_name));
        gpa.destroy(n);
    }
}

// ---- Ensembles ----

fn fullName(c: *Command, buf: *std.ArrayList(u8)) []const u8 {
    buf.clearRetainingCapacity();
    if (!std.mem.startsWith(u8, c.name, "::")) buf.appendSlice(gpa, "::") catch oom();
    buf.appendSlice(gpa, c.name) catch oom();
    return buf.items;
}

fn isEnsemble(c: *Command) bool {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var list: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::namespace", "ensemble", "exists", fullName(c, &buf) }) |w| word(&list, w);
    const r = run(c.interp, null, &list, false) orelse return false;
    defer obj.decr(r);
    return std.mem.eql(u8, obj.text(r), "1");
}

pub fn Tcl_IsEnsemble(c: *Command) callconv(.c) c_int {
    return @intFromBool(isEnsemble(c));
}

pub fn Tcl_CreateEnsemble(ip: *Interp, name: [*:0]const u8, ns: ?*Namespace, flags: c_int) callconv(.c) ?*Command {
    var list: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::namespace", "ensemble", "create", "-command", std.mem.span(name), "-prefixes", if (flags & ENSEMBLE_PREFIX != 0) "1" else "0" }) |w| word(&list, w);
    const r = run(ip, ns orelse Tcl_GetCurrentNamespace(ip), &list, true) orelse return null;
    defer obj.decr(r);
    const full = gpa.dupeSentinel(u8, obj.text(r), 0) catch oom();
    defer gpa.free(full);
    return interps.Tcl_FindCommand(ip, full.ptr, null, 0);
}

pub fn Tcl_FindEnsemble(ip: *Interp, name: *Obj, flags: c_int) callconv(.c) ?*Command {
    const c = interps.Tcl_GetCommandFromObj(ip, name) orelse {
        if (flags & LEAVE_ERR_MSG != 0) fail(ip, "unknown command \"{s}\"", .{obj.text(name)});
        return null;
    };
    if (isEnsemble(c)) return c;
    if (flags & LEAVE_ERR_MSG != 0) fail(ip, "\"{s}\" is not an ensemble command", .{obj.text(name)});
    return null;
}

/// Reads option `opt` of ensemble `c` into `out`: null for an empty
/// value, as in Tcl.
fn getOpt(ip: *Interp, c: *Command, opt: []const u8, out: ?*?*Obj) c_int {
    if (!isEnsemble(c)) {
        fail(ip, "command is not an ensemble", .{});
        return ERROR;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var list: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::namespace", "ensemble", "configure", fullName(c, &buf), opt }) |w| word(&list, w);
    const r = run(ip, null, &list, true) orelse return ERROR;
    if (out) |p| {
        if (obj.text(r).len == 0) {
            obj.decr(r);
            p.* = null;
        } else {
            r.refCount -= 1;
            p.* = r;
        }
    } else obj.decr(r);
    return OK;
}

fn setOpt(ip: *Interp, c: *Command, opt: []const u8, v: ?*Obj) c_int {
    if (!isEnsemble(c)) {
        fail(ip, "command is not an ensemble", .{});
        return ERROR;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var list: std.ArrayList(*Obj) = .empty;
    for ([_][]const u8{ "::namespace", "ensemble", "configure", fullName(c, &buf), opt }) |w| word(&list, w);
    if (v) |o| push(&list, o) else word(&list, "");
    const r = run(ip, null, &list, true) orelse return ERROR;
    obj.decr(r);
    return OK;
}

pub fn Tcl_SetEnsembleSubcommandList(ip: *Interp, c: *Command, l: ?*Obj) callconv(.c) c_int {
    return setOpt(ip, c, "-subcommands", l);
}

pub fn Tcl_SetEnsembleMappingDict(ip: *Interp, c: *Command, d: ?*Obj) callconv(.c) c_int {
    return setOpt(ip, c, "-map", d);
}

pub fn Tcl_SetEnsembleUnknownHandler(ip: *Interp, c: *Command, l: ?*Obj) callconv(.c) c_int {
    return setOpt(ip, c, "-unknown", l);
}

pub fn Tcl_SetEnsembleParameterList(ip: *Interp, c: *Command, l: ?*Obj) callconv(.c) c_int {
    return setOpt(ip, c, "-parameters", l);
}

pub fn Tcl_SetEnsembleFlags(ip: *Interp, c: *Command, flags: c_int) callconv(.c) c_int {
    const v = text(if (flags & ENSEMBLE_PREFIX != 0) "1" else "0");
    obj.incr(v);
    defer obj.decr(v);
    return setOpt(ip, c, "-prefixes", v);
}

pub fn Tcl_GetEnsembleSubcommandList(ip: *Interp, c: *Command, out: ?*?*Obj) callconv(.c) c_int {
    return getOpt(ip, c, "-subcommands", out);
}

pub fn Tcl_GetEnsembleMappingDict(ip: *Interp, c: *Command, out: ?*?*Obj) callconv(.c) c_int {
    return getOpt(ip, c, "-map", out);
}

pub fn Tcl_GetEnsembleUnknownHandler(ip: *Interp, c: *Command, out: ?*?*Obj) callconv(.c) c_int {
    return getOpt(ip, c, "-unknown", out);
}

pub fn Tcl_GetEnsembleParameterList(ip: *Interp, c: *Command, out: ?*?*Obj) callconv(.c) c_int {
    return getOpt(ip, c, "-parameters", out);
}

pub fn Tcl_GetEnsembleFlags(ip: *Interp, c: *Command, flags: *c_int) callconv(.c) c_int {
    var v: ?*Obj = null;
    if (getOpt(ip, c, "-prefixes", &v) != OK) return ERROR;
    var b: c_int = 0;
    if (v) |o| {
        obj.incr(o);
        defer obj.decr(o);
        _ = obj.Tcl_GetBooleanFromObj(null, o, &b);
    }
    flags.* = if (b != 0) ENSEMBLE_PREFIX else 0;
    return OK;
}

pub fn Tcl_GetEnsembleNamespace(ip: *Interp, c: *Command, out: *?*Namespace) callconv(.c) c_int {
    var v: ?*Obj = null;
    if (getOpt(ip, c, "-namespace", &v) != OK) return ERROR;
    const o = v orelse {
        out.* = record(ip, "::");
        return OK;
    };
    obj.incr(o);
    defer obj.decr(o);
    out.* = record(ip, obj.text(o));
    return OK;
}
