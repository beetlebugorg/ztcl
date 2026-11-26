# Module ztcl::pty

`ztcl::pty` runs a program on a pseudo-terminal (PTY): the program sees a terminal on its input and output, and the script reads and writes the other side as a channel. A terminal widget uses it to run a shell or a full-screen program.

> [!NOTE]
> `ztcl::pty` is on `main` and comes in the next release. [Build from source](../install.md#build-from-source) to use it now.

```tcl
set t [ztcl::pty spawn -size {80 24} /bin/sh]
puts -nonewline $t "echo hello\r"
flush $t
after 200
puts [read $t]            ;# the echo and the output, with the escape sequences of the terminal
ztcl::pty resize $t 100 30
ztcl::pty status $t       ;# running
close $t
```

## Capability

`ztcl::pty` exists only with the capability `exec` (`--allow exec`), and the reads and writes of its channel need `channels`, as for `open "|cmd"`. The program goes through the same checks as a program of [`exec`](../processes.md): the `PATH` of `exec_host.env`, the allowlist `exec_host.allow`, and `exec_host.allow_root`. `exec_host.timeout_ms` ends a program that runs too long.

The program runs outside the root folder and outside each limit of the interpreter, with the full power of the user. It is not sandboxed.

## Commands

### spawn

```tcl
ztcl::pty spawn ?-size {COLS ROWS}? ?-cwd DIR? ?-env {NAME VALUE ...}? ?--? PROGRAM ?ARG ...?
```

Starts `PROGRAM` with its arguments on a new PTY and gives a channel. The channel is readable and writable, binary, and has no buffering. `fileevent` and `fconfigure -blocking 0` work on it as on a pipe.

| Option | Default | Meaning |
|---|---|---|
| `-size {COLS ROWS}` | `{80 24}` | The size of the terminal. |
| `-cwd DIR` | the current folder of `file` | The working folder: a folder of `file`, so it needs the capability `file`. |
| `-env {NAME VALUE ...}` | none | Pairs added to the environment of `exec_host.env`. |

The program runs directly from its argument list, with no shell. Its environment is `exec_host.env`, then the pairs of `-env`, then `TERM=xterm-256color` when no entry sets `TERM`.

### resize and size

```tcl
ztcl::pty resize CHANNEL COLS ROWS
ztcl::pty size CHANNEL
```

`resize` sets the size of the terminal, and the program gets the change (SIGWINCH on Linux and macOS, the console event on Windows). `size` gives `{COLS ROWS}`.

### status

```tcl
ztcl::pty status CHANNEL
```

Gives `running`, `{exit CODE}`, or `{signal NAME}` (for example `{signal KILL}`), with no wait. The status stays until `close`.

### kill

```tcl
ztcl::pty kill CHANNEL ?SIGNAL?
```

Sends a signal to the program. `SIGNAL` is `HUP` (the default), `INT`, `QUIT`, `KILL`, `TERM`, `CONT`, `STOP`, `WINCH`, the same names with `SIG` in front, or a number from 1 to 64. The [platforms](#platforms) differ in what a signal does.

### close

`close $t` closes the PTY and ends the program: the program gets the hangup of its terminal, and after 500 ms each process of its tree that still runs ends. `close` does not report the exit code as an error, because a terminal program often ends with a code other than 0.

## Platforms

| | Linux | macOS (arm64) | Windows (x86-64) |
|---|---|---|---|
| The terminal | `/dev/ptmx` with `TIOCGPTPEER` (or `TIOCGPTN` and `/dev/pts/N` on a kernel before 4.13) | `posix_openpt`, `grantpt`, `unlockpt`, and `ptsname_r` | ConPTY: `CreatePseudoConsole` on two pipes |
| The start | `fork`, `setsid`, `TIOCSCTTY`, and `execve` | `posix_spawn` with `POSIX_SPAWN_SETSID`, and the first open of the terminal makes it the controlling terminal | `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` and no handle of the parent |
| The process tree | the cgroup or the process group of `exec` | the process group of `exec` | the Job Object of `exec` |
| `-size` and `resize` | 1 to 10,000 for each side | 1 to 10,000 for each side | 1 to 32,767 for each side |
| `size` | the size of the terminal from the kernel | the size of the terminal, read on the other side | the last size of `spawn` or `resize` |
| `kill` | the signal to the process group | the signal to the process group | `INT` writes Ctrl-C (byte 3) to the input; `CONT`, `STOP`, and `WINCH` have no effect; each other signal ends the Job Object; the numbers are 1, 2, 3, 9, and 15 |
| `close` | the kernel sends SIGHUP to the session | the kernel sends SIGHUP to the session | `ClosePseudoConsole` sends the close event to the program |
| The output | the bytes of the program | the bytes of the program | the console renders the program and sends VT escape sequences |

On Windows a program writes to a console, and ConPTY turns that console into the escape sequences of a VT terminal, so the output of a program has cursor moves and colors even when the program writes plain text. On Linux and macOS, the end of the program gives the end of the file on the channel (Linux reports EIO on the master side, and the channel reads it as the end).

`ztcl::pty` does not exist on WebAssembly, on x86-64 macOS, or on arm64 Windows, because those targets have no `exec`.

## Examples

A shell on Linux or macOS, with its output read until a marker:

```tcl
set t [ztcl::pty spawn -size {100 30} /bin/sh]
fconfigure $t -blocking 0
puts -nonewline $t "echo ready-marker\r"
flush $t
set out ""
while {[string first "ready-marker\r\n" $out] < 0} {
    append out [read $t]
    after 10
}
puts [ztcl::pty size $t]      ;# 100 30
close $t
```

The same on Windows with `cmd.exe`:

```tcl
set t [ztcl::pty spawn cmd.exe]
fconfigure $t -blocking 0
puts -nonewline $t "exit 4\r"
flush $t
while {[ztcl::pty status $t] eq "running"} { read $t; after 10 }
puts [ztcl::pty status $t]    ;# exit 4
close $t
```

## Errors

| Error text | `-errorcode` |
|---|---|
| `bad option "X": must be -cwd, -env, or -size` | `NONE` |
| `value for "X" missing` | `NONE` |
| `bad size "X": must be {cols rows}` | `NONE` |
| `bad column count "N": must be from 1 to 10000` (32767 on Windows; also `row count`) | `NONE` |
| `-cwd needs the file capability` | `NONE` |
| `-env needs a list of names and values` | `NONE` |
| `bad environment name "X"` | `NONE` |
| `channel "X" is not a pty` | `NONE` |
| `can not find channel named "X"` | `TCL LOOKUP CHANNEL X` |
| `bad signal "X": must be HUP, INT, QUIT, KILL, TERM, CONT, STOP, WINCH, or a number` | `NONE` |
| `bad option "X": must be kill, resize, size, spawn, or status` | `NONE` |
| `couldn't execute "X": the embedder does not allow this program` (and the other errors of `exec`) | `ZTCL EXEC DENIED` |
| `couldn't create a pseudo console: error 0xN` (Windows) | `ZTCL PTY UNAVAILABLE` |
| `couldn't set the pty size: error 0xN` (Windows) | `NONE` |
| `ztcl::pty is not available on X yet` | `ZTCL PTY UNAVAILABLE` |
| `wrong # args: should be "ztcl::pty spawn ?-size {cols rows}? ?-cwd dir? ?-env list? program ?arg ...?"` (and the other forms) | `TCL WRONGARGS` |

## Cost

Each command is one compute unit. The program runs outside the interpreter, so its work counts against no limit of the interpreter; `exec_host.timeout_ms` is its only limit. The reads and writes of the channel cost what other channel commands cost.

## Security

- The program has the full power of the user. `ztcl::pty` is not sandboxed, as `exec` is not.
- The allowlist of `exec` applies to the program of `spawn`, before any process starts, and a file below the root folder runs only through `exec_host.allow_root`.
- `close`, the time limit, and the end of the interpreter end each process of the tree of the program.
- See [the rules of `exec`](../../SECURITY.md#the-rules-of-exec).
