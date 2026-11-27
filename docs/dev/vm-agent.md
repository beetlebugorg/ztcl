# The guest agent of `ztcl::vm`

The agent is the first process of the guest of `ztcl::vm` (ztcl#203): `/sbin/agent` in the initramfs, with `rdinit=/sbin/agent` on the command line of the kernel. It runs a program in the guest and mounts a share for the host. Each host (Virtualization.framework on macOS, KVM on Linux, HCS on Windows) drives the same agent over the same protocol, so this page is the contract between them. The source is `tools/vm-guest/agent.zig`.

## The start

As process 1, the agent mounts `proc` at `/proc`, `sysfs` at `/sys`, `devtmpfs` at `/dev`, and `tmpfs` at `/tmp`. The share with the tag `share0` goes to `/mnt/share` when the guest has it: virtio-fs, or else 9p. Then the agent listens on two vsock ports, with the CID of any host:

| Port | Service |
|---|---|
| 1024 | The protocol below. |
| 1025 | The probe of the start time: 16 bytes (the boot clock of the guest in nanoseconds when `main` started and when the agent listened), then an echo of each byte. A first byte of 1 asks for the kernel log instead. `tools/vm-guest/spike.zig` uses it. |
| 1027 | The resume of a guest of a snapshot (ztcl#468): the host sends 48 bytes, `ZTISOVM1`, the clock of the host (`u64` ns since 1970), and 32 random bytes. The agent sets the clock, adds the bytes to the random pool of the kernel (RNDADDENTROPY, then RNDRESEEDCRNG), and sends one byte. It serves this port in its first process, with no fork. |

Each connection runs in a child process of the agent, so a long `exec` does not stop another connection. On Windows the host reaches the same ports through Hyper-V sockets (`HV_GUID_VSOCK_TEMPLATE` with the port in the first 4 bytes of the service id).

## The network

With a virtio-net device on the bus (virtio device id 1, from `-net nat`), the agent sets `lo` and `eth0` up before it listens. The host knows the network of its NAT and gives it on the command line of the kernel, `ztcl.net=10.0.2.15/24,10.0.2.2,10.0.2.3` (the address and prefix, the gateway, the DNS address), so the agent sets them with no DHCP. Without that option it asks with DHCP: first a REQUEST of 10.0.2.15 (the INIT-REBOOT state of RFC 2131), then DISCOVER and REQUEST, three tries of 500 ms each. It sets the address and the netmask of the answer on eth0 and the default route through its router, with the ioctls of the kernel. The guest kernel has no IP autoconfiguration. With a DNS address (the third field of `ztcl.net=`, or option 6 of DHCP), the agent mounts a tmpfs at `/run` and writes `/run/resolv.conf`; the root of an image is read-only, and its `/etc/resolv.conf` is a link to that file (`image.sh`, `pack.sh`). A guest with no network device skips this. On VZ the network costs about 0.5 ms before the agent listens, of which about 0.4 ms is the open of eth0 in the kernel (the virtio-net driver fills its receive queue); the DHCP path costs about 0.2 ms more.

## The client mode

`/sbin/agent connect -framed PORT` is the framed relay, for a listener with `-framed 1` (`src/vmrelay.zig` on the host). It sends the preamble `ZTRELAY1`, then frames in each direction: a kind byte (0 data, 1 end), a length (u32, little-endian, at most 65,536), and the data. The end of its input is an end frame, and an end frame of the host closes its output, so a half-close needs no shutdown of vsock, which Virtualization.framework loses when its buffer to the host holds data. The host turns the frames into a stream socket for the script. A connection with no preamble closes.

`/sbin/agent connect PORT` connects to vsock port `PORT` of the host (CID 2) and copies its standard input to the connection and the connection to its standard output, until both close. It exits 1 when the host has no listener there. The host listens with `ztcl::vm listen`; dockyard's guest proxy relays the connections of `127.0.0.1:3128` in the guest this way.

## Frames

Each message in each direction is one frame:

```
len u32 | type u8 | payload (len - 1 bytes)
```

Numbers are little endian. `len` counts the type byte and the payload, and is at most 1 MiB + 1. A string is `u32` length and bytes, with no NUL. A list of strings is a `u32` count and the strings.

## A connection

1. The agent sends `HELLO`: `version u16` (1), `features u32` (bit 0 `exec`, bit 1 `mount`, bit 2 `log`, bit 3 `resume`, bit 4 the framed relay, bit 5 `keepalive`), `boot_main u64`, `boot_listen u64`.
2. The host sends one request: `EXEC`, `MOUNT`, `LOG`, `PING`, or `RESUME`.

With `keepalive` (bit 5), the connection takes another request after the answer of one ends, until the host closes it: the agent reads the next request where the last one ended, and drops an `STDIN` or `SIGNAL` frame that comes before it (input for a program that ended). The host keeps the connection of a request that ended well for the next request of the guest, and checks first that the idle connection has no byte to read (an ended one is readable); a guest that stops or goes closes it. On Virtualization.framework this saves the connect of vsock and the HELLO, about 110 us of each `exec`. A host that closes after one request works with the agent as before.
3. The agent answers as below, then waits for the next request on the same connection until the host closes it (`keepalive`). A host without it closes after the answer, and a new request takes a new connection.

| Type | Value | From | Payload |
|---|---|---|---|
| `HELLO` | 0x01 | agent | as above |
| `EXEC` | 0x10 | host | `argv` list, `env` list (`NAME=value`), `cwd` string (empty: `/`), `flags u8` (bit 0: stdin is open) |
| `MOUNT` | 0x11 | host | `tag` string, `path` string, `flags u8` (bit 0: read only, bit 1: a 9p share in the place of virtio-fs) |
| `LOG` | 0x12 | host | none |
| `PING` | 0x13 | host | none |
| `RESUME` | 0x14 | host | `realtime_ns u64`, 32 random bytes: the request of port 1027 as a frame of port 1024 |
| `STARTED` | 0x20 | agent | `pid u32` |
| `STDOUT` | 0x21 | agent | bytes |
| `STDERR` | 0x22 | agent | bytes |
| `STDIN` | 0x23 | host | bytes; an empty payload closes stdin |
| `SIGNAL` | 0x24 | host | `signal u8` for the program |
| `EXIT` | 0x25 | agent | `code i32`: the exit code, or minus the number of the signal that ended the program |
| `OK` | 0x30 | agent | none (`MOUNT`, `PING`, `RESUME`) |
| `DATA` | 0x31 | agent | bytes of the kernel log (`LOG`), then `OK` |
| `ERROR` | 0x3f | agent | `errno u32`, `message` string |

`EXEC` runs `argv[0]` by its path, with no search of `PATH` and no shell: a shell is `argv` `{/bin/sh -c ...}` when the image has one. The agent answers `STARTED`, then `STDOUT` and `STDERR` frames as the program writes, then `EXIT` once the program ended and both pipes are at their end. The host may send `STDIN` and `SIGNAL` frames until `EXIT`. A host that closes the connection before `EXIT` ends the program with `SIGKILL`. A failed start gives `ERROR` with the `errno` of `execve` and no `STARTED`.

`MOUNT` makes the folder `path` and its parents, and mounts the share `tag` there: virtio-fs (Virtualization.framework), or with bit 1 a 9p share of virtio (`trans=virtio,version=9p2000.L`, the KVM monitor). A failure gives `ERROR`.

The protocol has no authentication: vsock reaches the agent only from the host of the guest. A host that gives the guest to a script lets the script run each program of the image as root in the guest, with no more reach than the guest has.

## Versions

A new request type or a new flag raises nothing; the host checks `features` first. A change of a frame raises `version`, and a host refuses an agent of a version it does not know with `ZTCL VM AGENT`.
