# Plan: `exec` and pipelines on Windows

`exec`, `pid`, `open |cmd`, and `ztcl::pty` run only on Linux and arm64 macOS. This plan adds the Windows form, in `src/proc_windows.zig`, with the names that other files use from `src/proc.zig`: `supported`, `Host`, `State`, `Tree`, `register`, `openPipeline`, `reap`, `abandon`, and `abandonAll`. The parse of the words (`|`, `<`, `>`, `2>@1`, `&`, and the others) is the same code on each platform.

## Programs and the allowlist

- A word with no `/` or `\` is a bare name. `resolve` looks for it in each folder of the `PATH` of `exec_host.env`, with each extension of its `PATHEXT` (the default is `.COM;.EXE`). Each entry of `PATH` must be a full path, as on Linux.
- The full path goes through `GetFinalPathNameByHandleW` of an open of the file, so each link and junction is resolved. The allowlist compares that path with no regard to case, and the child runs only that path.
- A `.bat` or `.cmd` file runs through `cmd.exe`, and `cmd.exe` reads the arguments with its own rules, so a script can inject a command through an argument. `resolve` refuses a `.bat` and a `.cmd` file. A script that needs one runs `cmd.exe /c` itself, and the allowlist names `cmd.exe`.
- A file below the root folder runs only when `allow_root` names it, as on Linux.

## The start

- The command line of each program follows the rules of the C runtime of Microsoft (`CommandLineToArgvW`): an argument with a space, a tab, or a quote goes in quotes, each quote gets a backslash, and the backslashes before a quote double. A program that reads its command line with other rules gets the words that those rules give.
- `CreateProcessW` with `CREATE_SUSPENDED`, `CREATE_UNICODE_ENVIRONMENT`, `EXTENDED_STARTUPINFO_PRESENT`, and `CREATE_NO_WINDOW`. `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` lists the three handles of the child, so the child inherits no other handle.
- The environment block is `exec_host.env` in UTF-16, sorted with no regard to case, as Windows wants.
- The working folder is the current folder of `file`: in host mode its path, and in the jail the final path of the folder handle below the root.
- The pipes between the programs come from `CreatePipe`. The text of `<<` and the error output go through a temporary file with `FILE_FLAG_DELETE_ON_CLOSE`.

## The process tree

Each pipeline is one Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Each child joins the job before `ResumeThread`, so each process that it starts is in the job too. The kill of a tree is `TerminateJobObject`, and `abandonAll` closes each job, which ends each process that still runs. `timeout_ms` of `exec_host` waits on the processes and then ends the job.

## Status and errors

- `GetExitCodeProcess` gives the exit code. The code of a process that `TerminateJobObject` ended is 1, and `errorCode` is `CHILDKILLED pid SIGKILL {child killed}`, as on Linux.
- `pid` gives the ids of `GetProcessId`.
- A program that does not start gives `couldn't execute "word": ...` with the POSIX name of the Win32 error, from the map of `sys_windows.zig`.

## Pipelines as channels

`open |cmd` gives a channel on the pipe handles. The channel code of Windows already reads pipes: `setBlocking` sets `PIPE_NOWAIT`, and `poll` checks a pipe with `PeekNamedPipe`, so `fileevent` and `vwait` work.

## ConPTY

`ztcl::pty` on Windows uses `CreatePseudoConsole` with two pipes, `ResizePseudoConsole` for `resize`, and the attribute `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` in the start of this plan, as `docs/dev/pty.md` says. It comes after `exec`.

## Tests

The tests use `cmd.exe /c` and the programs `findstr.exe`, `whoami.exe`, and `ping.exe` of `C:\Windows\System32`, through the `PATH` of the environment or a full path in the allowlist. No test opens a window: a child of a parent with no console has `CREATE_NO_WINDOW`, and a child of the test program shares its console.

1. The command line of words with spaces, quotes, tabs, empty words, and backslashes gives each word back through `CommandLineToArgvW`.
2. A pipeline of two programs, `<<`, the status, the error output, `2>@1`, `-ignorestderr`, and `&` with `pid`.
3. The allowlist refuses a program before a process starts, and `resolve` refuses a `.bat` file.
4. `timeout_ms` ends a program that waits, and no process of the job runs after it.
5. `open |cmd r` with `gets`, `pid` of the channel, and the status at `close`. `fileevent readable` with `vwait` on a pipe comes with ConPTY, which needs it.
6. The files of the Tcl suite that use `exec` pass at least as many tests as before.

## Steps

1. This plan.
2. `exec`, `pid`, `open |cmd`, and the tests 1 to 6 (the first PR).
3. ConPTY for `ztcl::pty`, with a test of `fileevent` on its pipes.
