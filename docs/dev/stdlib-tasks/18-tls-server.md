# Task 18: The TLS 1.3 server handshake, SNI, and ALPN

Platform: shared.

## Depends on

Decisions 6 and 7 of the user.

## Goal

The server state machine: ClientHello, HelloRetryRequest, the groups and suites of the design, ECDSA and Ed25519 certificates, SNI, ALPN, client certificates, and alerts.

## Files

- `src/tls/server.zig` (new).
- `src/tls/messages.zig` (new): the parse and the build of each handshake message, with the limits of the design.
- `src/http/server.zig`: `-tls` and ALPN for `serve`.

## Test sources

- RFC 8446 sections 4 and 6. RFC 8448 traces from the server side. RFC 7301 (ALPN). RFC 6066 (SNI).

## Acceptance

```sh
CAP zig build tls-vectors
CAP zig build tls-server-test
CAP tools/tls-interop.sh --quick server
```

Gates:

- The server side of each RFC 8448 trace matches byte for byte with the fixed randoms and keys.
- `openssl s_client -tls1_3` and `curl --tlsv1.3` connect for each group, suite, and key kind.
- A TLS 1.2 ClientHello gets the `protocol_version` alert.
