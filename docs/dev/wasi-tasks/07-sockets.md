# Task 07: sockets on `wasi:sockets` 0.3

Platform: shared/wasi.

## Goal

`socket` works in the p3 build: a client, a server, and `fileevent` on a socket. The network policy of the embedder holds.

## Files

- `src/sys_wasi.zig`: `listenAt`, `connectTo`, `accept`, `sockName`, `peerName`, `shutdown`, and `connectError` on `wasi:sockets/types`. WASI 0.3 has two socket interfaces, `types` and `ip-name-lookup`, in place of the seven of 0.2. A connection is a pair of `stream<u8>`, and `accept` gives a stream of sockets. `resolve` uses `wasi:sockets/ip-name-lookup`.
- `wit/ztcl.wit`: the runner world imports `wasi:sockets`.
- `tools/wasi-run.sh`: gives wasmtime the socket flags only when the runner gets the socket capability.

## Rules

- `sys.resolve` is the only name lookup. `sock.zig` checks each resolved address, each connection, and each peer with no change.
- A socket in the event loop is its streams and futures in the waitable set of task 06.
- The tests use only loopback addresses.
- `exec` stays absent.

## Acceptance

```sh
CAP zig build wasi-component
CAP tools/wasi-smoke.sh --component      # adds: echo server and client on 127.0.0.1, a refused host, a refused peer
CAP tools/suite.sh -t core-8-6-16 -r 'tools/wasi-run.sh --component'
```

Gate: `socket.test` under WASI passes at least the tests that do not need `exec`. Report the count and the cause of each fail.
