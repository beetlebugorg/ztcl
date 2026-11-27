# References for the standard library

The plan in [the design](../dev/stdlib.md) uses these sources. ztcl copies no code from them, except the SQLite amalgamation after decision 9 of the design. Each task checks the license of each source that it uses and adds the facts that it checked here.

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

The JSON parser of ztcl implements the simdjson algorithm in Zig. The code in `src/json/` is new: ztcl copies no code, no lookup table, and no constant set from simdjson. [licenses/simdjson-NOTICE.txt](../../licenses/simdjson-NOTICE.txt) has the notice.

- simdjson, https://github.com/simdjson/simdjson. **License:** Apache-2.0 or MIT. **What ztcl takes:** the two stages of the parser. Stage 1 (`src/json/index.zig`) makes bit masks of 64 bytes for the quotes, the backslashes, the white space, and the operators, finds the escaped bytes with an add of the starts of the backslash runs, makes the string mask with a prefix XOR of the quotes, and writes the positions of the structural bytes. Stage 2 (`src/json/build.zig`) walks the positions with a stack and makes the values. simdjson is also a peer in the benchmarks (`bench/stdlib/json/bench_c.cpp` runs it as an outside program).
- Geoff Langdale and Daniel Lemire, "Parsing Gigabytes of JSON per Second", The VLDB Journal 28 (2019), https://arxiv.org/abs/1902.08318. **What ztcl takes:** the method of stage 1 above, the carry of the escape state, of the string state, and of the scalar state from one block to the next, and the write of eight positions at a time with a count of the bits.
- John Keiser and Daniel Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte", Software: Practice and Experience 51 (2021), https://arxiv.org/abs/2010.03090. **What ztcl takes:** the idea to check only the blocks that have a byte above 127. The check of such a block is a byte state machine of RFC 3629, so ztcl does not use the lookup method of the paper.
- Daniel Lemire, "Number Parsing at a Gigabyte per Second", Software: Practice and Experience 51 (2021), https://arxiv.org/abs/2101.11408. **What ztcl takes:** a double with at most 19 digits and an exponent of 22 or less is exact with one multiply or one divide by a power of ten (the fast path of Clinger, as the paper gives it). A double with at most 19 digits and no fast path uses the Eisel-Lemire step of sections 5 and 6 on the parsed mantissa (`src/json/number.zig`). Its 128-bit table of the powers of five is made at compile time with the rules of the paper: a power with a positive exponent is truncated, and a power with a negative exponent is rounded up. The code of the step follows `std.fmt.parse_float/convert_eisel_lemire.zig` of Zig 0.16.0 (MIT, [licenses/zig-std-MIT.txt](../../licenses/zig-std-MIT.txt)). Other doubles go to `std.fmt.parseFloat`, which has an exact fallback.
- RFC 8259, The JavaScript Object Notation (JSON) Data Interchange Format. The grammar.
- JSONTestSuite, Nicolas Seriot, https://github.com/nst/JSONTestSuite. **License:** MIT. The conformance gate: `zig build json-test` runs its `test_parsing/` files as outside files. The repository has no copy.
- nativejson-benchmark, Milo Yip, https://github.com/miloyip/nativejson-benchmark: `twitter.json`, `canada.json`, and `citm_catalog.json`, fetched by `bench/stdlib/fetch.sh` with a SHA-256 of each file. The repository has no copy.
- yyjson, https://github.com/ibireme/yyjson. **License:** MIT. A peer in the benchmarks only.

## HTTP

- RFC 9110 (semantics), RFC 9112 (HTTP/1.1), RFC 9113 (HTTP/2), RFC 7541 (HPACK), RFC 9218 (priorities), RFC 6455 (WebSockets), RFC 8441 (WebSockets over HTTP/2), RFC 7301 (ALPN), and the HTML standard section on server-sent events.
- h2spec, https://github.com/summerwind/h2spec. **License:** MIT. The HTTP/2 conformance gate, run as an outside program.
- `hpack-test-case`, HTTP/2 Japan Community, https://github.com/http2jp/hpack-test-case. **License:** MIT. Test data: `zig build hpack-corpus -- DIR` reads its stories. The repository has no copy.
- nghttp2, https://nghttp2.org. **License:** MIT. `h2load` and the reference server `nghttpd` in the benchmarks only.
- `src/h2/hpack_tables.zig` has the static table (appendix A), the Huffman code (appendix B), and the examples of appendix C.3 to C.6 of RFC 7541, from the text of the RFC by `tools/hpack-tables.py`.
- The Autobahn test suite, https://github.com/crossbario/autobahn-testsuite. The WebSocket gate.
- TechEmpower Framework Benchmarks, the plaintext and JSON test rules, https://www.techempower.com/benchmarks/.
- The WHATWG URL standard and its `urltestdata.json`, https://url.spec.whatwg.org.

## TLS

- RFC 8446 (TLS 1.3), RFC 8448 (example handshake traces), RFC 5869 (HKDF), RFC 5280 (X.509), RFC 6125 (host names), RFC 6066 (SNI), RFC 7748 (X25519), RFC 8032 (Ed25519), RFC 8017 (RSA), RFC 8439 (ChaCha20-Poly1305).
- `src/tls/testdata/rfc8448.txt` has the values of the five traces of RFC 8448. `tools/rfc8448-vectors.py` makes it from the text of the RFC.
- Project Wycheproof, https://github.com/C2SP/wycheproof. Test sets for the primitives.
- x509-limbo, https://github.com/C2SP/x509-limbo. The chain validation cases.
- tlsfuzzer, https://github.com/tlsfuzzer/tlsfuzzer. It runs as an outside program. ztcl reads no source of it. Task 21 records its license.
- OpenSSL 3 (`s_client`, `s_server`, `s_time`, `speed`) and curl. Interop peers.
- Reparaz, Balasch, and Verbauwhede, "Dude, is my code constant time?", DATE 2017. The timing test method.
- Shay Gueron and Michael E. Kounavis, "Intel Carry-Less Multiplication Instruction and its Usage for Computing the GCM Mode", Intel white paper 323640 (2010). **What ztcl takes:** in `src/crypto/x86_avx2.zig`, the GHASH of the byte-reversed blocks with the key shifted left by one bit, the reduction with two carry-less multiplications, the aggregated reduction of 8 blocks with the powers H^1 to H^8, and the AES-128 and AES-256 key expansion with AESKEYGENASSIST. The code is new.
- Zig 0.17.0, `lib/std/crypto/ghash_polyval.zig` (MIT, [licenses/zig-std-MIT.txt](../../licenses/zig-std-MIT.txt)). **What ztcl takes:** the same GHASH method as above, in `std.crypto`; `src/crypto/x86_avx2.zig` uses its order of the operations of the reduction and its constant 0xC2 << 56.
- RFC 8439 sections 2.1 to 2.8 for `src/crypto/x86_chacha.zig`. The Poly1305 with two 64-bit limbs and the fold of the bits from 2^130 up with a multiply by 5 is the method of the scalar Poly1305 of `std.crypto` of Zig 0.17.0 (MIT); the code is new.
- Martin Goll and Shay Gueron, "Vectorization of Poly1305 Message Authentication Code", ITNG 2015. **What ztcl takes:** in `src/crypto/x86_chacha.zig`, the 4 lanes of five 26-bit limbs, the step h = h * r^4 + m, and the end with the powers r^4 to r^1. The code is new.
- Intel 64 and IA-32 Architectures Software Developer's Manual, volume 2: CPUID leaves 1 and 7 and XGETBV, for the run-time check of `src/tls/aead.zig`.

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
