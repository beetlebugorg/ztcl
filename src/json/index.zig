//! Stage 1 of the JSON parser: the structural index.
//!
//! The JSON parser of ztcl implements the simdjson algorithm in Zig
//! (https://github.com/simdjson/simdjson, see docs/references/stdlib.md).
//! This file is stage 1 of that method. It reads the input 64 bytes at a
//! time as an `@Vector(64, u8)` and makes one bit mask of 64 bits for
//! each class of byte: backslashes, quotes, white space, and the
//! operators `{ } [ ] : ,`. Then, with bit operations only:
//!
//! 1. The escaped bytes. A run of backslashes that starts at an even
//!    place and has an odd length ends at an odd place, and the byte after
//!    it is escaped (the same for odd and even). An add of the run starts
//!    to the backslash mask moves a carry to the byte after each run. The
//!    carry out of the block says if the first byte of the next block is
//!    escaped.
//! 2. The string mask: the prefix XOR of the quotes that are not escaped.
//!    A bit is set from an opening quote up to the byte before its closing
//!    quote. The top bit goes to the next block.
//! 3. The structural bytes: each operator and the first byte of each
//!    scalar (a string, a number, or a literal), outside of strings.
//!
//! The positions of the set bits go to an array of `u32`, eight at a
//! time with `@ctz`. Stage 1 runs in chunks of 64 KiB, so the index stays
//! small and stage 2 has a safe point after each chunk.
//!
//! The same pass checks UTF-8 and the control bytes in strings. A block
//! of ASCII bytes needs only one compare. A block with other bytes gets
//! the check of `checkUtf8`: bit masks of the lead bytes and of the
//! continuation bytes, with no table.
//!
//! `Scalar` is the second form of stage 1: a loop over the bytes with
//! the same results. The tests and the fuzzer compare the two forms, and
//! a build can select it.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const Fault = enum { none, utf8, control, unclosed, too_large, escape };

/// The bytes of stage 1 for each chunk.
pub const chunk_bytes = 64 * 1024;
/// The room in an index buffer: one chunk of positions and the slack of
/// the unrolled write.
pub const buf_len = chunk_bytes + 64 + 8;
/// The blocks of one chunk.
pub const chunk_blocks = chunk_bytes / 64;

const V = @Vector(64, u8);
const even: u64 = 0x5555_5555_5555_5555;
const odd: u64 = ~even;

inline fn eq(v: V, c: u8) u64 {
    return @bitCast(v == @as(V, @splat(c)));
}

const builtin = @import("builtin");
const has_avx2 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
const has_pclmul = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);

inline fn prefixXor(x: u64) u64 {
    if (comptime has_pclmul) {
        // A carry-less multiply by all ones is the prefix XOR.
        const a: @Vector(2, u64) = .{ x, 0 };
        const b: @Vector(2, u64) = .{ ~@as(u64, 0), 0 };
        // With AVX, the VEX form: the legacy SSE form after 256-bit
        // instructions waits for the upper halves of the registers.
        if (comptime has_avx2) {
            return (asm ("vpclmulqdq $0, %[b], %[a], %[ret]"
                : [ret] "=x" (-> @Vector(2, u64)),
                : [a] "x" (a),
                  [b] "x" (b),
            ))[0];
        }
        const r = asm ("pclmulqdq $0, %[b], %[a]"
            : [ret] "=x" (-> @Vector(2, u64)),
            : [a] "0" (a),
              [b] "x" (b),
        );
        return r[0];
    }
    var y = x;
    y ^= y << 1;
    y ^= y << 2;
    y ^= y << 4;
    y ^= y << 8;
    y ^= y << 16;
    y ^= y << 32;
    return y;
}

/// The state of the UTF-8 check between blocks.
const Utf8 = struct {
    need: u8 = 0,
    lo: u8 = 0x80,
    hi: u8 = 0xBF,
    bad: bool = false,

    fn run(u: *Utf8, bytes: []const u8) void {
        var need = u.need;
        var lo = u.lo;
        var hi = u.hi;
        for (bytes) |b| {
            if (need == 0) {
                if (b < 0x80) continue;
                lo = 0x80;
                hi = 0xBF;
                switch (b) {
                    0xC2...0xDF => need = 1,
                    0xE0 => {
                        need = 2;
                        lo = 0xA0;
                    },
                    0xE1...0xEC, 0xEE, 0xEF => need = 2,
                    0xED => {
                        need = 2;
                        hi = 0x9F;
                    },
                    0xF0 => {
                        need = 3;
                        lo = 0x90;
                    },
                    0xF1...0xF3 => need = 3,
                    0xF4 => {
                        need = 3;
                        hi = 0x8F;
                    },
                    else => {
                        u.bad = true;
                        return;
                    },
                }
            } else {
                if (b < lo or b > hi) {
                    u.bad = true;
                    return;
                }
                need -= 1;
                lo = 0x80;
                hi = 0xBF;
            }
        }
        u.need = need;
        u.lo = lo;
        u.hi = hi;
    }
};

/// Stage 1 with vectors.
pub const Indexer = struct {
    input: []const u8,
    /// The start of the next block.
    pos: usize = 0,
    prev_escape: u64 = 0,
    prev_in_string: u64 = 0,
    prev_scalar: u64 = 0,
    /// The UTF-8 state of the last bytes (see `checkUtf8`).
    carry: u64 = 0,
    /// When set, the quote mask and the backslash mask of each block of
    /// the last chunk, so stage 2 finds the end of a string with no scan.
    quote_masks: ?*[chunk_blocks]u64 = null,
    bs_masks: ?*[chunk_blocks]u64 = null,
    /// The start of the last chunk.
    chunk_start: usize = 0,
    /// The places of the next block that must be hex digits of a `\u`.
    hex_carry: u64 = 0,
    fault: Fault = .none,
    /// The place of the fault, as a byte offset.
    fault_at: usize = 0,

    pub fn init(input: []const u8) Indexer {
        var ix: Indexer = .{ .input = input };
        if (input.len >= std.math.maxInt(u32)) ix.fault = .too_large;
        return ix;
    }

    pub fn done(ix: *const Indexer) bool {
        return ix.pos >= ix.input.len;
    }

    /// Indexes the next chunk. Writes the positions to `out` (at least
    /// `buf_len` long) and gives their count. At the end of the input it
    /// checks the state and sets `fault`.
    pub fn next(ix: *Indexer, out: []u32) usize {
        std.debug.assert(out.len >= buf_len);
        var n: usize = 0;
        const end = @min(ix.input.len, ix.pos + chunk_bytes);
        const p = out.ptr;
        ix.chunk_start = ix.pos;
        while (ix.pos + 64 <= end) {
            const v: V = ix.input[ix.pos..][0..64].*;
            const s = ix.block(v);
            if (ix.fault != .none) return n;
            flatten(p, &n, @intCast(ix.pos), s);
            ix.pos += 64;
        }
        if (ix.pos < end) {
            // The tail: a block with spaces after the input.
            var tail: [64]u8 = @splat(' ');
            @memcpy(tail[0 .. end - ix.pos], ix.input[ix.pos..end]);
            const s = ix.block(tail);
            if (ix.fault != .none) return n;
            flatten(p, &n, @intCast(ix.pos), s);
            ix.pos = end;
        }
        if (ix.pos >= ix.input.len) ix.finish();
        return n;
    }

    fn finish(ix: *Indexer) void {
        if (ix.fault != .none) return;
        // A sequence that wants bytes after the end of the input.
        if (ix.hex_carry != 0) {
            ix.fault = .escape;
            ix.fault_at = ix.input.len;
        } else if (ix.carry & 0x3F != 0) {
            ix.fault = .utf8;
            ix.fault_at = ix.input.len;
        } else if (ix.prev_in_string != 0) {
            ix.fault = .unclosed;
            ix.fault_at = ix.input.len;
        }
    }

    /// The structural bits of one block.
    inline fn block(ix: *Indexer, v: V) u64 {
        // UTF-8: only a block with a high byte, or a pending sequence.
        const high: u64 = @bitCast(v >= @as(V, @splat(0x80)));
        if (high != 0 or ix.carry != 0) {
            if (!ix.checkUtf8(v)) {
                ix.fault = .utf8;
                ix.fault_at = ix.pos;
                return 0;
            }
        }

        const bs = eq(v, '\\');
        const qt = eq(v, '"');
        // 1. The escaped bytes.
        const pe = ix.prev_escape;
        const b = bs & ~pe;
        const starts = b & ~(b << 1);
        const ec = @addWithOverflow(b, starts & even);
        const oc = @addWithOverflow(b, starts & odd);
        const escaped = (ec[0] & ~b & odd) | (oc[0] & ~b & even) | pe;
        ix.prev_escape = oc[1];
        // 2. The strings.
        const quotes = qt & ~escaped;
        if (ix.quote_masks) |qm| {
            const k = (ix.pos - ix.chunk_start) / 64;
            qm[k] = quotes;
            ix.bs_masks.?[k] = bs;
        }
        const in_string = prefixXor(quotes) ^ ix.prev_in_string;
        ix.prev_in_string = @bitCast(@as(i64, @bitCast(in_string)) >> 63);
        // 3. The structural bytes.
        const ws, const ops = classify(v);
        const scalar = ~(ops | ws);
        const nq_scalar = scalar & ~qt;
        const follows = (nq_scalar << 1) | ix.prev_scalar;
        ix.prev_scalar = nq_scalar >> 63;
        const tail = in_string ^ quotes;
        // The escapes in strings: the byte after a backslash is one of
        // `"\/bfnrtu`, and four hex digits follow a `u`.
        if (bs != 0 or ix.hex_carry != 0 or pe != 0) {
            const e = escaped & in_string;
            const good = eq(v, '"') | eq(v, '\\') | eq(v, '/') | eq(v, 'b') | eq(v, 'f') |
                eq(v, 'n') | eq(v, 'r') | eq(v, 't') | eq(v, 'u');
            const u: u128 = e & eq(v, 'u');
            const want = (u << 1) | (u << 2) | (u << 3) | (u << 4);
            const lower = v | @as(V, @splat(0x20));
            const digit: u64 = @bitCast((v >= @as(V, @splat('0'))) & (v <= @as(V, @splat('9'))));
            const hexa: u64 = @bitCast((lower >= @as(V, @splat('a'))) & (lower <= @as(V, @splat('f'))));
            const need = @as(u64, @truncate(want)) | ix.hex_carry;
            ix.hex_carry = @truncate(want >> 64);
            const bad = (e & ~good) | (need & ~(digit | hexa));
            if (bad != 0) {
                ix.fault = .escape;
                ix.fault_at = ix.pos + @ctz(bad);
            }
        }
        const ctrl: u64 = @bitCast(v < @as(V, @splat(0x20)));
        if (ctrl & in_string != 0) {
            ix.fault = .control;
            ix.fault_at = ix.pos + @ctz(ctrl & in_string);
        }
        return (ops | (scalar & ~follows)) & ~tail;
    }

    /// Checks the UTF-8 of one block with bit masks (RFC 3629). Each lead
    /// byte gives the places where its continuation bytes must be, and
    /// the masks of these places must equal the mask of the continuation
    /// bytes. Four lead bytes limit the range of their second byte. The
    /// top bits of the masks go to the next block in `carry`.
    inline fn checkUtf8(ix: *Indexer, v: V) bool {
        const ge = struct {
            inline fn f(x: V, c: u8) u64 {
                return @bitCast(x >= @as(V, @splat(c)));
            }
        }.f;
        const c80 = ge(v, 0x80);
        const cC0 = ge(v, 0xC0);
        const cE0 = ge(v, 0xE0);
        const cF0 = ge(v, 0xF0);
        const cont = c80 & ~cC0;
        // C0, C1, and F5 to FF are never in UTF-8.
        var bad = (cC0 & ~ge(v, 0xC2)) | ge(v, 0xF5);
        const l234 = cC0;
        const l34 = cE0;
        const l4 = cF0;
        const p = ix.carry;
        // The carry: bits 0 to 2 are the lead masks of the last byte
        // (l234, l34, l4), bits 3 and 4 the l34 and l4 masks of the byte
        // before it, bit 5 the l4 mask of the third byte from the end,
        // and bits 6 to 9 the E0, ED, F0, and F4 masks of the last byte.
        const want = (l234 << 1) | (p & 1) | (l34 << 2) | ((p >> 1) & 1) << 1 | ((p >> 3) & 1) |
            (l4 << 3) | ((p >> 2) & 1) << 2 | ((p >> 4) & 1) << 1 | ((p >> 5) & 1);
        // Two leads that want the same byte, or a byte that is not wanted.
        const want1 = (l234 << 1) | (p & 1);
        const want2 = (l34 << 2) | (((p >> 1) & 1) << 1) | ((p >> 3) & 1);
        const want3 = (l4 << 3) | (((p >> 2) & 1) << 2) | (((p >> 4) & 1) << 1) | ((p >> 5) & 1);
        bad |= (want1 & want2) | (want1 & want3) | (want2 & want3);
        bad |= want ^ cont;
        // The second byte of E0 is at least A0, of ED at most 9F, of F0 at
        // least 90, and of F4 at most 8F.
        const e0 = eq(v, 0xE0);
        const ed = eq(v, 0xED);
        const f0 = eq(v, 0xF0);
        const f4 = eq(v, 0xF4);
        const after = struct {
            inline fn f(m: u64, bit: u64) u64 {
                return (m << 1) | bit;
            }
        }.f;
        bad |= after(e0, (p >> 6) & 1) & ~ge(v, 0xA0);
        bad |= after(ed, (p >> 7) & 1) & ge(v, 0xA0);
        bad |= after(f0, (p >> 8) & 1) & ~ge(v, 0x90);
        bad |= after(f4, (p >> 9) & 1) & ge(v, 0x90);
        ix.carry = (l234 >> 63) | ((l34 >> 63) << 1) | ((l4 >> 63) << 2) |
            (((l34 >> 62) & 1) << 3) | (((l4 >> 62) & 1) << 4) | (((l4 >> 61) & 1) << 5) |
            ((e0 >> 63) << 6) | ((ed >> 63) << 7) | ((f0 >> 63) << 8) | ((f4 >> 63) << 9);
        return bad == 0;
    }
};

/// The white space and the operators of a block. With AVX2, two table
/// lookups by the high and the low half of each byte give a class bit,
/// and an AND of the two keeps the bits of the exact bytes:
///   bit 0: tab, line feed, and carriage return (high 0; low 9, A, D)
///   bit 1: space (high 2; low 0)
///   bit 2: the brackets (high 5 or 7; low B or D)
///   bit 3: colon (high 3; low A)
///   bit 4: comma (high 2; low C)
inline fn classify(v: V) struct { u64, u64 } {
    if (comptime has_avx2) {
        const H = @Vector(32, u8);
        const hi_table: H = std.simd.repeat(32, [16]u8{ 1, 0, 2 | 16, 8, 0, 4, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0 });
        const lo_table: H = std.simd.repeat(32, [16]u8{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1 | 8, 4, 16, 1 | 4, 0, 0 });
        const bytes: [64]u8 = v;
        var ws: u64 = 0;
        var ops: u64 = 0;
        inline for (0..2) |h| {
            const x: H = bytes[h * 32 ..][0..32].*;
            const lo = x & @as(H, @splat(15));
            const hi = (x >> @splat(4)) & @as(H, @splat(15));
            const r = pshufb(hi_table, hi) & pshufb(lo_table, lo);
            const w: u32 = @bitCast((r & @as(H, @splat(3))) != @as(H, @splat(0)));
            const o: u32 = @bitCast((r & @as(H, @splat(28))) != @as(H, @splat(0)));
            ws |= @as(u64, w) << (h * 32);
            ops |= @as(u64, o) << (h * 32);
        }
        return .{ ws, ops };
    }
    const ws = eq(v, ' ') | eq(v, '\n') | eq(v, '\r') | eq(v, '\t');
    const lower = v | @as(V, @splat(0x20));
    const ops = eq(lower, '{') | eq(lower, '}') | eq(v, ':') | eq(v, ',');
    return .{ ws, ops };
}

inline fn pshufb(table: @Vector(32, u8), idx: @Vector(32, u8)) @Vector(32, u8) {
    return asm ("vpshufb %[idx], %[tbl], %[ret]"
        : [ret] "=x" (-> @Vector(32, u8)),
        : [tbl] "x" (table),
          [idx] "x" (idx),
    );
}

inline fn flatten(p: [*]u32, n: *usize, base: u32, bits_in: u64) void {
    var bits = bits_in;
    const cnt = @popCount(bits);
    const q = p + n.*;
    var k: usize = 0;
    while (k < cnt) : (k += 8) {
        inline for (0..8) |j| {
            q[k + j] = base +% @as(u32, @ctz(bits));
            bits &= bits -% 1;
        }
    }
    n.* += cnt;
}

/// Stage 1 as a loop over the bytes. It gives the same positions and the
/// same fault as `Indexer`.
pub const Scalar = struct {
    input: []const u8,
    pos: usize = 0,
    in_string: bool = false,
    escape: bool = false,
    prev_scalar: bool = false,
    hex_need: u8 = 0,
    utf8: Utf8 = .{},
    fault: Fault = .none,
    fault_at: usize = 0,

    pub fn init(input: []const u8) Scalar {
        var s: Scalar = .{ .input = input };
        if (input.len >= std.math.maxInt(u32)) s.fault = .too_large;
        return s;
    }

    pub fn done(s: *const Scalar) bool {
        return s.pos >= s.input.len;
    }

    pub fn next(s: *Scalar, out: []u32) usize {
        var n: usize = 0;
        const end = @min(s.input.len, s.pos + chunk_bytes);
        while (s.pos < end) : (s.pos += 1) {
            const c = s.input[s.pos];
            s.utf8.run(&.{c});
            if (s.utf8.bad) {
                s.fault = .utf8;
                // The vector form gives the start of the block.
                s.fault_at = s.pos & ~@as(usize, 63);
                return n;
            }
            // A byte after a backslash that is not escaped is escaped,
            // inside and outside of strings, as in the vector form.
            const escaped = s.escape;
            s.escape = c == '\\' and !escaped;
            if (s.in_string) {
                if (c < 0x20) {
                    s.fault = .control;
                    s.fault_at = s.pos;
                    return n;
                }
                var bad = false;
                if (s.hex_need > 0) {
                    bad = !std.ascii.isHex(c);
                    s.hex_need -= 1;
                }
                if (escaped) {
                    bad = bad or std.mem.indexOfScalar(u8, "\"\\/bfnrtu", c) == null;
                    if (c == 'u') s.hex_need = 4;
                }
                if (bad) {
                    s.fault = .escape;
                    s.fault_at = s.pos;
                    return n;
                }
                if (c == '"' and !escaped) s.in_string = false;
                s.prev_scalar = c != '"';
                continue;
            }
            const is_op = switch (c) {
                '{', '}', '[', ']', ':', ',' => true,
                else => false,
            };
            const is_ws = c == ' ' or c == '\n' or c == '\r' or c == '\t';
            if (is_op) {
                out[n] = @intCast(s.pos);
                n += 1;
                s.prev_scalar = false;
            } else if (is_ws) {
                s.prev_scalar = false;
            } else {
                if (!s.prev_scalar) {
                    out[n] = @intCast(s.pos);
                    n += 1;
                }
                if (c == '"' and !escaped) {
                    s.in_string = true;
                    s.prev_scalar = false;
                } else s.prev_scalar = c != '"';
            }
        }
        if (s.pos >= s.input.len and s.fault == .none) {
            if (s.utf8.need != 0) {
                s.fault = .utf8;
                s.fault_at = s.input.len;
            } else if (s.in_string) {
                s.fault = .unclosed;
                s.fault_at = s.input.len;
            }
        }
        return n;
    }
};
