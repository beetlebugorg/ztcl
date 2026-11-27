//! Tests of `ztcl debug` (`debug.zig`) and its MCP server
//! (`debugmcp.zig`), with no terminal and no process.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const tcl = @import("ztcl.zig");
const debug = @import("debug.zig");
const debugmcp = @import("debugmcp.zig");
const options = @import("build_options");

const average =
    \\proc average {items} {
    \\    set total 0
    \\    set n 0
    \\    foreach x $items {
    \\        incr total $x
    \\        if {$x < 0} { set n 0 } else { incr n }
    \\    }
    \\    return [expr {$total / $n}]
    \\}
    \\proc report {} {
    \\    puts "avg [average {4 6 8}]"
    \\    puts "avg [average {3 -3}]"
    \\}
    \\report
    \\
;

fn has(text: []const u8, part: []const u8) !void {
    if (std.mem.indexOf(u8, text, part) == null) {
        std.debug.print("missing: {s}\nin:\n{s}\n", .{ part, text });
        return error.TestExpectedEqual;
    }
}

test "explain gives the stack with the locals and the changes of the last call" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var rep = try debug.run(&it, average, .{ .explain = true });
    defer rep.deinit();
    try std.testing.expect(!rep.ok);
    const text = try debug.writeText(it.alloc(), &rep, .{});
    try has(text, "error: divide by zero\n");
    try has(text, "at: expr {$total / $n}\n");
    try has(text, "  average {3 -3}\n    items = 3 -3\n    total = 0\n    n = 0\n    x = -3\n  report\n");
    try has(text, "  n: 1 -> 0 (line 6 to 8)\n");
    try has(text, "  x: 3 -> -3 (line 6 to 5)\n");
    // Only the last call: the changes of the first call are not there.
    try std.testing.expect(std.mem.indexOf(u8, text, "18") == null);
    const js = try debug.writeJson(it.alloc(), &rep, .{});
    try has(js, "\"status\":\"error\"");
    try has(js, "{\"var\":\"n\",\"from\":\"1\",\"to\":\"0\",\"line\":6,\"next\":8}");
}

test "a run with probes, the budget, and a bad probe" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    var rep = try debug.run(&it, "proc f {a} {expr {$a * 2}}; foreach i {1 2 3 4 5} {f $i}", .{ .probes = &.{"-proc f -capture a"} });
    defer rep.deinit();
    try std.testing.expect(rep.ok);
    const text = try debug.writeText(it.alloc(), &rep, .{ .last = 2 });
    try has(text, "status: ok\nprobes:\n");
    try has(text, "p2 proc f: 5 hits, 5 records, 0 dropped, 0 errors\n");
    try has(text, "records (the last 2 of 5; --detail records), oldest first:\n  #3 p2 proc=f words=f 4 a=4\n");
    const small = try debug.writeText(it.alloc(), &rep, .{ .budget = 40 });
    try has(small, "status: ok\n");
    try has(small, "bytes left out: use --budget ");
    try it.reset();
    try std.testing.expectError(error.TclError, debug.run(&it, "set x 1", .{ .probes = &.{"-bogus"} }));
}

fn noRead(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator) anyerror![]u8 {
    return error.FileNotFound;
}

test "the MCP server answers initialize, tools/list, and tools/call" {
    if (!options.mod_probe) return error.SkipZigTest;
    var it: tcl.Interp = undefined;
    try it.init(std.testing.allocator);
    defer it.deinit();
    const input =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ztcl_run","arguments":{"script":"proc f {a} {puts hi$a}; f 1; f 2","probes":["-proc f -capture a"]}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ztcl_records","arguments":{"where":"a > 1"}}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ztcl_eval","arguments":{"code":"info procs f"}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ztcl_run","arguments":{"path":"none.tcl"}}}
        \\{"jsonrpc":"2.0","id":7,"method":"bogus"}
        \\not json
        \\
    ;
    var in: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var server: debugmcp.Server = .{ .it = &it, .gpa = std.testing.allocator, .read = noRead };
    defer server.captured.deinit(std.testing.allocator);
    try debugmcp.serve(&server, &in, &out.writer);
    const text = out.written();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    // One answer for each request with an id, and one for the bad line.
    try std.testing.expectEqual(@as(usize, 8), n);
    try has(text, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{\"tools\":{}}");
    try has(text, "\"name\":\"ztcl_explain\"");
    try has(text, "status: ok\\nprobes:\\n  p2 proc f: 2 hits");
    try has(text, "output:\\nhi1\\nhi2\\n");
    try has(text, "\\\"values\\\":{\\\"a\\\":\\\"2\\\"}");
    try has(text, "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"f\"}],\"isError\":false}}");
    try has(text, "none.tcl: FileNotFound\"}],\"isError\":true");
    try has(text, "\"id\":7,\"error\":{\"code\":-32601");
    try has(text, "\"id\":null,\"error\":{\"code\":-32700");
}
