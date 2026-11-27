# The guest agent of `ztcl::vm`

The agent is the first process of the guest of `ztcl::vm` (ztcl#203): `/sbin/agent` in the initramfs, with `rdinit=/sbin/agent` on the command line of the kernel. It runs a program in the guest and mounts a share for the host. Each host (Virtualization.framework on macOS, KVM on Linux, HCS on Windows) drives the same agent over the same protocol, so this page is the contract between them. The source is `tools/vm-guest/agent.zig`.

## The start

As process 1, the agent mounts `proc` at `/proc`, `sysfs` at `/sys`, `devtmpfs` at `/dev`, and `tmpfs` at `/tmp`. The virtio-fs share with the tag `share0` goes to `/mnt/share` when the guest has it. Then the agent listens on two vsock ports, with the CID of any host:

| Port | Service |
|---|---|
| 1024 | The protocol below. |
| 1025 | The probe of the start time: 16 bytes (the boot clock of the guest in nanoseconds when `main` started and when the agent listened), then an echo of each byte. A first byte of 1 asks for the kernel log instead. `tools/vm-guest/spike.zig` uses it. |

Each connection runs in a child process of the agent, so a long `exec` does not stop another connection. On Windows the host reaches the same ports through Hyper-V sockets (`HV_GUID_VSOCK_TEMPLATE` with the port in the first 4 bytes of the service id).

## Frames

Each message in each direction is one frame:

```
len u32 | type u8 | payload (len - 1 bytes)
```

Numbers are little endian. `len` counts the type byte and the payload, and is at most 1 MiB + 1. A string is `u32` length and bytes, with no NUL. A list of strings is a `u32` count and the strings.

## A connection

1. The agent sends `HELLO`: `version u16` (1), `features u32` (bit 0 `exec`, bit 1 `mount`, bit 2 `log`), `boot_main u64`, `boot_listen u64`.
2. The host sends one request: `EXEC`, `MOUNT`, `LOG`, or `PING`.
3. The agent answers as below, and closes the connection after its last frame. A new request takes a new connection.

| Type | Value | From | Payload |
|---|---|---|---|
| `HELLO` | 0x01 | agent | as above |
| `EXEC` | 0x10 | host | `argv` list, `env` list (`NAME=value`), `cwd` string (empty: `/`), `flags u8` (bit 0: stdin is open) |
| `MOUNT` | 0x11 | host | `tag` string, `path` string, `flags u8` (bit 0: read only) |
| `LOG` | 0x12 | host | none |
| `PING` | 0x13 | host | none |
| `STARTED` | 0x20 | agent | `pid u32` |
| `STDOUT` | 0x21 | agent | bytes |
| `STDERR` | 0x22 | agent | bytes |
| `STDIN` | 0x23 | host | bytes; an empty payload closes stdin |
| `SIGNAL` | 0x24 | host | `signal u8` for the program |
| `EXIT` | 0x25 | agent | `code i32`: the exit code, or minus the number of the signal that ended the program |
| `OK` | 0x30 | agent | none (`MOUNT`, `PING`) |
| `DATA` | 0x31 | agent | bytes of the kernel log (`LOG`), then `OK` |
| `ERROR` | 0x3f | agent | `errno u32`, `message` string |

`EXEC` runs `argv[0]` by its path, with no search of `PATH` and no shell: a shell is `argv` `{/bin/sh -c ...}` when the image has one. The agent answers `STARTED`, then `STDOUT` and `STDERR` frames as the program writes, then `EXIT` once the program ended and both pipes are at their end. The host may send `STDIN` and `SIGNAL` frames until `EXIT`. A host that closes the connection before `EXIT` ends the program with `SIGKILL`. A failed start gives `ERROR` with the `errno` of `execve` and no `STARTED`.

`MOUNT` makes the folder `path` and its parents, and mounts the virtio-fs share `tag` there. A failure gives `ERROR`.

The protocol has no authentication: vsock reaches the agent only from the host of the guest. A host that gives the guest to a script lets the script run each program of the image as root in the guest, with no more reach than the guest has.

## Versions

A new request type or a new flag raises nothing; the host checks `features` first. A change of a frame raises `version`, and a host refuses an agent of a version it does not know with `ZTCL VM AGENT`.
