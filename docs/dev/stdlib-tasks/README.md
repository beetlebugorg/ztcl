# Tasks for the batteries-included runtime

[The design](../stdlib.md) gives the modules, the API, the limits, and the choices. Issue 27 has the goal and the decisions of the user. Do the tasks in the order of their numbers. One task is one branch and one review.

## Milestones

| Milestone | Tasks | Result |
|---|---|---|
| 1: modules and JSON | 01 to 05 | `package require` loads built-in modules. CI reports the size of each module. `ztcl::json` and the tcllib `json` names pass JSONTestSuite and the speed gates. |
| 2: async I/O | 06 to 10 | The event loop on io_uring, kqueue, and IOCP. Blocking calls yield in a coroutine on each target. |
| 3: HTTP/1.1 | 11 to 15 | The client, the server with routes and middleware, the worker pool with limits, WebSockets, SSE, and the HTTP speed gates. |
| 4: TLS 1.3 | 16 to 27 | The server and the client on one record layer, X.509 chains, resumption, interop, fuzzing, constant-time checks, and the external review. TLS is on by default only after task 27. |
| 5: HTTP/2 | 28 to 30 | HPACK, streams, flow control, the limits, `h2` and `h2c`, and h2spec. |
| 6: the other modules | 31 to 38 | Formats, compression, crypto, time and zones, logs, system, templates, and tooling. |
| 7: SQLite | 39 to 41 | The `sqlite3` command with the binding API of SQLite, limits, and the capability. |
| 8: bundles and the web | 42 to 44 | `ztcl build`, the modules of the wasm build, and the final reports. |
| 9: HTTP/3 (later) | 45 to 49 | QUIC, loss recovery, HTTP/3, QPACK, and quic-interop-runner. |

The user decides the points of "Decisions for the user" in the design at these tasks: 1 to 3 before task 01 merges, 4 before task 35, 5 before task 13, 6 and 7 before task 16, 8 before task 26, 9 before task 39, 10 before task 42, and 11 after task 03.

Milestones 2 to 5 depend on the threads plan for the worker pool: task 13 starts after task 05 of [the threads tasks](../threads-tasks/README.md). Milestone 6 has no dependency on milestones 2 to 5, except the HTTP parts of compression (task 33). Its tasks can run before or between them when the user asks.

## Platforms

| Mark | Where the task runs |
|---|---|
| Linux | Linux. |
| macOS | macOS. |
| Windows | Windows. |
| shared | Any platform. The code is the same on each platform, and the tests run on Linux first. CI runs them on the three systems. |

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/dev/design.md`, `docs/embedding.md`, `docs/threads.md`, and `docs/dev/stdlib.md` first.
2. Run each build, test, and benchmark under the memory cap. `CAP` in each task means this prefix:

   ```sh
   systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 --
   ```

   Use at most 3 parallel jobs. Bound each server and each network test with `timeout`. Stop only your own processes, by PID.
3. A task is done when each command of its acceptance list passes. Put the output of each command in the PR body.
4. The common acceptance commands apply to each task, also when the task does not list them:

   ```sh
   CAP zig build
   CAP zig build test
   CAP zig build test -Dbatteries=core
   CAP zig build test -Dbatteries=full
   CAP zig build test -Djit=false
   CAP zig build wasm && node tools/wasm-smoke.mjs
   CAP tools/suite.sh -a
   CAP tools/jit-diff.sh
   CAP tools/size-report.sh --check          # from task 02 on
   ```

   The pass count of each suite file must not drop.
5. Each module is in its own folder or file under `src/`. A change to `src/interp.zig`, `src/vm.zig`, `src/event.zig`, `src/sys.zig`, `src/main.zig`, or `src/ztcl.zig` stays inside the hunks that the task names.
6. Each module follows the rule of "Limits and capabilities" in the design: steps for work, memory through the counter, a safe point at least each 64 KiB, a capability for host access, the network policy for each address, and the root folder for each path. Each task adds the tests that show its commands are absent without their capability, and in a safe child.
7. Tests and benchmarks stay offline. A network test uses only loopback addresses. A test that needs an outside program (`openssl`, `curl`, `node`, `go`, `h2spec`, `wrk`) skips with a clear message when the program is absent, and CI installs each one.
8. Each new source file starts with a `//!` comment that explains its algorithm, and an SPDX line for BSD-2-Clause.
9. Write fresh code. Copy no code from tcllib, Tcl, SQLite's `tclsqlite.c`, or another project. Read no source of a GPL or AGPL project for this work. Outside test tools run as outside programs. Credit each source in `docs/references/stdlib.md`.
10. Use only the Zig 0.16.0 standard library. The one exception is the SQLite amalgamation (task 39), after decision 9.
11. A size gate is the module row of the size table in the design, plus 10 %. A task that needs more changes the row in the same PR and says why.
12. A speed gate is a ratio in the same job (see "Performance targets" in the design). The numbers in a task are targets until the user sets them after task 03.
13. Use the words "step limit" for the limit on steps. Name no AI model or vendor in the repository. Add no attribution line.
14. If a gate fails, do not change the gate. Report the measured number and the cause.
15. If a fact in a task is wrong, stop and report it. Do not guess.

## The tasks

| Task | Platform | Title |
|---|---|---|
| [01](01-modules.md) | shared | The module table, `package require` from memory, and the build flags |
| [02](02-size-report.md) | shared | The size report and its CI gate |
| [03](03-baselines.md) | Linux | The outside benchmark harness and the first numbers |
| [04](04-json-parse.md) | shared | The JSON parser: the SIMD index and the builder |
| [05](05-json-api.md) | shared | `ztcl::json`, the tcllib names, and the JSON gates |
| [05b](05b-json-jit.md) | Linux | JSON with the JIT: shapes, paths, writers, tier 2 reads, and a fused parse and loop |
| [06](06-aio-linux.md) | Linux | `aio` on io_uring and epoll |
| [07](07-event-on-aio.md) | Linux | The event loop, channels, and sockets on `aio`, and calls that yield |
| [08](08-coroutines.md) | shared | The coroutine switch on arm64, macOS, and Windows |
| [09](09-aio-macos.md) | macOS | `aio` on kqueue |
| [10](10-aio-windows.md) | Windows | `aio` on IOCP |
| [11](11-http-client.md) | shared | The HTTP/1.1 parser, the client, and the `http` package names |
| [12](12-http-server.md) | shared | The server: I/O threads, routes, middleware, files, streams, and shutdown |
| [13](13-workers.md) | shared | The worker pool: one interpreter for each worker, and the limits of a request |
| [14](14-websocket-sse.md) | shared | WebSockets and SSE |
| [15](15-http-bench.md) | Linux | The HTTP/1.1 speed gates |
| [16](16-tls-record.md) | shared | The TLS record layer and the key schedule |
| [17](17-x509.md) | shared | PEM, keys, X.509 chains, and root stores |
| [18](18-tls-server.md) | shared | The TLS 1.3 server handshake, SNI, and ALPN |
| [19](19-tls-client.md) | shared | The client on the shared code, `ztcl::tls`, and `tls::socket` |
| [20](20-tls-resume.md) | shared | Resumption, tickets, 0-RTT off by default, and key update |
| [21](21-tls-interop.md) | Linux | The interop matrix and the negative tests |
| [22](22-tls-fuzz.md) | Linux | Fuzzing of the parsers and the state machines |
| [23](23-tls-constant-time.md) | shared | The constant-time tests and the machine code review |
| [24](24-tls-rsa.md) | shared | RSA-PSS server keys |
| [25](25-tls-bench.md) | Linux | The TLS speed gates |
| [26](26-tls-review-prep.md) | shared | The package for the external review |
| [27](27-tls-default.md) | shared | The findings of the review and TLS on by default |
| [28](28-hpack.md) | shared | HPACK |
| [29](29-h2-server.md) | shared | HTTP/2 in the server: frames, streams, flow control, and limits |
| [30](30-h2-client-gates.md) | shared | HTTP/2 in the client, h2spec, and the HTTP/2 speed gates |
| [31](31-formats.md) | shared | CSV, URLs, encodings, and the tcllib names |
| [32](32-toml-msgpack-cbor.md) | shared | TOML, MessagePack, and CBOR |
| [33](33-compress.md) | shared | `zlib`, `ztcl::zstd`, and HTTP content encodings |
| [34](34-crypto.md) | shared | Hashes, crypto, the capability `random`, and the tcllib names |
| [35](35-time-log.md) | shared | Zones, `ztcl::time`, and `ztcl::log` |
| [36](36-system.md) | shared | Files, paths, processes, the environment, arguments, and DNS |
| [37](37-templates.md) | shared | Templates that escape by default |
| [38](38-tooling.md) | shared | `ztcl test`, `ztcl::bench`, and `ztcl prof` |
| [39](39-sqlite-build.md) | shared | The SQLite build with no libc, the VFS, and the allocator |
| [40](40-sqlite-binding.md) | shared | The `sqlite3` command, the statement cache, and the limits |
| [41](41-sqlite-tests.md) | Linux | The SQLite tests and the speed gate |
| [42](42-bundle.md) | shared | `ztcl build` and cross targets |
| [43](43-wasm.md) | shared | The modules of the wasm build and `fetch` |
| [44](44-docs.md) | shared | The docs, the final size table, and the speed report |
| [45](45-quic-packets.md) | Linux | UDP on `aio`, QUIC packets, and packet protection |
| [46](46-quic-transport.md) | Linux | The QUIC handshake, streams, flow control, and connection IDs |
| [47](47-quic-recovery.md) | Linux | Loss recovery and congestion control |
| [48](48-http3.md) | Linux | HTTP/3 and QPACK |
| [49](49-quic-interop.md) | Linux | quic-interop-runner, the HTTP/3 gates, fuzzing, and the ports |
