# Task 19: The client on the shared code, `zt::tls`, and `tls::socket`

Platform: shared.

## Goal

The client state machine on the shared record layer and messages, the `zt::tls` API, the TclTLS subset, and https in the HTTP client.

## Files

- `src/tls/client.zig` (new).
- `src/tls/cmd.zig` (new): `zt::tls socket`, `server`, and `status`.
- `src/tls/compat.tcl` (new, embedded): `tls::socket`, `tls::import`, `tls::handshake`, and `tls::status`.
- `src/http/client.zig`: https and ALPN.

## Test sources

- RFC 8448 from the client side. The std client as a second peer in the tests. The TclTLS manual page for the subset.

## Acceptance

```sh
CAP zig build tls-vectors
CAP tools/tls-interop.sh --quick client
```

Gates:

- The client side of each RFC 8448 trace matches byte for byte.
- The client connects to `openssl s_server` for each group, suite, and key kind, and refuses a bad chain, a wrong host name, and an expired certificate.
- With decision 7 for TLS 1.2: the fallback uses the std client only after a `protocol_version` alert, and only with the option on.
