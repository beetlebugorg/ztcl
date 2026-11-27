//! The command `dom` of `ztcl-host.wasm` (#85, tasks 01 and 02 of
//! docs/dev/dom-tasks/README.md): reads and writes of the DOM of the page
//! below a root element that the host gives.
//!
//!   dom query ?el? selector        the first match, or ""
//!   dom queryAll ?el? selector     a list of the matches
//!   dom text el ?value?            the text of an element
//!   dom attr el name ?value?       an attribute ("" when it is absent)
//!   dom class el action name       add, remove, toggle (gives 0 or 1), has
//!   dom style el property ?value?  one property of the inline style
//!   dom value el ?value?           the value of a form element (0 or 1
//!                                  for a checkbox or a radio button)
//!   dom focus el                   moves the focus to the element
//!   dom create tag                 a new element, not in the page yet
//!   dom append parent child        puts child at the end of parent
//!   dom remove el                  takes the element out; the handle ends
//!   dom html el ?value?            the inner HTML; a set needs `dom-html`
//!   dom on el event script         runs script for each event of el
//!   dom off el event               ends the script of `dom on`
//!
//! An element is a handle `domN`. A tree of new elements is in scope
//! before `dom append` puts it below the root. The host gives an error
//! for the elements and the attributes that can run code: `script`,
//! `iframe`, `object`, and the like, each `on...` attribute, and
//! `javascript:` URLs. A set of `dom html` needs the grant `dom-html`.
//! The table of handles is in `web/ztcl.mjs`, so Tcl never gets a
//! pointer, and an omitted `el` is the root. Each command makes one call of the import
//! `ztcl_host.dom(op, handle, a, a_len, b, b_len)`. The host gives an
//! integer, and for text it puts a reply into the memory of the module
//! (`ztcl_alloc`) and its address and length into `reply`. A negative
//! integer is an error, with the message in the reply. The host checks
//! that each handle is in scope. Each call costs one compute
//! unit. The command exists only after `ztcl_dom_allow`, so it is absent
//! by default and in `ztcl.wasm`.
//!
//! The host keeps the scripts of `dom on` and puts each event in a
//! queue. `Interp.runEvents` of `web/ztcl.mjs` gives each event of the
//! queue to `runEvent`, which puts the values of the event in place of
//! `%x`, `%y`, `%key`, `%value`, and `%target` (`%%` is one `%`) and
//! runs the script at the global level.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const Interp = ztcl.Interp;
const Value = ztcl.Value;
const Error = ztcl.interp.Error;

pub const Op = enum(u32) {
    query = 1,
    query_all = 2,
    text_get = 3,
    text_set = 4,
    attr_get = 5,
    attr_set = 6,
    class = 7,
    style_get = 8,
    style_set = 9,
    value_get = 10,
    value_set = 11,
    focus = 12,
    create = 13,
    append = 14,
    remove = 15,
    html_get = 16,
    html_set = 17,
    on = 18,
    off = 19,
};

/// The names of the substitutions of `dom on`, in the order of the
/// values of `runEvent`.
pub const subs = [_][]const u8{ "x", "y", "key", "value", "target" };

/// Gives `script` with each `%name` of `subs` replaced by its value as
/// one list element, and `%%` replaced by `%`.
pub fn substitute(a: std.mem.Allocator, script: []const u8, vals: [subs.len][]const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    outer: while (k < script.len) {
        if (script[k] == '%' and k + 1 < script.len) {
            if (script[k + 1] == '%') {
                try out.append(a, '%');
                k += 2;
                continue;
            }
            // The longest name first: `%key` and `%x` do not share a start.
            for (subs, 0..) |n, j| {
                if (std.mem.startsWith(u8, script[k + 1 ..], n)) {
                    try ztcl.value.appendElement(a, &out, vals[j], true);
                    k += 1 + n.len;
                    continue :outer;
                }
            }
        }
        try out.append(a, script[k]);
        k += 1;
    }
    return out.toOwnedSlice(a);
}

/// Runs the script of one DOM event with the values of `subs`, at the
/// global level.
pub fn runEvent(it: *Interp, script: []const u8, vals: [subs.len][]const u8) Error!Value {
    const text = try substitute(it.alloc(), script, vals);
    const frame = it.frame;
    const ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    defer {
        it.frame = frame;
        it.ns = ns;
    }
    return it.eval(text);
}

const host = struct {
    extern "ztcl_host" fn dom(op: u32, handle: i32, a: [*]const u8, a_len: usize, b: [*]const u8, b_len: usize) i32;
};

/// The reply of the last call: the address and the length of bytes that
/// the host put in the memory of the module with `ztcl_alloc`.
pub export var ztcl_dom_reply: [2]u32 = .{ 0, 0 };

fn call(it: *Interp, gpa: std.mem.Allocator, op: Op, handle: i32, a: []const u8, b: []const u8) Error!struct { rc: i32, text: []const u8 } {
    if (it.compute_limit == 0) return it.fail("compute limit reached", .{});
    if (it.compute_limit != std.math.maxInt(u64)) it.compute_limit -= 1;
    ztcl_dom_reply = .{ 0, 0 };
    const rc = host.dom(@backingInt(op), handle, a.ptr, a.len, b.ptr, b.len);
    var text: []const u8 = "";
    if (ztcl_dom_reply[1] > 0) {
        const p: [*]u8 = @ptrFromInt(ztcl_dom_reply[0]);
        const bytes = p[0..ztcl_dom_reply[1]];
        text = try it.alloc().dupe(u8, bytes);
        gpa.free(bytes);
    }
    if (rc < 0) return it.fail("{s}", .{text});
    return .{ .rc = rc, .text = text };
}

fn handleOf(it: *Interp, v: Value) Error!i32 {
    const s = try it.str(v);
    if (std.mem.startsWith(u8, s, "dom")) {
        if (std.fmt.parseInt(i32, s[3..], 10)) |n| {
            if (n > 0) return n;
        } else |_| {}
    }
    return it.fail("invalid DOM handle \"{s}\"", .{s});
}

fn name(it: *Interp, n: i32) Error!Value {
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "dom{d}", .{n}) };
}

pub fn Commands(comptime gpa: std.mem.Allocator) type {
    return struct {
        fn cmdDom(it: *Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) Error!Value {
            if (argv.len < 2) return it.wrongArgs("dom subcommand ?arg ...?");
            const sub = try it.str(argv[1]);
            const args = argv[2..];
            if (std.mem.eql(u8, sub, "query") or std.mem.eql(u8, sub, "queryAll")) {
                if (args.len < 1 or args.len > 2) {
                    if (sub.len == 5) return it.wrongArgs("dom query ?el? selector");
                    return it.wrongArgs("dom queryAll ?el? selector");
                }
                const el: i32 = if (args.len == 2) try handleOf(it, args[0]) else 0;
                const sel = try it.str(args[args.len - 1]);
                if (sub.len == 5) {
                    const r = try call(it, gpa, .query, el, sel, "");
                    return if (r.rc == 0) Value.empty else name(it, r.rc);
                }
                const r = try call(it, gpa, .query_all, el, sel, "");
                var list: std.ArrayList(Value) = .empty;
                var words = std.mem.tokenizeScalar(u8, r.text, ' ');
                while (words.next()) |w| {
                    const n = std.fmt.parseInt(i32, w, 10) catch continue;
                    try list.append(it.alloc(), try name(it, n));
                }
                return ztcl.value.wrapList(it.alloc(), list.items);
            }
            if (std.mem.eql(u8, sub, "text")) {
                if (args.len < 1 or args.len > 2) return it.wrongArgs("dom text el ?value?");
                const el = try handleOf(it, args[0]);
                if (args.len == 2) {
                    _ = try call(it, gpa, .text_set, el, try it.str(args[1]), "");
                    return Value.empty;
                }
                return .{ .str = (try call(it, gpa, .text_get, el, "", "")).text };
            }
            if (std.mem.eql(u8, sub, "attr")) {
                if (args.len < 2 or args.len > 3) return it.wrongArgs("dom attr el name ?value?");
                const el = try handleOf(it, args[0]);
                const attr = try it.str(args[1]);
                if (args.len == 3) {
                    _ = try call(it, gpa, .attr_set, el, attr, try it.str(args[2]));
                    return Value.empty;
                }
                return .{ .str = (try call(it, gpa, .attr_get, el, attr, "")).text };
            }
            if (std.mem.eql(u8, sub, "class")) {
                if (args.len != 3) return it.wrongArgs("dom class el add|remove|toggle|has name");
                const el = try handleOf(it, args[0]);
                const action = try it.str(args[1]);
                const known = [_][]const u8{ "add", "remove", "toggle", "has" };
                for (known) |k| {
                    if (!std.mem.eql(u8, action, k)) continue;
                    const r = try call(it, gpa, .class, el, action, try it.str(args[2]));
                    if (action[0] == 't' or action[0] == 'h') return .{ .int = r.rc };
                    return Value.empty;
                }
                return it.fail("bad action \"{s}\": must be add, has, remove, or toggle", .{action});
            }
            if (std.mem.eql(u8, sub, "style")) {
                if (args.len < 2 or args.len > 3) return it.wrongArgs("dom style el property ?value?");
                const el = try handleOf(it, args[0]);
                const prop = try it.str(args[1]);
                if (args.len == 3) {
                    _ = try call(it, gpa, .style_set, el, prop, try it.str(args[2]));
                    return Value.empty;
                }
                return .{ .str = (try call(it, gpa, .style_get, el, prop, "")).text };
            }
            if (std.mem.eql(u8, sub, "value")) {
                if (args.len < 1 or args.len > 2) return it.wrongArgs("dom value el ?value?");
                const el = try handleOf(it, args[0]);
                if (args.len == 2) {
                    _ = try call(it, gpa, .value_set, el, try it.str(args[1]), "");
                    return Value.empty;
                }
                return .{ .str = (try call(it, gpa, .value_get, el, "", "")).text };
            }
            if (std.mem.eql(u8, sub, "focus")) {
                if (args.len != 1) return it.wrongArgs("dom focus el");
                _ = try call(it, gpa, .focus, try handleOf(it, args[0]), "", "");
                return Value.empty;
            }
            if (std.mem.eql(u8, sub, "create")) {
                if (args.len != 1) return it.wrongArgs("dom create tag");
                return name(it, (try call(it, gpa, .create, 0, try it.str(args[0]), "")).rc);
            }
            if (std.mem.eql(u8, sub, "append")) {
                if (args.len != 2) return it.wrongArgs("dom append parent child");
                const parent = try handleOf(it, args[0]);
                const kid = try handleOf(it, args[1]);
                var buf: [12]u8 = undefined;
                _ = try call(it, gpa, .append, parent, "", std.fmt.bufPrint(&buf, "{d}", .{kid}) catch unreachable);
                return Value.empty;
            }
            if (std.mem.eql(u8, sub, "remove")) {
                if (args.len != 1) return it.wrongArgs("dom remove el");
                _ = try call(it, gpa, .remove, try handleOf(it, args[0]), "", "");
                return Value.empty;
            }
            if (std.mem.eql(u8, sub, "html")) {
                if (args.len < 1 or args.len > 2) return it.wrongArgs("dom html el ?value?");
                const el = try handleOf(it, args[0]);
                if (args.len == 2) {
                    _ = try call(it, gpa, .html_set, el, try it.str(args[1]), "");
                    return Value.empty;
                }
                return .{ .str = (try call(it, gpa, .html_get, el, "", "")).text };
            }
            if (std.mem.eql(u8, sub, "on")) {
                if (args.len != 3) return it.wrongArgs("dom on el event script");
                _ = try call(it, gpa, .on, try handleOf(it, args[0]), try it.str(args[1]), try it.str(args[2]));
                return Value.empty;
            }
            if (std.mem.eql(u8, sub, "off")) {
                if (args.len != 2) return it.wrongArgs("dom off el event");
                _ = try call(it, gpa, .off, try handleOf(it, args[0]), try it.str(args[1]), "");
                return Value.empty;
            }
            return it.fail("bad subcommand \"{s}\": must be append, attr, class, create, focus, html, off, on, query, queryAll, remove, style, text, or value", .{sub});
        }

        pub fn register(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("dom", cmdDom);
        }
    };
}
