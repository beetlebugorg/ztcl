//! The command `dom` of `ztcl-host.wasm` (#85, task 01 of
//! docs/dev/dom-tasks/README.md): reads and writes of the DOM of the page
//! below a root element that the host gives.
//!
//!   dom query ?el? selector        the first match, or ""
//!   dom queryAll ?el? selector     a list of the matches
//!   dom text el ?value?            the text of an element
//!   dom attr el name ?value?       an attribute ("" when it is absent)
//!
//! An element is a handle `domN`. The table of handles is in
//! `web/ztcl.mjs`, so Tcl never gets a pointer, and an omitted `el` is
//! the root. Each command makes one call of the import
//! `ztcl_host.dom(op, handle, a, a_len, b, b_len)`. The host gives an
//! integer, and for text it puts a reply into the memory of the module
//! (`ztcl_alloc`) and its address and length into `reply`. A negative
//! integer is an error, with the message in the reply. The host checks
//! that each handle is the root or below it. Each call costs one compute
//! unit. The command exists only after `ztcl_dom_allow`, so it is absent
//! by default and in `ztcl.wasm`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");
const Interp = ztcl.Interp;
const Value = ztcl.Value;
const Error = ztcl.interp.Error;

pub const Op = enum(u32) { query = 1, query_all = 2, text_get = 3, text_set = 4, attr_get = 5, attr_set = 6 };

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
            return it.fail("bad subcommand \"{s}\": must be attr, query, queryAll, or text", .{sub});
        }

        pub fn register(it: *Interp) std.mem.Allocator.Error!void {
            try it.register("dom", cmdDom);
        }
    };
}
