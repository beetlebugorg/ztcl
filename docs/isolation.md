# Isolated threads

A thread of ztcl runs at an isolation level. The level sets what a crash, a bad C package, or a hostile script in the thread can reach. `thread::create -isolation LEVEL` picks the level, and the default is `interp`.

```tcl
set t [thread::create -isolation process {proc sq x {expr {$x * $x}}; thread::wait}]
thread::send $t {sq 12}
```

The script of the thread is the same at each level. `thread::send`, `tsv`, the mutexes, the conditions, the errors, and `thread::join` work the same way. [Threads](threads.md) has the commands.

## The levels

- `interp`, the default: the thread has an interpreter of its own in the same process. It shares no interpreter data, but a crash or a bad C package ends the whole process. Each target with threads has it.
- `process`: the thread runs in a child process, in the sandbox of the system. A crash, a memory error, or a bad C package ends only the child. Linux, macOS, and Windows have it.
- `wasm` (another instance of the wasm engine), `vm`, and `vm-confidential` (a guest of the hypervisor) are planned. They give `ZTCL ISOLATION LEVEL` in this version.

Use `process` for code that you did not read, such as the code of an agent or a C package from another project, and for work that can crash. Each message to a `process` thread costs a round trip between two processes, so keep the messages large and few.

## The sandbox of each system

The child gets the capabilities, the compute limit, and the memory limit of the thread. The system adds the limits of this table.

| | Linux | macOS | Windows |
|---|---|---|---|
| The sandbox | User, PID, mount, IPC, UTS, cgroup, and network namespaces, Landlock, and a seccomp filter | `sandbox_init` | An AppContainer and a Job Object |
| Files | The root folder of the creator, in a new root with a new `/proc` | The root folder of the creator | The root folder of the creator |
| Network | Only with `socket`. Without it, the child is in a new network namespace. | Only with `socket` | Only with `socket` |
| Programs | No program can start | No program can start, and no Mach service | One process in the job, so `exec` fails |
| Memory | `memory.max` at the memory limit plus 64 MiB | The parent ends a child past its memory limit plus 128 MiB | The job ends a child past its memory limit plus 64 MiB |
| Other | `pids.max` 32, `cpu.max` one CPU | | |

The margin over the memory limit is for the runner of the child. A child that does not stop within 2 seconds at the end of the group gets a kill.

On Linux the level needs unprivileged user namespaces, mounts in them, a delegated cgroup v2 with the `cpu`, `memory`, and `pids` controllers, and Landlock. A system with no such feature gives `ZTCL ISOLATION LEVEL` with the name of the feature. Ubuntu limits user namespaces with AppArmor by default.

## Files of the host

A creator in host mode, such as the `ztcl` program with no `--root`, has the files of the user. A `process` thread of that creator gets `ZTCL ISOLATION HOSTFILES` when the creator has `file` or the channels: "give the thread a root folder, or pass -files host". Choose one:

- Run the creator with a root folder (`ztcl --root DIR`). The child gets that folder.
- Pass `-files host`. The child gets the files of the user, and keeps the other limits: the process, the memory limit, and the network and program limits.

`-files host` is an error from a creator with a root folder, and with no `-isolation process`.

> [!WARNING]
> On Windows, `-files host` runs the child with no AppContainer, because an AppContainer reaches no folder of the user. The child keeps the Job Object and gets a token with no privilege, with the administrators group for deny only. It has no network limit of the system: with `socket`, the child reaches each address that the user can reach. Without `socket`, the interpreter has no socket command.

## Sends back to the parent

A thread can send a script to the main thread, as in the Thread package. That script runs in the parent with all of the power of the parent. The sandbox limits the child, and a send to the parent goes past it.

When you review the code of a parent:

- Find each script that a child can send, and each proc that such a script calls.
- A send from a child is input. Check it as a line from the network: no `eval`, `uplevel`, or `subst` of its text.
- A result of `thread::send` is data from the child. Parse it, and do not run it.

## Limits of this version

- `thread::transfer` and a thread that the child creates give an error in the child. Pull request [#253](https://github.com/beetlebugorg/ztcl/pull/253) adds `thread::transfer` for `process` threads.
- The runner starts the child (`Interp.iso_runner`). An embedder that is not the runner sets `iso_runner` to the path of a `ztcl` runner, or gets `ZTCL ISOLATION RUNNER`.
- `tsv`, the mutexes, the conditions, and `thread::eval` in the child go through the parent, so each one costs a round trip.

## Errors

| `errorCode` | When |
|---|---|
| `ZTCL ISOLATION LEVEL` | The level does not exist on this system, or the system has no feature that the level needs. |
| `ZTCL ISOLATION HOSTFILES` | A creator in host mode with files asks for a `process` thread with no `-files host`, or `-files host` comes with a root folder or with no `-isolation process`. |
| `ZTCL ISOLATION RUNNER` | The embedder gave no runner for the child. |
| `ZTCL ISOLATION START` | The child did not start. |
| `ZTCL ISOLATION BROKER` | The parent does not run a command for the child, or the parent of the thread is gone. |

The protocol between the parent and the child is in the design notes of the repository (`docs/dev/isolation.md`).
