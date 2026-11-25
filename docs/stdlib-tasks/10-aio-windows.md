# Task 10: `aio` on IOCP

Platform: Windows.

## Goal

The `aio` layer on Windows with I/O completion ports. Files use `Io.Threaded`.

## Files

- `src/aio/iocp.zig` (new): `CreateIoCompletionPort`, `AcceptEx`, `ConnectEx`, `WSARecv`, `WSASend`, `TransmitFile`, and `GetQueuedCompletionStatusEx`. Each `kernel32` and `ws2_32` function is declared in the file.

## Test sources

- The tests of task 06.

## Acceptance

```sh
CAP zig build aio-test
zig build aio-stress -- --conns 5000 --seconds 300
```

Gates:

- The tests of task 06 pass on x86-64 Windows.
- No leaked handle after the stress run.

`CAP` has no form on Windows. Use a job object with a memory limit of 4 GB, as `tools/winjob.ps1` sets it up (new in this task).
