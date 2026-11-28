//! The command `ztcl::meter` (capability `meter`, ztcl#243): meters of
//! compute units, time, memory, and I/O, for the threads and the child
//! interpreters that a host runs for a customer. `meter.zig` has the
//! counts and the record form.
//!
//!   ztcl::meter create NAME ?-budget UNITS? ?-tenant TEXT?
//!   ztcl::meter get NAME
//!   ztcl::meter list
//!   ztcl::meter reset NAME
//!   ztcl::meter delete NAME
//!   ztcl::meter run NAME SCRIPT
//!   ztcl::meter record NAME ?-tenant TEXT? ?-script TEXT? ?-sign? ?-key SEED?
//!   ztcl::meter verify RECORD PUBLICKEY
//!   ztcl::meter pubkey SEED
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const interp = @import("interp.zig");
const value = @import("value.zig");
const mt = @import("meter.zig");
const Interp = interp.Interp;
const Value = value.Value;
const Error = interp.Error;
const Cmd = interp.Cmd;
const Ed25519 = std.crypto.sign.Ed25519;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn cmdMeter(it: *Interp, argv: []const Value, _: ?*Cmd) Error!Value {
    if (argv.len < 2) return it.wrongArgs("ztcl::meter subcommand ?arg ...?");
    const Sub = enum { create, delete, get, list, pubkey, record, reset, run, verify };
    const sub = @tagName(try @import("tcl9.zig").pick(it, Sub, try it.str(argv[1]), .{ .code = "TCL LOOKUP SUBCOMMAND" }));
    const args = argv[2..];
    if (eql(sub, "create")) return create(it, args);
    if (eql(sub, "get")) {
        if (args.len != 1) return it.wrongArgs("ztcl::meter get name");
        const m = try find(it, args[0]);
        defer m.release();
        // A read in the interpreter of the meter sees its own last units.
        if (it.meter == m) mt.sync(it);
        return mt.dict(it, m.name, try m.snapshot(it.alloc()));
    }
    if (eql(sub, "list")) {
        if (args.len != 0) return it.wrongArgs("ztcl::meter list");
        const r = try mt.registry(it);
        r.acquire();
        defer r.lock.unlock();
        const out = try it.alloc().alloc(Value, r.meters.count());
        for (r.meters.keys(), 0..) |k, i| out[i] = .{ .str = try it.alloc().dupe(u8, k) };
        return value.wrapList(it.alloc(), out);
    }
    if (eql(sub, "reset")) {
        if (args.len != 1) return it.wrongArgs("ztcl::meter reset name");
        const m = try find(it, args[0]);
        defer m.release();
        if (it.meter == m) mt.sync(it);
        m.reset();
        return Value.empty;
    }
    if (eql(sub, "delete")) {
        if (args.len != 1) return it.wrongArgs("ztcl::meter delete name");
        const r = try mt.registry(it);
        if (!r.remove(try it.str(args[0]))) return noMeter(it, try it.str(args[0]));
        return Value.empty;
    }
    if (eql(sub, "run")) {
        if (args.len != 2) return it.wrongArgs("ztcl::meter run name script");
        if (it.meter != null) return it.failCode("ZTCL METER BUSY", "the interpreter already counts in a meter", .{});
        const m = try find(it, args[0]);
        defer m.release();
        // The budget of the meter caps the units of the script.
        const script = try it.scriptOfValue(args[1], null);
        const before = it.compute_limit;
        const got = m.reserve(before);
        it.compute_limit = got;
        mt.attach(it, m, got);
        const r = it.evalBody(script, argv, &.{});
        mt.detach(it);
        // The units of the script come off the limit of the caller.
        it.compute_limit = before -| (got - it.compute_limit);
        return r;
    }
    if (eql(sub, "record")) return record(it, args);
    if (eql(sub, "verify")) {
        if (args.len != 2) return it.wrongArgs("ztcl::meter verify record publickey");
        const pk = try hex32(it, try it.str(args[1]), "public key");
        mt.verify(try it.str(args[0]), pk) catch return .{ .int = 0 };
        return .{ .int = 1 };
    }
    if (eql(sub, "pubkey")) {
        if (args.len != 1) return it.wrongArgs("ztcl::meter pubkey seed");
        const kp = try keyOf(it, args[0]);
        return .{ .str = try it.alloc().dupe(u8, &std.fmt.bytesToHex(kp.public_key.toBytes(), .lower)) };
    }
    unreachable;
}

fn noMeter(it: *Interp, name: []const u8) Error {
    return it.failCode("ZTCL METER NAME", "no meter \"{s}\"", .{name});
}

fn find(it: *Interp, v: Value) Error!*mt.Meter {
    const name = try it.str(v);
    return (try mt.registry(it)).get(name) orelse noMeter(it, name);
}

fn create(it: *Interp, args: []const Value) Error!Value {
    const use = "ztcl::meter create name ?-budget units? ?-tenant text?";
    if (args.len < 1 or args.len % 2 != 1) return it.wrongArgs(use);
    const m = try (try mt.registry(it)).obtain(try it.str(args[0]));
    defer m.release();
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const o = try it.str(args[i]);
        if (eql(o, "-budget")) {
            const t = try it.str(args[i + 1]);
            if (t.len == 0) {
                m.budget = std.math.maxInt(u64);
                continue;
            }
            const n = try it.int(args[i + 1]);
            if (n < 0) return it.fail("bad budget \"{d}\": must be 0 or more", .{n});
            m.budget = @intCast(n);
        } else if (eql(o, "-tenant")) {
            const t = try m.gpa.dupe(u8, try it.str(args[i + 1]));
            m.acquire();
            m.gpa.free(m.tenant);
            m.tenant = t;
            m.unlock();
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -budget or -tenant", .{o});
    }
    return .{ .str = try it.alloc().dupe(u8, m.name) };
}

fn hex32(it: *Interp, t: []const u8, what: []const u8) Error![32]u8 {
    var out: [32]u8 = undefined;
    if (t.len != 64) return it.failCode("ZTCL METER KEY", "a {s} is 64 hex digits", .{what});
    _ = std.fmt.hexToBytes(&out, t) catch return it.failCode("ZTCL METER KEY", "a {s} is 64 hex digits", .{what});
    return out;
}

fn keyOf(it: *Interp, v: Value) Error!Ed25519.KeyPair {
    const seed = try hex32(it, try it.str(v), "seed");
    return Ed25519.KeyPair.generateDeterministic(seed) catch it.failCode("ZTCL METER KEY", "the seed gives no key", .{});
}

fn record(it: *Interp, args: []const Value) Error!Value {
    const use = "ztcl::meter record name ?-tenant text? ?-script text? ?-sign? ?-key seed?";
    if (args.len < 1) return it.wrongArgs(use);
    const m = try find(it, args[0]);
    defer m.release();
    if (it.meter == m) mt.sync(it);
    m.acquire();
    var o: mt.RecordOpts = .{ .tenant = try it.alloc().dupe(u8, m.tenant) };
    m.unlock();
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const opt = try it.str(args[i]);
        if (eql(opt, "-sign")) {
            const r = try mt.registry(it);
            o.key = r.key orelse return it.failCode("ZTCL METER KEY", "the host gave no key: use -key, or set Interp.meter_key", .{});
            continue;
        }
        if (i + 1 >= args.len) return it.wrongArgs(use);
        i += 1;
        if (eql(opt, "-tenant")) {
            o.tenant = try it.str(args[i]);
        } else if (eql(opt, "-script")) {
            var h: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(try it.str(args[i]), &h, .{});
            o.script_hash = h;
        } else if (eql(opt, "-key")) {
            o.key = try keyOf(it, args[i]);
        } else return it.failCode("TCL LOOKUP INDEX option", "bad option \"{s}\": must be -key, -script, -sign, or -tenant", .{opt});
    }
    const text = mt.record(it.alloc(), m, o) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Sign => return it.failCode("ZTCL METER KEY", "the key cannot sign", .{}),
    };
    return .{ .str = text };
}
