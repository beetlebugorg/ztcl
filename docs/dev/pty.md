# Plan: a pseudo-terminal for scripts (`ztcl::pty`)

A script with the `exec` capability starts a program on a pseudo-terminal (PTY). The program sees a terminal on its standard input, output, and error. The script reads and writes the other side of the PTY as a channel, on the event loop. A terminal widget (for example `ztk::terminal`) uses this command to run a shell or a full-screen program.

## Commands

```tcl
set t [ztcl::pty spawn ?-size {cols rows}? ?-cwd dir? ?-env {NAME value ...}? program ?arg ...?]
ztcl::pty resize $t cols rows
ztcl::pty size $t                ;# {cols rows}
ztcl::pty status $t              ;# running | {exit code} | {signal NAME}
ztcl::pty kill $t ?signal?       ;# HUP is the default
close $t
```

- `spawn` gives a channel. It is readable and writable, and its translation is binary. `fileevent` and `fconfigure -blocking 0` work on it as on a pipe.
- The program runs directly from its argument list. There is no shell. The first word goes through the same path resolution and the same allowlist check as `exec` (`Interp.exec_host`): the `PATH` of `env`, `allow`, and `allow_root`.
- The environment is `exec_host.env`, then the pairs of `-env`. `TERM=xterm-256color` is added when no entry sets `TERM`.
- The size is 80 by 24 unless `-size` gives it.
- The working folder is the current folder of `file`, as for `exec`. `-cwd` names a folder below the root folder, and it needs the `file` capability.
- `resize` sets the window size of the PTY. The kernel sends SIGWINCH to the foreground process group.
- `status` does not block. The exit code stays available after the process ends, until `close`.
- `close` closes the PTY. The kernel sends SIGHUP to the session of the program. After 500 ms each process of the tree that still runs gets SIGKILL. `close` does not report the exit code as an error: a terminal program often ends with a code other than 0.

When the program ends and its last descriptor of the PTY closes, a read gives the end of the file. Linux reports EIO on the master side at that point, and the channel reads EIO on a PTY as the end of the file.

## Capabilities and limits

`ztcl::pty` exists only with the `exec` capability. The reads and writes need the `channels` capability, as for `open |cmd`. A child interp gets it only when its parent has `exec`. A test proves that the command is absent by default.

WARNING: a program on a PTY is outside the root folder and outside each limit of the interpreter, as with `exec`. It has the full power of the user. It is not sandboxed.

The process tree uses the same code as `exec`: the cgroup on Linux when the embedder can make one, the process group otherwise. `abandonAll` and `timeout_ms` of `exec_host` apply to a PTY process too.

## Platforms

| Platform | Form | State in the first PR |
|---|---|---|
| Linux | `/dev/ptmx` with `TIOCSPTLCK` and `TIOCGPTPEER`. The child calls `setsid`, sets the PTY as its controlling terminal with `TIOCSCTTY`, and runs `execve`. | Done (PR 2) |
| macOS | `posix_openpt`, `grantpt`, `unlockpt`, `ptsname`, and `posix_spawn` with `POSIX_SPAWN_SETSID` (macOS 10.15 and later). `fork` is not used, as in `exec`. | Done (step 3). The parent opens the other side with O_NOCTTY for the size, because macOS answers EIO to a size on the master side before that open. |
| Windows | ConPTY: `CreatePseudoConsole` with two pipes, `ResizePseudoConsole`, and `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`. The channel reads and writes the pipes. | `exec` has its Windows form (`docs/dev/exec-windows.md`). `spawn` gives the error "ztcl::pty is not available on Windows yet" until the ConPTY form. |
| WASI, the web | No processes. | The command is absent. |

The platform code is in `src/pty.zig` (Linux and the shared parts), `src/pty_mac.zig`, and `src/pty_windows.zig`. Each form gives the same four calls: open with a size, resize, the child start, and the close. The command code does not change between the platforms.

## Hooks in shared files

The PTY is new code, and it changes these shared files with small hooks only:

1. `src/interp.zig`: `pty.register(it)` next to `proc.register(it)` when `exec` turns on.
2. `src/chan.zig`: a field `pty: bool` on `Channel`. `close` calls `pty.hangup` for a PTY channel in place of `proc.reap`. A read error EIO on a PTY channel gives the end of the file.
3. `src/proc.zig`: `resolve`, `treeOpen`, `treeKill`, `treeClose`, and `waitPid` become `pub`.

## Tests

The tests use `/bin/sh` and small programs from the standard system (`stty`, `cat`, `printf`). No test starts a large program.

1. `ztcl::pty` is absent without `exec`.
2. `spawn /bin/sh -c {tty}` prints a path below `/dev/pts/`.
3. `-size {100 40}` and then `stty size` prints `40 100`. `resize` and then `stty size` prints the new size.
4. A write of `echo hi\n` to `cat` gives `hi` back through the echo of the terminal.
5. `fileevent readable` fires for the output of the program, and `vwait` ends.
6. `status` gives `{exit 3}` after `sh -c {exit 3}`, and `{signal KILL}` after `kill $t KILL`.
7. `close` of a channel with `sh -c {trap {} HUP; sleep 30}` returns in less than 2 s, and no process of the tree runs after it.
8. The allowlist of `exec_host` stops a program that it does not list, before a process starts.
9. On a platform with `exec` and no PTY: `spawn` gives the error `ZTCL PTY UNAVAILABLE`.

## Steps

1. This plan.
2. Linux: `src/pty.zig`, the hooks, the tests, and a section in the user docs of `exec`.
3. macOS: `src/pty_mac.zig` and the tests on the macOS CI job.
4. Windows: `src/pty_windows.zig` with ConPTY and the tests on the Windows CI job.
