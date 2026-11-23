# Port the platform code to macOS and Windows

All platform code is in five files: `src/coro.zig`, `src/sys.zig`, `src/fsroot.zig`, `src/proc.zig`, and the open flags in `src/chan.zig`. Each port writes the same functions again for its system and changes no caller.

## General rules

- BSD-2-Clause. Write fresh code. Use no code from Tcl or a GPL or AGPL project.
- Use only the Zig 0.16.0 standard library. Add no libc dependency unless the target already links it.
- Each file keeps its `//!` header and SPDX line. Follow WRITING.md and AGENTS.md. Add no attribution lines.
- Keep `pub const supported` in each file. Set it true for a new target only when the unit tests of that file pass there.
- The Linux results must not change.
- A port must not lower a suite count.
- Run each command under a 4 GB memory cap.

## Order

Do the pieces in this order. Send each piece for review when its tests pass.

## Piece 1: the coroutine stack switch (`src/coro.zig`)

Interface: `ztcl_coro_swap(from: *usize, to: usize)` saves the callee-saved registers on the current stack, stores the stack pointer in `from.*`, loads `to` as the stack pointer, restores the registers, and returns. `ztcl_coro_start` is the first return address of a new stack. It calls the function pointer in one callee-saved register with the argument in another, and it must never return. The setup code near line 262 writes the first frame of a new stack (`slots[...]`). Write these three parts for each ABI.

- **aarch64 macOS (AAPCS64, Apple):** save x19-x28, x29, x30, and d8-d15. Keep the stack pointer 16-byte aligned. Do not use x18. Plain arm64 builds do not use arm64e pointer authentication.
- **x86-64 macOS (System V):** the Linux routine is correct. Check only the symbol names (Mach-O adds a leading underscore) and the `.hidden` visibility.
- **x86-64 Windows (Microsoft x64):** save rbx, rbp, rdi, rsi, r12-r15, and xmm6-xmm15. The first argument is rcx, and the second is rdx. Give the callee 32 bytes of shadow space. Save and restore the TIB stack fields at gs:[0x08] (StackBase), gs:[0x10] (StackLimit), and gs:[0x1478] (DeallocationStack), or stack probes (`__chkstk`) fail on the coroutine stack. No SEH unwinding crosses a switch.

The stacks come from the interpreter arena (`stack_size`). Keep that.

Tests: `zig build test` (the test "coroutine..." must run, not skip), and `tools/suite.sh -r zig-out/bin/ztcl coroutine.test tailcall.test`. Linux at this base: coroutine.test pass 37, fail 19, skip 3. tailcall.test pass 20, fail 9, skip 8.

## Piece 2: channels, the event loop, and sockets (`src/sys.zig`)

`sys.zig` is the whole interface. Each function has a contract in its doc comment: `read`, `write`, `close`, `seek`, `setBlocking`, `ignorePipeSignal`, `poll(wants, timeout_ms)`, `listenLoop`, `connectLoop`, `connectError`, `accept`, `sockName`, `peerName`, `shutdown`, and `failOf`.

Security rule: `listenLoop` and `connectLoop` take the address as the enum `Loop { v4, v6 }`. They build 127.0.0.1 or ::1 themselves. No function takes a host name or free address bytes, and no resolver call exists. Keep that shape. `accept` returns the peer address, and the caller closes a peer that is not loopback.

Each descriptor closes on exec.

- **macOS:** SOCK_CLOEXEC does not exist, so use `fcntl` FD_CLOEXEC right after `socket` and `accept`. Use `std.c` and `std.posix`. MSG_NOSIGNAL does not exist: set SO_NOSIGPIPE on each socket, and ignore SIGPIPE in `ignorePipeSignal`.
- **Windows:** `Fd` becomes a union of a file HANDLE and a SOCKET, or two integer ranges. Use Winsock2 (WSAStartup once), `WSAPoll` for sockets, `ioctlsocket(FIONBIO)` for `setBlocking`, and `WSAGetLastError` mapped in `failOf`. Handles are not inherited: pass bInheritHandle = FALSE. `WSAPoll` does not accept file handles, and a regular file is always ready. `ignorePipeSignal` does no work.

Keep these edge cases: a non-blocking connect that fails reports through `connectError` once; `poll` reports an error or a closed peer as ready; a `read` of 0 bytes is the end of data; EINTR runs the call again; `seek` on a socket gives an error.

`src/chan.zig`, `src/sock.zig`, and `src/event.zig` need only their `linux.O` open flags (`parseMode` in chan.zig) moved to a neutral struct. The event loop has no platform code.

Tests: `zig build test` ("the event loop runs timers and idle scripts in order", "socket accepts only loopback addresses"). Suite through `zig build suite-runner`, on Linux: event.test pass 33, timer.test pass 53, socket.test pass 82, fail 8, skip 85.

## Piece 3: the root folder jail (`src/fsroot.zig`, used by chan.zig and filecmd.zig)

This piece is large and security-critical. Do it after the others, and send it for review alone.

Contract: the embedder gives one root folder, and a script sees it as `/`. `normal()` normalizes the path as text first. Then the system must refuse every open and every other operation when any component is a symlink or leaves the root. The check fails closed: if the mechanism is absent, give an error.

**macOS:** there is no `openat2`. Walk the path one component at a time from the root descriptor with `openat(dirfd, name, O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)` for each folder, and `O_NOFOLLOW` (or `O_NOFOLLOW_ANY` on macOS 11 and later as a second guard) for the last name. Never build a full path string for a system call. Use `fstatat(AT_SYMLINK_NOFOLLOW)`, `unlinkat`, `mkdirat`, `renameat`, and `fdopendir` on the parent descriptor. A race that swaps a folder for a symlink must give ELOOP or ENOTDIR, never an escape.

**Windows:** open the root with CreateFileW (FILE_FLAG_BACKUP_SEMANTICS). Open each component relative to its parent handle with NtCreateFile (RootDirectory = parent handle, FILE_OPEN_REPARSE_POINT set). Query FILE_ATTRIBUTE_TAG_INFORMATION, and refuse ANY reparse point (symlinks, junctions, mount points).

Refuse these before any system call: a name with `:`; a name with `\` or `/` inside one component; a name that ends with a dot or a space; the device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, with or without an extension); `\\?\`, `\\.\`, and UNC prefixes; and 8.3 short names (refuse a component that matches `~[0-9]` unless the real long name is byte-equal to it). Compare names case-insensitively where the text check removes `..`. After the open, call GetFinalPathNameByHandleW and check that the result has the final path of the root as a prefix. This is the fail-closed second check.

The escape list in the unit test "file and channels cannot leave the root folder" must pass on each platform, with the platform cases added. On Windows add: a junction to C:\Windows, a `file::$DATA` stream name, `..\..\x`, `C:x`, `\\?\C:\x`, `PROGRA~1`, `nul`, and a name with a trailing dot.

Suite on Linux: fCmd.test pass 124, fileName.test pass 50, fileSystem.test pass 37, cmdAH.test pass 84, io.test pass 237, chanio.test pass 228.

## Piece 4: exec (`src/proc.zig`)

`exec` is not sandboxed on any platform. Say so in the comments.

Contract: programs run from an argument list with NO shell. `Interp.exec_host` gives an allowlist (checked before the first process starts), a time limit, and the whole environment. Each pipeline is one group. The group is killed at the time limit, at a failed start, and when the interpreter ends. A test proves that no process stays.

- **macOS:** `posix_spawn` with a file-actions list (dup2 for 0, 1, 2; POSIX_SPAWN_CLOEXEC_DEFAULT to close all others; POSIX_SPAWN_SETPGROUP), `posix_spawn_file_actions_addfchdir_np` for the working folder, `killpg(SIGKILL)`, and `waitpid`. There is no memfd: use an unlinked temporary file inside the root folder, or a pipe drained by poll, for the error output and for `<<`.
- **Windows:** CreateProcessW with an explicit command line built by the documented CommandLineToArgvW quoting rules (backslashes before a quote double). Set `lpApplicationName` to the resolved full path, so no search and no cmd.exe happens. Refuse `.bat` and `.cmd` files, because they run through cmd.exe. Use STARTUPINFOEX with PROC_THREAD_ATTRIBUTE_HANDLE_LIST, so only the three standard handles are inherited, an explicit environment block, CREATE_SUSPENDED + AssignProcessToJobObject + ResumeThread, and a Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, so the whole tree ends with TerminateJobObject or when the handle closes.

Tests: the unit test "exec has an allowlist and a time limit, and leaves no process" (port its program names). Suite on Linux: exec.test pass 86, fail 5, skip 9. pid.test pass 5.

## How to run

```sh
zig build test
zig build && zig build suite-runner
tools/suite.sh -r zig-out/bin/ztcl-suite coroutine.test event.test timer.test socket.test exec.test fCmd.test
```

`tools/fetch-tcl.sh` downloads the Tcl 8.6.16 tests. The suite script is POSIX sh. On Windows, run it from Git Bash.
