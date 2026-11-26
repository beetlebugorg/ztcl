//! The core of ztcl for the VBS enclave of Windows (ztcl#180): the
//! interpreter with no capability, on a fixed arena, as a library with
//! no import. The shim in `enclave/` links it into `ztcl-enclave.dll`.
//! See docs/dev/enclave.md.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl.zig");

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
pub const std_options: std.Options = .{ .logFn = noLog };

/// A panic stops the thread of the enclave, and `CallEnclave` gives the
/// host an error.
fn stop(_: []const u8, _: ?usize) noreturn {
    @trap();
}
pub const panic = std.debug.FullPanic(stop);

/// The memory of the interpreter. The enclave asks the host for no memory.
var arena: [48 << 20]u8 align(16) = undefined;

const Out = struct {
    buf: []u8,
    len: usize = 0,
    full: bool = false,
};

fn write(ctx: ?*anyopaque, bytes: []const u8) void {
    const o: *Out = @ptrCast(@alignCast(ctx.?));
    const n = @min(bytes.len, o.buf.len - o.len);
    @memcpy(o.buf[o.len..][0..n], bytes[0..n]);
    o.len += n;
    if (n < bytes.len) o.full = true;
}

/// Runs `script` in a new interpreter with the limits, writes the output
/// of `puts` into `out`, and gives 0, 1 for an error of the script, or 2
/// for a full output. `out_len` gets the length of the output, or of the
/// message of the error.
fn run(script: [*]const u8, script_len: usize, compute_limit: u64, mem_limit: usize, out: [*]u8, out_cap: usize, out_len: *usize) callconv(.{ .x86_64_win = .{} }) i32 {
    var fba = std.heap.FixedBufferAllocator.init(&arena);
    const gpa = fba.allocator();
    var o: Out = .{ .buf = out[0..out_cap] };
    var it: ztcl.Interp = undefined;
    it.init(gpa) catch return 2;
    it.output = .{ .ctx = &o, .write = write };
    it.mem_limit = mem_limit;
    it.compute_limit = compute_limit;
    var code: i32 = 0;
    if (it.eval(script[0..script_len])) |_| {} else |e| {
        const msg = if (e == error.TclError) it.str(it.result) catch "out of memory" else @errorName(e);
        o.len = 0;
        write(&o, msg);
        code = 1;
    }
    out_len.* = o.len;
    if (o.full) code = 2;
    // The arena goes back whole at the next call, so `deinit` is not needed.
    return code;
}

/// The 64 bytes of the data of an attestation report: the SHA-512 of the
/// nonce, the two limits (8 bytes each, little-endian), the capability
/// list, and the script. A verifier computes the same hash.
fn reportData(nonce: [*]const u8, nonce_len: usize, compute_limit: u64, mem_limit: u64, caps: [*]const u8, caps_len: usize, script: [*]const u8, script_len: usize, out: *[64]u8) callconv(.{ .x86_64_win = .{} }) void {
    var h = std.crypto.hash.sha2.Sha512.init(.{});
    h.update(nonce[0..nonce_len]);
    var limits: [16]u8 = undefined;
    std.mem.writeInt(u64, limits[0..8], compute_limit, .little);
    std.mem.writeInt(u64, limits[8..16], mem_limit, .little);
    h.update(&limits);
    h.update(caps[0..caps_len]);
    h.update(script[0..script_len]);
    h.final(out);
}

comptime {
    @export(&run, .{ .name = "ztcl_core_run" });
    @export(&reportData, .{ .name = "ztcl_core_report_data" });
}
