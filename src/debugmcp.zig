//! `ztcl debug --mcp`: the tools of `ztcl debug` for agents, over the
//! Model Context Protocol on stdin and stdout.
//!
//! Each request is one line of JSON-RPC 2.0. The server answers
//! `initialize`, `ping`, `tools/list`, and `tools/call`, and ignores each
//! notification. The tools run in one interpreter, with the capabilities
//! and the limits of the runner options. `ztcl_run` and `ztcl_explain`
//! reset the interpreter first, so each run starts new. `ztcl_records`
//! and `ztcl_eval` read the state of the last run, and `ztcl_disasm`
//! gives the bytecode of one of its procs. The output of `puts`
//! goes into the answer of the tool, because stdout has the protocol.
//! Each answer stops at the byte budget of the tool (`budget`).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const debug = @import("debug.zig");
const probe = @import("probe.zig");
const value = @import("value.zig");

const Interp = interp.Interp;
const Allocator = std.mem.Allocator;
const json = std.json;

/// Reads a script file for a tool.
pub const ReadFn = *const fn (ctx: ?*anyopaque, path: []const u8, a: Allocator) anyerror![]u8;

pub const Server = struct {
    it: *Interp,
    gpa: Allocator,
    read: ReadFn,
    read_ctx: ?*anyopaque = null,
    /// The output of `puts` during a tool call.
    captured: std.ArrayList(u8) = .empty,
    version: []const u8 = "1.0",
};

fn capture(ctx: ?*anyopaque, bytes: []const u8) void {
    const s: *Server = @ptrCast(@alignCast(ctx.?));
    if (s.captured.items.len + bytes.len > 1 << 20) return;
    s.captured.appendSlice(s.gpa, bytes) catch {};
}

const tools_json =
    \\[{"name":"ztcl_run","description":"Runs a Tcl script with probes and gives a short report: the status, the error with the stack and the locals, the probes, and the last records. Give path or script.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"The script file."},"script":{"type":"string","description":"The script text."},"probes":{"type":"array","items":{"type":"string"},"description":"The words of `ztcl::probe add` for each probe, such as \"-proc parse -line 4 -capture {i [llength $toks]}\"."},"budget":{"type":"integer","description":"The most bytes of the answer. The default is 4000."},"detail":{"type":"string","enum":["summary","stack","changes","records","all"]},"last":{"type":"integer","description":"The count of records. The default is 10."}}}},
    \\{"name":"ztcl_explain","description":"Runs a Tcl script, and after an error runs it again with a probe on each line of the proc of the error. Gives the error, the stack with the locals, and the last changes of the variables of the failed command, with the line of each change.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"script":{"type":"string"},"probes":{"type":"array","items":{"type":"string"}},"budget":{"type":"integer"},"detail":{"type":"string","enum":["summary","stack","changes","records","all"]}}}},
    \\{"name":"ztcl_records","description":"Gives the probe records of the last run as JSON lines, with an optional filter. A bare name in where is a field or a captured value, such as \"n > 10\".","inputSchema":{"type":"object","properties":{"where":{"type":"string"},"probe":{"type":"string","description":"A probe id such as p2."},"last":{"type":"integer"},"since":{"type":"integer"},"budget":{"type":"integer"}}}},
    \\{"name":"ztcl_eval","description":"Evaluates Tcl code in the interpreter of the last run, for example to read a global variable or to add a probe for the next records.","inputSchema":{"type":"object","properties":{"code":{"type":"string"},"budget":{"type":"integer"}},"required":["code"]}},
    \\{"name":"ztcl_disasm","description":"Gives the bytecode of a proc of the last run, or of a script, under the source line of each command, with the state of the JIT (ztcl::disasm). Give proc or script.","inputSchema":{"type":"object","properties":{"proc":{"type":"string"},"script":{"type":"string"},"budget":{"type":"integer"}}}}]
;

/// Serves requests from `in` until the end of the input.
pub fn serve(s: *Server, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    s.it.output = .{ .ctx = s, .write = capture };
    while (true) {
        const line = in.takeDelimiterExclusive('\n') catch break;
        _ = in.take(1) catch {};
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const answer = handle(s, a, line) catch |e| try errorAnswer(a, null, -32603, @errorName(e));
        if (answer) |text| {
            try out.writeAll(text);
            try out.writeAll("\n");
            try out.flush();
        }
    }
}

fn errorAnswer(a: Allocator, id: ?json.Value, code: i32, msg: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(a, &o, id);
    try o.print(a, ",\"error\":{{\"code\":{d},\"message\":", .{code});
    try probe.jsonString(a, &o, msg);
    try o.appendSlice(a, "}}");
    return o.items;
}

fn writeId(a: Allocator, o: *std.ArrayList(u8), id: ?json.Value) !void {
    const v = id orelse return o.appendSlice(a, "null");
    switch (v) {
        .integer => |n| try o.print(a, "{d}", .{n}),
        .string => |t| try probe.jsonString(a, o, t),
        else => try o.appendSlice(a, "null"),
    }
}

fn result(a: Allocator, id: ?json.Value, body: []const u8) ![]const u8 {
    var o: std.ArrayList(u8) = .empty;
    try o.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(a, &o, id);
    try o.appendSlice(a, ",\"result\":");
    try o.appendSlice(a, body);
    try o.append(a, '}');
    return o.items;
}

/// The answer to one line, or null for a notification.
fn handle(s: *Server, a: Allocator, line: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;
    const req = json.parseFromSliceLeaky(json.Value, a, trimmed, .{}) catch return try errorAnswer(a, null, -32700, "parse error");
    if (req != .object) return try errorAnswer(a, null, -32600, "invalid request");
    const id = req.object.get("id");
    const method_v = req.object.get("method") orelse return try errorAnswer(a, id, -32600, "no method");
    if (method_v != .string) return try errorAnswer(a, id, -32600, "no method");
    const method = method_v.string;
    if (id == null) return null;
    if (std.mem.eql(u8, method, "initialize")) {
        var proto: []const u8 = "2025-06-18";
        if (req.object.get("params")) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
            proto = v.string;
        };
        var o: std.ArrayList(u8) = .empty;
        try o.appendSlice(a, "{\"protocolVersion\":");
        try probe.jsonString(a, &o, proto);
        try o.appendSlice(a, ",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"ztcl-debug\",\"version\":");
        try probe.jsonString(a, &o, s.version);
        try o.appendSlice(a, "}}");
        return try result(a, id, o.items);
    }
    if (std.mem.eql(u8, method, "ping")) return try result(a, id, "{}");
    if (std.mem.eql(u8, method, "tools/list")) {
        // A message is one line, so the lines of the table join.
        const tools = try std.mem.replaceOwned(u8, a, tools_json, "\n", "");
        return try result(a, id, try std.fmt.allocPrint(a, "{{\"tools\":{s}}}", .{tools}));
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = req.object.get("params") orelse return try errorAnswer(a, id, -32602, "no params");
        if (params != .object) return try errorAnswer(a, id, -32602, "no params");
        const name = params.object.get("name") orelse return try errorAnswer(a, id, -32602, "no tool name");
        if (name != .string) return try errorAnswer(a, id, -32602, "no tool name");
        const args: ?json.ObjectMap = if (params.object.get("arguments")) |v| (if (v == .object) v.object else null) else null;
        var failed = false;
        const text = call(s, a, name.string, args, &failed) catch |e| blk: {
            failed = true;
            break :blk try std.fmt.allocPrint(a, "the tool failed: {s}", .{@errorName(e)});
        };
        var o: std.ArrayList(u8) = .empty;
        try o.appendSlice(a, "{\"content\":[{\"type\":\"text\",\"text\":");
        try probe.jsonString(a, &o, text);
        try o.print(a, "}}],\"isError\":{s}}}", .{if (failed) "true" else "false"});
        return try result(a, id, o.items);
    }
    return try errorAnswer(a, id, -32601, "unknown method");
}

fn str(args: ?json.ObjectMap, key: []const u8) ?[]const u8 {
    const m = args orelse return null;
    const v = m.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(args: ?json.ObjectMap, key: []const u8) ?usize {
    const m = args orelse return null;
    const v = m.get(key) orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}

/// Runs a tool and gives its text. `failed` is true for an error of the
/// tool or of the script.
fn call(s: *Server, a: Allocator, name: []const u8, args: ?json.ObjectMap, failed: *bool) ![]const u8 {
    const it = s.it;
    const budget = int(args, "budget") orelse 4000;
    s.captured.clearRetainingCapacity();
    if (std.mem.eql(u8, name, "ztcl_run") or std.mem.eql(u8, name, "ztcl_explain")) {
        var opts: debug.Options = .{ .explain = std.mem.eql(u8, name, "ztcl_explain"), .budget = budget };
        if (str(args, "detail")) |d| opts.detail = std.meta.stringToEnum(debug.Detail, d) orelse .summary;
        if (int(args, "last")) |n| opts.last = n;
        var specs: std.ArrayList([]const u8) = .empty;
        if (args) |m| if (m.get("probes")) |v| if (v == .array) for (v.array.items) |p| {
            if (p == .string) try specs.append(a, p.string);
        };
        opts.probes = specs.items;
        const text = if (str(args, "script")) |t| t else if (str(args, "path")) |p| s.read(s.read_ctx, p, a) catch |e| {
            failed.* = true;
            return std.fmt.allocPrint(a, "{s}: {s}", .{ p, @errorName(e) });
        } else {
            failed.* = true;
            return "give path or script";
        };
        try it.reset();
        var rep = debug.run(it, text, opts) catch |e| {
            failed.* = true;
            if (e == error.TclError) return std.fmt.allocPrint(a, "probe error: {s}", .{it.str(it.result) catch ""});
            return e;
        };
        defer rep.deinit();
        if (!rep.ok) failed.* = true;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, try debug.writeText(a, &rep, opts));
        if (s.captured.items.len > 0) {
            const room = budget -| out.items.len;
            try out.appendSlice(a, "output:\n");
            if (s.captured.items.len <= room) {
                try out.appendSlice(a, s.captured.items);
            } else {
                try out.appendSlice(a, s.captured.items[0..room]);
                try out.print(a, "\n... {d} bytes of output left out\n", .{s.captured.items.len - room});
            }
        }
        return out.items;
    }
    if (std.mem.eql(u8, name, "ztcl_records")) {
        if (it.probes == null) return "no run has records yet";
        var q: probe.Query = .{ .last = int(args, "last") orelse 20 };
        if (int(args, "since")) |n| q.since = n;
        if (str(args, "probe")) |p| q.probe = std.fmt.parseInt(u32, std.mem.trimStart(u8, p, "p"), 10) catch null;
        var text: []const u8 = undefined;
        if (str(args, "where")) |w| {
            var words: std.ArrayList(interp.Value) = .empty;
            const ia = it.alloc();
            try words.appendSlice(ia, &.{ .{ .str = "ztcl::probe" }, .{ .str = "records" }, .{ .str = "-json" }, .{ .str = "-where" }, .{ .str = try ia.dupe(u8, w) }, .{ .str = "-last" }, .{ .int = @intCast(q.last.?) } });
            if (q.since) |n| try words.appendSlice(ia, &.{ .{ .str = "-since" }, .{ .int = @intCast(n) } });
            if (q.probe) |n| try words.appendSlice(ia, &.{ .{ .str = "-probe" }, .{ .int = n } });
            const v = it.callWords(words.items) catch {
                failed.* = true;
                return std.fmt.allocPrint(a, "error: {s}", .{it.str(it.result) catch ""});
            };
            text = try a.dupe(u8, try it.str(v));
        } else {
            var o: std.ArrayList(u8) = .empty;
            for (try probe.select(it, q)) |r| {
                try probe.writeJson(a, &o, r);
                try o.append(a, '\n');
            }
            text = o.items;
        }
        if (text.len == 0) return "no records match";
        return clipText(a, text, budget);
    }
    if (std.mem.eql(u8, name, "ztcl_eval")) {
        const code = str(args, "code") orelse {
            failed.* = true;
            return "give code";
        };
        const v = it.eval(code) catch {
            failed.* = true;
            return clipText(a, try std.fmt.allocPrint(a, "error: {s}\n{s}", .{ it.str(it.result) catch "", s.captured.items }), budget);
        };
        return clipText(a, try std.fmt.allocPrint(a, "{s}{s}", .{ s.captured.items, try it.str(v) }), budget);
    }
    if (std.mem.eql(u8, name, "ztcl_disasm")) {
        if (comptime !@import("disasm.zig").enabled) {
            failed.* = true;
            return "this build has no ztcl::disasm";
        }
        const kind: []const u8, const arg = if (str(args, "proc")) |p| .{ "proc", p } else if (str(args, "script")) |t| .{ "script", t } else {
            failed.* = true;
            return "give proc or script";
        };
        const words = try value.listToString(a, &.{ .{ .str = "ztcl::disasm" }, .{ .str = kind }, .{ .str = arg } });
        const v = it.eval(try std.fmt.allocPrint(a, "package require ztcl::disasm\n{s}", .{words})) catch {
            failed.* = true;
            return clipText(a, try std.fmt.allocPrint(a, "error: {s}", .{it.str(it.result) catch ""}), budget);
        };
        return clipText(a, try it.str(v), budget);
    }
    failed.* = true;
    return std.fmt.allocPrint(a, "unknown tool \"{s}\"", .{name});
}

fn clipText(a: Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}\n... {d} bytes left out: use a larger budget, -last, or where\n", .{ text[0..end], text.len - end });
}
