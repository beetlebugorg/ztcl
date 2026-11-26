# Run programs

With the capability `exec`, a script runs programs of the host: `exec` runs a pipeline and gives its output, `open "|cmd"` gives a channel on a pipeline, and `pid` gives the ids of the processes. [`ztcl::pty`](modules/pty.md) runs a program on a terminal.

> [!WARNING]
> **`exec` is not sandboxed.** A program runs outside the root folder and outside the compute, memory, and nesting limits of the interpreter, with the full power of the user that runs the embedder. Turn `exec` on only for scripts that you trust, with a program list and a time limit.

```tcl
puts [exec git rev-parse --short HEAD]
set f [open "|sort" r+]
puts $f "b\na"
close $f write
puts [read $f]                    ;# a b
close $f
```

```sh
ztcl --allow exec,channels --exec-allow git,sort --exec-env PATH=/usr/bin:/bin --exec-timeout 10000 build.tcl
```

## Capability, program list, and limits

The commands `exec` and `pid` exist only with the capability `exec`. `open "|cmd"` also needs `channels`. `file` does not turn on `exec`, and a child interp has `exec` only when its parent has it.

The embedder sets `Interp.exec_host`. The runner has a flag for each field:

| Field | Runner | Meaning |
|---|---|---|
| `allow` | `--exec-allow a,b` | The programs that a script can run. An entry with no path separator is a bare name: the word of the script must be that name, and the program is the first match in the `PATH`. Another entry is a full host path, and it matches each word that resolves to the same file. Null (no flag) allows each host program. |
| `allow_root` | `--exec-allow-root /a,/b` | The files below the root folder that a script can run, by their path in the root. A script with `file` can write these files, so each entry lets the script run its own code. |
| `timeout_ms` | `--exec-timeout MS` | The longest run time of a pipeline. At the end of it, each process of the tree of the pipeline ends. 0 is no limit. |
| `env` | `--exec-env NAME=value` (again for each name) | The whole environment of each program. A program gets no other variable of the embedder. |

The output that `exec` reads counts against the memory limit of the interpreter: at the limit, the pipeline ends. The programs themselves count against no limit of the interpreter.

## exec

```tcl
exec ?-ignorestderr? ?-keepnewline? ?--? ARG ?ARG ...?
```

Runs a pipeline and gives the standard output of its last program, with the last newline removed (unless `-keepnewline`). Each program runs directly from its words, with no shell. The words follow the rules of Tcl:

| Word | Meaning |
|---|---|
| `\|` | The output of a program goes to the input of the next. |
| `\|&` | The output and the error output go to the next program. |
| `< FILE`, `<< TEXT`, `<@ CHAN` | The input of the first program: a file, a text, or a channel. |
| `> FILE`, `>> FILE`, `>@ CHAN` | The output of the last program: a file, a file to append to, or a channel. |
| `2> FILE`, `2>> FILE`, `2>@ CHAN` | The error output. |
| `>& FILE`, `>>& FILE`, `>&@ CHAN` | The output and the error output. |
| `2>@1` | The error output goes with the output. It is the last word. |
| `&` as the last word | Runs the pipeline in the background and gives the list of its process ids. |

The pipeline fails, and `exec` gives an error with the output as the result, when:

- a program ends with a code other than 0: `-errorcode` is `CHILDSTATUS PID CODE`;
- a program ends by a signal (or by the time limit): `CHILDKILLED PID SIGNAL MESSAGE`, for example `CHILDKILLED 4242 SIGKILL {kill signal}`;
- a program writes to its error output and `-ignorestderr` is absent: the text of the error output is in the result.

With no other text, the result is `child process exited abnormally`.

## open "|cmd"

```tcl
open "|PROGRAM ARG ... ?REDIRECTIONS?" ?r|w|r+?
```

Gives a channel on a pipeline: `r` reads the output of the last program, `w` writes the input of the first, and `r+` does both. `close` waits for the programs and gives the error of the pipeline as `exec` does. A channel with `-blocking 0` does not wait at `close`: its processes stay on a list that the time limit and the end of the interpreter reach.

## pid

```tcl
pid ?CHANNEL?
```

With no channel, gives the id of this process. With the channel of a pipeline, gives the list of the ids of its processes.

## How a program word becomes a program

Before any process starts, the first word of each program becomes one full host path, and the checks run on that path:

- A word with a path separator must be a full path. It names a host file. A file below the root folder runs only through `allow_root`.
- A bare name goes through the `PATH` of `exec_host.env`. Each entry of that `PATH` must be a full path: a relative entry is the error `ZTCL EXEC PATH`.
- Links, `.`, and `..` of the path are resolved, the allowlist compares the resolved path, and the child runs only that path. The child does no search of its own.

The details for each system follow.

## Platforms

| | Linux | macOS (arm64 and x86-64) | Windows (x86-64) |
|---|---|---|---|
| Separators of a path | `/` | `/` | `/`, `\`, and a drive (`C:`) |
| `PATH` with none in `env` | `/usr/bin:/bin` | `/usr/bin:/bin` | the system folder (`C:\Windows\System32`) |
| Extensions of a bare name | none | none | each of `PATHEXT` in `env`, or `.COM;.EXE` |
| Comparison of paths | exact | exact | no regard to case |
| Start | `fork` and `execve` | `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` | `CreateProcessW`, suspended, with a handle list of the three standard handles |
| Arguments | one string each | one string each | one command line, quoted with the rules of the C runtime of Microsoft |
| Process tree | a cgroup below the cgroup of the embedder, or the process group and a scan of `/proc` | the process group and a scan of the children | a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, joined before the program runs |
| Kill | `cgroup.kill`, or SIGSTOP and SIGKILL to each process found | SIGSTOP and SIGKILL to each process found | `TerminateJobObject` with the code 137 |
| Error output and `<<` text | a memory file | a temporary file with its name removed | a temporary file deleted at its last close |
| Output | as the program writes it | as the program writes it | CR LF becomes LF, as Tcl does on Windows |

Windows also has these rules:

- A `.bat` or `.cmd` file is the error `ZTCL EXEC DENIED`, before any process starts. `cmd.exe` runs such a file and reads its arguments with rules of its own, so an argument of a script could hold a command. Run `cmd.exe /c` and list `cmd.exe` in the allowlist.
- A program of Windows often needs `SystemRoot` in its environment: `--exec-env SystemRoot=C:\Windows`.
- With no console in the parent (a GUI program such as ztk), each program starts with `CREATE_NO_WINDOW`, so no console window opens. With a console, a program shares it.
- An access violation or a stack overflow of a program is `CHILDKILLED PID SIGSEGV`, an illegal instruction `SIGILL`, a division by zero `SIGFPE`, and Ctrl-C `SIGINT`.

`exec` does not exist on WebAssembly or on arm64 Windows.

## Examples

```tcl
# The output of a pipeline.
puts [exec printf "b\na\n" | sort]           ;# a b, on two lines

# The status of a program.
if {[catch {exec sh -c {exit 3}} msg opts]} {
    puts [dict get $opts -errorcode]          ;# CHILDSTATUS <pid> 3
}

# Text for the input, and the error output with the output.
puts [exec grep two << "one\ntwo\n"]          ;# two
puts [exec sh -c {echo oops 1>&2} 2>@1]       ;# oops
```

On Windows, with `--exec-env PATH=C:\Windows\System32 --exec-env SystemRoot=C:\Windows`:

```tcl
puts [exec cmd.exe /c echo hello]                    ;# hello
puts [exec cmd.exe /c {echo a b} | findstr a]         ;# a b
catch {exec C:/tools/build.bat} msg
puts $msg    ;# couldn't execute "C:/tools/build.bat": a .bat or .cmd file runs through cmd.exe with other rules for its arguments; run cmd.exe /c
```

## Errors

| Error text | `-errorcode` |
|---|---|
| `couldn't execute "W": the embedder does not allow this program` | `ZTCL EXEC DENIED` |
| `couldn't execute "W": a program path must be a full path or a bare name` | `ZTCL EXEC DENIED` |
| `couldn't execute "W": the program is in the root folder` | `ZTCL EXEC DENIED` |
| `couldn't execute "W": the host path of the root folder changed` (Linux and macOS) | `ZTCL EXEC DENIED` |
| `couldn't execute "W": a .bat or .cmd file runs through cmd.exe with other rules for its arguments; run cmd.exe /c` (Windows) | `ZTCL EXEC DENIED` |
| `couldn't execute "W": the PATH entry "E" is not a full path` | `ZTCL EXEC PATH` |
| `couldn't execute "W": no such file or directory` | `POSIX ENOENT {no such file or directory}` |
| `couldn't read file "F": permission denied` (and `write`) | `POSIX EACCES {permission denied}` |
| `illegal use of \| or \|& in command` | `NONE` |
| `can't specify "W" as last word in command` | `NONE` |
| `must specify "2>@1" as last word in command` | `NONE` |
| `illegal use of & in a command pipeline` | `NONE` |
| `can't read output from command: standard output was redirected` | `NONE` |
| `can't write input to command: standard input was redirected` | `NONE` |
| `can not find channel named "C"` | `NONE` |
| `channel "C" wasn't opened for reading` (and `writing`) | `NONE` |
| `user "U" doesn't exist` (a word `~user`) | `NONE` |
| `bad option "X": must be -ignorestderr, -keepnewline, or --` | `TCL LOOKUP INDEX option` |
| `child process exited abnormally`, `child killed: kill signal`, or the error output | `CHILDSTATUS ...`, `CHILDKILLED ...`, or `NONE` |
| `child killed: the time limit of N ms ended` | `CHILDKILLED PID SIGKILL {kill signal}` |
| `wrong # args: should be "exec ?-option ...? arg ?arg ...?"` | `TCL WRONGARGS` |

## Security

See [the rules of `exec`](../SECURITY.md#the-rules-of-exec). In short:

- A program has the full power of the user. The program list, the time limit, and the environment of `exec_host` limit what a script starts, and do not limit what a program does.
- Each program is one resolved host path, checked against the list before any process starts.
- Each pipeline is one process tree, and the time limit, a failed start, and the end of the interpreter end the whole tree. A program can still leave the tree on purpose.
