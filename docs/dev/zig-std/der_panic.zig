//! Three inputs that make `std.crypto.Certificate.der.Element.parse` of
//! Zig 0.17.0 panic in a Debug or ReleaseSafe build. The function reads
//! `bytes[i]` with no check against `bytes.len`, and adds the length to
//! the index in a u32 with no overflow check. Run one test at a time
//! with `--test-filter`, because the first panic stops the test runner.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Certificate = std.crypto.Certificate;

test "Element.parse reads past the end of a 1-byte buffer" {
    _ = Certificate.der.Element.parse(&.{0x30}, 0) catch {};
}

test "Certificate.parse on a SEQUENCE whose length is past the end" {
    const bytes = [_]u8{ 0x30, 0x7f };
    _ = Certificate.parse(.{ .buffer = &bytes, .index = 0 }) catch {};
}

test "Element.parse long-form length overflows u32" {
    _ = Certificate.der.Element.parse(&.{ 0x30, 0x84, 0xff, 0xff, 0xff, 0xff }, 0) catch {};
}
