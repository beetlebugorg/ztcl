//! The WebAssembly interface of ztcl: a small C ABI over `Interp`.
//!
//! The host calls `ztcl_alloc`, writes the script into the memory, and
//! calls `ztcl_eval`. See docs/embedding.md for an example.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// libghostty-vt logs, and WebAssembly has no stderr.
pub const std_options: std.Options = .{ .logFn = @import("vt.zig").noLog };
const ztcl = @import("ztcl.zig");
const build_options = @import("build_options");
const thread = @import("thread.zig");

/// The thread model of this build: `none`, `shared`, or `async`. See
/// docs/webassembly.md.
const web_threads = if (@hasDecl(build_options, "web_threads")) build_options.web_threads else .none;
const shared = web_threads == .shared;

pub const gpa = if (shared) @import("webthread.zig").heap_allocator else std.heap.wasm_allocator;

pub const Handle = struct {
    it: ztcl.Interp,
    out: std.ArrayList(u8) = .empty,
    /// With threads, the output that `ztcl_output_take` moved out of
    /// `out`. Other threads add to `out` under the lock of the group.
    taken: std.ArrayList(u8) = .empty,
    result: []const u8 = "",
    /// The files of the bundle, for `ztcl_allow` with `file`.
    files: wasmfiles.State = .{},
    /// The point procs, after `ztcl_point_install`.
    points: ztcl.point.State = .{},
    point_on: bool = false,
    /// The names of the procs of `ztcl_point_compile`. An id is an index
    /// plus 1, so a proc that the script defines again runs in its new form.
    point_names: std.ArrayList([]u8) = .empty,
    /// The time of `ztcl_run_events` in microseconds, during the run.
    event_us: ?i64 = null,
};

const wasmbundle = @import("wasmbundle.zig");
const wasmfiles = @import("wasmfiles.zig");

/// The slot of a bundle. `ztcl build --wasm` writes the address and the
/// length of the payload into the last two words. See
/// src/wasmbundle.zig.
export var ztcl_bundle_slot: [4]u32 = wasmbundle.slot_words;

/// The payload of the bundle, or an empty slice.
fn payload() []const u8 {
    const slot: *volatile [4]u32 = &ztcl_bundle_slot;
    const ptr = slot[2];
    if (ptr == 0xffffffff) return &.{};
    return @as([*]const u8, @ptrFromInt(ptr))[0..slot[3]];
}

/// The release of the setting `tcl` of the bundle, or 9.1.
fn bundleTcl() ztcl.interp.TclVersion {
    var r: wasmbundle.Reader = .init(payload());
    while (r.next()) |e| {
        if (e.kind == .setting and std.mem.eql(u8, e.name, "tcl")) return ztcl.interp.TclVersion.parse(e.data) orelse continue;
    }
    return ztcl.interp.TclVersion.host_default;
}

/// True for `ztcl-host.wasm`, the form with the imports of the module
/// `ztcl_host`. `ztcl.wasm` has no imports.
const host_imports = @hasDecl(build_options, "wasm_host") and build_options.wasm_host;

const host = struct {
    extern "ztcl_host" fn output(ptr: [*]const u8, len: usize) void;
    extern "ztcl_host" fn now_ms() f64;
    extern "ztcl_host" fn zone(ptr: [*]const u8, len: usize) i32;
};

/// The reply of `ztcl_host.zone`: the address and the length of the TZif
/// bytes that the host put in the memory of the module with `ztcl_alloc`.
var zone_reply: [2]u32 = .{ 0, 0 };

fn ztcl_zone_reply() callconv(.c) [*]u32 {
    return &zone_reply;
}

fn hostNow(_: ?*anyopaque) i64 {
    return @intFromFloat(@floor(host.now_ms() * 1000));
}

fn hostZone(_: ?*anyopaque, name: []const u8, a: std.mem.Allocator) ?[]const u8 {
    zone_reply = .{ 0, 0 };
    if (host.zone(name.ptr, name.len) != 0 or zone_reply[1] == 0) return null;
    const p: [*]u8 = @ptrFromInt(zone_reply[0]);
    const bytes = p[0..zone_reply[1]];
    defer gpa.free(bytes);
    return a.dupe(u8, bytes) catch null;
}

/// Turns on `clock` with the time and the zones of the host, in
/// `ztcl-host.wasm` only. Gives 0, or 1 when the memory is full.
fn ztcl_clock_allow(h: *Handle) callconv(.c) i32 {
    h.it.clock_host = .{ .now = hostNow, .zone = hostZone };
    h.it.allow(@backingInt(Capability.clock)) catch return 1;
    return 0;
}

/// The clock of the events in `ztcl-host.wasm`: the time of the run of
/// `ztcl_run_events`, or the time of the host.
fn eventNow(ctx: ?*anyopaque) i64 {
    const h: *Handle = @ptrCast(@alignCast(ctx.?));
    return h.event_us orelse hostNow(null);
}

/// Turns on `event` (`after`, `update`, `vwait`) in `ztcl-host.wasm`.
/// The host runs the events with `ztcl_run_events`, so `vwait` and a
/// plain `after ms` give an error. Gives 0, or 1 when the memory is full.
fn ztcl_events_allow(h: *Handle) callconv(.c) i32 {
    h.it.event_host = .{ .ctx = h, .now = eventNow, .sleep = null };
    h.it.allow(@backingInt(Capability.event)) catch return 1;
    return 0;
}

/// Runs the events that are due at `now_ms` (milliseconds on the clock
/// of `now_ms` of the host), as `update` runs them. Gives 0, or 1 with
/// the error in the result.
fn ztcl_run_events(h: *Handle, now_ms: f64) callconv(.c) i32 {
    if (!std.math.isFinite(now_ms)) {
        h.result = "ztcl_run_events: the time is not a finite number";
        return 1;
    }
    h.event_us = @intFromFloat(@floor(now_ms * 1000));
    defer h.event_us = null;
    h.result = "";
    return ztcl_eval(h, "update", 6);
}

/// The milliseconds from `now_ms` to the next event: 0 for an event
/// that is due, and -1 for no event.
fn ztcl_next_event(h: *Handle, now_ms: f64) callconv(.c) f64 {
    if (!std.math.isFinite(now_ms)) return -1;
    h.event_us = @intFromFloat(@floor(now_ms * 1000));
    defer h.event_us = null;
    const at = (@import("event.zig").nextDue(&h.it) catch return -1) orelse return -1;
    const left: f64 = @as(f64, @floatFromInt(at)) / 1000 - now_ms;
    return @max(left, 0);
}

/// The text of `puts`. `ztcl-host.wasm` gives it to the host at once
/// (`ztcl_host.output`), and `ztcl.wasm` keeps it until the eval ends.
/// Each write costs one compute unit in both forms, so a script that
/// writes in a loop stops at the same point in each form.
fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const h: *Handle = @ptrCast(@alignCast(ctx.?));
    if (h.it.compute_limit > 0 and h.it.compute_limit != std.math.maxInt(u64)) h.it.compute_limit -= 1;
    if (comptime host_imports) {
        host.output(bytes.ptr, bytes.len);
        return;
    }
    h.out.appendSlice(gpa, bytes) catch {};
}

export fn ztcl_alloc(len: usize) ?[*]u8 {
    const s = gpa.alloc(u8, len) catch return null;
    return s.ptr;
}

export fn ztcl_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

/// Makes an interpreter with a memory limit of 2 GiB and no compute
/// limit. It follows Tcl 9.1, or the release of the setting `tcl` of the
/// bundle; `ztcl_set_tcl_version` changes it.
export fn ztcl_new() ?*Handle {
    const h = gpa.create(Handle) catch return null;
    h.* = .{ .it = undefined };
    h.it.init(gpa) catch {
        gpa.destroy(h);
        return null;
    };
    h.it.setTclVersion(bundleTcl()) catch {
        h.it.deinit();
        gpa.destroy(h);
        return null;
    };
    h.it.output = .{ .ctx = h, .write = write };
    h.it.mem_limit = 2 << 30;
    return h;
}

export fn ztcl_delete(h: *Handle) void {
    for (h.point_names.items) |n| gpa.free(n);
    h.point_names.deinit(gpa);
    h.files.deinit(gpa);
    h.out.deinit(gpa);
    h.taken.deinit(gpa);
    h.it.deinit();
    gpa.destroy(h);
}

/// Sets the compute units that the next scripts can use.
export fn ztcl_set_compute_limit(h: *Handle, compute_limit: u64) void {
    h.it.compute_limit = compute_limit;
}

/// The compute units that are left of the count of `ztcl_set_compute_limit`.
export fn ztcl_compute_left(h: *Handle) u64 {
    return h.it.compute_limit;
}

export fn ztcl_set_mem_limit(h: *Handle, bytes: usize) void {
    h.it.mem_limit = bytes;
}

/// Starts a collection at each Nth safe point. Zero turns the mode off.
/// A test uses it to find a missed root.
export fn ztcl_set_gc_stress(h: *Handle, n: u32) void {
    h.it.setGcStress(n);
}

/// Sets the Tcl release that the commands follow: the text "8.6" or
/// "9.1". Returns 0 on success, 1 for other text, and 2 when the memory
/// runs out. Call it before the first script.
export fn ztcl_set_tcl_version(h: *Handle, ptr: [*]const u8, len: usize) i32 {
    const v = ztcl.interp.TclVersion.parse(ptr[0..len]) orelse return 1;
    h.it.setTclVersion(v) catch return 2;
    return 0;
}

/// Runs a script. Returns 0 on success and 1 on an error. The result
/// or the error message stays valid until the next call.
export fn ztcl_eval(h: *Handle, ptr: [*]const u8, len: usize) i32 {
    if (h.it.eval(ptr[0..len])) |v| {
        h.result = h.it.str(v) catch "out of memory";
        return 0;
    } else |e| {
        h.result = if (e == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(e);
        return 1;
    }
}

// ---- The DOM of the page (`wasmdom.zig`, #85) ----

/// Adds `dom` to the interpreter, in `ztcl-host.wasm` only. The host
/// calls it for `allow: ["dom"]`. Gives 0, or 1 when the memory is full.
fn ztcl_dom_allow(h: *Handle) callconv(.c) i32 {
    @import("wasmdom.zig").Commands(gpa).register(&h.it) catch return 1;
    return 0;
}

/// Runs the script of one DOM event of `dom on`. `vals` has the values
/// of `%x`, `%y`, `%key`, `%value`, and `%target`, each one followed by
/// a zero byte. Gives 0, or 1 with the error in the result.
fn ztcl_dom_event(h: *Handle, sptr: [*]const u8, slen: usize, vptr: [*]const u8, vlen: usize) callconv(.c) i32 {
    const dom = @import("wasmdom.zig");
    var vals: [dom.subs.len][]const u8 = @splat("");
    var parts = std.mem.splitScalar(u8, vptr[0..vlen], 0);
    for (&vals) |*v| v.* = parts.next() orelse "";
    if (dom.runEvent(&h.it, sptr[0..slen], vals)) |v| {
        h.result = h.it.str(v) catch "out of memory";
        return 0;
    } else |e| {
        h.result = if (e == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(e);
        return 1;
    }
}

// ---- The Web APIs of the page (`wasmweb.zig`, #251) ----

/// Adds the commands `web::` to the interpreter, in `ztcl-host.wasm`
/// only. The host calls it for an `allow` of a group `web:...`. Gives 0,
/// or 1 when the memory is full.
fn ztcl_web_allow(h: *Handle) callconv(.c) i32 {
    @import("wasmweb.zig").Commands(gpa).register(&h.it) catch return 1;
    return 0;
}

/// Adds the ports of Web Serial: `web::serial::request`,
/// `web::serial::ports`, and the channel commands of the streams of
/// `wasmfiles.zig`. The host calls it for `allow: ["web:serial"]`, after
/// `ztcl_web_allow`. Gives 0, or 1 when the memory is full.
fn ztcl_web_serial_allow(h: *Handle) callconv(.c) i32 {
    const web = @import("wasmweb.zig").Commands(gpa);
    h.files.stream_host = &web.stream_host;
    h.files.on = true;
    wasmfiles.Commands(filesOf, gpa, false).registerStreams(&h.it) catch return 1;
    web.registerSerial(&h.it) catch return 1;
    return 0;
}

/// The Tcl wrappers of the groups of `web::` (src/web/). The helpers of
/// `common.tcl` run before each one, and a second run of them defines
/// the same procs again.
const web_libs = [_]struct { group: []const u8, script: []const u8 }{
    .{ .group = "bluetooth", .script = @embedFile("web/bluetooth.tcl") },
    .{ .group = "gamepad", .script = @embedFile("web/gamepad.tcl") },
    .{ .group = "midi", .script = @embedFile("web/midi.tcl") },
    .{ .group = "usb", .script = @embedFile("web/usb.tcl") },
    .{ .group = "hid", .script = @embedFile("web/hid.tcl") },
};

/// Runs the Tcl wrapper of the group `ptr[0..len]`, such as
/// `bluetooth`, at the global level. The host calls it for each granted
/// group, after `ztcl_web_allow`. Gives 0, 1 with the error in the
/// result, or 2 for a group with no wrapper.
fn ztcl_web_lib(h: *Handle, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    for (web_libs) |lib| {
        if (!std.mem.eql(u8, lib.group, ptr[0..len])) continue;
        for ([_][]const u8{ @embedFile("web/common.tcl"), lib.script }) |script| {
            _ = h.it.eval(script) catch |e| {
                h.result = if (e == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(e);
                return 1;
            };
        }
        return 0;
    }
    return 2;
}

/// Adds the channels of WebUSB: the stream commands of `wasmfiles.zig`
/// and `web::usb::Stream`. The host calls it for `allow: ["web:usb"]`,
/// after `ztcl_web_allow`. Gives 0, or 1 when the memory is full.
fn ztcl_web_usb_allow(h: *Handle) callconv(.c) i32 {
    const web = @import("wasmweb.zig").Commands(gpa);
    h.files.stream_host = &web.stream_host;
    h.files.on = true;
    wasmfiles.Commands(filesOf, gpa, false).registerStreams(&h.it) catch return 1;
    web.registerUsb(&h.it) catch return 1;
    return 0;
}

/// Adds the channel `webusbN` for the stream `id` of the host. Gives 0,
/// or 1 when the memory is full.
fn ztcl_web_usb_port(h: *Handle, id: u32) callconv(.c) i32 {
    var buf: [24]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "webusb{d}", .{id}) catch unreachable;
    h.files.addPort(gpa, name, id) catch return 1;
    return 0;
}

/// Adds the port `webserialN` for the port `id` of the host. Gives 0, or
/// 1 when the memory is full.
fn ztcl_web_serial_port(h: *Handle, id: u32) callconv(.c) i32 {
    var buf: [24]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "webserial{d}", .{id}) catch unreachable;
    h.files.addPort(gpa, name, id) catch return 1;
    return 0;
}

/// Puts the bytes of the port `id` into its channel: data (`kind` 0),
/// the end (1), or an error (2, with the message). Gives 0, 1 when the
/// memory is full, or 2 for an unknown port.
fn ztcl_web_serial_data(h: *Handle, id: u32, ptr: [*]const u8, len: usize, kind: u32) callconv(.c) i32 {
    const known = h.files.feed(gpa, id, ptr[0..len], kind) catch return 1;
    return if (known) 0 else 2;
}

/// Splits a Tcl list for the conversions of the host. See
/// `wasmweb.split`.
fn ztcl_web_split(ptr: [*]const u8, len: usize) callconv(.c) i32 {
    return @import("wasmweb.zig").split(gpa, ptr[0..len]);
}

/// Runs the script of one event of `web::`: the result of a promise
/// (`subst` 0) or an event of `web::on` (`subst` 1). `vptr` has a list
/// of values in the form of `wasmweb.readValue`. Gives 0, or 1 with the
/// error in the result.
fn ztcl_web_event(h: *Handle, sptr: [*]const u8, slen: usize, vptr: [*]const u8, vlen: usize, subst: i32) callconv(.c) i32 {
    if (@import("wasmweb.zig").runEvent(&h.it, sptr[0..slen], vptr[0..vlen], subst != 0)) |v| {
        h.result = h.it.str(v) catch "out of memory";
        return 0;
    } else |e| {
        h.result = if (e == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(e);
        return 1;
    }
}

comptime {
    if (host_imports) {
        @export(&ztcl_web_allow, .{ .name = "ztcl_web_allow" });
        @export(&ztcl_web_event, .{ .name = "ztcl_web_event" });
        @export(&ztcl_web_split, .{ .name = "ztcl_web_split" });
        @export(&ztcl_web_serial_allow, .{ .name = "ztcl_web_serial_allow" });
        @export(&ztcl_web_lib, .{ .name = "ztcl_web_lib" });
        @export(&ztcl_web_usb_allow, .{ .name = "ztcl_web_usb_allow" });
        @export(&ztcl_web_usb_port, .{ .name = "ztcl_web_usb_port" });
        @export(&ztcl_web_serial_port, .{ .name = "ztcl_web_serial_port" });
        @export(&ztcl_web_serial_data, .{ .name = "ztcl_web_serial_data" });
        @export(&ztcl_dom_event, .{ .name = "ztcl_dom_event" });
        @export(&ztcl_dom_allow, .{ .name = "ztcl_dom_allow" });
        @export(&ztcl_clock_allow, .{ .name = "ztcl_clock_allow" });
        @export(&ztcl_events_allow, .{ .name = "ztcl_events_allow" });
        @export(&ztcl_run_events, .{ .name = "ztcl_run_events" });
        @export(&ztcl_next_event, .{ .name = "ztcl_next_event" });
        @export(&ztcl_zone_reply, .{ .name = "ztcl_zone_reply" });
    }
}

// ---- Point procs (docs/webassembly.md, "Point procs") ----

/// The point procs are in `ztcl-simd.wasm` and the other forms of
/// `addWasmForm` with `point`, so `ztcl.wasm` keeps its size budget.
const point_on = @hasDecl(build_options, "wasm_point") and build_options.wasm_point;

comptime {
    if (point_on) {
        @export(&ztcl_point_install, .{ .name = "ztcl_point_install" });
        @export(&ztcl_point_compile, .{ .name = "ztcl_point_compile" });
        @export(&ztcl_point_outputs, .{ .name = "ztcl_point_outputs" });
        @export(&ztcl_point_run, .{ .name = "ztcl_point_run" });
    }
}

const point = ztcl.point;
const point_fields = @typeInfo(point.Field).@"enum".field_names.len;
const point_outs = @typeInfo(point.Out).@"enum".field_names.len;

/// Adds `point proc` and the output commands (`offset`, `move`, `width`,
/// `flow`, `speed`, `skip`) to the interpreter. Gives false when the
/// memory is full.
fn ztcl_point_install(h: *Handle) callconv(.c) bool {
    if (h.point_on) return true;
    point.install(&h.it, &h.points) catch return false;
    h.point_on = true;
    return true;
}

/// Gives the id of the point proc `name`, or 0 with an error message in
/// the result when `name` is not a point proc.
fn ztcl_point_compile(h: *Handle, ptr: [*]const u8, len: usize) callconv(.c) u32 {
    const name = ptr[0..len];
    if (!h.point_on or h.points.program(name) == null) {
        h.result = std.fmt.allocPrint(h.it.alloc(), "\"{s}\" is not a point proc", .{name}) catch "out of memory";
        return 0;
    }
    for (h.point_names.items, 0..) |n, k| if (std.mem.eql(u8, n, name)) return @intCast(k + 1);
    const copy = gpa.dupe(u8, name) catch return 0;
    h.point_names.append(gpa, copy) catch {
        gpa.free(copy);
        return 0;
    };
    return @intCast(h.point_names.items.len);
}

/// The mask of the output columns that the point proc `prog` writes, in
/// the order of `point.Out`, or 0 for a bad id.
fn ztcl_point_outputs(h: *Handle, prog: u32) callconv(.c) u32 {
    if (prog == 0 or prog > h.point_names.items.len) return 0;
    const p = h.points.program(h.point_names.items[prog - 1]) orelse return 0;
    var m: u32 = 0;
    for (ztcl.point_wasm.outputs(p), 0..) |b, k| if (b) {
        m |= @as(u32, 1) << @intCast(k);
    };
    return m;
}

/// Runs the point proc `prog` over `count` points at `ptr`, which must be
/// 8-byte aligned: 11 input columns of `count` f64 in the order of
/// `point.Field` (the column of `feature` is not read), then 7 output
/// columns of `count` f64 with the start values in the order of
/// `point.Out`, then `count` feature numbers of one byte. A bit of
/// `in_mask` or `out_mask` marks a column as present. Gives the compute
/// units of the run (`Program.steps`), -1 when they are more than the
/// compute units that are left, -2 for a bad id, and -3 when the memory
/// is full. The compute units come off the compute limit.
fn ztcl_point_run(h: *Handle, prog: u32, ptr: [*]align(8) u8, count: usize, seed: u32, in_mask: u32, out_mask: u32) callconv(.c) i64 {
    if (prog == 0 or prog > h.point_names.items.len) return -2;
    const p = h.points.program(h.point_names.items[prog - 1]) orelse return -2;
    const units = p.steps(count);
    if (units > h.it.compute_limit) return -1;
    if (h.it.compute_limit != std.math.maxInt(u64)) h.it.compute_limit -= units;
    const cols: [*]f64 = @ptrCast(ptr);
    var pts: point.Points = .{ .len = count, .seed = seed };
    for (0..point_fields) |k| {
        if (in_mask & (@as(u32, 1) << @intCast(k)) == 0) continue;
        if (k == @backingInt(point.Field.feature)) {
            pts.feature = ptr[(point_fields + point_outs) * count * 8 ..][0..count];
        } else pts.in[k] = cols[k * count ..][0..count];
    }
    // Only the columns that the proc writes, as in the native host: the
    // limits of `point.bound` apply to each column of `out`.
    const writes = ztcl.point_wasm.outputs(p);
    for (0..point_outs) |k| {
        if (out_mask & (@as(u32, 1) << @intCast(k)) != 0 and writes[k]) pts.out[k] = cols[(point_fields + k) * count ..][0..count];
    }
    const scratch = gpa.alloc(f64, p.scratchLen()) catch return -3;
    defer gpa.free(scratch);
    p.run(&pts, scratch);
    return @intCast(units);
}

export fn ztcl_result_ptr(h: *Handle) [*]const u8 {
    return h.result.ptr;
}

export fn ztcl_result_len(h: *Handle) usize {
    return h.result.len;
}

export fn ztcl_output_ptr(h: *Handle) [*]const u8 {
    return if (web_threads == .none) h.out.items.ptr else h.taken.items.ptr;
}

export fn ztcl_output_len(h: *Handle) usize {
    return if (web_threads == .none) h.out.items.len else h.taken.items.len;
}

export fn ztcl_output_clear(h: *Handle) void {
    if (web_threads == .none) h.out.clearRetainingCapacity() else h.taken.clearRetainingCapacity();
}

// The shell of the runner on a terminal of `ztcl::vt`, in
// ztcl-shell.wasm. See src/wasm_shell.zig.
comptime {
    if (web_threads == .none and build_options.mod_vt and build_options.shell) _ = @import("wasm_shell.zig");
}

// The exports of the build with no threads for a bundle. See
// web/ztcl.mjs.
comptime {
    if (web_threads == .none) {
        @export(&ztcl_bundle_size, .{ .name = "ztcl_bundle_size" });
        @export(&ztcl_bundle_run, .{ .name = "ztcl_bundle_run" });
        @export(&ztcl_allow_plain, .{ .name = "ztcl_allow" });
    }
}

/// The size of the payload of the bundle. Zero for a module with no
/// bundle.
fn ztcl_bundle_size() callconv(.c) usize {
    return payload().len;
}

/// Runs the scripts of the bundle in order, as `ztcl a.tcl b.tcl` runs
/// them. Returns 0 on success and 1 on an error. On an error, the
/// result is "name:line: message" and the next scripts do not run.
fn ztcl_bundle_run(h: *Handle) callconv(.c) i32 {
    var r: wasmbundle.Reader = .init(payload());
    h.result = "";
    while (r.next()) |e| {
        if (e.kind != .script) continue;
        h.it.error_line = 0;
        if (h.it.eval(e.data)) |v| {
            h.result = h.it.str(v) catch "out of memory";
        } else |err| {
            const msg = if (err == error.TclError) h.it.str(h.it.result) catch "out of memory" else @errorName(err);
            h.result = std.fmt.allocPrint(h.it.alloc(), "{s}:{d}: {s}", .{ e.name, h.it.error_line, msg }) catch msg;
            return 1;
        }
    }
    return 0;
}

pub fn filesOf(it: *ztcl.Interp) *wasmfiles.State {
    const h: *Handle = @fieldParentPtr("it", it);
    return &h.files;
}

/// Turns on capabilities. This build has only `file`: the commands
/// `source`, `open`, `read`, `gets`, `eof`, and `close` on the files of
/// the bundle. Gives 0 on success, 1 when the memory ends, and 2 for
/// another bit.
fn ztcl_allow_plain(h: *Handle, bits: u32) callconv(.c) i32 {
    const file = @backingInt(Capability.file);
    if (bits & ~file != 0) return 2;
    if (bits == 0) return 0;
    // The ports of Web Serial can turn the commands on first.
    h.files.payload = payload();
    if (h.files.on) return 0;
    h.files.on = true;
    wasmfiles.Commands(filesOf, gpa, false).register(&h.it) catch return 1;
    return 0;
}

// The exports of the builds with threads. See web/ztcl-threads.mjs.
comptime {
    if (web_threads != .none) {
        @export(&ztcl_output_take, .{ .name = "ztcl_output_take" });
        @export(&ztcl_set_thread_limits, .{ .name = "ztcl_set_thread_limits" });
        @export(&ztcl_allow, .{ .name = "ztcl_allow" });
    }
    if (web_threads == .async) {
        @export(&ztcl_web_init, .{ .name = "ztcl_web_init" });
        @export(&ztcl_web_waiting, .{ .name = "ztcl_web_waiting" });
        @export(&ztcl_web_recv, .{ .name = "ztcl_web_recv" });
        @export(&ztcl_web_msg_ptr, .{ .name = "ztcl_web_msg_ptr" });
        @export(&ztcl_web_msg_len, .{ .name = "ztcl_web_msg_len" });
        @export(&ztcl_web_reply, .{ .name = "ztcl_web_reply" });
        @export(&ztcl_web_gone, .{ .name = "ztcl_web_gone" });
    }
}

// The exports of ztcl-async.wasm for web/ztcl-thread-worker.mjs. See
// src/webasync.zig.
const webasync = if (web_threads == .async) @import("webasync.zig") else struct {};

/// Sets the thread id of the interpreter. `main` is 1 for the main
/// interpreter.
fn ztcl_web_init(_: *Handle, id: u32, main: u32) callconv(.c) void {
    webasync.init(id, main != 0);
}

/// 1 when the script of the thread ran `thread::wait`.
fn ztcl_web_waiting(_: *Handle) callconv(.c) i32 {
    return @intFromBool(webasync.waiting());
}

/// Runs a script of another thread. Gives the return code. The result
/// is at `ztcl_web_msg_ptr` in the byte form.
fn ztcl_web_recv(h: *Handle, from: u32, token: u32, ptr: [*]const u8, len: usize) callconv(.c) i32 {
    _ = from;
    return webasync.recv(&h.it, token, ptr[0..len]);
}

fn ztcl_web_msg_ptr(_: *Handle) callconv(.c) [*]const u8 {
    return webasync.msgBytes().ptr;
}

fn ztcl_web_msg_len(_: *Handle) callconv(.c) usize {
    return webasync.msgBytes().len;
}

/// A reply in the byte form to a token of this interpreter.
fn ztcl_web_reply(h: *Handle, token: u32, code: i32, ptr: [*]const u8, len: usize) callconv(.c) void {
    webasync.reply(&h.it, token, code, ptr[0..len]);
}

/// Thread `id` ended.
fn ztcl_web_gone(_: *Handle, id: u32) callconv(.c) void {
    webasync.gone(id);
}

/// Moves the output of all threads to the buffer of
/// `ztcl_output_ptr`. Call it before the read of the output.
fn ztcl_output_take(h: *Handle) callconv(.c) void {
    if (shared) if (thread.outLock(&h.it)) |l| {
        l.lock();
        defer l.unlock();
        return take(h);
    };
    take(h);
}

fn take(h: *Handle) void {
    h.taken.clearRetainingCapacity();
    std.mem.swap(std.ArrayList(u8), &h.out, &h.taken);
}

/// Sets the limits of the threads. Zero in a field keeps its default.
/// Call it before `ztcl_allow`.
fn ztcl_set_thread_limits(h: *Handle, max_threads: u32, compute_limit: u64, mem_limit: usize, total_compute: u64, total_mem: usize, max_queue: usize) callconv(.c) void {
    var lim: thread.Limits = .{};
    if (max_threads != 0) lim.max_threads = max_threads;
    if (compute_limit != 0) lim.compute_limit = compute_limit;
    if (mem_limit != 0) lim.mem_limit = mem_limit;
    if (total_compute != 0) lim.total_compute = total_compute;
    if (total_mem != 0) lim.total_mem = total_mem;
    if (max_queue != 0) lim.max_queue = max_queue;
    thread.setLimits(&h.it, lim);
}

const Capability = @import("interp.zig").Capability;

/// The capabilities that a build with threads can turn on.
const web_caps = if (shared)
    [_]Capability{ .thread, .event, .clock, .package, .interp }
else
    [_]Capability{ .thread, .clock, .package, .interp };

/// Turns on capabilities: a mask of the bits of `Capability`. The mask
/// can have only `thread`, `clock`, `package`, `interp`, and in the
/// build with one shared memory, `event`. Gives 0 on success, 1 when
/// the memory ends, and 2 for another bit.
fn ztcl_allow(h: *Handle, bits: u32) callconv(.c) i32 {
    var ok: u32 = 0;
    for (web_caps) |c| ok |= @backingInt(c);
    if (bits & ~ok != 0) return 2;
    if (shared) {
        const wt = @import("webthread.zig");
        h.it.clock_host = .{ .now = wt.nowMicros };
        h.it.event_host = .{ .now = wt.nowMicros, .sleep = wt.sleepMicros };
        h.it.allow(bits) catch return 1;
    } else {
        const t = @backingInt(Capability.thread);
        h.it.clock_host = .{ .now = webasync.nowMicros };
        h.it.allow(bits & ~t) catch return 1;
        if (bits & t != 0) webasync.register(&h.it) catch return 1;
    }
    return 0;
}

// ---- C packages in WebAssembly (`-Dcext-wasm`, docs/dev/cext-tasks/04w-wasm-bridge.md) ----

comptime {
    if (@hasDecl(build_options, "cext") and build_options.cext) _ = @import("wasm_cext.zig");
}
