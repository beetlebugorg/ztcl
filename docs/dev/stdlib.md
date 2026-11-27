# A batteries-included runtime

This page is the plan for issue 27: a standard library of native modules in one static binary. It has the module system, the API rules, each module, the HTTP server, TLS 1.3, HTTP/2, SQLite, the limits and the capabilities, the size budget, the performance targets, and the decisions that are still open. [The task list](stdlib-tasks/README.md) has the order of the work. [References](../references/stdlib.md) lists the sources.

The plan adds no code. The user approves it before task 01 starts.

## Summary

- Each module is Zig code in the binary. `package require` loads it from memory. A build flag leaves it out.
- The new API is in the namespace `ztcl`. The names of tcllib, of the core `http` package, and of TclTLS stay where they exist, as thin commands over the same native code.
- The HTTP server has a pool of workers. Each worker is a thread with its own interpreter, as in [the threads plan](../threads.md). A request runs with its own compute limit, memory limit, and deadline, so a runaway handler fails alone.
- Async I/O runs on io_uring (Linux), kqueue (macOS), and IOCP (Windows) behind the `std.Io` interface. A handler runs in a coroutine and looks synchronous.
- TLS 1.3 is new code on `std.crypto` for both the server and the client. It stays behind a flag until an external review is done.
- HTTP/1.1, WebSockets, SSE, and HTTP/2 come first. HTTP/3 over QUIC is the last milestone.
- SQLite is an optional module: the amalgamation, compiled with `zig cc`, with no libc, behind the capability `sqlite`.
- A full build has a budget of 6 MB, stripped. CI reports the size of each module and fails above the budget.

## The decisions of the user

Issue 27 has four decisions of 2026-11-24. They bind this plan.

1. TLS: our own TLS 1.3, server and client, on the primitives of `std.crypto`.
2. SQLite: an optional module compiled with `zig cc`.
3. API: the names of tcllib where they exist, plus a fresh, consistent API in a new namespace, unless the current API is already good.
4. HTTP/2 now. HTTP/3 over QUIC later.

## What exists today

These facts are from `main` at the commit of this plan.

- The runner `ztcl` is 2 343 816 bytes after `strip`, built with `ReleaseFast` for x86-64 Linux from commit `05e7669`. Issue 27 gives 2.5 MB as the size of today. The budget uses the measured number.
- `zig build wasm` makes `ztcl.wasm` of 825 KB (`docs/webassembly.md`).
- The core has `binary encode` and `binary decode` for base64 and hex, `regexp`, `format`, `scan`, `coroutine`, TclOO, and `clock` with zones from TZif data of the embedder.
- The capabilities are `package`, `interp`, `clock`, `channels`, `file`, `event`, `socket`, and `exec` (`Interp.Capability` in `src/interp.zig`). Each is off by default.
- `src/event.zig` waits with `poll` through `src/sys.zig`. `src/sys.zig` has the Linux forms only.
- The coroutine switch exists for x86-64 Linux only (`src/coro.zig`). On other targets, `coroutine` gives an error.
- `package` keeps versions and `ifneeded` scripts in memory and reads no files (`src/pkg.zig`).
- The thread commands are a plan ([threads](../threads.md)). `src/thread.zig` does not exist yet.

## What Zig 0.16 std has

The plan uses the std code where it fits and says what is missing. The sizes are of a small program that references the named functions, stripped, for x86-64 Linux. They include the std code that the functions pull in, such as `std.Io`. So they are upper bounds for the module alone.

| std part | What it has | Size, ReleaseFast / ReleaseSmall | What is missing for ztcl |
|---|---|---|---|
| `std.json` | A streaming scanner (`Scanner.zig`), typed parse to Zig structs, a dynamic `Value`, and `Stringify`. | not measured | No SIMD stage. The output is Zig values, and ztcl needs Tcl values in its own heap. No path query. |
| `std.http.Server` | HTTP/1.1 for one connection, chunked bodies, and a small WebSocket (`respondWebSocket`, `readSmallMessage`, `writeMessage`). | 33 584 / 21 296 | No router, no HTTP/2, no limits for a hostile peer beyond the buffer size, no SSE helpers, no fragmented WebSocket messages over the small size. |
| `std.http.Client` | HTTP/1.1, a connection pool, redirects, and TLS through `std.crypto.tls.Client`. | 965 064 / 573 048 | No HTTP/2, no network policy check per address. |
| `std.crypto.tls.Client` | A TLS 1.3 and 1.2 client with AES-GCM, ChaCha20-Poly1305, and AEGIS suites, X25519, P-256, P-384, and the hybrid groups `x25519_ml_kem768` and `secp256r1_ml_kem256`. | 570 160 / 320 304 | No server. No ALPN result for the caller to choose `h2`. No resumption or 0-RTT. The record code is inside the client. |
| `std.crypto.Certificate` | X.509 parse, signature checks (RSA PKCS#1 v1.5, RSA-PSS, ECDSA, Ed25519), host name checks, and `Bundle.rescan` for the system roots on Linux, macOS, and Windows. | 303 920 / 193 328 | `Parsed.verify` checks the issuer name, the dates, and the signature. It does not check `basicConstraints` (the CA flag and the path length), the key usage, the extended key usage, or name constraints. No PEM private key parse. No RSA private key operation. |
| `std.crypto` | SHA-1, SHA-2, SHA-3, BLAKE2, BLAKE3, HMAC, HKDF, PBKDF2, scrypt, argon2, bcrypt, AES-GCM, ChaCha20-Poly1305, AEGIS, Ed25519, X25519, ECDSA P-256 and P-384, ML-KEM, ML-DSA, and `timing_safe`. `std.crypto.ff` is constant-time modular arithmetic. Its header says "best-effort" constant time. | part of the rows above | A secure random source that honors the capabilities. |
| `std.compress` | `flate` with `Compress` and `Decompress` for raw, zlib, and gzip containers. `zstd` with `Decompress` only. xz and lzma decompression. | flate 45 872 / 29 488, zstd 302 392 / 185 368 | A zstd compressor. |
| `std.Io` | The async interface: files, sockets, processes, time, `async`, `concurrent`, `select`, groups, and locks. `Io.Threaded` on each system. `Io.Evented` is `Uring` on Linux, `Dispatch` on macOS, and `Kqueue` on the BSDs. Fibers exist for x86-64, aarch64, and riscv64. | | No evented backend on Windows: `Io.Evented` is `void` there. The evented backends have open `TODO` and `@panic` markers: 21 in `Uring.zig`, 17 in `Dispatch.zig`, and 61 in `Kqueue.zig`. |
| `std.tz` | A TZif parser. | | No zone data. |
| `std.Uri`, `std.base64` | URI parse and format, base64. | | No query string parse, no IDNA. |

The size of the TLS client and of the certificate code overlap. The plan estimates the TLS module from both.

## The module system

### Built-in modules

A module is a Zig file with a table entry:

```zig
pub const module = ztcl.Module{
    .name = "ztcl::json",
    .version = "1.0",
    .aliases = &.{ .{ "json", "1.3.4" }, .{ "json::write", "1.0.4" } },
    .needs = 0, // capability bits
    .install = install,
    .script = @embedFile("json.tcl"), // optional Tcl code of the module
};
```

- `src/modules.zig` has the table. The build adds each module that its flag allows.
- `package require ztcl::json` calls `install` once for each interpreter. `install` registers the native commands and runs the embedded script. The script is text in the binary. No file is read.
- An alias name loads the same module and installs the compatible commands (see below). `package require json` gives the tcllib commands. `package require ztcl::json` gives the new API. Both use one copy of the native code.
- The registry works without the capability `package`. Today a script with no `package` capability has no `package` command. The plan adds a small `package require` (and `package present`, `package provide`, `package versions`) that sees only the built-in modules and that is present by default. The full `package` command stays a capability. **Decision for the user (1).**
- A module that needs a capability is visible in `package names` but `package require` gives the error `module "ztcl::http" needs the capability socket`.
- A child interpreter gets only the modules that it requires itself, and only with the capabilities of the child.

### Build flags

| Flag | Effect |
|---|---|
| `-Dbatteries=core` | No module. The binary of today. |
| `-Dbatteries=std` (default) | All modules except `sqlite` and `http3`. |
| `-Dbatteries=full` | All modules. |
| `-Dmod-NAME=false` or `=true` | Leaves one module out or puts it in, after the preset. |
| `-Dtls=off`, `experimental`, `on` | TLS is `experimental` until task 27 (the review). `experimental` builds TLS, and the runner needs `--allow-experimental-tls` to use it. |
| `-Dtzdata=embed` (default), `host`, `none` | Where the zone data comes from. |

A module that another module needs is put in with it, and the build prints the reason. `http` needs `aio`. `https` needs `tls` and `http`. `h2` needs `http`.

### The size report

`tools/size-report.sh` builds the runner once with `-Dbatteries=core`, once with `full`, and once with `full` and each module off. It strips each binary and writes a table: the size of each module (the full size minus the size without it), the full size, and the change from `main`. CI runs it on x86-64 Linux, arm64 macOS, and x86-64 Windows, and fails when:

- the full build of x86-64 Linux passes 6,600,000 bytes after `strip` (6,000,000 before `ztcl::tls`, 6,500,000 until 2026-11-27), or
- a module grows more than 10 % above its budget in the table below without a change of the table in the same PR.

The WebAssembly build has its own row and gate (see "WebAssembly").

### The size budget

The estimates are guesses from the measured std sizes above and from the size of similar code in ztcl. Each task measures its module and corrects the row.

| Module | Estimate, KB | Basis |
|---|---|---|
| Core of today | 2 344 | measured |
| Module table and `package require` | 10 | estimate |
| `json` | 115 | measured: 104.5 in task 05 (x86-64 Linux, `ReleaseFast`). The parser has two forms of the walk (build and check), and the module has the writer and the tcllib names. |
| `formats` (csv, toml, msgpack, cbor), `url`, `encode` | 90 | estimate |
| `compress` (flate, zstd both ways) | 270 | std flate and zstd measured as upper bounds, a new zstd compressor estimated at 60 |
| `crypto` (the hashes, HMAC, argon2, AEAD, signatures, random) | 200 | estimate |
| `aio` | 80 | estimate |
| `http` (HTTP/1.1 client and server, WebSockets, SSE, router) | 220 | estimate |
| `h2` (HTTP/2 and HPACK) | 90 | estimate |
| `tls` (TLS 1.3 both sides, X.509, PEM, roots) | 650 | std client 570 and certificates 304 measured, with overlap |
| `time` (zones, durations) and the zone data | 65 | estimate, and 24 532 bytes measured for `tzdata.zi` with `gzip -9` |
| `log` | 20 | estimate |
| `sys` (paths, watch, processes, env, args) and `dns` | 100 | estimate |
| `tmpl` | 30 | estimate |
| `tooling` (test runner, bench, profiler) | 60 | estimate |
| `build` (the bundle reader) | 30 | estimate |
| `sqlite` | 800 | 761 615 bytes measured (text, data, and bss of `sqlite3.o`, see below), and 40 for the binding |
| **Full build without `http3`** | **5 174** | sum |
| `http3` (QUIC, HTTP/3, QPACK) | 250 | estimate |
| **Full build** | **5 424** | sum, under the budget of 6 000 |

The SQLite measure: SQLite 3.53.0 amalgamation, `zig cc -target x86_64-linux-musl -Os -c` with `SQLITE_OS_OTHER=1`, `SQLITE_THREADSAFE=0`, `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_DQS=0`, `SQLITE_DEFAULT_MEMSTATUS=0`, `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_SHARED_CACHE`, and `SQLITE_OMIT_LOCALTIME`. `size` gave text 749 535, data 11 136, and bss 944. The compile used 26 s. The same flags without `SQLITE_OS_OTHER`, `SQLITE_OMIT_LOCALTIME`, and with the unix VFS gave 780 265 bytes. Task 39 picks the optimize mode of SQLite. The table assumes `-Os` for SQLite.

The margin is about 600 KB. A module can build with `ReleaseSmall` in a `ReleaseFast` runner, because a Zig module has its own optimize mode. The size task of each module tries this for code that is not hot.

## The API rules

### The namespace `ztcl`

The new API is in `::ztcl`. Each module is an ensemble command in it: `ztcl::json`, `ztcl::http`, `ztcl::hash`, and so on.

The reasons:

- It is short. A handler of a service names it often, and `namespace import` or `namespace path ::ztcl` makes it shorter.
- It is the first two letters of the binary name, so a reader of a script can see where it comes from.
- tcllib, the Tcl core (`tcl::` and `::oo`), and the packages that issue 27 names do not use it. The task of the module system checks the names of tcllib 2.0 and of Tcl 9.1 again.
- The other choices: `ztcl::` is longer in each call. `std::` is generic, a user namespace can have that name, and it says that the API is a standard. `tcl::` belongs to the Tcl core.

**Decision for the user (2):** the name `ztcl`. The first name was `zt`. The modules moved to `ztcl` before v0.3.0-beta, and the deprecated aliases `zt::` went away in #134.

### Rules for the new API

1. One ensemble for each module. Subcommands are verbs: `ztcl::json parse`, `ztcl::json encode`, `ztcl::hash sha256`.
2. Options come before the positional arguments, start with `-`, and accept `--` to end the options.
3. A result is a plain Tcl value: a string, a list, or a dict. A resource with a life (a connection, a server, a stream, a database) is a command, as `open` gives a channel and TclOO gives an object. `$obj close` or `rename $obj {}` frees it.
4. Bytes are byte strings (each character below 256), as in `binary`. A text result is UTF-8. A command that reads bytes says so in its manual.
5. Errors have an `errorCode` that starts with `ZT` and the module: `ZT JSON SYNTAX 1 17`, `ZT HTTP TIMEOUT`, `ZT TLS ALERT bad_certificate`.
6. A blocking call inside a coroutine yields to the event loop and looks synchronous. Outside a coroutine, it runs the event loop until it is done, as `vwait` does.
7. Each command with a cost that grows with its input pays compute units and gets its memory through the counter (see "Limits and capabilities").

### The choice for each module

"Keep" means the old names stay, with the same results. "Wrap" means the old names stay as thin commands over the new native code. "Replace" means only the new API exists for that function, and the old package is not provided. The names of tcllib are from its table of contents. The task of each module checks each name, each option, and each result against the manual page of tcllib 2.0, and adds the tests of the tcllib test file when its license allows that (BSD style, as tcllib).

| Package or command | Source | Choice | The new API |
|---|---|---|---|
| `json` (`json::json2dict`, `json::many-json2dict`, `json::validate`) | tcllib | Wrap | `ztcl::json`: SIMD parse, typed encode, path queries, and streams. The tcllib API has no typed encode and no path query. |
| `json::write` | tcllib | Wrap | `ztcl::json` builders |
| `http` (`http::geturl`, `http::config`, `http::data`, `http::status`, `http::ncode`, `http::meta`, `http::cleanup`, `http::register`) | Tcl core package 2.9 | Wrap | `ztcl::http`: client and server. The `http` package is a client only, and its state array per token does not fit a coroutine handler. |
| `tls` (`tls::socket`, `tls::import`, `tls::handshake`, `tls::status`) | TclTLS | Wrap a subset | `ztcl::tls` |
| `zlib` | Tcl core command | Keep | `ztcl::zstd` has the same shape as `zlib` for zstd. The `zlib` API is good, and the core test file `zlib.test` measures it. |
| `binary encode` and `binary decode` (base64, hex) | Tcl core | Keep | None. The API is good. `ztcl::encode` adds base32, base58, and base64url with the same shape. |
| `base64` (`base64::encode`, `base64::decode`), `base32`, `uuencode` | tcllib | Wrap | `binary encode` and `ztcl::encode` |
| `uri` (`uri::split`, `uri::join`, `uri::resolve`, `uri::isrelative`, `uri::canonicalize`) | tcllib | Wrap | `ztcl::url`: parse, build, query strings, and percent codes. |
| `csv` (`csv::split`, `csv::join`, `csv::joinlist`, `csv::iscomplete`) | tcllib | Wrap | `ztcl::csv`: RFC 4180 read and write, rows from a channel. |
| `sha256` (`sha2::sha256`, `sha2::hmac`), `sha1`, `md5`, `crc32` (`crc::crc32`) | tcllib | Wrap | `ztcl::hash` |
| `aes`, `pki`, `rc4`, `blowfish`, `des` | tcllib | Replace | `ztcl::crypto`: AEAD and signatures only. The old ciphers are not provided. |
| `uuid` (`uuid::uuid generate`) | tcllib | Wrap | `ztcl::crypto uuid` |
| `logger`, `log` | tcllib | Wrap a subset of `logger` | `ztcl::log`: structured records. |
| `cmdline` (`cmdline::getoptions`, `cmdline::getKnownOptions`, `cmdline::usage`) | tcllib | Wrap | `ztcl::args` |
| `fileutil` | tcllib | Wrap `cat`, `writeFile`, `appendToFile`, `find`, `tempfile` | `ztcl::fs`: walk, watch, atomic write. `file` and `glob` stay as the core commands. |
| `websocket` | tcllib | Wrap the client (`websocket::open`, `websocket::send`, `websocket::close`) | `ztcl::http websocket` and the server API |
| `httpd` | tcllib | Replace | `ztcl::http server` |
| `dns` | tcllib | Replace | `ztcl::dns` |
| `textutil::expander` | tcllib | Replace | `ztcl::tmpl` with escapes by default |
| `clock_iso8601`, `clock_rfc2822` | tcllib | Replace | `clock` (core, kept) and `ztcl::time` |
| `tcltest` | Tcl | Keep | `ztcl test` runs `.test` files. The API is good. |
| `bench`, `profiler` | tcllib | Replace | `ztcl::bench`, `ztcl prof` |
| `sqlite3` | SQLite | Keep | None. The binding of SQLite is the API (decision 2). |
| TOML, MessagePack, CBOR | none in tcllib | New | `ztcl::toml`, `ztcl::msgpack`, `ztcl::cbor` |

A wrapped command keeps the result and the error message of the old package for each input of its test file. Where the old package is wrong by RFC (for example a JSON text that tcllib accepts and RFC 8259 rejects), the wrapper keeps the old behavior, and the new API follows the RFC. The manual of the wrapper lists each such case.

## Limits and capabilities

### The rule for each module

1. **Steps.** A native command pays one compute unit for each 4,096 bytes of input or output, and one compute unit for each element of a list or dict that it makes. A command that runs a script (a handler, a callback) pays as a script does.
2. **Memory.** Each allocation of a Tcl value goes through the counter of the interpreter. A native buffer outside the heap (a socket buffer, a TLS record, a zstd window) counts in the per-connection limits of its module, and the module has a fixed top for it.
3. **Safe points.** A loop in native code over large input checks the compute limit and the memory limit at least each 64 KiB, so a limit stops one command at a bounded point.
4. **Host access.** A command that reaches the host needs a capability. The default interpreter stays deterministic: no clock, no entropy, no network, no files.
5. **Network.** Each address goes through the policy of `src/sock.zig`: the check runs on each resolved address, on each connection, and on each peer of a server.
6. **Files.** Each path goes through the root folder of `src/fsroot.zig`.
7. **Bounds on hostile input.** Each parser has a depth limit and a size limit, with the defaults in the table below. A peer that passes a limit gets a protocol error, and the connection closes.

### New capabilities

| Capability | What it turns on |
|---|---|
| `random` | Entropy from the system: `ztcl::crypto random`, `uuid`, and the key generation of TLS. Without it, the default stays deterministic. TLS needs it. |
| `env` | `ztcl::sys env`: read the environment. |
| `thread` | From the threads plan. The worker pool of the server needs it. |
| `sqlite` | The `sqlite3` command. Files need `file` too. `:memory:` needs only `sqlite`. |
| `fetch` | WebAssembly only: the HTTP client through a host import. |

The server needs `socket`, `event`, and `thread`. TLS also needs `random` and a key from the embedder or from a file under the root folder.

### The capability and the limits of each module

| Module | Capability | Default limits for hostile input |
|---|---|---|
| `json` | none | depth 512, a number at most 1 MB of digits, the input at most the memory limit |
| `formats`, `url`, `encode` | none | depth 512 for msgpack, cbor, and toml |
| `compress` | none | output at most 64 times the input and at most the memory limit, unless `-maxsize` says more (a bound on zip bombs). The zstd window is at most 8 MiB, the default of `std.compress.zstd`. |
| `hash` | none | |
| `crypto` | `random` for keys, nonces, and `uuid`. Hashes, HMAC, signatures with a given key, and AEAD with a given nonce need none. | argon2 memory counts in the memory limit |
| `time` | `clock` for the current time. Conversions of a given time need none. | |
| `log` | none. Records go to the output callback of the embedder or to a channel that the script has. | |
| `sys` | `file` for paths and watch, `exec` for processes, `env` for the environment | |
| `dns` | `socket` | the policy also applies to the name server address |
| `tmpl` | none | |
| `aio` | `event` | |
| `http` client | `socket` and `event` | 64 KiB of headers, 100 headers, the body at most the memory limit, 20 redirects |
| `http` server | `socket`, `event`, and `thread` | see "The server" |
| `tls` | `socket`, `random` | 16 KiB records, a chain of at most 10 certificates, 64 KiB of handshake messages |
| `h2` | as `http` | 100 streams, 64 KiB of header list, 4,096 bytes of HPACK table, a reset flood limit |
| `sqlite` | `sqlite`, and `file` for files | see "SQLite" |
| `build` | `file` | |

The tests of each module show that its commands are absent without the capability, in a safe child interpreter, and in a child that has fewer capabilities than its parent.

## Async I/O

### The design

One module, `src/aio/`, gives the event loop, the sockets, the files of channels, the timers, and the waits of threads. Its interface is `std.Io`, so the std HTTP and TLS readers and writers work on it, and new code is written once.

- Linux: io_uring. `std.Io.Uring` exists. Task 06 tests it against the needs of ztcl: accept, connect, read, write, `sendfile` through `netWriteFile`, timers, cancel, and a wake from another thread. Where it fails a test, `src/aio/uring.zig` implements that part of the `std.Io` vtable on `std.os.linux.IoUring`. A kernel with io_uring off (a seccomp filter or the sysctl `kernel.io_uring_disabled`) uses `epoll` through the same vtable.
- macOS: kqueue. `std.Io.Evented` on macOS is `Dispatch`. `std.Io.Kqueue` is for the BSDs and has 61 open markers. Task 09 compares both on macOS and picks one. If neither passes the tests, `src/aio/kqueue.zig` implements the vtable subset.
- Windows: IOCP. std has no evented backend for Windows. `src/aio/iocp.zig` implements the vtable subset on `CreateIoCompletionPort`, `AcceptEx`, `ConnectEx`, `WSARecv`, `WSASend`, and `GetQueuedCompletionStatusEx`. Files use `Io.Threaded`.
- WebAssembly: no `aio`. The event loop of the host drives the module (see "WebAssembly").

### The test of `std.Io.Uring` (task 06)

On 2026-11-26, a probe program used `std.Io.Uring` of Zig 0.17.0 on x86-64 Linux for the operations of task 06. The result:

- A program that calls `Uring.io()` does not compile. The vtable of `Uring.zig` sets `processReplacePath`, and `Io.VTable` has no field of that name (`Uring.zig:759`).
- `net.Stream.read` does not compile on any `Io` (`net.zig:1286`: "type 'Io.net.Stream.ReadResult' cannot be destructured").
- These vtable entries of `Uring` return `error.Unimplemented`: `netListenIp`, `netAccept`, `netConnectIp`, `netListenUnix`, `netConnectUnix`, `netSocketCreatePair`, `netWriteFile` (`sendfile`), `netInterfaceNameResolve`, `netInterfaceName`, and `netLookup`.
- The `net_write` operation is `@panic("TODO implement net_write operation")` (`Uring.zig:2120`). The batch forms of `net_receive`, `net_send`, `net_read`, and `net_write` are `@panic` too.

So ztcl uses no part of `std.Io.Uring`. `src/aio/uring.zig` implements each operation of task 06 on `std.os.linux.IoUring`, which has `accept`, `connect`, `read`, `write`, `recv`, `send`, `splice`, `timeout`, `link_timeout`, `poll_add`, and `cancel`.

The interface of `aio` is open (see questions). An implementation of `std.Io` needs `async`, `await`, `cancel`, and the futex calls on fibers of its own, and 110 vtable entries. ztcl writes its own TLS and HTTP code. The std TLS 1.2 client of decision 7 reads and writes an `Io.Reader` and an `Io.Writer` (`std.crypto.tls.Client.init`), and a buffer of a connection of `aio` can give these two interfaces with no `std.Io`. A completion interface of its own (submit an operation with a callback or a coroutine to resume, and run the loop) is smaller, and `src/event.zig` and the coroutines of ztcl can use it directly.

### The aio loop on Linux (task 06)

`src/aio/` has the completion interface of the paragraph above, for Linux. A `Completion` has an operation (accept, connect, read, write, writev, or a timer), a callback, and a result: the count of bytes, the new descriptor, or 0, and a negative errno for an error. `Loop.submit` starts the operation, `Loop.run` waits with an optional time limit and runs the callbacks, `Loop.cancel` ends an operation with `-ECANCELED`, and `Loop.wake` ends a wait from another thread. The loop has no interpreter and no `std.Io`. `src/event.zig` does not use it yet.

- `uring.zig`: one SQE for each operation on `std.os.linux.IoUring`. A wait with a time limit adds a timeout with a count of one, so no timeout stays in the ring after the wait.
- `epoll.zig`: the system call at once, then a level-triggered wait for the read side or the write side of the descriptor. Timers are a list sorted by deadline. One operation can wait on each side of a descriptor.
- `Backend.auto` uses io_uring, and epoll when `io_uring_setup` fails. With `io_uring_setup` blocked by a seccomp filter (`systemd-run -p SystemCallFilter=~io_uring_setup`), `auto` gives epoll.

`zig build aio-test` runs the same tests on both backends. `zig build aio-stress -- --conns N --seconds S` runs N loopback connections that each send 16 bytes and read the echo, in one loop. `sendfile` is later work, with the HTTP server.

The stress gate on 2026-11-27 (x86-64 Linux, a shared machine, `--conns 10000 --seconds 300`, ReleaseSafe):

| Backend | Round trips | Memory after the connects | At 60 s | At the end | Descriptors left |
|---|---:|---:|---:|---:|---|
| uring | 9,560,457 | 3,564 KiB | 3,572 KiB | 3,572 KiB | the 2 of the loop |
| epoll | 7,740,000 | 3,640 KiB | 4,104 KiB | 4,104 KiB | the 2 of the loop |

### The aio loop on macOS (task 09)

`std.Io.Kqueue` and `std.Io.Dispatch` of Zig 0.17.0 are implementations of the `std.Io` interface on fibers (`Kqueue.zig` and `Dispatch.zig` use `std.Io.fiber`), as `std.Io.Uring` is. The reasons of task 06 hold for them too: `aio` is a completion interface with no `std.Io` and no fibers. So `src/aio/kqueue.zig` implements the loop on the `kqueue` and `kevent` calls of libc, with the same API and the same tests. ztcl ran no probe of the two `std.Io` files on macOS.

- `kqueue.zig`: the model of `epoll.zig`. The system call runs at once. On EAGAIN, the completion waits on its side, and a one-shot EVFILT_READ or EVFILT_WRITE filter goes into a list of changes. The next `kevent` of `run` gives the list and waits in one system call. A change that fails comes back with EV_ERROR and ends the completion with its errno. `wake` triggers an EVFILT_USER event.
- `sys.zig`: the system calls of `aio` and its tests, raw on Linux and through libc on macOS. macOS has no `accept4` and no `SOCK_NONBLOCK`, so `sys.accept` and `sys.tcpSocket` set O_NONBLOCK and FD_CLOEXEC with `fcntl`, and set SO_NOSIGPIPE.
- `aio-stress` on macOS raises the soft limit of descriptors to 40,000 (a finite limit above OPEN_MAX works up to `kern.maxfilesperproc`), keeps at most 100 connects in flight (macOS caps a backlog at `kern.ipc.somaxconn`, 128), counts the open descriptors with `fcntl`, and gives the peak RSS of `getrusage` in place of the current RSS.

`zig build aio-test` and `zig build aio-stress` build for macOS. The checks on 2026-11-27: the tests and the stress run pass on x86-64 Linux, and the tests and `aio-stress` compile for aarch64-macos and x86_64-macos. The run on a Mac (Apple M1, ReleaseFast):

| Run | Result |
|---|---|
| `zig build aio-test` | 8 of 8 pass |
| `--conns 1000 --seconds 20` | pass, 3,261,118 round trips, RSS 2.3 MB flat |
| `--conns 10000 --seconds 60` | pass, 20,005 descriptors, 6,940,000 round trips, RSS 4.5 MB flat |
| `--conns 5000 --seconds 300` (the gate) | pass, 10,005 descriptors, 35,790,000 round trips, RSS 3,248 KiB at the connects, the checkpoint, and the end |

Runs back to back leave the client sockets in TIME_WAIT (about 30 s on macOS), and the 16,384 ephemeral ports run out. Wait between runs: `aio-stress` reports the connects that fail with EADDRNOTAVAIL.

### The event loop of an interpreter

`src/event.zig` keeps its Tcl behavior: `after`, `vwait`, `update`, `fileevent`, the order of timers, and the idle scripts. Its wait changes from `poll` to the `aio` loop. The test files `event.test`, `socket.test`, `timer.test`, and `ioCmd.test` must keep their pass counts.

### Handlers that look synchronous

A blocking call of a module (`ztcl::http get`, a read of a socket, `ztcl::dns resolve`, `$db eval` when SQLite waits on a lock, `ztcl::sys sleep`) checks if it runs in a coroutine.

- In a coroutine, the command starts the operation, registers the coroutine as its waiter, and yields to the event loop. The loop resumes the coroutine with the result.
- Outside a coroutine, the command runs the event loop until its operation is done, as `vwait` does.

The server runs each request in its own coroutine. So a handler is plain sequential Tcl.

The coroutine switch is x86-64 Linux only today. Task 08 adds the switch for arm64 Linux, arm64 macOS, x86-64 macOS, and x86-64 Windows. It follows the register sets of `std.Io.fiber` and the stack rules of each ABI, and runs the core file `coroutine.test` on each target. Without a switch, a handler runs to its end, and a blocking call blocks the worker.

## JSON

### The parser

`src/json/` is a Zig implementation of the simdjson algorithm (see References). It has two stages:

1. A structural index. A pass over 64 bytes at a time with `@Vector` finds the quotes, the backslashes, and the structural characters, and checks UTF-8. The result is a list of positions. The pass has a scalar form for targets with no vectors and for the tail of the input.
2. A builder. It walks the index and makes Tcl values in the heap of the interpreter: a dict for an object, a list for an array, an int or a double for a number, and a string for a string. It allocates each list and dict at its final size, because the index gives the count of elements.

The builder is the expensive part, because each value is a heap object. The gate compares the time to a Tcl value with the time of other runtimes to their own values.

`std.json.Scanner` is the reference in the tests: both parsers must accept and reject the same inputs of JSONTestSuite.

### The new API

```tcl
package require ztcl::json

set doc [ztcl::json parse $text]                 ;# dicts and lists, null as the empty string
set doc [ztcl::json parse -null null $text]      ;# null as the string "null"
set doc [ztcl::json parse -typed $text]          ;# a tagged tree: {object {name {string ana}}}
ztcl::json get $text users 0 name                ;# a path query on the text, with no full parse
ztcl::json exists $text users 0 email
ztcl::json valid $text

ztcl::json encode -schema {id int name string tags {list string} meta object} $user
ztcl::json encode -typed $tree                   ;# the tagged tree back to text
ztcl::json object id 7 name [ztcl::json string ana] tags [ztcl::json array 1 2]
ztcl::json pretty $text

set s [ztcl::json stream $chan {apply {{event value} { ... }}}]
```

- A Tcl value has no visible type. So `encode` needs a schema or the typed tree. Without one, `encode` writes a dict as an object only with `-schema`, and the builders (`object`, `array`, `string`, `number`, `bool`, `null`, `raw`) write JSON text directly. The builders are the fast path for a handler that writes a response.
- The schema words: `string`, `int`, `number`, `bool`, `null`, `object` (any dict, values guessed), `{object SCHEMA}`, `{list WORD}`, `{optional WORD}`, and `raw` (already JSON text).
- "Guessed" means: a canonical integer or double is a number, `true` and `false` are booleans, and anything else is a string. The guess is the rule of `-schema object` and of `ztcl::json encode -auto`.
- `get` and `exists` run the index stage and walk only the path. A path step is a key or an index.
- `stream` gives events (`begin_object`, `key`, `value`, `end_object`, and so on) for input from a channel, in parts. It uses `std.json.Scanner`.

**Decision for the user (3):** null as the empty string by default, as tcllib does, or an error on null without `-null`.

### The tcllib names

`json::json2dict`, `json::many-json2dict`, `json::validate`, and the `json::write` commands (`object`, `array`, `string`, `indented`, `aligned`) use the same parser and builders.

## Formats and encodings

- `ztcl::csv read ?-sep ,? ?-quote \"? ?-header? $text`, `ztcl::csv write $rows`, and `ztcl::csv foreach row $chan {body}`. RFC 4180, with an option for the dialects of Excel. The tcllib `csv` commands wrap it.
- `ztcl::toml parse` and `ztcl::toml encode -schema`: TOML 1.0, with the `toml-test` suite.
- `ztcl::msgpack pack -schema` and `unpack`, `ztcl::cbor encode -schema` and `decode` (RFC 8949, with its appendix A vectors). Both use the typed tree form of `ztcl::json` for round trips.
- `ztcl::url parse $url` gives a dict (`scheme`, `user`, `host`, `port`, `path`, `query`, `fragment`). `ztcl::url build`, `ztcl::url query decode` and `encode`, `ztcl::url escape` and `unescape`, and `ztcl::url resolve`. It follows the WHATWG URL standard for the parse, with the test data `urltestdata.json`. `std.Uri` is the reference for RFC 3986 cases.
- `ztcl::encode base32`, `base32hex`, `base58`, and `base64url`, with the shape of `binary encode` and `binary decode`. The test vectors of RFC 4648.

## Compression

- The core command `zlib` (`compress`, `decompress`, `deflate`, `inflate`, `gzip`, `gunzip`, `stream`, `push`, `adler32`, `crc32`) on `std.compress.flate`. The core test file `zlib.test` is the gate.
- `ztcl::zstd compress ?-level N? $data`, `ztcl::zstd decompress ?-maxsize N? $data`, `ztcl::zstd stream`, and `ztcl::zstd push` for channels. The decoder is `std.compress.zstd.Decompress`. The encoder is new: levels 1 to 3 with a hash chain match finder and the entropy coders of RFC 8878. A level above 3 maps to level 3 in the first version.
- The HTTP module uses both for `Content-Encoding` (`gzip`, `deflate`, `zstd`), with the zip bomb bound.

## Hashes and crypto

```tcl
ztcl::hash sha256 $data                 ;# hex
ztcl::hash sha256 -bin $data            ;# bytes
ztcl::hash blake3 -length 64 $data
ztcl::hash hmac sha256 $key $data
set h [ztcl::hash new sha512]; $h update $part; $h digest; $h close
ztcl::hash equal $a $b                  ;# constant time compare

ztcl::crypto random 32                  ;# needs the capability random
ztcl::crypto uuid                       ;# version 4, needs random; uuid7 needs clock too
ztcl::crypto password hash $pw          ;# argon2id, a PHC string
ztcl::crypto password verify $pw $phc
ztcl::crypto seal chacha20-poly1305 $key $nonce $plain ?$ad?
ztcl::crypto open chacha20-poly1305 $key $nonce $sealed ?$ad?
ztcl::crypto keypair ed25519            ;# needs random
ztcl::crypto sign ed25519 $secret $msg
ztcl::crypto verify ed25519 $public $msg $sig
ztcl::crypto derive hkdf-sha256 $ikm -salt $s -info $i -length 32
```

All primitives are `std.crypto`. The hashes are SHA-1, SHA-2, SHA-3, BLAKE2b, BLAKE3, MD5, and CRC-32. The tcllib names (`sha2::sha256`, `sha2::hmac`, `sha1::sha1`, `md5::md5`, `crc::crc32`, `uuid::uuid generate`) wrap them. The test vectors are the NIST CAVP files, the BLAKE3 test vectors, RFC 4231 (HMAC), RFC 8032 (Ed25519), RFC 9106 (argon2), and RFC 8439 (ChaCha20-Poly1305).

## Time, zones, and logs

- `clock` stays the core command. Its zones come from the embedded data when the embedder gives no `zone` callback.
- The zone data. The plan embeds the IANA `tzdata.zi` file (the compact text of the zone rules, 104 917 bytes, 24 532 bytes with `gzip -9`, version 2026e), compressed with deflate. `src/tz.zig` compiles one zone to the TZif form of `clock.zig` at its first use. The other choice is the compiled TZif files of the 599 zones: 819 200 bytes in a tar, 142 766 bytes with `gzip -9`, and 74 613 bytes with `zstd -19`. The text form is smaller and needs a rule compiler of about 600 lines. **Decision for the user (4).** `-Dtzdata=host` reads `/usr/share/zoneinfo` through the embedder, and `none` has UTC and fixed offsets only.
- `ztcl::time now` (needs `clock`), `ztcl::time mono` (a clock that does not go back, needs `clock`), `ztcl::time parse iso8601|rfc3339|rfc2822|http $text`, `ztcl::time format`, `ztcl::time add $t 1h30m`, `ztcl::time zone $t America/New_York`, and durations as integers of nanoseconds with `ztcl::time duration 1h30m`.
- `ztcl::log`: `ztcl::log info "user login" user $id ip $addr`. A record is a dict: the time (with `clock`), the level, the message, and the fields. A sink is the output callback (the default), a channel, or a command. The formats are `text` and `json` (one object on each line). `ztcl::log level`, `ztcl::log with fields script` for a context, and a limit of records for each second. The tcllib `logger` subset (`logger::init`, `${log}::debug` and the other levels, `${log}::setlevel`) wraps it.

## System

- `ztcl::fs walk`, `ztcl::fs read`, `ztcl::fs write -atomic`, `ztcl::fs tempfile`, and `ztcl::fs watch $path $cmd` (inotify on Linux, kqueue on macOS, `ReadDirectoryChangesW` on Windows). All under the root folder and the capability `file`.
- `ztcl::path join`, `split`, `normalize`, `rel`, `ext`, and `stem`. Pure string functions, with no capability.
- `ztcl::proc run ?-timeout ms? ?-memory bytes? ?-env dict? ?-stdin data? cmd args`: one process with no shell, and a result dict (`code`, `stdout`, `stderr`, `time`). It uses the program list of `exec` and the capability `exec`. The memory limit uses `setrlimit` on Linux and macOS and a job object on Windows. `exec` stays unsandboxed, and the manual says so.
- `ztcl::sys env ?name?` (capability `env`), `ztcl::sys platform`, `ztcl::sys cpus`, and `ztcl::sys signal $name $cmd` (the runner only).
- `ztcl::args parse $spec $argv`: a spec of options, types, defaults, and help text. It gives a dict and prints the usage for `--help`. The tcllib `cmdline` commands wrap it.
- `ztcl::dns resolve ?-type A|AAAA|TXT|MX|SRV? $name`: a stub resolver over UDP and TCP to the name servers of the embedder, with the policy on the name server address and on each result. `sys.resolve` stays the only path from a name to a socket address, and it calls this resolver when the module is present. The roadmap lists this gap.

## Templates

`ztcl::tmpl compile $text` gives a command. A template has `{{ $var }}`, `{{ [cmd] }}`, `{% if %}`, `{% foreach %}`, and `{% include name %}`. Each output is HTML-escaped by default. `{{= raw }}` writes raw text, and the context (an attribute, a URL, a script) chooses the escape for `href` and `src` values. A template compiles to Tcl bytecode once. The server finds templates under a folder of the bundle.

## Tooling

- `ztcl test ?files?`: runs `.test` files with the `tcltest` package of Tcl. It uses the stand-in of `tools/tcltest.tcl` until a full `tcltest` passes its own test file. It has `-j N` with one worker thread for each file, a filter, and a JUnit XML report.
- `ztcl::bench`: `ztcl::bench run -iterations N -warmup M {script}` gives the time and the compute units of each pass, the mean, and the spread. `ztcl bench file.tcl` runs the `bench` blocks of a file and compares with a saved result.
- `ztcl prof script.tcl`: samples the stack of procs at each N steps (a step count, so the result is deterministic) and writes the folded format of flame graphs. A JIT frame reports its proc name.

## The HTTP module

### The client

```tcl
package require ztcl::http
set r [ztcl::http get https://example.org/api -headers {Accept application/json} -timeout 5s]
dict get $r status                ;# 200
dict get $r headers content-type
set data [ztcl::json parse [dict get $r body]]

ztcl::http post $url -json [ztcl::json object name [ztcl::json string ana]]
ztcl::http request PUT $url -body $bytes -headers $h
set c [ztcl::http client -max-conns 8 -http2 auto -roots system]
$c get $url
$c close
```

- HTTP/1.1 with keep-alive and a pool for each host, HTTP/2 with ALPN `h2` over TLS, and `h2c` with prior knowledge when the caller asks for it.
- `-stream $cmd` calls the command for each part of the body, for large downloads and SSE. `-stream-response` gives a response command in place of the dict: `$r status`, `$r header name`, `$r read`, and `$r close`.
- Redirects, `gzip` and `zstd` bodies, and cookies when the caller gives a jar.
- The `http` package names (`http::geturl` with `-command`, `-timeout`, `-headers`, `-query`, `-type`, `-channel`, and `-progress`, then `http::data`, `http::status`, `http::ncode`, `http::meta`, `http::cleanup`, and `http::register https 443 ::tls::socket`) wrap the client. The core file `http.test` is the gate. It runs a server in a child process (`httpd` in the test folder), so it needs `exec` and `socket` with loopback.
- The tcllib `websocket::open`, `websocket::send`, and `websocket::close` wrap the WebSocket client.

### The server: the model

```
          accept, TLS, HTTP/1.1 parse, HTTP/2 frames, WebSocket frames
 I/O threads (one per core, an aio loop each)   ── Zig only, no interpreter
          │ a parsed request: method, path, headers, body or a body stream
          ▼
 the dispatch queue (bounded)
          │
          ▼
 workers (N threads, one interpreter each, the app script loaded once)
   each request runs in its own coroutine, with its own limits
```

- The I/O threads have no interpreter. They parse, check the limits of the protocol, and write the responses. A slow client costs a buffer and no worker.
- A worker is a thread of the group of the threads plan, as a `tpool` worker is. It loads the app script once at its start, so procs and templates compile once in each worker.
- A request goes to a worker as a copy in the neutral form of the threads plan. The body is a byte string, or a stream command for large bodies.
- A worker runs each request in a new coroutine. A blocking call yields, so a worker serves other requests while one waits on a database, a client call, or a timer. `-concurrency` sets the most coroutines in one worker (default 64).

### The server: limits

| Limit | Default | What happens at the limit |
|---|---|---|
| `-steps` | 10 000 000 for each request | The request ends with 500, and the error goes to the log. Other requests of the worker keep running. |
| `-memory` | 64 MiB for each worker | The worker stops. Its requests in flight end with 503. A new worker starts and loads the app script. |
| `-request-memory` | none | With `-concurrency 1`, the memory limit of the worker is the limit of the request, and the worker resets its heap after a request that passed it. |
| `-timeout` | 30 s for each request | The I/O thread sets the stop flag of the request (as `thread::cancel` does). The handler stops at its next safe point, and the client gets 504. |
| `-body` | 1 MiB | 413 before the handler runs. |
| `-header-bytes`, `-headers` | 64 KiB, 100 | 431 |
| `-conns` | 10 000 | New connections wait in the listen queue. |
| `-idle` | 60 s for keep-alive | The connection closes. |
| h2 limits | 100 streams, a window of 1 MiB, a reset flood limit | GOAWAY with the error code of RFC 9113. |
| WebSocket | a message of at most 1 MiB, fragments of at most 64 KiB | close code 1009 |

The step count of a request is exact: the coroutine switch saves and restores the step counter, so each coroutine pays its own steps. The memory of one worker is one heap, so a memory limit for each request needs `-concurrency 1`. **Decision for the user (5):** the default of `-concurrency`, 64 (fast, a memory limit for each worker) or 1 (a memory limit for each request).

### The server: the API

```tcl
package require ztcl::http
namespace import ztcl::http::*

# Routes. The path params are in [req param NAME]. A type checks the param.
route GET /users/{id:int} {
    set user [users::find [req param id]]
    if {$user eq ""} { reply status 404 }
    reply json -schema {id int name string} $user
}

route POST /users {
    set in [req json -schema {name string email string}]
    reply json -status 201 [users::create $in]
}

route GET /files/{path:*} { reply file -root public [req param path] }

# Middleware: runs around each handler of its path. [next] runs the rest.
use / {
    set t [ztcl::time mono]
    next
    ztcl::log info request method [req method] path [req path] \
        status [res status] ms [expr {([ztcl::time mono] - $t) / 1000000}]
}

use /admin {
    if {[req header authorization] ne "Bearer $::token"} { reply status 401 }
    next
}

# Errors of a handler.
on error {
    ztcl::log error [req path] error $::errorInfo
    reply json -status 500 [ztcl::json object error [ztcl::json string "internal error"]]
}

serve -port 8080 -workers 4
```

The commands of `ztcl::http` for the server:

| Command | What it does |
|---|---|
| `route METHOD PATH ?-name n? BODY` | Adds a route. `METHOD` is a method, a list of methods, or `*`. A path has literal parts and params: `{name}`, `{name:int}`, `{name:uuid}`, `{name:re:REGEX}`, and a last `{name:*}`. Routes compile to a tree of path parts, so a lookup cost depends on the path length and not on the count of routes. A literal part wins over a param. |
| `group PREFIX SCRIPT` | Runs `route` and `use` calls of the script with the prefix. |
| `use PREFIX BODY` | Adds a middleware. The middlewares run in the order of their definition. `next` runs the next middleware or the handler. A middleware that does not call `next` ends the request. |
| `on error BODY`, `on notfound BODY` | Handlers for an error and for no route. |
| `req method`, `req path`, `req param n`, `req query n ?default?`, `req queries`, `req header n ?default?`, `req headers`, `req cookie n`, `req body`, `req json ?-schema s?`, `req form`, `req multipart`, `req remote`, `req id`, `req stream $cmd` | The request of the current coroutine. A header name is case-insensitive. |
| `res status ?code?`, `res header n v`, `res cookie n v ?opts?` | The response. `res status` with no code gives the status, for a middleware after `next`. |
| `reply text\|html\|json\|bytes ?-status c? ?-headers h? VALUE` | Sends the response and returns from the handler, as `return` does. `reply json` accepts a value with `-schema`, the builders of `ztcl::json`, or `-raw` text. |
| `reply status CODE ?MESSAGE?` | A body with the reason text. |
| `reply redirect URL ?-status 302?` | |
| `reply file ?-root DIR? PATH` | A static file under the root folder: `ETag`, `Last-Modified`, `Range`, `If-None-Match`, a content type from the extension, a precompressed `.gz` or `.zst` file when the client accepts it, and `sendfile` on Linux. A path that leaves `DIR` gives 404. |
| `static PREFIX DIR ?-index index.html? ?-cache 1h?` | A route for a folder. |
| `reply stream ?-type t? SCRIPT` | Runs the script with `res write $data` and `res flush`. HTTP/1.1 uses chunked transfer, and HTTP/2 uses DATA frames with flow control. `res write` yields when the window or the buffer is full. |
| `reply sse SCRIPT` | Server-Sent Events: `sse send ?-event e? ?-id i? DATA`, `sse retry ms`, and a comment line as a keep-alive each 15 s. `req header last-event-id` gives the resume point. |
| `websocket PATH ?-protocols p? BODY` | A WebSocket route. The body runs in a coroutine for the connection: `ws recv ?-timeout t?` gives `{text DATA}`, `{binary DATA}`, or `{close CODE}`, and `ws send`, `ws ping`, and `ws close` write. HTTP/2 WebSockets (RFC 8441) are later. |
| `serve ?options?` | Starts the server. In the main interpreter, it starts the I/O threads and the workers and runs the event loop until a stop. In a worker, it returns at once. |
| `stop ?-grace 10s?` | Graceful shutdown: close the listeners, send GOAWAY on HTTP/2 and `Connection: close` on HTTP/1.1, wait for the requests in flight up to the grace time, then end the workers. The runner calls it on SIGTERM and SIGINT. |
| `config` | The settings as a dict. |

The options of `serve`, also in a file of `-config app.toml`:

```
-host 0.0.0.0 -port 8080 -unix PATH
-tls {cert cert.pem key key.pem ?alpn {h2 http/1.1}? ?roots system?}
-http2 on|off|h2c        -workers N        -io-threads N        -concurrency N
-steps N -memory N -timeout 30s -body 1M -header-bytes 64K -conns N -idle 60s
-init SCRIPT             (the script that each worker runs; the default is the app script)
-log {format json level info}
```

How a worker loads the app: `serve` in the main interpreter records the path of the script (`info script`) or the `-init` script. Each worker runs it with `ztcl::http::worker` set to 1, so `route`, `use`, and `on` build the tables of the worker, and `serve` returns. A `if {![ztcl::http worker]} {...}` block runs only in the main interpreter, for example to open a database file before the workers start. Shared state goes in `tsv`, in SQLite, or in an outside store. No Tcl value is shared between workers.

### Example services

A JSON API on SQLite:

```tcl
package require ztcl::http
package require sqlite3
namespace import ztcl::http::*

sqlite3 db data/todo.db
db eval {CREATE TABLE IF NOT EXISTS todo(id INTEGER PRIMARY KEY, title TEXT NOT NULL, done INT DEFAULT 0)}

set schema {id int title string done bool}

route GET /todos {
    set rows {}
    db eval {SELECT id, title, done FROM todo ORDER BY id} r {
        lappend rows [dict create id $r(id) title $r(title) done $r(done)]
    }
    reply json -schema [list list [list object $::schema]] $rows
}

route POST /todos {
    set in [req json -schema {title string}]
    set title [dict get $in title]
    db eval {INSERT INTO todo(title) VALUES(:title)}
    reply json -status 201 -schema $::schema \
        [dict create id [db last_insert_rowid] title $title done 0]
}

route PATCH /todos/{id:int} {
    set id [req param id]
    db eval {UPDATE todo SET done = 1 WHERE id = :id}
    if {[db changes] == 0} { reply status 404 }
    reply status 204
}

serve -port 8080 -workers 4 -steps 2000000
```

A static site with templates and a contact form:

```tcl
package require ztcl::http
package require ztcl::tmpl
namespace import ztcl::http::*

set page [ztcl::tmpl load templates/page.html]

static /assets public/assets -cache 7d

route GET / {
    reply html [$::page render title Home items [news::latest 5]]
}

route POST /contact {
    set f [req form]
    if {![regexp {^[^@\s]+@[^@\s]+$} [dict get $f email]]} {
        reply html -status 400 [$::page render title Contact error "Check the address."]
    }
    ztcl::log info contact email [dict get $f email]
    reply redirect /thanks -status 303
}

serve -port 8443 -tls {cert certs/site.pem key certs/site.key} -http2 on
```

A chat server with WebSockets and SSE:

```tcl
package require ztcl::http
namespace import ztcl::http::*

# Messages go between workers through a tsv list and a condition.
if {![ztcl::http worker]} { tsv::set chat seq 0 }

websocket /ws {
    while 1 {
        lassign [ws recv] kind data
        if {$kind eq "close"} break
        chat::post [req query room main] $data
    }
}

route GET /events/{room} {
    reply sse {
        set seen [req header last-event-id 0]
        while 1 {
            foreach {id msg} [chat::since [req param room] $seen -wait 15s] {
                sse send -id $id $msg
                set seen $id
            }
        }
    }
}

serve -port 8080 -workers 2 -concurrency 1000 -timeout 0
```

A proxy with streaming and a client pool:

```tcl
package require ztcl::http
namespace import ztcl::http::*

set upstream [ztcl::http client -max-conns 64 -http2 auto]

use / {
    if {[req header x-api-key] ni $::keys} { reply status 403 }
    next
}

route * /api/{rest:*} {
    set r [$::upstream request [req method] https://backend.internal/[req param rest] \
        -headers [req headers] -body [req body] -stream-response]
    res status [$r status]
    reply stream -type [$r header content-type] {
        while {[set part [$r read]] ne ""} { res write $part }
        $r close
    }
}

serve -port 8080 -workers 8 -timeout 60s -body 16M
```

The names `chat::post`, `chat::since`, `news::latest`, `users::find`, and `users::create` are procs of the app.

## TLS 1.3

### The parts

| Part | Source |
|---|---|
| The record layer: framing, AEAD seal and open, sequence numbers, padding, key update, the limits of RFC 8446 section 5 | new, shared by the client and the server. QUIC uses the same AEAD code for its packets later (see HTTP/3). |
| The key schedule: HKDF, `Derive-Secret`, the traffic secrets, the finished keys, the resumption secret | new, on `std.crypto.kdf.hkdf` |
| The handshake state machines of the client and the server | new. The std client is a reference in the tests. |
| Key exchange | `std.crypto` X25519, P-256, P-384, and the hybrid `x25519_ml_kem768` |
| Signatures | Ed25519, ECDSA P-256 and P-384 with SHA-256 and SHA-384 from `std.crypto`. RSA-PSS verification from `std.crypto.Certificate.rsa`. |
| RSA private keys for a server | new: RSA-PSS sign on `std.crypto.ff` with blinding. **Decision for the user (6):** RSA server keys in milestone 4 or later. ECDSA and Ed25519 keys cover new certificates. |
| PEM and PKCS#8 keys, PEM chains | new |
| X.509 parse | `std.crypto.Certificate` |
| Chain validation | new: path building from the leaf to a root, `basicConstraints` (the CA flag and the path length), key usage, extended key usage (`serverAuth`, `clientAuth`), name constraints, the validity of each certificate, a refusal of unknown critical extensions, and the host name against the subject alternative names |
| Root stores | `std.crypto.Certificate.Bundle.rescan` for the system store, a PEM file, or bytes from the embedder |
| ALPN, SNI | new. The server picks a certificate by SNI and a protocol by ALPN (`h2`, `http/1.1`). |
| Session resumption | new: PSK with `psk_dhe_ke` only, tickets sealed with a server key that rotates, one use for each ticket when the server keeps a cache |
| 0-RTT | off by default. When the user turns it on, the server accepts early data only for safe methods (`GET`, `HEAD`) and keeps an anti-replay window (RFC 8446 section 8). |
| HelloRetryRequest, cookies, key update, `close_notify`, alerts | new |
| TLS 1.2 | none on the server. The client can use the std client for a TLS 1.2 peer, behind an option. **Decision for the user (7).** |

The API:

```tcl
ztcl::tls socket ?-alpn {h2 http/1.1}? ?-servername n? ?-roots system|FILE? host port
ztcl::tls server -cert c.pem -key k.pem ?-sni {host {cert key} ...}? ?-alpn ...? $cmd port
ztcl::tls status $chan          ;# version, cipher, alpn, peer chain, resumed
tls::socket ...               ;# the TclTLS subset: -cafile, -certfile, -keyfile, -servername, -alpn, -require, -server
```

### Security work

The parts of a TLS stack that go wrong are the state machine, the parsers, the validation of chains, and the timing of secret-dependent code. The plan has these checks:

1. **RFC test vectors.** RFC 8446 gives the protocol. The example handshakes with all keys and secrets are in RFC 8448. Tests replay each handshake of RFC 8448 byte for byte through the key schedule, the record layer, and both state machines. RFC 5869 (HKDF), RFC 7748 (X25519), and RFC 8032 (Ed25519) vectors run in the unit tests. The NIST ECDSA vectors and the Wycheproof test sets run for each primitive that TLS uses.
2. **Interop.** A matrix runs in CI: the ztcl client against `openssl s_server`, the ztcl server against `openssl s_client` and `curl`, for each group, each suite, each signature kind, ALPN, resumption, HelloRetryRequest, key update, and client certificates. The BoringSSL test runner (BoGo) is an option for a later task.
3. **Negative tests.** A set in the style of tlsfuzzer: messages out of order, duplicate and missing extensions, bad lengths, a downgrade, a record above the limit, bad padding, bad finished data, a wrong `legacy_session_id`, alerts in each state, early data with no PSK. tlsfuzzer itself runs as an outside program against the server, with its scripts for TLS 1.3. ztcl copies no code from it.
4. **Fuzzing.** `zig build tls-fuzz` fuzzes the record parser, the handshake parsers, the X.509 and PEM parsers, the chain builder, and the state machines (a fuzzer drives a peer that sends mutated flights). It runs with the Zig fuzzer and with a corpus from the interop runs. The gate is a time budget for each run in CI and a longer run before the default changes.
5. **Constant time.** The rules: a secret never selects a branch or a memory address. Compares of MACs, tags, and finished data use `std.crypto.timing_safe`. Padding removal scans the whole record. RSA uses blinding. A decryption error and a bad padding give the same alert at the same point. A test in the style of dudect measures the time of the record open with good and bad tags and fails on a difference. A review checks the machine code of the hot paths of the record layer on x86-64 and arm64.
6. **External review.** A review by a person outside the project, with TLS experience, of the state machines, the key schedule, the record layer, the validation of chains, and the constant-time rules. TLS stays behind `-Dtls=experimental` until the review is done (task 27) and its findings are fixed. **Decision for the user (8):** who does the review, and the budget.

### The risks that stay

- The primitives are `std.crypto`. Its finite field code says "best-effort" constant time. A side channel in a primitive or a change in the Zig compiler that adds a branch is outside this plan. The machine code review lowers this risk and does not remove it.
- No formal proof of the state machine exists, as there is for some other stacks.
- The plan has no revocation check (OCSP or CRLs) in the first version. A revoked certificate passes until it expires. OCSP stapling on the server is later work.
- RSA signing is new code. It is the highest risk of the new primitives. ECDSA and Ed25519 keys avoid it.
- A handshake costs CPU before the peer proves anything. The server limits the handshakes in flight and the handshakes per second per address. A large attack still costs CPU.
- 0-RTT has replay risks by design. It stays off by default.
- A bug in the TLS code of a ztcl server exposes the data of each connection of that process. The worker interpreters have no access to the keys, because the keys stay in the I/O threads. A bug in a handler cannot read a key.
- The team is small. Fuzzing and review find many bugs and not all.

## HTTP/2

- The frame layer, the stream states of RFC 9113, flow control for each stream and for the connection, SETTINGS, PING, GOAWAY, RST_STREAM, PRIORITY frames read and ignored (RFC 9113 deprecates the priority tree), and the `PRIORITY_UPDATE` frame of RFC 9218.
- HPACK (RFC 7541): the static table, the dynamic table with a limit, and the Huffman code. The tests use the examples of RFC 7541 appendix C and the `hpack-test-case` corpus.
- `h2` with ALPN over TLS, and `h2c` with prior knowledge (a client preface on a plain connection). The `Upgrade: h2c` path of RFC 7540 is out, because RFC 9113 deprecates it.
- Limits against the known attacks: the rapid reset attack (a limit of RST_STREAM per second), CONTINUATION floods (a limit on the header block size and the count of frames), a settings flood, a ping flood, a window of zero kept open (a timeout), and HPACK bombs (the decoded header list size).
- The server pushes no streams.
- The conformance gate is `h2spec` with all its tests passing for the server. The client runs against `nghttpd` or a Go server in the interop matrix.

### HPACK (task 28)

`src/h2/hpack.zig` has the integers, the strings, the Huffman code, the static table, the dynamic table, a decoder, and an encoder. `tools/hpack-tables.py` makes `src/h2/hpack_tables.zig` from the text of RFC 7541: the static table of appendix A, the Huffman code of appendix B (it checks that the code is canonical), and the 12 examples of appendix C.3 to C.6 with the dynamic table after each block.

- The decoder gives one field at a time. A plain string is a slice of the header block, an indexed field is a slice of a table, and a Huffman string goes into a scratch buffer of the caller. The fields stay valid until the next call. The decoder allocates its dynamic table once, and a field past the limit of the header list gives an error before the caller copies it.
- The dynamic table keeps the bytes of its entries in one buffer, oldest first. An add that does not fit at the end moves the live bytes to the start, so each name and value is one slice. A literal with incremental indexing whose name comes from the dynamic table copies the name to the scratch buffer before the add, because the add can move or evict it.
- The Huffman decoder looks up 12 bits at a time in a table of 4,096 entries made at compile time, which gives up to 2 symbols for each lookup. A longer code goes through the canonical form of the code.
- The encoder writes an indexed field for a full match in a table, and a literal with incremental indexing otherwise, with an indexed name when the name is in a table. Strings use the Huffman code when it is shorter, or always, or never. The examples of appendix C come out byte for byte with `always` (C.4, C.6) and `never` (C.3, C.5).

`zig build test` runs the examples, the integers of C.1, the fields of C.2, each byte value through the Huffman code, the bad paddings, random round trips with table sizes of 0 to 4,096 and size updates, bad blocks, and 20,000 random blocks. `zig build hpack-fuzz -- --seconds N` runs random round trips and decodes changed and random blocks in ReleaseSafe. `zig build hpack-bench` prints the speed.

2026-11-27, i7-6700K (shared), a browser request of 12 fields (360 bytes of names and values): Huffman decode 386 MB/s of text and encode 1,032 MB/s; the first block of a connection (304 bytes) decodes 605,518 times a second and a later block (12 bytes) 8,757,279 times a second; the encoder makes 621,467 first blocks and 1,391,199 later blocks a second. `zig build hpack-corpus` runs the `hpack-test-case` corpus (see Conformance below).

### The HTTP/2 connection (task 29, first part)

`src/h2/conn.zig` is the server side of a connection with no transport: `feed` takes the bytes of the client and `pending` gives the bytes to send, so the same code runs `h2c` on a socket and `h2` in TLS. `src/h2/frame.zig` reads and writes the frames. There is no HTTP server of task 12 yet, so a handler gets a `Request` (the pseudo-header fields, the other fields, and the body) and answers with `Conn.respond`.

- `feed` reads whole frames in place in the buffer of the caller. A header block in one HEADERS frame decodes from that buffer. The fields of a request go to the handler as slices of a buffer of the connection that keeps its capacity, so a GET needs no allocation once the buffers have grown. A request with a body keeps its fields and body in the stream until END_STREAM.
- The response goes out as HEADERS (and CONTINUATION past the frame size of the peer) and DATA frames within the windows of the stream and the connection. The rest of a body waits in the stream for WINDOW_UPDATE.
- The checks of RFC 9113: the preface, SETTINGS first, the frame size, the stream ids, CONTINUATION only after HEADERS, the pseudo-header fields (each one once, before the other fields, `:method`, `:scheme`, and `:path` present), no uppercase field names, no connection-specific fields, `te` only `trailers`, and `content-length` against the DATA.
- The limits of `Limits` against the attacks of the design: a CONTINUATION flood and a header block past its size give ENHANCE_YOUR_CALM, a header list past its size resets the stream, more than `max_resets` client resets or `max_control` SETTINGS and PING frames in a second give ENHANCE_YOUR_CALM, and a stream past `max_streams` gets REFUSED_STREAM.

`zig build test` runs the tests of `src/h2/conn_test.zig` with a client in memory: GETs on three streams, a POST body in two frames with a response past a window of 100 bytes, the flood and protocol cases, and a stream error that leaves the connection open.

`zig build h2-serve -- --port N` runs `conn.zig` on the aio loop (Linux) for h2c with prior knowledge. `curl --http2-prior-knowledge` (curl 8.23.0 with nghttp2 1.70.0) gets its responses, with GETs on one connection and a POST of 40 KB. `zig build h2-load` is a load client in the manner of h2load: connections with a number of requests in flight on each.

2026-11-27, i7-6700K (4 cores, 8 threads, shared with other jobs), `h2-serve` and `h2-load` on the same machine, one thread each, io_uring:

| Connections | Streams each | Body | Requests/s | Body MB/s |
|---:|---:|---:|---:|---:|
| 1 | 1 | 13 bytes | 30,831 | 0.4 |
| 4 | 32 | 13 bytes | 813,224 | 10.6 |
| 64 | 100 | 13 bytes | 1,176,542 | 15.3 |
| 8 | 8 | 65,536 bytes | 17,823 | 1,168.1 |

The RSS of the server stayed under 3 MB.

#### h2load against nghttpd

2026-11-27, the same machine at a load of 14, h2c with prior knowledge. h2load 1.71.0 (`-t 1`) loads `h2-serve` and the reference server nghttpd 1.71.0 (`--no-tls`, one thread, a file from `-d`). Each row is the median of three runs:

| Connections | Streams each | Body | `h2-serve` requests/s | nghttpd requests/s | Ratio |
|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 13 bytes | 22,381 | 18,446 | 1.21 |
| 4 | 32 | 13 bytes | 317,872 | 140,625 | 2.26 |
| 64 | 100 | 13 bytes | 307,522 | 105,771 | 2.91 |
| 8 | 8 | 65,536 bytes, a copy of the body (`--copy on`) | 17,725 | 16,798 | 1.06 |
| 8 | 8 | 65,536 bytes, no copy (`respondRef`, the default) | 28,088 | 16,586 | 1.69 |

- nghttpd sends more header fields (`server`, `date`, `content-length`, `last-modified`) than `h2-serve`, so a row of small bodies is part HPACK work.
- With `-t 1`, h2load itself is the limit near 320,000 requests/s: `zig build h2-load` gets 1,176,542 requests/s from the same server (the table above).
- With a copy of a body of 64 KiB, the two servers are equal: the copy into the output buffer is the cost. `Conn.respondRef` removes it. The DATA frames point at the body of the caller, `Conn.pendingVecs` gives the frame headers and the body slices as iovecs, and `h2-serve` sends them with the `writev` op of `aio`. A run of the copy and the no-copy server in the same minute gave 19,182 and 28,088 requests/s.
- `respondRef` copies a piece of a body under 1 KiB: one more iovec costs more than the copy. Before that rule, the row of 4 connections and 32 streams fell from 317,872 to 261,786 requests/s; with it, the row gives 335,236.
- The body of `respondRef` must stay valid and unchanged until the end of the connection. The HTTP server of task 12 needs a release callback for each response, for bodies that do not live that long.

#### Conformance

- h2spec 2.6.0 (`h2spec -h 127.0.0.1 -p PORT`) gives 146 of 146 on `h2-serve`, and 147 of 147 with `-S` (strict). The first run gave 144: a PRIORITY frame on its own stream and an empty `:path` did not reset the stream. Both have a test in `conn_test.zig` now.
- `zig build hpack-corpus -- DIR` runs the hpack-test-case corpus (github.com/http2jp/hpack-test-case, commit 8a1406e, MIT). It decodes each story of the 14 encoder folders (3,267 or 3,384 cases each) with one decoder for each story, and compares the fields in order. It also encodes the `raw-data` stories with `Encoder` in each Huffman mode and decodes them again. No case fails.

The sizes of all the blocks of the `raw-data` stories, for each encoder of the corpus that uses a table of 4,096 bytes:

| Encoder | Block bytes |
|---|---:|
| nghttp2 | 360,319 |
| node-http2-hpack | 360,328 |
| `hpack.zig`, Huffman `shorter` (the default) | 361,250 |
| swift-nio-hpack-huffman | 361,259 |
| python-hpack | 361,262 |
| haskell-http2-linear-huffman | 368,177 |
| `hpack.zig`, no Huffman | 455,386 |
| go-hpack | 993,735 |

The next parts: `h2` over `ztcl::tls` with ALPN, and the HTTP server of task 12.

## HTTP/3 and QUIC (later)

HTTP/3 is its own milestone after the rest. It reuses the key schedule, the AEAD, and the handshake messages of TLS 1.3. QUIC sends the TLS handshake in CRYPTO frames and uses packet protection in place of the record layer (RFC 9001).

- QUIC transport (RFC 9000): packets, frames, streams, flow control, connection IDs, the handshake, address validation with Retry and tokens, path validation, migration of the client, stateless reset, and idle timeout.
- Loss detection and congestion control (RFC 9002): the NewReno controller of the RFC first. CUBIC is later.
- HTTP/3 (RFC 9114) and QPACK (RFC 9204), with the QPACK test corpus (`qifs`).
- UDP on the `aio` backends: `recvmmsg` and `sendmmsg` with GSO on Linux, and the same vtable on macOS and Windows.
- The server announces HTTP/3 with `Alt-Svc`.
- The interop gate: `quic-interop-runner` with its test cases (handshake, transfer, retry, resumption, zero-RTT, HTTP/3, multiplexing, key update, migration) against at least three other stacks. The tests of RFC 9001 appendix A (the Initial packet protection) run as unit tests.
- The same rules for fuzzing and constant time as TLS. The review of TLS covers the shared parts. QUIC needs its own review before it is on by default.

## SQLite

### The build

- The amalgamation (`sqlite3.c`, public domain) goes into the repository under `vendor/sqlite/` with its version and checksum. It is the one file of C in ztcl. AGENTS.md rule 7 says "Add no dependency". **Decision for the user (9):** the vendored file, or a fetch at build time with a checksum.
- `zig cc` compiles it with `SQLITE_OS_OTHER=1`, `SQLITE_THREADSAFE=0` (one connection belongs to one interpreter and one thread), `SQLITE_OMIT_LOAD_EXTENSION`, `SQLITE_DQS=0`, `SQLITE_DEFAULT_MEMSTATUS=0`, and `SQLITE_OMIT_DEPRECATED`. FTS5 and JSON are in by default and a flag can leave them out.
- With `SQLITE_OS_OTHER`, the object needs only these symbols from outside (measured with `nm -u`): `malloc`, `realloc`, `free`, `memcpy`, `memmove`, `memset`, `memcmp`, `bcmp`, `memchr`, `strlen`, `strcmp`, `strncmp`, `strchr`, `strrchr`, `strspn`, `strcspn`, `sqlite3_os_init`, and `sqlite3_os_end`. A Zig file gives each one. So ztcl stays free of libc.
- The VFS is Zig code: `src/sqlite/vfs.zig` opens files only through the root folder of `fsroot.zig`, with file locks on Linux and macOS and `LockFileEx` on Windows, and the WAL mode with its shared memory file. `:memory:` and the `memdb` VFS need no file capability.
- The allocator: `SQLITE_CONFIG_MALLOC` gives SQLite an allocator that counts in the memory limit of the interpreter. The page cache counts too.

### The Tcl API

The API is the binding of SQLite, `tclsqlite.c`, as its manual page describes it. ztcl writes it again in Zig and copies no code. The first version has:

```tcl
sqlite3 db data/app.db ?-readonly 1? ?-create 1? ?-vfs name?
db eval {SELECT a, b FROM t WHERE id = :id}            ;# a flat list
db eval {SELECT a, b FROM t} row { puts "$row(a) $row(b)" }
db eval {SELECT a, b FROM t} { puts "$a $b" }
db onecolumn {SELECT count(*) FROM t}
db exists {SELECT 1 FROM t WHERE id = $id}
db transaction ?deferred|immediate|exclusive? { ... }
db changes; db total_changes; db last_insert_rowid
db function name ?-deterministic? ?-argcount n? proc
db collate name proc
db nullvalue ?text?
db timeout ms; db busy proc
db cache size N; db cache flush
db progress N proc
db interrupt
db limit name ?value?
db serialize ?schema?; db deserialize ?schema? bytes
db incrblob ?-readonly? table column rowid           ;# needs channels
db status; db errorcode; db version; db close
```

- A `$name`, `:name`, or `@name` in the SQL binds the Tcl variable of that name, as in the binding of SQLite. `@name` binds bytes as a BLOB.
- Prepared statements stay in a cache for each connection, keyed by the SQL text. `db cache size` sets the count (default 10, as SQLite).
- The test gate is the subset of `tclsqlite.test` and of the other test files of SQLite that use only the `sqlite3` command and `db` methods of the list above. The test files of SQLite need the `testfixture` program for most of their commands, so the subset is a list in the task, and its pass count is the gate.

### Limits

- **Steps.** `sqlite3_progress_handler` runs each 1000 virtual machine instructions of SQLite and pays one compute unit of the compute limit. At the compute limit, the handler stops the query, and the script gets the compute limit error. A `db progress` of the script runs on top of this.
- **Memory.** The allocator of SQLite counts in the memory limit. At the limit, the allocator fails, SQLite gives `SQLITE_NOMEM`, and the script gets the memory error.
- **Limits of SQLite.** `sqlite3_limit` sets the length of a string or a blob (the default is the memory limit, at most 1 GB), the SQL length (1 MB), the columns (2000), the depth of an expression (1000), and the attached databases (0 when the capability `file` is off, so `ATTACH` reaches no file).
- **Capability.** `sqlite3` exists only with the capability `sqlite`. A path needs `file` and stays under the root folder. `ATTACH` follows the same rule.
- **Untrusted SQL.** `SQLITE_DBCONFIG_DEFENSIVE` is on, and `trusted_schema` is off. 

## WebAssembly

| Module | In the wasm build | Note |
|---|---|---|
| `json`, `formats`, `url`, `encode`, `tmpl`, `log` | yes | `log` writes to the output |
| `hash`, `crypto` | yes | `random` needs a host import (issue 26) |
| `compress` | yes | |
| `time` | yes | the current time needs the clock import of issue 26. The zone data is in the module. |
| `sqlite` | an option | `:memory:` and the files of the virtual file system of issue 26. About 750 KB more. |
| `http` client | through `fetch` | a host import that the page gives, behind the capability `fetch` (issue 26). No TLS in the module: the browser does it. |
| `http` server, `aio`, `tls`, `h2`, `http3`, `dns`, `sys`, `proc`, `thread` | no | no sockets, processes, or threads in the module |

- The no-import build of issue 26 stays. It has the modules with no host access only.
- A blocking call through `fetch` needs the host to resume the script. The wasm build has no coroutine switch, so `ztcl::http get` in wasm uses a callback form (`-command`). A sync form needs JSPI (the JavaScript Promise Integration of WebAssembly) and is later work.
- The wasm size gate: `ztcl.wasm` with the wasm modules, in `ReleaseSmall`, at most 1.5 MB, and the no-import build at most 1.0 MB. Today it is 825 KB.

## `ztcl build`

```sh
ztcl build app.tcl -o app                      # for the host
ztcl build app.tcl -o app.exe --target x86_64-windows
ztcl build app.tcl --include templates/ --include public/ --allow socket,event,thread
```

- A bundle is the runner plus a zip archive of the scripts and files at the end of the file, with an index. The runner reads the index at its start, mounts the archive as a read-only folder for `source`, `ztcl::tmpl load`, and `reply file`, and runs the main script.
- The bundle records the capabilities, the limits, and the network policy of the app. The runner applies them at the start. A flag at the command line of the bundle cannot add a capability that the bundle does not list.
- Cross builds need no compiler. `ztcl build --target T` reads the runner of target T from a cache, or downloads the release asset of the same version and checks its checksum (with the capability `socket` of the build tool, and only with `--fetch`). `ztcl build --runner PATH` uses a local runner.
- The targets: x86-64 and arm64 Linux, arm64 and x86-64 macOS, x86-64 Windows. A macOS bundle needs a new ad hoc signature after the archive is added. The plan uses `codesign` when it is present and prints a step when it is not. **Decision for the user (10):** a Zig code signer for ad hoc signatures, or `codesign` only.
- The archive can be compressed with zstd. The runner then needs the `compress` module.

## Performance targets

### How CI measures

- One job on a fixed machine type runs the outside benchmarks. Each run of an outside program is the best of 5 runs of the same job, and each gate is a ratio of ztcl to another runtime in the same job. A ratio holds on a busy machine better than a time.
- The benchmarks of the interpreter itself stay instruction counts (`perf stat -e instructions:u`), as in the JIT plan.
- `bench/stdlib/` has the scripts and the data. `tools/bench-stdlib.py` runs each program and writes a table to the job summary and a TSV file to the artifacts.
- The first numbers come from task 03 (the baselines). Each gate below is a target. The task of the module measures it, and the user sets the final number.

### JSON

The data: `twitter.json`, `canada.json`, and `citm_catalog.json` from the nativejson-benchmark, as simdjson uses them.

| Measure | ztcl | Compared with | Target |
|---|---|---|---|
| Validate (`ztcl::json valid`) | stage 1 and the grammar walk | simdjson DOM | at least 0.67 of simdjson DOM on each file (the goal of the user) |
| Stage 1 | the structural index alone | the stage 1 of simdjson | at least 0.8 (the goal of the user) |
| Parse to a Tcl value | `ztcl::json parse` | Node `JSON.parse`, Go `encoding/json` to `any`, Python `json.loads`, `tclsh` 8.6 with tcllib `json::json2dict` | at least the speed of Python on each file, at least 0.8 of Node, and at least 10 times `tclsh` with tcllib |
| Path query | `ztcl::json get` for one value | Node `JSON.parse` then a property read | at least 2 times Node |
| Encode | `ztcl::json encode -schema` of the parsed value | Node `JSON.stringify`, Go `json.Marshal`, Python `json.dumps` | at least the speed of Python, at least 0.7 of Node |

The unit is MB/s of the input text.

The goal of the user (2026-11-24): beat each scripting runtime outright, and beat simdjson DOM when a script reads a few fields of a document. `ztcl::json get` walks the structural index and makes only the value at its path, so it makes no value for the rest of the document. The JIT task 05b adds parsers for a repeated shape. The measured numbers are in the PRs of tasks 04 and 05.

### HTTP

The test: the TechEmpower plaintext test (`/plaintext`, with pipelining of 16) and JSON test (`/json`, `{"message":"Hello, World!"}`), run with `wrk` on the same machine with a fixed core split, 256 connections, 30 s.

| Measure | Compared with | Target |
|---|---|---|
| Requests per second, plaintext and JSON, HTTP/1.1 | Go `net/http`, Node `http`, Python `uvicorn` with a plain ASGI app | at least 0.8 of Go, at least Node, at least 3 times uvicorn |
| p99 latency at 50 % of the peak rate of Go | the same | at most 1.5 times Go |
| The same over HTTP/2 with `h2load` | Go `net/http` with h2c | at least 0.7 of Go |
| One worker with a compute limit, to show the cost of the limits | ztcl with no compute limit | at most 5 % slower |

A worker runs a Tcl handler for each request. Go and Node run their own code. The ratio is the cost of a scripted handler against a compiled one.

### TLS

| Measure | Compared with | Target |
|---|---|---|
| Full handshakes per second, X25519 and ECDSA P-256, one core | Go `crypto/tls`, `openssl s_server` with `openssl s_time` | at least 0.7 of Go |
| Resumed handshakes per second | the same | at least 0.7 of Go |
| Bulk throughput, AES-128-GCM and ChaCha20-Poly1305, 16 KiB records | `openssl speed -evp`, Go | at least 0.8 of Go |

### SQLite

| Measure | Compared with | Target |
|---|---|---|
| The time of each row of `db eval {SELECT a, b, c FROM t} r {}` for 1 000 000 rows, minus the time of the same query in the C API | `tclsh` 8.6 with its `sqlite3` package of the same SQLite version | at most the cost of `tclsh` |
| `db eval {INSERT ...}` with a cached statement in a transaction, 1 000 000 rows | the same | at most the cost of `tclsh` |

## Platforms

| Part | Linux | macOS | Windows | WebAssembly |
|---|---|---|---|---|
| Pure modules (JSON, formats, compress, hash, crypto, time, tmpl, log) | yes | yes | yes | yes |
| `aio`, `http`, `tls`, `h2` | io_uring, epoll | kqueue | IOCP | no |
| Coroutine handlers | x86-64 today, arm64 in task 08 | task 08 | task 08 | no |
| Worker pool | after the threads plan | after its port task | after its port task | no |
| `ztcl::fs watch` | inotify | kqueue | `ReadDirectoryChangesW` | no |
| `sqlite` | yes | yes | yes | an option |
| `http3` | the first target | later task | later task | no |

The other platform work of `src/sys.zig` (channels, sockets, and processes on macOS and Windows) is a dependency: `aio` replaces the socket part of it.

## Dependencies on other plans

- The worker pool needs tasks 01 to 05 of [the threads plan](threads-tasks/README.md): the group, the messages, the stop flag, `tsv`, and `tpool`. Task 13 of this plan starts after them.
- The coroutine handlers need the coroutine switch on each target (task 08 of this plan).
- The wasm parts follow issue 26: the host imports for output, the clock, and capabilities.

## Decisions for the user

The user approved the plan and these answers on 2026-11-24.

1. Built-in modules load with `package require` by default. The capability `package` is still needed to load a package from a file.
2. The namespace is `ztcl`.
3. JSON null is an error unless the caller gives `-null` a value. A silent empty string hides bugs.
4. The zone data is `tzdata.zi` with a rule compiler, about 25 KB of data.
5. The server gives each request a memory limit. The default `-concurrency` of a worker is 1, so one request runs in one interp at a time, and the pool has many workers (64 by default, or the count that the memory budget allows). A service can raise `-concurrency` for I/O-bound handlers, and then the limit is per worker.
6. RSA server keys are in the TLS milestone, because many certificates still use RSA.
7. The client also speaks TLS 1.2 through the std client, for older servers. The server speaks TLS 1.3 only.
8. The external review of TLS is open: the user decides who does it, the budget, and the time. TLS stays behind a flag until the review is done.
9. The SQLite amalgamation is fetched at build time with a pinned checksum. AGENTS.md rule 7 gets an exception for it.
10. macOS bundles use `codesign` first. A Zig signer for ad hoc signatures is later work.
11. The final performance gates are set after task 03 measures the other runtimes. On 2026-11-25 the user set the JSON gates of `bench/stdlib/gates.tsv`: the targets of task 03, and four floors about 10 % below the lowest measured ratio where task 05 did not reach the target: `valid` against simdjson DOM is at least 0.56 on twitter and 0.60 on citm_catalog, and `encode` against Node is at least 0.35 on twitter and 0.60 on canada. The floors catch regressions. Task 05b and the work on the value representation are expected to raise them.

## Future work

- HTTP/2 WebSockets (RFC 8441), HTTP/3 WebSockets (RFC 9220), and WebTransport.
- OCSP stapling and revocation checks.
- A shared, frozen form of large values between workers (the threads plan lists it).
- `tdbc` on SQLite.
- The sync form of `ztcl::http get` in WebAssembly with JSPI.
- YAML (tcllib `yaml` and `huddle`). Issue 27 does not list it.
