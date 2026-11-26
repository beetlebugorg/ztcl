# Limits and capabilities

ztcl runs scripts that you did not write. A script gets no host access by default, and two exact limits bound its CPU work and its memory. Tcl has `interp limit` for commands and time, and no memory limit.

## The step limit

Each command and each loop pass uses one step. At the limit, the script stops with the error `step limit reached`. `catch` and `try` cannot catch it.

- The count uses no clock, so a slow machine stops a script at the same step as a fast one.
- The JIT gives the same step counts as the interpreter on the whole Tcl test suite.
- Runner: `--max-steps N`. Zig: `Interp.step_limit`. JS: `stepLimit`.

## The memory limit

The heap of an interpreter and its children never goes above twice the memory limit. One command can go over the limit by at most the limit itself. A large request stops before the allocation.

- At the limit, the script stops with the error `the script used too much memory`.
- The collector can move the point of the error between two runs. `--gc off` (Zig: `gc_on = false`) makes it exact.
- Runner: `--mem BYTES` (default 2 GiB). Zig: `Interp.mem_limit`. JS: `memLimit`.

Nesting limits also protect the native stack: 600 levels of calls and 2000 levels of nested scripts.

## Capabilities

The default interpreter has no command that reaches the host. `puts` writes to a callback of your program. Turn on a capability with `--allow NAME,NAME` in the runner, or with `Interp.allow` in Zig.

| Capability | Commands | Policy of the host |
|---|---|---|
| `package` | `package require` of Tcl packages | |
| `interp` | `interp create` and child interpreters | A child never has more capabilities than its parent. |
| `clock` | `clock`, `time`, `timerate` | The time and the zone data come from a callback. |
| `channels`, `file` | `open`, `read`, `gets`, `file`, `glob`, and the other channel commands | The real paths of the host, as in tclsh, with symlinks followed. With `--root DIR`, one root folder that `..` and symlinks cannot leave. An embedder gets the root folder unless it turns on host mode. |
| `event` | `after`, `vwait`, `update`, `fileevent` | The clock comes from a callback. |
| `socket` | `socket` | A network policy (`--net`): `loopback` (the default), an allowlist of hosts, ranges, and ports, or `any`. |
| `thread` | `thread::*`, `tsv::*`, `tpool::*` | Limits for each thread and totals for the group. See [Threads](threads.md). |
| `exec` | `exec`, `pid`, and pipelines | A program list (`--exec-allow`), a time limit (`--exec-timeout MS`), and a fixed environment (`--exec-env`). |
| `launch` | `ztcl::open` | A URL (`http`, `https`, or `mailto`) or a file in the default app of the host. A file also needs `file`. On Windows a file of a type that runs as code (`.exe`, `.bat`, `.lnk`, and others) is an error. The app is outside the root folder and each limit. Only Windows has a backend in this version. |

> [!WARNING]
> `exec` is not sandboxed. A process from `exec` runs outside the root folder and outside each limit, with the full power of the user. Turn it on only for scripts that you trust.

Built-in modules such as [`ztcl::json`](modules/json.md) need no capability.

## Determinism

With no capability on, the output of a script depends only on the script, its inputs, and the noise seed. `rand()` has a fixed seed, and `info commands` and `array names` have a fixed order. With threads or the event loop on, the order of events depends on the system.

## Example

```sh
$ ztcl --max-steps 1000000 --mem 67108864 --allow channels,file --root ./data script.tcl
```

In Zig:

```zig
it.step_limit = 1_000_000;
it.mem_limit = 64 << 20;
const cap = ztcl.interp.Capability;
try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.file));
```

[Embed in Zig](embedding.md#capabilities) has the data that each capability needs, and [Security](../SECURITY.md) has the threat model.
