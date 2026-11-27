# Limits and capabilities

ztcl runs scripts that you did not write. A script gets no host access by default, and two exact limits bound its CPU work and its memory. Tcl has `interp limit` for commands and time, and no memory limit.

## The compute limit

The compute limit bounds the CPU work of a script. It counts compute units. At the limit, the script stops with the error `compute limit reached`. `catch` and `try` cannot catch it.

One compute unit is about one Tcl command executed:

- Each command call is one unit. A command that the compiler puts inline keeps one unit for the command that it replaces.
- Each pass of a loop is one unit, and each guard is one unit.
- Work on large data costs units in proportion to its size: one unit for each 4,096 bytes of data. A list element, a table entry, and a compare of a sort count as 64 bytes each.

A compute unit is not one bytecode. The interpreter, the JIT, WebAssembly level 3, and the superinstructions give the same count, so a limit gives the same result for each way that the code runs. The count uses no clock, so a slow machine stops a script at the same point as a fast one. The JIT gives the same counts as the interpreter on the whole Tcl test suite.

The nearest feature of Tcl is `interp limit PATH commands`. The compute limit also charges for the size of the data.

- Runner: `--compute N`. `--report` writes the compute units used to stderr.
- Zig: `Interp.compute_limit`, the units that are left.
- JS: the option `computeLimit`.

For example, this script uses 28 compute units:

```sh
$ cat sum.tcl
set s 0
foreach x {1 2 3 4 5 6 7 8 9 10} {incr s $x}
puts $s
$ ztcl --report sum.tcl
report compute=28 mem=547928 peak=547928
55
$ ztcl --compute 20 sum.tcl
sum.tcl:2: compute limit reached
```

A sort of a list of 100,000 elements uses about 28,000 units, most of them for the data.

## The memory limit

The heap of an interpreter and its children never goes above twice the memory limit. One command can go over the limit by at most the limit itself. A large request stops before the allocation.

- At the limit, the script stops with the error `the script used too much memory`.
- The collector can move the point of the error between two runs. `--gc off` (Zig: `gc_on = false`) makes it exact.
- Runner: `--mem BYTES` (default 2 GiB). Zig: `Interp.mem_limit`. JS: `memLimit`.
- The process can hold up to 16 MiB more than the count of the heap. These are free pages of the heap that the interpreter keeps for its next pages, so a collection does not give them to the system and map them again. The count and the limit do not include them. Zig: `Interp.counter.spare.max` (0 gives each free page back at once).

Nesting limits also protect the native stack: 600 levels of calls and 2000 levels of nested scripts.

## Capabilities

The default interpreter has no command that reaches the host. `puts` writes to a callback of your program. Turn on a capability with `--allow NAME,NAME` in the runner, or with `Interp.allow` in Zig.

| Capability | Commands | Policy of the host |
|---|---|---|
| `package` | `package require` of Tcl packages | |
| `interp` | `interp create` and child interpreters | A child never has more capabilities than its parent. |
| `clock` | `clock`, `time`, `timerate` | The time and the zone data come from a callback. |
| `channels`, `file` | `open`, `read`, `gets`, `file`, `glob`, and the other channel commands | The real paths of the host, as in tclsh, with symlinks followed. With `--root DIR`, one root folder that `..` and symlinks cannot leave. An embedder gets the root folder unless it turns on host mode. |
| `embedded` | `open` for reading, `source`, `glob`, the queries of `file`, and `zipfs`, on the zip mounts under `//zipfs:/` only | A path outside a mount is the error "permission denied". See [Build a program](build.md). |
| `event` | `after`, `vwait`, `update`, `fileevent` | The clock comes from a callback. |
| `socket` | `socket` | A network policy (`--net`): `loopback` (the default), an allowlist of hosts, ranges, and ports, or `any`. |
| `thread` | `thread::*`, `tsv::*`, `tpool::*` | Limits for each thread and totals for the group. See [Threads](threads.md). |
| `exec` | `exec`, `pid`, and pipelines | A program list (`--exec-allow`), a time limit (`--exec-timeout MS`), and a fixed environment (`--exec-env`). |
| `launch` | `ztcl::open` | A URL (`http`, `https`, or `mailto`) or a file in the default app of the host. A file also needs `file`. A file of a type that the system runs as code is an error: `.exe`, `.bat`, `.lnk`, and others on Windows, and an app bundle, `.command`, `.pkg`, a file with an execute bit, and others on macOS. The app is outside the root folder and each limit. Windows and macOS have a backend in this version. |
| `registry` | `ztcl::win::registry` | The keys of a list (`--registry-allow KEY,KEY`) and the keys below them, on Windows. An empty list reaches no key. A key such as `Run` starts a program at the next login, so list only the keys of your app. |
| `keychain` | `ztcl::mac::keychain` | The generic passwords of the login keychain of macOS, for the services of a list (`--keychain-allow S,S`) only. An empty list reaches none. A secret goes to the script as a string. |
| `defaults` | `ztcl::mac::defaults` | The string values of the user defaults of macOS, for the domains of a list (`--defaults-allow D,D`) only. An empty list reaches none. |
| `notify` | `ztcl::notify` | A notification of the system with a title, a subtitle, and a body: at most 256 bytes for the title and the subtitle and 4,096 for the body, in UTF-8. macOS shows it with `osascript`, and the texts are arguments of the script. Windows shows a toast of the notification center. Linux needs `notify_host` in this version. |
| `vm` | `ztcl::vm` | A small Linux guest on the hypervisor of the host (macOS in this version). The limits of `Interp.vm_host`: 4 CPUs, 2,048 MB, and 4 guests by default. Its paths also need `file` and stay below the root folder. A share or a disk is read-only unless it says `rw`. A child interp never has it. See [ztcl::vm](modules/vm.md). |

> [!WARNING]
> `exec` is not sandboxed. A process from `exec` runs outside the root folder and outside each limit, with the full power of the user. Turn it on only for scripts that you trust.

Built-in modules such as [`ztcl::json`](modules/json.md) need no capability.

## Determinism

With no capability on, the output of a script depends only on the script, its inputs, and the noise seed. `rand()` has a fixed seed, and `info commands` and `array names` have a fixed order. With threads or the event loop on, the order of events depends on the system.

## Example

```sh
$ ztcl --compute 1000000 --mem 67108864 --allow channels,file --root ./data script.tcl
```

In Zig:

```zig
it.compute_limit = 1_000_000;
it.mem_limit = 64 << 20;
const cap = ztcl.interp.Capability;
try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.file));
```

[Embed in Zig](embedding.md#capabilities) has the data that each capability needs, and [Security](../SECURITY.md) has the threat model.
