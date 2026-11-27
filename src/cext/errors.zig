//! The error slots of the stubs table of Tcl 8.6: the error code, the
//! error info, the error line, the return options, the names of errno
//! values and of signals, and background errors. The native path
//! (`stubs.zig`) and the WebAssembly path (`wasm_stubs.zig`) use this
//! one file.
//!
//! The interp of a package keeps its error state (`Interp.err_code`,
//! `Interp.err_info`, the `errorLine` field), and Tcl_ResetResult clears
//! it, as in Tcl. Two calls of the host move the state over the bridge:
//! after a script or a variable of ztcl fails, `takeError` gets the
//! state of ztcl. When a command of the package ends with TCL_ERROR or
//! TCL_RETURN, `giveError` gives its state to ztcl.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const obj = @import("obj.zig");
const host = @import("host.zig");
const cchan = @import("chan.zig");

const Obj = obj.Obj;
const Interp = obj.Interp;
const OK = obj.OK;
const ERROR = obj.ERROR;
const RETURN: c_int = 2;
const gpa = std.heap.c_allocator;

/// The slots of this file for the table builder of `table.zig`.
pub const slots = @This();

fn newText(s: []const u8) *Obj {
    return obj.Tcl_NewStringObj(s.ptr, @intCast(s.len));
}

fn setCode(ip: *Interp, o: *Obj) void {
    obj.incr(o);
    if (ip.err_code) |old| obj.decr(old);
    ip.err_code = o;
}

/// Gets the error state of ztcl after a failed call of the host.
pub fn takeError(ip: *Interp) void {
    const get = host.host.err_get orelse return;
    if (get(ip.handle) != 0) return;
    const l = host.objOf(host.reply);
    obj.incr(l);
    defer obj.decr(l);
    var n: c_int = 0;
    var v: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(null, l, &n, &v) != OK or n != 3) return;
    setCode(ip, v[0]);
    obj.incr(v[1]);
    if (ip.err_info) |old| obj.decr(old);
    ip.err_info = v[1];
    var line: c_int = 0;
    _ = obj.Tcl_GetIntFromObj(null, v[2], &line);
    ip.error_line_dont_use = line;
}

/// Gives ztcl the error state of a command that ends with `code`
/// (TCL_ERROR or TCL_RETURN).
pub fn giveError(ip: *Interp, code: c_int) void {
    const set = host.host.err_set orelse return;
    const l = obj.Tcl_NewListObj(0, null);
    obj.incr(l);
    defer obj.decr(l);
    const items = [_]*Obj{
        // An empty code keeps the code of ztcl, such as the code of a
        // cancel that Tcl_Canceled gave.
        ip.err_code orelse newText(""),
        ip.err_info orelse newText(""),
        obj.Tcl_NewIntObj(@intFromBool(ip.err_info != null)),
        obj.Tcl_NewIntObj(ip.error_line_dont_use),
        obj.Tcl_NewIntObj(if (code == RETURN) ip.ret_code else code),
        obj.Tcl_NewIntObj(if (code == RETURN) ip.ret_level else 0),
    };
    for (items) |o| _ = obj.Tcl_ListObjAppendElement(null, l, o);
    const a = host.argOf(l);
    _ = set(ip.handle, &a);
}

/// Sets the error code to the list of `words`.
pub fn setErrorCodeWords(ip: *Interp, words: []const []const u8) void {
    const l = obj.Tcl_NewListObj(0, null);
    for (words) |w| _ = obj.Tcl_ListObjAppendElement(null, l, newText(w));
    setCode(ip, l);
}

pub fn Tcl_SetObjErrorCode(ip: *Interp, o: *Obj) callconv(.c) void {
    setCode(ip, o);
}

fn errorCodeOf(ap: *std.builtin.VaList) callconv(.c) *Obj {
    const l = obj.Tcl_NewListObj(0, null);
    while (true) {
        const p = @cVaArg(ap, ?[*:0]const u8) orelse break;
        _ = obj.Tcl_ListObjAppendElement(null, l, newText(std.mem.span(p)));
    }
    return l;
}

pub fn Tcl_SetErrorCode(ip: *Interp, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    setCode(ip, errorCodeOf(&ap));
}

pub fn Tcl_SetErrorCodeVA(ip: *Interp, va: obj.VaArg) callconv(.c) void {
    var arg = va;
    setCode(ip, errorCodeOf(obj.vaList(&arg)));
}

/// Starts the error info from the result, as Tcl does on the first
/// append. The error code is NONE when the package set none.
fn startInfo(ip: *Interp) *Obj {
    if (ip.err_info) |i| {
        if (i.refCount > 1) {
            const d = obj.Tcl_DuplicateObj(i);
            obj.incr(d);
            obj.decr(i);
            ip.err_info = d;
        }
        return ip.err_info.?;
    }
    const legacy = std.mem.span(ip.result_dont_use);
    const i = newText(if (legacy.len != 0) legacy else obj.text(obj.result(ip)));
    obj.incr(i);
    ip.err_info = i;
    if (ip.err_code == null) setCode(ip, newText("NONE"));
    return i;
}

pub fn Tcl_AddObjErrorInfo(ip: *Interp, msg: [*]const u8, len: c_int) callconv(.c) void {
    const i = startInfo(ip);
    const n: usize = if (len < 0) std.mem.len(@as([*:0]const u8, @ptrCast(msg))) else @intCast(len);
    if (n != 0) obj.appendText(i, msg[0..n]);
}

pub fn Tcl_AddErrorInfo(ip: *Interp, msg: [*:0]const u8) callconv(.c) void {
    Tcl_AddObjErrorInfo(ip, msg, -1);
}

pub fn Tcl_AppendObjToErrorInfo(ip: *Interp, o: *Obj) callconv(.c) void {
    obj.incr(o);
    defer obj.decr(o);
    const t = obj.text(o);
    Tcl_AddObjErrorInfo(ip, t.ptr, @intCast(t.len));
}

pub fn Tcl_GetErrorLine(ip: *Interp) callconv(.c) c_int {
    return ip.error_line_dont_use;
}

pub fn Tcl_SetErrorLine(ip: *Interp, line: c_int) callconv(.c) void {
    ip.error_line_dont_use = line;
}

/// Adds the text of the command that failed to the error info, as the
/// evaluator of Tcl does: "while executing" at the start, else "invoked
/// from within", with the first 150 bytes of the command.
pub fn Tcl_LogCommandInfo(ip: *Interp, _: [*]const u8, command: [*]const u8, length: c_int) callconv(.c) void {
    const first = ip.err_info == null;
    const n: usize = if (length < 0) std.mem.len(@as([*:0]const u8, @ptrCast(command))) else @intCast(length);
    const cut = @min(n, 150);
    _ = startInfo(ip);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, if (first) "\n    while executing\n\"" else "\n    invoked from within\n\"") catch return;
    buf.appendSlice(gpa, command[0..cut]) catch return;
    if (cut < n) buf.appendSlice(gpa, "...") catch return;
    buf.append(gpa, '"') catch return;
    Tcl_AddObjErrorInfo(ip, buf.items.ptr, @intCast(buf.items.len));
}

fn appendPair(l: *Obj, key: []const u8, v: *Obj) void {
    _ = obj.Tcl_ListObjAppendElement(null, l, newText(key));
    _ = obj.Tcl_ListObjAppendElement(null, l, v);
}

/// The return options of `code`, as a dictionary with no reference.
pub fn Tcl_GetReturnOptions(ip: *Interp, code: c_int) callconv(.c) *Obj {
    const l = obj.Tcl_NewListObj(0, null);
    if (code == RETURN) {
        appendPair(l, "-code", obj.Tcl_NewIntObj(ip.ret_code));
        appendPair(l, "-level", obj.Tcl_NewIntObj(ip.ret_level));
    } else {
        appendPair(l, "-code", obj.Tcl_NewIntObj(code));
        appendPair(l, "-level", obj.Tcl_NewIntObj(0));
    }
    if (code == ERROR) {
        const i = startInfo(ip);
        appendPair(l, "-errorcode", ip.err_code.?);
        appendPair(l, "-errorinfo", i);
        appendPair(l, "-errorline", obj.Tcl_NewIntObj(ip.error_line_dont_use));
    }
    return l;
}

const code_names = [_][]const u8{ "ok", "error", "return", "break", "continue" };

fn fail(ip: *Interp, code: []const u8, msg: []const u8) c_int {
    obj.setResultText(ip, msg);
    setCode(ip, newText(code));
    return ERROR;
}

/// Sets the return options of `opts` and gives the code of a command
/// that ends with them, as `return -options` does.
pub fn Tcl_SetReturnOptions(ip: *Interp, opts: *Obj) callconv(.c) c_int {
    obj.incr(opts);
    defer obj.decr(opts);
    var n: c_int = 0;
    var v: [*]*Obj = undefined;
    if (obj.Tcl_ListObjGetElements(ip, opts, &n, &v) != OK) return ERROR;
    if (@rem(n, 2) != 0) return fail(ip, "TCL RESULT ILLEGAL_OPTIONS", "missing value in return options dictionary");
    var code: c_int = OK;
    var level: c_int = 1;
    var ecode: ?*Obj = null;
    var info: ?*Obj = null;
    var line: ?c_int = null;
    var i: usize = 0;
    while (i < n) : (i += 2) {
        const k = obj.text(v[i]);
        const x = v[i + 1];
        if (std.mem.eql(u8, k, "-code")) {
            const t = obj.text(x);
            code = for (code_names, 0..) |cn, j| {
                if (std.mem.eql(u8, t, cn)) break @intCast(j);
            } else blk: {
                var c: c_int = 0;
                if (obj.Tcl_GetIntFromObj(null, x, &c) != OK) {
                    var buf: [200]u8 = undefined;
                    const m = std.fmt.bufPrint(&buf, "bad completion code \"{s}\": must be ok, error, return, break, continue, or an integer", .{t[0..@min(t.len, 100)]}) catch "bad completion code";
                    return fail(ip, "TCL RESULT ILLEGAL_CODE", m);
                }
                break :blk c;
            };
        } else if (std.mem.eql(u8, k, "-level")) {
            if (obj.Tcl_GetIntFromObj(null, x, &level) != OK or level < 0) {
                var buf: [200]u8 = undefined;
                const t = obj.text(x);
                const m = std.fmt.bufPrint(&buf, "bad -level value: expected non-negative integer but got \"{s}\"", .{t[0..@min(t.len, 100)]}) catch "bad -level value";
                return fail(ip, "TCL RESULT ILLEGAL_LEVEL", m);
            }
        } else if (std.mem.eql(u8, k, "-errorcode")) {
            ecode = x;
        } else if (std.mem.eql(u8, k, "-errorinfo")) {
            info = x;
        } else if (std.mem.eql(u8, k, "-errorline")) {
            var l: c_int = 0;
            if (obj.Tcl_GetIntFromObj(null, x, &l) == OK) line = l;
        }
    }
    if (code == ERROR) {
        setCode(ip, ecode orelse newText("NONE"));
        if (info) |o| {
            const d = obj.Tcl_DuplicateObj(o);
            obj.incr(d);
            if (ip.err_info) |old| obj.decr(old);
            ip.err_info = d;
        }
        if (line) |l| ip.error_line_dont_use = l;
    }
    if (level == 0) return code;
    ip.ret_code = code;
    ip.ret_level = level;
    return RETURN;
}

pub fn Tcl_AllowExceptions(ip: *Interp) callconv(.c) void {
    ip.allow_exceptions = true;
}

/// The name of the errno value `e`, such as "ENOENT".
fn errnoName(e: c_int) ?[]const u8 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .freestanding) return null;
    const E = std.posix.E;
    const info = @typeInfo(E).@"enum";
    inline for (info.field_names, info.field_values) |name, val| {
        if (val == e and val != 0) return "E" ++ name;
    }
    return null;
}

threadlocal var errno_id: [32]u8 = undefined;

pub fn Tcl_ErrnoId() callconv(.c) [*:0]const u8 {
    const n = errnoName(cchan.Tcl_GetErrno()) orelse return "unknown error";
    const k = @min(n.len, errno_id.len - 1);
    @memcpy(errno_id[0..k], n[0..k]);
    errno_id[k] = 0;
    return errno_id[0..k :0];
}

/// Sets the error code {POSIX NAME message} of errno and gives the
/// message.
pub fn Tcl_PosixError(ip: *Interp) callconv(.c) [*:0]const u8 {
    const e = cchan.Tcl_GetErrno();
    const id = std.mem.span(Tcl_ErrnoId());
    const msg = cchan.Tcl_ErrnoMsg(e);
    const l = obj.Tcl_NewListObj(0, null);
    _ = obj.Tcl_ListObjAppendElement(null, l, newText("POSIX"));
    _ = obj.Tcl_ListObjAppendElement(null, l, newText(id));
    _ = obj.Tcl_ListObjAppendElement(null, l, newText(std.mem.span(msg)));
    setCode(ip, l);
    return msg;
}

/// The signals of Tcl, with the text of Tcl_SignalMsg.
const signals = [_]struct { []const u8, []const u8 }{
    .{ "ABRT", "SIGABRT" },
    .{ "ALRM", "alarm clock" },
    .{ "BUS", "bus error" },
    .{ "CHLD", "child status changed" },
    .{ "CONT", "continue after stop" },
    .{ "FPE", "floating-point exception" },
    .{ "HUP", "hangup" },
    .{ "ILL", "illegal instruction" },
    .{ "INT", "interrupt" },
    .{ "IO", "input/output possible on file" },
    .{ "KILL", "kill signal" },
    .{ "PIPE", "write on pipe with no readers" },
    .{ "PROF", "profiling alarm" },
    .{ "PWR", "power-fail restart" },
    .{ "QUIT", "quit signal" },
    .{ "SEGV", "segmentation violation" },
    .{ "STOP", "stop" },
    .{ "SYS", "bad argument to system call" },
    .{ "TERM", "software termination signal" },
    .{ "TRAP", "trace trap" },
    .{ "TSTP", "stop signal from tty" },
    .{ "TTIN", "background tty read" },
    .{ "TTOU", "background tty write" },
    .{ "URG", "urgent I/O condition" },
    .{ "USR1", "user-defined signal 1" },
    .{ "USR2", "user-defined signal 2" },
    .{ "VTALRM", "virtual time alarm" },
    .{ "WINCH", "window changed" },
    .{ "XCPU", "exceeded CPU time limit" },
    .{ "XFSZ", "exceeded file size limit" },
};

const has_signals = builtin.os.tag != .windows and builtin.os.tag != .wasi and builtin.os.tag != .freestanding;

fn signalIndex(sig: c_int) ?usize {
    if (comptime !has_signals) return null;
    const SIG = std.posix.SIG;
    const is_enum = @typeInfo(SIG) == .@"enum";
    inline for (signals, 0..) |s, i| {
        if (if (is_enum) @hasField(SIG, s[0]) else @hasDecl(SIG, s[0])) {
            const f = @field(SIG, s[0]);
            const n: c_int = @intCast(if (is_enum) @backingInt(f) else f);
            if (n == sig) return i;
        }
    }
    return null;
}

const signal_ids = blk: {
    var out: [signals.len][:0]const u8 = undefined;
    for (signals, 0..) |s, i| out[i] = "SIG" ++ s[0];
    break :blk out;
};

const signal_msgs = blk: {
    var out: [signals.len][:0]const u8 = undefined;
    for (signals, 0..) |s, i| out[i] = s[1] ++ "";
    break :blk out;
};

pub fn Tcl_SignalId(sig: c_int) callconv(.c) [*:0]const u8 {
    const i = signalIndex(sig) orelse return "unknown signal";
    return signal_ids[i];
}

pub fn Tcl_SignalMsg(sig: c_int) callconv(.c) [*:0]const u8 {
    const i = signalIndex(sig) orelse return "unknown signal";
    return signal_msgs[i];
}

/// Queues a background error of ztcl with the message and the error
/// code of the result of `ip`. The bgerror handler of ztcl gets it.
pub fn Tcl_BackgroundException(ip: *Interp, code: c_int) callconv(.c) void {
    if (code == OK) return;
    const msg = obj.result(ip);
    obj.incr(msg);
    defer obj.decr(msg);
    const ecode = ip.err_code orelse newText("NONE");
    obj.incr(ecode);
    defer obj.decr(ecode);
    const words = obj.Tcl_NewListObj(0, null);
    obj.incr(words);
    defer obj.decr(words);
    _ = obj.Tcl_ListObjAppendElement(null, words, newText("::error"));
    _ = obj.Tcl_ListObjAppendElement(null, words, msg);
    _ = obj.Tcl_ListObjAppendElement(null, words, if (ip.err_info) |i| i else msg);
    _ = obj.Tcl_ListObjAppendElement(null, words, ecode);
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    script.appendSlice(gpa, "::after idle ") catch return;
    // The list text of {::error msg info code} is one word of `after`.
    const t = obj.text(words);
    const one = obj.Tcl_NewListObj(0, null);
    obj.incr(one);
    defer obj.decr(one);
    _ = obj.Tcl_ListObjAppendElement(null, one, newText(t));
    script.appendSlice(gpa, obj.text(one)) catch return;
    // The script must not change the result or the error state of `ip`.
    const saved_code = ip.err_code;
    const saved_info = ip.err_info;
    const saved_line = ip.error_line_dont_use;
    ip.err_code = null;
    ip.err_info = null;
    const keep = obj.result(ip);
    obj.incr(keep);
    _ = host.host.eval(ip.handle, script.items.ptr, script.items.len, host.TCL_EVAL_GLOBAL);
    obj.Tcl_SetObjResult(ip, keep);
    obj.decr(keep);
    ip.err_code = saved_code;
    ip.err_info = saved_info;
    ip.error_line_dont_use = saved_line;
}
