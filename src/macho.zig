//! The Mach-O form of `ztcl build`: the payload at the end of
//! `__LINKEDIT`, and a new ad hoc code signature.
//!
//! arm64 macOS runs only signed code, and a signature covers each page
//! of the file up to its own offset, so the payload must be under the
//! signature. `bundle` cuts the file at the old signature (or at the
//! end of `__LINKEDIT` when the file has none), adds the payload, makes
//! `__LINKEDIT` cover the payload and the new signature, writes the
//! offset of the payload into the slot of `buildnative.zig`, and then
//! writes the signature. A file with no `LC_CODE_SIGNATURE` gets one in
//! the space after the load commands (the header pad of the linker).
//!
//! The signature is a SuperBlob with one CodeDirectory (version
//! 0x20400): the identifier, no special slots, and the SHA-256 hash of
//! each 4 KiB page up to the signature. The flags are `CS_ADHOC`, and
//! the executable segment is `__TEXT` with `CS_EXECSEG_MAIN_BINARY`.
//! The layout follows `cs_blobs.h` of the xnu source of Apple
//! (docs/references/static-build.md). Each number of the signature is
//! big endian, and each number of the load commands is little endian.
//! The code uses byte slices only, so it can run in `ztcl.wasm`.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadMachO, NoRoom } || Allocator.Error;

const lc_segment_64 = 0x19;
const lc_code_signature = 0x1d;
const page = 4096;

fn rd32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

fn rd64(b: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, b[i..][0..8], .little);
}

fn wr32(b: []u8, i: usize, v: u32) void {
    std.mem.writeInt(u32, b[i..][0..4], v, .little);
}

fn wr64(b: []u8, i: usize, v: u64) void {
    std.mem.writeInt(u64, b[i..][0..8], v, .little);
}

const Layout = struct {
    ncmds: u32,
    cmds_end: usize,
    linkedit: usize,
    text_off: u64,
    text_size: u64,
    sig: ?usize,
    /// The smallest file offset of a section, the end of the space for
    /// load commands.
    first_section: u64,
};

fn layout(bin: []const u8) Error!Layout {
    if (bin.len < 32 or rd32(bin, 0) != 0xfeedfacf) return error.BadMachO;
    const ncmds = rd32(bin, 16);
    const size = rd32(bin, 20);
    if (32 + @as(usize, size) > bin.len) return error.BadMachO;
    var l: Layout = .{ .ncmds = ncmds, .cmds_end = 32 + size, .linkedit = 0, .text_off = 0, .text_size = 0, .sig = null, .first_section = bin.len };
    var o: usize = 32;
    var k: u32 = 0;
    while (k < ncmds) : (k += 1) {
        if (o + 8 > l.cmds_end) return error.BadMachO;
        const cmd = rd32(bin, o);
        const cs = rd32(bin, o + 4);
        if (cs < 8 or o + cs > l.cmds_end) return error.BadMachO;
        if (cmd == lc_segment_64) {
            if (cs < 72) return error.BadMachO;
            const name = std.mem.sliceTo(bin[o + 8 .. o + 24], 0);
            if (std.mem.eql(u8, name, "__LINKEDIT")) l.linkedit = o;
            if (std.mem.eql(u8, name, "__TEXT")) {
                l.text_off = rd64(bin, o + 40);
                l.text_size = rd64(bin, o + 48);
            }
            const nsects = rd32(bin, o + 64);
            if (72 + @as(usize, nsects) * 80 > cs) return error.BadMachO;
            for (0..nsects) |s| {
                const off = rd32(bin, o + 72 + s * 80 + 48);
                if (off != 0 and off < l.first_section) l.first_section = off;
            }
        }
        if (cmd == lc_code_signature) l.sig = o;
        o += cs;
    }
    if (l.linkedit == 0) return error.BadMachO;
    return l;
}

/// A copy of the Mach-O runtime `bin` with `payload` in `__LINKEDIT`
/// and a new ad hoc signature. `slot_at` is the offset of the slot of
/// `buildnative.zig`, and `ident` is the identifier of the signature.
pub fn bundle(a: Allocator, bin: []const u8, payload: []const u8, slot_at: usize, ident: []const u8) Error![]u8 {
    const l = try layout(bin);
    const le_off = rd64(bin, l.linkedit + 40);
    const le_end = le_off + rd64(bin, l.linkedit + 48);
    if (le_end > bin.len) return error.BadMachO;
    // The file ends at the old signature, or at the end of __LINKEDIT.
    var cut: u64 = le_end;
    if (l.sig) |s| {
        const off = rd32(bin, s + 8);
        if (@as(u64, off) + rd32(bin, s + 12) > bin.len or off < le_off) return error.BadMachO;
        cut = off;
    } else if (l.first_section < l.cmds_end + 16) return error.NoRoom;
    if (slot_at + 32 > cut) return error.BadMachO;
    const p_off = std.mem.alignForward(u64, cut, 16);
    const s_off = std.mem.alignForward(u64, p_off + payload.len, 16);
    const n_pages = (s_off + page - 1) / page;
    const ident_len = ident.len + 1;
    const cd_len = 88 + ident_len + n_pages * 32;
    const sig_len = 20 + cd_len;
    const total = s_off + sig_len;
    if (total > std.math.maxInt(u32)) return error.BadMachO;

    const out = try a.alloc(u8, @intCast(total));
    errdefer a.free(out);
    @memset(out, 0);
    @memcpy(out[0..@intCast(cut)], bin[0..@intCast(cut)]);
    @memcpy(out[@intCast(p_off)..][0..payload.len], payload);
    // The slot: the offset and the length of the payload.
    wr64(out, slot_at + 16, p_off);
    wr64(out, slot_at + 24, payload.len);
    // __LINKEDIT covers the payload and the signature.
    const le_size = total - le_off;
    wr64(out, l.linkedit + 48, le_size);
    wr64(out, l.linkedit + 32, std.mem.alignForward(u64, le_size, 0x4000));
    // LC_CODE_SIGNATURE.
    const sc = l.sig orelse blk: {
        const at = l.cmds_end;
        wr32(out, at, lc_code_signature);
        wr32(out, at + 4, 16);
        wr32(out, 16, l.ncmds + 1);
        wr32(out, 20, rd32(out, 20) + 16);
        break :blk at;
    };
    wr32(out, sc + 8, @intCast(s_off));
    wr32(out, sc + 12, @intCast(sig_len));

    // The signature, big endian.
    const sig = out[@intCast(s_off)..];
    const be = std.builtin.Endian.big;
    std.mem.writeInt(u32, sig[0..4], 0xfade0cc0, be);
    std.mem.writeInt(u32, sig[4..8], @intCast(sig_len), be);
    std.mem.writeInt(u32, sig[8..12], 1, be);
    std.mem.writeInt(u32, sig[12..16], 0, be); // CSSLOT_CODEDIRECTORY
    std.mem.writeInt(u32, sig[16..20], 20, be);
    const cd = sig[20..];
    std.mem.writeInt(u32, cd[0..4], 0xfade0c02, be);
    std.mem.writeInt(u32, cd[4..8], @intCast(cd_len), be);
    std.mem.writeInt(u32, cd[8..12], 0x20400, be);
    std.mem.writeInt(u32, cd[12..16], 0x2, be); // CS_ADHOC
    std.mem.writeInt(u32, cd[16..20], @intCast(88 + ident_len), be); // hashOffset
    std.mem.writeInt(u32, cd[20..24], 88, be); // identOffset
    std.mem.writeInt(u32, cd[24..28], 0, be); // nSpecialSlots
    std.mem.writeInt(u32, cd[28..32], @intCast(n_pages), be);
    std.mem.writeInt(u32, cd[32..36], @intCast(s_off), be); // codeLimit
    cd[36] = 32; // hashSize
    cd[37] = 2; // CS_HASHTYPE_SHA256
    cd[38] = 0; // platform
    cd[39] = 12; // log2 of the page size
    // spare2, scatterOffset, teamOffset, spare3, and codeLimit64 are 0.
    std.mem.writeInt(u64, cd[64..72], l.text_off, be); // execSegBase
    std.mem.writeInt(u64, cd[72..80], l.text_size, be); // execSegLimit
    std.mem.writeInt(u64, cd[80..88], 1, be); // CS_EXECSEG_MAIN_BINARY
    @memcpy(cd[88..][0..ident.len], ident);
    const hashes = cd[88 + ident_len ..];
    for (0..@intCast(n_pages)) |i| {
        const start = i * page;
        const end = @min(start + page, @as(usize, @intCast(s_off)));
        std.crypto.hash.sha2.Sha256.hash(out[start..end], hashes[i * 32 ..][0..32], .{});
    }
    return out;
}

test "macho: a payload in __LINKEDIT and a new signature" {
    const a = std.testing.allocator;
    // A small Mach-O: the header, __TEXT with one section at 0x1000, and
    // __LINKEDIT at 0x2000 with 0x100 bytes, with no signature.
    var bin: [0x2100]u8 = @splat(0);
    wr32(&bin, 0, 0xfeedfacf);
    wr32(&bin, 16, 2);
    const text = 32;
    wr32(&bin, text, lc_segment_64);
    wr32(&bin, text + 4, 72 + 80);
    @memcpy(bin[text + 8 ..][0..6], "__TEXT");
    wr64(&bin, text + 48, 0x2000);
    wr32(&bin, text + 64, 1);
    wr32(&bin, text + 72 + 48, 0x1000);
    const le = text + 72 + 80;
    wr32(&bin, le, lc_segment_64);
    wr32(&bin, le + 4, 72);
    @memcpy(bin[le + 8 ..][0..10], "__LINKEDIT");
    wr64(&bin, le + 40, 0x2000);
    wr64(&bin, le + 48, 0x100);
    wr32(&bin, 20, 72 + 80 + 72);
    const out = try bundle(a, &bin, "PAYLOAD", 0x1800, "app");
    defer a.free(out);
    try std.testing.expectEqual(@as(u32, 3), rd32(out, 16));
    try std.testing.expectEqual(@as(u64, 0x2100), rd64(out, 0x1810));
    try std.testing.expectEqualStrings("PAYLOAD", out[0x2100..0x2107]);
    const sc = 32 + 72 + 80 + 72;
    try std.testing.expectEqual(@as(u32, lc_code_signature), rd32(out, sc));
    const s_off = rd32(out, sc + 8);
    try std.testing.expectEqual(@as(u32, 0x2110), s_off);
    try std.testing.expectEqual(@as(u64, out.len - 0x2000), rd64(out, le + 48));
    // The hash of the last page.
    const cd = out[s_off + 20 ..];
    const n = std.mem.readInt(u32, cd[28..32], .big);
    try std.testing.expectEqual(@as(u32, 3), n);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out[0x2000..s_off], &h, .{});
    try std.testing.expectEqualSlices(u8, &h, cd[88 + 4 + 64 ..][0..32]);
    try std.testing.expectError(error.BadMachO, bundle(a, "nope", "x", 0, "app"));
}
