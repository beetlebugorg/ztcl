# Port the platform code to macOS and Windows

All platform code is in five files: `src/coro.zig`, `src/sys.zig`, `src/fsroot.zig`, `src/proc.zig`, and the open flags in `src/chan.zig`. Each port writes the same functions again for its system and changes no caller.

## General rules

- BSD-2-Clause. Write fresh code. Use no code from Tcl or a GPL or AGPL project.
- Use only the Zig 0.17.0 standard library. Add no libc dependency unless the target already links it.
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

`sys.zig` is the whole interface. Each function has a contract in its doc comment.

- Unchanged: `read`, `write`, `close`, `seek`, `setBlocking`, `ignorePipeSignal`, `poll`, `connectError`, `accept`, `sockName`, `peerName`, `shutdown`, and `failOf`.
- New: `Addr { v6: bool, bytes: [16]u8, port: u16 }`, `parseAddr(text) ?Addr` (portable, no system call), `resolve(allocator, host, *ArrayList(Addr))`, `listenAt(addr, reuse) SockResult`, and `connectTo(addr, mine: ?Addr, wait) SockResult`.

The network policy is not platform code. It is in `src/sock.zig` and needs no port. `Interp.net` is `loopback` (the default), `allow` (rules: a host name or an address range, plus a port range), or `any`. The runner flag is `--net loopback|any|allow=LIST`. `sock.zig` resolves each host, drops each address that the policy refuses, connects or listens, then checks `sys.peerName` of the new connection again. A server checks each accepted peer, and closes one that fails. A child interp gets a copy of the policy of its parent, and no script command changes it.

Rules for a port:

1. `resolve` is the only name lookup. It returns every address of the name, so the caller can check each one. It must not connect. It reads an address literal, `localhost`, and the system hosts file. It must not query a name server: `sock.zig` calls it before the policy check, so a query can send data in a host name off the machine. Do not call `getaddrinfo` or `GetAddrInfoW` until `sock.zig` looks up only a name that the policy can allow.
2. `listenAt` and `connectTo` take address bytes only. They never take a name, and they never widen the address. Set IPV6_V6ONLY = 1 on each IPv6 socket, so an IPv4 peer cannot appear as `::ffff:a.b.c.d`.
3. `accept` returns the real peer address. `peerName` after a connect returns the address of the connection.
4. `connectTo(addr, mine, wait=false)` starts a non-blocking connect and returns at once. `connectError` gives the end result once. `chan.zig` then calls `sock.checkPeer`, and shuts the socket down if the policy refuses the peer.
5. Each descriptor closes on exec. macOS: set FD_CLOEXEC with `fcntl` right after `socket` and `accept`. Windows: use `WSASocketW` with WSA_FLAG_NO_HANDLE_INHERIT.
6. A write to a closed peer gives an error and no signal. macOS: SO_NOSIGPIPE on each socket, and ignore SIGPIPE in `ignorePipeSignal`. Windows needs no work.
7. `poll` reports an error or a closed peer as ready for the direction that waits. macOS: `poll`. Windows: `WSAPoll` for sockets, and also check SO_ERROR after the wait for a failed connect. A file handle is always ready. A pipe of `exec` on Windows needs PeekNamedPipe for the read side.
8. A `read` of 0 bytes is the end of data. EINTR runs the call again. `seek` on a socket gives an error.
9. Windows: `Fd` holds a file HANDLE or a SOCKET, as a tagged integer or a small union. Call WSAStartup once. Map WSAGetLastError in `failOf` (WSAECONNREFUSED, WSAEADDRINUSE, WSAEADDRNOTAVAIL, WSAECONNRESET, WSAENOTCONN, WSAETIMEDOUT, and WSAEWOULDBLOCK as `.again`).
10. `chan.zig` still uses `linux.O` in `parseMode`, and `lseek` in two places. Move them to a neutral struct and `sys.seek`.

Tests stay offline and never contact an outside host:

- `zig build test`: "the network policy of socket: allowlist, ranges, ports, and peers", "socket accepts only loopback addresses by default", "socket refuses a blocked address and closes a blocked peer", and "the event loop runs timers and idle scripts in order". The blocked-address test listens on 127.0.0.2. On macOS that address needs an alias, so mark that case Linux-only, and add a case with `::1` against a list of 127.0.0.1 only. Do not change the network settings of the machine.
- Suite on Linux: socket.test pass 148, fail 6, skip 21. event.test pass 35. timer.test pass 53. chan.test pass 14. io.test pass 238. chanio.test pass 228.

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

## Suite tools on other systems

`tools/suite.sh` may change so it runs on each system: pass `--root` only where the jail is supported, and use a portable time limit where `timeout` is absent. The Linux counts must not change. Where `systemd-run` does not exist, use the memory limit of that system.

The root jail lets the file and channel suites run, so do the jail before `exec` on each platform.

## How to run

```sh
zig build test
zig build && zig build suite-runner
tools/suite.sh -r zig-out/bin/ztcl-suite coroutine.test event.test timer.test socket.test exec.test fCmd.test
```

`tools/fetch-tcl.sh` downloads the Tcl 8.6.16 tests. The suite script is POSIX sh. On Windows, run it from Git Bash.
