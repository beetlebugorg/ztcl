# TLS 1.3

ztcl has its own TLS 1.3 code, for the client and for the server, on the primitives of `std.crypto`. This page gives the threat model and the rules of the work. The code is in `src/tls/`. No command uses it yet, and TLS stays behind a build flag until an outside review is done ([the plan](dev/stdlib.md#tls-13), decision 8).

## The threat model

- The peer and the network are hostile. Each byte that comes from the network can have any value, at any length, in any order.
- An attacker on the path can read, change, drop, replay, and delay records.
- An attacker can measure the time of each answer, so code that handles secret data must not branch on it or index memory with it.
- The attacker does not run code on the host and does not read its memory.

## The rules

1. TLS 1.3 only on the server (RFC 8446). The client also speaks TLS 1.2 through `std.crypto.tls.Client`, for older servers (decision 7).
2. The cipher suites are TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, and TLS_CHACHA20_POLY1305_SHA256.
3. Each error of a peer ends the connection with the alert of the RFC. A parser reads each length before it reads the bytes of that length.
4. The record layer keeps the limits of RFC 8446 section 5: at most 2^14 bytes of content, at most 2^14 + 256 bytes of a protected fragment, and the record limit of each AEAD key. A key update comes before that limit.
5. The open of a record compares the tag with `std.crypto.timing_safe.eql` (in the AEADs of `std.crypto`) and scans the padding with no branch on a byte.
6. Secrets stay in fixed buffers of the connection.
7. Each part has its test vectors: RFC 8448 for the key schedule and the records, RFC 5869 for HKDF, RFC 8439 for ChaCha20-Poly1305, and the Wycheproof sets for each primitive.

## State

| Part | State |
|---|---|
| The primitives, the key schedule, and the record layer | In `src/tls/`, with the checks of this page |
| X.509: the parse, the chain checks, PEM keys, and the root stores | Coming: pull request [#391](https://github.com/beetlebugorg/ztcl/pull/391) |
| The client handshake, checked with RFC 8448 and `openssl s_server` | Coming: pull request [#395](https://github.com/beetlebugorg/ztcl/pull/395) |
| A TLS socket command, https in the HTTP client, and the server | Coming: issue [#27](https://github.com/beetlebugorg/ztcl/issues/27) |

## The parts that exist

| File | What it has |
|---|---|
| `src/tls/schedule.zig` | HKDF-Expand-Label, Derive-Secret, the early, handshake, and master secrets, the finished key and the Finished HMAC, the traffic keys, the key update secret, and the PSK of a ticket. SHA-256 and SHA-384. |
| `src/tls/record.zig` | Plain records, the seal and the open of protected records, the sequence numbers, the padding, the record limits, the key update, and the alerts. |
| `src/tls/crypto.zig` | The signature checks (ECDSA on P-256 and P-384, RSASSA-PSS, RSASSA-PKCS1-v1_5, and Ed25519) and the key exchanges (X25519, P-256, and P-384) by the codes of `SignatureScheme` and `NamedGroup`. |
| `src/tls/vectors.zig` | The replay of the five traces of RFC 8448. |
| `src/tls/wycheproof.zig` | The runner of the Wycheproof sets. |
| `src/tls/der.zig` | A strict DER reader with a bounds check before each read. |
| `src/tls/x509.zig` | The parse of a certificate: names, dates, the key, the signature algorithm, and the extensions that the chain checks read. |
| `src/tls/pem.zig` | PEM blocks, and the private keys of PKCS#8 and SEC 1 for P-256, P-384, and Ed25519. |
| `src/tls/chain.zig` | The path search from the leaf to an anchor, and the checks of the path and of the host name. |
| `src/tls/roots.zig` | The trust anchors: PEM text, a PEM file, DER bytes, or the store of the system. |
| `src/tls/limbo.zig` | The runner of the x509-limbo cases. |
| `src/tls/x509_fuzz.zig` | A mutation fuzzer of the DER, X.509, PEM, and chain code. |

Run the checks:

```sh
zig build tls-vectors
```

Run the Wycheproof sets. The script downloads 20 files from a fixed commit of [Wycheproof](https://github.com/C2SP/wycheproof) and checks the SHA-256 of each file:

```sh
zig build tls-wycheproof -Doptimize=ReleaseSafe -- "$(tools/fetch-wycheproof.sh)"
```

A "valid" case must pass and an "invalid" case must fail. The run counts the results of the "acceptable" cases. The runner skips the AES-GCM groups with a nonce of other than 12 bytes, a tag of other than 16 bytes, or a key of 192 bits, because TLS does not use them. A compressed point of P-256 or P-384 must fail, because RFC 8446 section 4.2.8.2 allows uncompressed points only.

The RSA checks are in `crypto.zig` and do not use `std.crypto.Certificate.rsa`. In Zig 0.17.0, the PSS check of that code reads one byte of the zero padding only, and it accepts 4 signatures of the 2048-bit Wycheproof sets that must fail. The chain checks call `crypto.verifyCert` for each signature.

## Certificates

The TLS code has its own DER reader and X.509 parse. In Zig 0.17.0, `std.crypto.Certificate.der.Element.parse` and `rsa.PublicKey.parseDer` read past the end of the input on a bad length, and `Parsed.verify` does not check `basicConstraints`, the key usage, or name constraints. A unit test in `chain.zig` shows a leaf that signs a second leaf: `chain.verify` refuses the chain, and `Parsed.verify` accepts it.

`chain.verify` follows the profile of the Web PKI where it and RFC 5280 differ: a CA certificate is not a leaf, a leaf with an extended key usage has `serverAuth` and no `anyExtendedKeyUsage`, and a name constraint that is not critical applies. The common name is not read. It has no revocation checks, no certificate policies, and no Public Suffix List.

The system store is the bundle file of the distribution on Linux, and `std.crypto.Certificate.Bundle.rescan` on the other systems.

Run the x509-limbo cases. The script downloads `limbo.json` from a fixed commit of [x509-limbo](https://github.com/C2SP/x509-limbo) and checks its SHA-256:

```sh
zig build tls-x509-test -Doptimize=ReleaseSafe -- "$(tools/fetch-x509-limbo.sh)"
zig build x509-fuzz -- --seconds 600
```

The runner skips the cases of revocation, of the network, of ML-DSA, of policy constraints, and of client certificates. Where an RFC 5280 case conflicts with a webpki case, the runner follows the webpki case. `differ` in `limbo.zig` lists each case where the result can differ from the expected result, with the reason: the key identifiers, the common name, the authority information access, the Public Suffix List, a leaf with no extended key usage, the extended key usage of an anchor, a root with a `basicConstraints` that is not critical, and a CA certificate as the leaf.
