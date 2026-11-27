//! EMSA-PSS-VERIFY (RFC 8017 section 9.1.2, step 10) needs every byte of
//! PS to be zero. The signature below has PS[10] = 0x5a and is otherwise
//! valid (SHA-256, MGF1-SHA-256, salt length 32, 2048-bit key, e = 65537).
//! `mkpss.py` made the key and the signature. `openssl dgst -verify` with
//! PSS padding gives "Verification failure" for this signature.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const rsa = std.crypto.Certificate.rsa;
const Sha256 = std.crypto.hash.sha2.Sha256;
const n_hex = "e1b7a2fe1530c665230b3cf8b2a7c22d3f979c1d06c5ca6df484b78e67a9b357c836a6cb8593cd2036d7add53845974147dd1a7458478ea92f9e9289075d1fc6bc57a357db035cf90598a1d01be385de4232980fb72f06f7664c767504422be1801d68158fccd555d5fe27de20523a27f270f0adc377d78eb2ed377e91cf1ae9db230bf9a72b4723aa16c37c1898ea6dd216ddd5d6697c3c97c58e3c7334c05b1f66ad18e951e64d01421ed3e4a4c7257ea86d2381a5ea3c600dbec26d6ba81986c5b76ef0e41bd0e0a9c6daf27357c45e628c0fe2caa0b8e1ac0c7a11559a837982175fafd96889f087957b1881e59714b9ec7e253762e0c171c7c029a6c73f";
const sig_hex = "ba79a3d6211a0d5e858c11c7c13cd77be3bc03d65db4c321dac48e55bfc7ef794a4cc0edc4d52d144f121642bb487e1334531cdab77a34fd7db8b60bb91da02ab23d2c898db704ab7ecfac67f522c8f4c36772823e089a3cf10f685f934cf312edd55830c0ea584bd8e199023e2f046c19f50ae0e82178dfb17f2d142eab9dd07f10d1915058bdbc42df5ef663ebba76ef9d62b838064c310d830370922c14ed53e528628d43c6e811b111892079fe7fc8985a7c4c21cba5e806c5374a0a7080cc741bb0fcd70ac099b675ec945a2daa2b135047d92203a424810db3960798ab93c54dcefae7961798db82a92444c8c17441d3d6a77900c6e7f4bea1be6d8ef1";

test "PSSSignature.verify accepts a non-zero byte in PS" {
    var n: [256]u8 = undefined;
    var sig: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&n, n_hex);
    _ = try std.fmt.hexToBytes(&sig, sig_hex);
    const pk = try rsa.PublicKey.fromBytes(&.{ 0x01, 0x00, 0x01 }, &n);
    // RFC 8017 says "inconsistent" for this signature. This call returns
    // with no error.
    try rsa.PSSSignature.verify(256, &sig, "zig std pss", pk, Sha256);
}
