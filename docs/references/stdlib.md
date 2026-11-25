# References for the standard library

The plan in [the design](../stdlib.md) uses these sources. ztcl copies no code from them, except the SQLite amalgamation after decision 9 of the design. Each task checks the license of each source that it uses and adds the facts that it checked here.

## Zig standard library

Zig 0.16.0, `lib/std`: `std.json`, `std.http`, `std.crypto` (the TLS client, `Certificate`, the hashes, the AEADs, the signatures, `ff`, and `timing_safe`), `std.compress` (`flate` and `zstd`), `std.Io` (`Threaded`, `Uring`, `Kqueue`, `Dispatch`, and `fiber`), `std.tz`, and `std.Uri`. https://ziglang.org

**License:** MIT.

**How ztcl uses it:** ztcl calls these parts as its one dependency. The sizes and the gaps in the design come from the source of 0.16.0 and from small programs that reference each part.

## Tcl and its packages

- The core `http` package 2.9 and the `zlib` command of Tcl 8.6.16, and the core test files `http.test`, `zlib.test`, `clock.test`, `event.test`, `socket.test`, `timer.test`, `ioCmd.test`, `chanio.test`, and `coroutine.test`. https://github.com/tcltk/tcl, tag `core-8-6-16`. **License:** Tcl/Tk License (BSD style).
- tcllib: the manual pages and test files of `json`, `json::write`, `base64`, `base32`, `uuencode`, `uri`, `csv`, `sha1`, `sha256`, `md5`, `crc32`, `uuid`, `logger`, `cmdline`, `fileutil`, `websocket`, and the other packages of the API table in the design. https://core.tcl-lang.org/tcllib. **License:** BSD style; each task checks it.
- TclTLS: the manual page of `tls::socket`, `tls::import`, `tls::handshake`, and `tls::status`. https://core.tcl-lang.org/tcltls. **License:** each task checks it.

**How ztcl uses them:** the names, options, results, and error messages of the commands that the design wraps. The test files run as outside files.

## JSON

- Langdale and Lemire, "Parsing Gigabytes of JSON per Second", VLDB Journal 28 (2019). The two stages of the parser. The simdjson project, https://github.com/simdjson/simdjson, is a benchmark peer.
- RFC 8259.
- JSONTestSuite, Nicolas Seriot, https://github.com/nst/JSONTestSuite. The conformance gate.
- nativejson-benchmark, Milo Yip, https://github.com/miloyip/nativejson-benchmark: `twitter.json`, `canada.json`, and `citm_catalog.json`.

## HTTP

- RFC 9110 (semantics), RFC 9112 (HTTP/1.1), RFC 9113 (HTTP/2), RFC 7541 (HPACK), RFC 9218 (priorities), RFC 6455 (WebSockets), RFC 8441 (WebSockets over HTTP/2), RFC 7301 (ALPN), and the HTML standard section on server-sent events.
- h2spec, https://github.com/summerwind/h2spec. The HTTP/2 conformance gate.
- `hpack-test-case`, https://github.com/http2jp/hpack-test-case.
- The Autobahn test suite, https://github.com/crossbario/autobahn-testsuite. The WebSocket gate.
- TechEmpower Framework Benchmarks, the plaintext and JSON test rules, https://www.techempower.com/benchmarks/.
- The WHATWG URL standard and its `urltestdata.json`, https://url.spec.whatwg.org.

## TLS

- RFC 8446 (TLS 1.3), RFC 8448 (example handshake traces), RFC 5869 (HKDF), RFC 5280 (X.509), RFC 6125 (host names), RFC 6066 (SNI), RFC 7748 (X25519), RFC 8032 (Ed25519), RFC 8017 (RSA), RFC 8439 (ChaCha20-Poly1305).
- Project Wycheproof, https://github.com/C2SP/wycheproof. Test sets for the primitives.
- x509-limbo, https://github.com/C2SP/x509-limbo. The chain validation cases.
- tlsfuzzer, https://github.com/tlsfuzzer/tlsfuzzer. It runs as an outside program. ztcl reads no source of it. Task 21 records its license.
- OpenSSL 3 (`s_client`, `s_server`, `s_time`, `speed`) and curl. Interop peers.
- Reparaz, Balasch, and Verbauwhede, "Dude, is my code constant time?", DATE 2017. The timing test method.

## QUIC and HTTP/3

- RFC 9000, RFC 9001, RFC 9002, RFC 9114, and RFC 9204.
- quic-interop-runner, https://github.com/quic-interop/quic-interop-runner. The interop gate.
- The QPACK interop corpus, https://github.com/qpackers/qifs.

## Formats, compression, and crypto

- RFC 4180 (CSV), TOML 1.0 and `toml-test` (https://github.com/toml-lang/toml-test), the MessagePack specification, RFC 8949 (CBOR), RFC 4648 (base encodings).
- RFC 1950, 1951, 1952 (zlib, deflate, gzip), RFC 8878 (zstd).
- NIST CAVP test vectors, the BLAKE3 test vectors (https://github.com/BLAKE3-team/BLAKE3), RFC 4231, RFC 9106 (argon2).

## Time

- The IANA time zone database, https://www.iana.org/time-zones. `tzdata.zi` and the TZif format of RFC 8536. **License:** public domain.

## SQLite

- SQLite, https://sqlite.org: the amalgamation, the manual page of the Tcl interface, the documentation of the VFS, `SQLITE_OS_OTHER`, and `SQLITE_CONFIG_MALLOC`, and the test files. **License:** public domain.

**How ztcl uses it:** the amalgamation compiles into the module after decision 9. The `sqlite3` command follows the manual page of the Tcl interface. ztcl has no code of `tclsqlite.c`.
