# Plan: the protocol of isolated threads (ztcl#209)

ztcl#209 gives `thread::create` the levels `interp`, `wasm`, `process`, `vm`, and `vm-confidential`. At each level past `interp`, the thread runs in another address space: another instance of the wasm engine, another process, or a guest of the hypervisor. This page is the one protocol between the parent (the process of the host interpreter) and such a child, for every level. The Linux, macOS, and Windows process levels, the vm level of ztcl#203, and the wasm level of ztcl#202 build on it.

The goal is the rule of the issue: a script that uses the Thread package works the same at each level, and a feature that cannot cross a level gives an error that says so.

ztcl is BSD-2-Clause, and this design comes from the documentation of the Thread package, the Noise Protocol Framework specification, RFC 5869 (HKDF), RFC 7748 (X25519), RFC 8439 (ChaCha20-Poly1305), the AMD SEV-SNP and Intel TDX documentation, and man pages. No copyleft source.

## The shape

```
parent process                                  child (process, guest, or wasm instance)
+-------------------------------+               +------------------------------+
| host interpreter              |               | ztcl runtime                 |
| thread group:                 |   transport   | one interpreter, the thread  |
|   registry, tsv, pools, locks |<------------->| reader: control frames       |
|   proxy worker of the child   |  frames (v1)  | queue of the interpreter     |
+-------------------------------+               +------------------------------+
```

- The parent keeps the group: the registry of the threads, `tsv`, the pools, the mutexes, and the conditions. A child has no copy of them. Each of its calls on them is a request to the parent (the broker).
- In the group, an isolated thread is a proxy worker: an entry of the registry with a queue, as an `interp` thread has. A reader thread of the parent turns the frames of the child into entries of that queue and into the answers of waiting calls. So the code of `thread.zig` that routes a send, waits, and handles an error sees a normal worker.
- The child is the ztcl runtime with one interpreter. Its reader thread reads the frames: a control frame (a cancel, the end) acts at once, as the stop flag does today, and a script goes to the queue of the interpreter.
- A send from a child to another thread goes through the parent, which routes it. Two children never talk directly.

## Transports

The protocol needs a reliable, ordered stream of bytes in each direction. Each level has its own:

| Level | Transport | Descriptor passing |
|---|---|---|
| `process` on Linux and macOS | `socketpair(AF_UNIX, SOCK_STREAM)`, one end inherited by the child | `SCM_RIGHTS` |
| `process` on Windows | One duplex, overlapped named pipe with a random name, one instance, and a DACL for the current user only. The parent opens the client end and the child inherits it (see below). | `DuplicateHandle`, and `WSADuplicateSocketW` for a socket |
| `vm`, `vm-confidential` | vsock: the guest agent listens on port 1024 (the agent of `docs/dev/vm.md`), on macOS through Virtualization.framework, on Linux through `vhost-vsock`, on Windows through Hyper-V sockets | none: a proxy channel |
| `wasm` | Two rings in the memory of the instance, with a futex or a host call for the wake | none: a proxy channel |

The vsock port of the guest agent serves both `exec` of `ztcl::vm` and threads: the first frame names the service.

On Windows the parent calls `CreateNamedPipeW` with the name `\\.\pipe\ztcl-iso-` and 128 random bits, `PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE`, and `PIPE_TYPE_BYTE | PIPE_REJECT_REMOTE_CLIENTS`. It opens the client end itself with `CreateFileW` before the child starts, so no other process can take the one instance. It starts the child suspended with only that handle in `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, as `exec` does, and gives the value of the handle on the command line of the child (`--iso-handle 0x...`). An inherited handle needs no access check in the child, so an AppContainer child needs no right on the pipe, and the name never reaches it. Anonymous pipes give synchronous handles only, and a blocked read on one stops only with a close or `CancelSynchronousIo`.

## Frames

Each frame is a 4-byte length (little-endian), and then that many bytes:

```
length u32 | kind u8 | flags u8 | stream u32 | payload
```

The length counts each byte after it: the header, the payload, and the 16-byte tag of a sealed frame.

- `kind` is the type of the frame (see "Messages"). `flags` bit 0 is `more`: the payload continues in the next frame of the same stream. Bit 1 is `skip`: a receiver that does not know the kind ignores the frame. A frame of an unknown kind without `skip` is an error of the protocol.
- `stream` is 0 for the connection, or the id of a request, of a proxy channel, or of a lock. The side that opens a stream picks its id: the parent uses even ids and the child odd ids, so the two never collide.
- The largest frame is 1 MiB of payload. A larger message goes as frames with `more`, so a 100 MB result does not stop the control frames of other streams behind it.
- A value is in the byte form of `src/webasync.zig`, which keeps the kind of the value: `i` and an 8-byte integer, `d` and an 8-byte double, `s` with a 4-byte length and the bytes, and `l` with a 4-byte count and the items. A list deeper than 200 levels goes as its string form, as in `thread.zig`.
- A receiver checks each length against the bytes it has and against its limits before it allocates. A frame or a value that breaks a rule ends the connection with the error `ZTCL ISOLATION PROTOCOL`, and the thread ends.

## The handshake

The first two frames, in the clear, before any other:

```
parent -> child   HELLO     versions {min max}, services, e_p (32 bytes), nonce_p (32 bytes)
child  -> parent  WELCOME   version, service, features, e_c (32 bytes), nonce_c (32 bytes), proof
```

1. Each side makes a new X25519 key pair for this connection (`e_p`, `e_c`).
2. The shared secret is `X25519(e_p, e_c)`. HKDF-SHA256 makes two keys from it, one for each direction: the input key is the shared secret, the salt is the bootstrap secret of the level (see below), and the info is the transcript: the SHA-256 of `HELLO` and of `WELCOME` up to its `proof`.
3. `proof` is the tag of ChaCha20-Poly1305 with the key of the child over an empty message, so the parent knows that the child has the bootstrap secret. The parent answers with a sealed `START`, so the child knows the same of the parent.
4. Each frame after the handshake is sealed with ChaCha20-Poly1305: the key of its direction, a 96-bit nonce of 4 zero bytes and the 64-bit counter of that direction (little-endian, as in Noise), and the header of the frame (length, kind, flags, stream) as the associated data. The sealed part is the payload, and the tag follows it. A tag that fails ends the connection.

The idea is the pattern `NNpsk0` of the Noise Protocol Framework: two new key pairs and a pre-shared key. The framing is our own.

The bootstrap secret binds the connection to the child that the parent started:

| Level | Bootstrap secret | Note |
|---|---|---|
| `process` | None (a salt of zeros) | Only the child has the other end of the socket pair or pipe, so the new keys are enough. |
| `vm` | 32 random bytes, on the command line of the kernel of the guest (`ztcl.secret=`) | Only the host sets the command line. A warm guest from a pool, or a restored snapshot, keeps its secret, and each connection makes new keys, so a restore reuses no key and no nonce. |
| `vm-confidential` | The same, and the attestation report of the guest | See "Confidential guests". |
| `wasm` | None | The instance is in the memory of the parent. The parent seals no frame, and the handshake has no keys (feature `plain`). |

With the encryption off (`-encrypt 0`, see the questions), the handshake still runs, so the version and the services are the same, and the frames after it are in the clear.

### Confidential guests

On SEV-SNP and TDX, the host is outside the trust. The parent is still the side that starts the guest, but a host that the guest cannot trust can read its vsock traffic and its command line. So:

- The child puts the SHA-256 of `HELLO`, `e_c`, and `nonce_c` in the 64 bytes of the report data of its attestation report (`REPORT_DATA` of SEV-SNP, `REPORTDATA` of TDX) and sends the report in `WELCOME`, after `proof`.
- The party that checks the report (the parent, or a remote party of ztcl#180) checks the signature chain of the report, the measurement of the guest image, and that the report data is that hash for this connection. Only then does it send secrets or scripts. A key of a channel is then bound to the measured guest, and a host in the middle cannot swap `e_c`.
- The bootstrap secret of the command line is only a check that the guest is the one that the parent started: the attestation is the trust.

### The threat model of the `process` level

A process of the same user can read the memory of the parent and take its handles and descriptors (`ptrace` on Linux, the debug rights on macOS, `DuplicateHandle` on Windows). The sealing cannot stop such a process, so it is outside the threat model of the `process` level. The level protects the parent and the system from the child.

## Messages

| Kind | From | Payload | Meaning |
|---|---|---|---|
| `START` | parent | thread id, capabilities, limits, the script of `thread::create`, `-joinable`, `-preserved`, the options of the group | Make the interpreter and run the script. |
| `READY` | child | none | The interpreter exists: `thread::create` returns. |
| `SEND` | both | flags (`async`, `head`, `reply`), target thread id, script | A `thread::send`. A send of the child to any thread goes to the parent, which routes it. |
| `RESULT` | both | stream of the send, return code, value, `-errorinfo`, `-errorcode` | The answer of a send with `reply`. |
| `CANCEL` | parent | `unwind`, the result | `thread::cancel`: the reader of the child sets the stop flag, as today. |
| `RELEASE` | both | the count change | `thread::preserve` and `thread::release` of the child. |
| `TSV` | child | stream, the command, its arguments | A `tsv::*` command. The broker of the parent runs it on the arrays of the group and answers with a `TSV` frame on the same stream: the code, the result, and the error code. `src/isobroker.zig` has the payloads. |
| `LOCK`, `UNLOCK` | child | stream, the array, or the mutex, rwmutex, or condition | `tsv::lock`, `thread::mutex lock`, `thread::cond wait`, and the others. The broker holds the lock for the child and frees it when the child ends. |
| `OUTPUT` | child | the channel (`stdout` or `stderr`), the bytes | The output of the child goes to the output callback of the parent. |
| `BGERROR` | child | `-errorinfo` | An error for `thread::errorproc` in the parent. |
| `CHAN` | both | stream, the operation (`open`, `data`, `credit`, `eof`, `close`, `config`) | A proxy channel (see "Channels"). |
| `FD` | both | stream, the form (a descriptor, a handle value, or a `WSAPROTOCOL_INFOW`), the configuration of the channel, and a flag for an overlapped handle | A descriptor goes with this frame (`SCM_RIGHTS`), or a handle or a socket crosses as below (Windows). |
| `USAGE` | child | the compute units and the bytes of the heap | The use of the child, at its end and every 100 ms of compute. |
| `EXIT` | child | the exit status, or the error that ended the thread | The end of the thread. `thread::join` gets it. |
| `GOODBYE` | both | none | The connection ends normally. |

- A send that waits (`thread::send` without `-async`) keeps the reader of the sender running: it runs each `SEND` that comes for its own thread while it waits, so two threads that send to each other do not deadlock, as today.
- `thread::broadcast`, `thread::names`, `thread::exists`, and the pools are in the parent. A child asks with `SEND` to the group (thread id 0) and a fixed command.
- The thread id of an isolated thread is an id of the group (`tid0x...`), so `thread::names` lists it and a send names it as any thread.

### A send from a child to a thread of a lower level

A child can send a script to the main thread, as in the Thread package. A worker often sends its result back that way (`thread::send -async $main [list set result $x]`). At a level past `interp`, that script runs in the parent with all of the power of the parent, so a hostile script in the child can reach the parent through it.

The default keeps the scripts working: the parent runs the sends of a child as today. The option `thread::configure $id -sendback LIST` limits them: the parent then runs a send of the child only when its first word is in the list, and runs it as one command with its words as arguments, with no substitution. `-sendback {}` refuses each send of the child with `ZTCL ISOLATION SENDBACK`. `docs/isolation.md` says that a level stops a hostile script only with `-sendback`.

### `tsv` through the broker

- Each `tsv` command of a child is one `TSV` request and one `RESULT`. The values are in the byte form, so a list stays a list, as in the neutral form of today.
- `tsv::lock array script` sends `LOCK`, runs the script in the child, and sends `UNLOCK`. Each `tsv` command of the script has the stream of the lock, so the broker runs it in that lock. A child that ends with a lock frees it.
- `tsv::object` is a command of the child that sends `TSV` requests.
- The cost is a round trip for each command. The benchmarks of ztcl#209 measure it at each level.

### Channels

- At the `process` level on Linux and macOS, `thread::transfer id chan` and `thread::attach` move the descriptor itself (`src/tchan.zig` `shipOut` has the record, and `FD` is to u64, the count of descriptors u8, and the record, with the descriptors on the first byte of the frame): the parent sends `FD` with the descriptor in `SCM_RIGHTS` and the configuration of the channel (the translation, the encoding, the buffering, and the blocking mode). On Windows:
  - The `FD` frame of Windows is to u64, the count u8, then for each handle its kind u8 and its value: 0 a file or 1 a socket, with its value u64 in the process of the receiver, or 2 a socket for a child, with the 628 bytes of its `WSAPROTOCOL_INFOW`. Then the record of `shipOut` (`isothread.winh`).
  - A file, a pipe, or a console from the parent: the parent calls `DuplicateHandle` into the child with `DUPLICATE_SAME_ACCESS`, sends the value in `FD`, and closes its own handle, as `shipOut` does on Linux and macOS. A child that ends before it reads the frame closes the handle at its end, so no handle leaks.
  - From the child to the parent: the child gets no handle of the parent with `PROCESS_DUP_HANDLE`, and an AppContainer child cannot. The child makes a copy of its handle in its own process, sends its value in `FD`, and the parent pulls it with `DuplicateHandle(child, value, self, &h, 0, FALSE, DUPLICATE_SAME_ACCESS | DUPLICATE_CLOSE_SOURCE)`. A hostile child can name any handle of its own table, so the parent checks the object before it makes a channel: `GetFileType` gives a disk file, a character device, or a pipe for a file, and `SO_TYPE` gives `SOCK_STREAM` for a socket. A process, a thread, or a token has no file type.
  - From one isolated thread to another: the parent pulls the handle from the first child and duplicates it into the second.
  - A socket from the parent: the documentation of `DuplicateHandle` says to use `WSADuplicateSocketW` for a socket. The parent calls it with the pid of the child and sends the `WSAPROTOCOL_INFOW` in `FD` (kind 2), and the child calls `WSASocketW` with `FROM_PROTOCOL_INFO`, overlapped and not inherited. The call opens the process of the receiver, which a child cannot do for its parent, so a socket from a child goes as its handle (kind 1), as a file does, and the parent checks it with `SO_TYPE`. The parent drops a frame of a child with a kind 2 entry and closes the handles that it took from it.

  The channel then belongs to the receiver, as with threads today.
- At the `vm`, `vm-confidential`, and `wasm` levels a descriptor cannot cross, so the channel stays in the parent and the child gets a proxy channel: each read and write of the child is `CHAN data`, with credits (`CHAN credit`, 256 KiB to start) so a fast writer cannot fill the memory of the other side. `fileevent` on a proxy channel works from the credits and the data that arrived.
- A server socket and a command pipeline stay with their thread, as today. A transfer of one gives `ZTCL ISOLATION TRANSFER`, with a message that names the level.

## Files

- `START` gives the root folder of the creator and its current folder, and the child opens that root as its jail (`fsroot.setRoot`) before its first script. The sandbox of each platform gives the child that folder only.
- A creator in host mode with the capability `file` or `channels` gets `ZTCL ISOLATION HOSTFILES` from `thread::create` at the level `process` or a stronger level: "host file mode is not available in an isolated thread: give the thread a root folder, or pass -files host". The sandbox gives the child no folder of the user, so a silent host mode there gives only errors of access later. The rule is the same on each platform.
- `thread::create -files host` gives the child the files of the host (`files` 1 in `START`), with the other parts of the isolation in place: the crash of the child ends only the child, the limits of the system apply, and the network and the processes stay limited where the platform can. A creator with a root folder gets `ZTCL ISOLATION HOSTFILES` for `-files host`, so a thread never gets more files than its creator.
- On Windows an AppContainer reaches no folder of the user, so a child of `-files host` runs with no AppContainer (`Spawn.host_files`). It keeps the Job Object with each of its limits, and gets a token from `CreateRestrictedToken` with `DISABLE_MAX_PRIVILEGE` and the group of the administrators for deny only. It loses the network limit of the AppContainer: the capability `socket` in the child is then the only limit of the network. It also loses the limits of an AppContainer on the objects of the session, such as named pipes and the registry of the user.

## The JIT

- `START` ends with `jit u8`, after `files`: 1 when the creator has the JIT on, else 0. As the JIT is on by default where it can run, a child of a creator with the default gets 1.
- With 1, the child turns the JIT on with the default options after it enters its sandbox (`jail`), before its first script. When the platform or the sandbox refuses executable memory, the self test of the JIT fails and the child runs each script in the interpreter, with the same results.
- Windows: an AppContainer allows executable memory, so the child of an AppContainer has the JIT. A process with Arbitrary Code Guard has none. macOS: the sandbox profile of the child must allow `MAP_JIT`. Linux: the seccomp filter must allow `mmap` and `mprotect` with the execute right.

## Limits and cancels

- The child enforces the compute limit and the memory limit of the thread in its own interpreter, as a thread does today. The limits come in `START`.
- The system enforces a second limit, so a child that a C package or a kernel bug broke still stops: on Linux the cgroup of the child (`memory.max`, `cpu.max`, `pids.max`), on macOS the CPU time with `RLIMIT_CPU` and, because macOS does not reliably enforce `RLIMIT_AS`, a check of the memory footprint of the child by the parent (`proc_pid_rusage`) that ends it past the limit, on Windows the Job Object (below), and for a guest its memory size and its CPU count. The second limit is the limit of the thread plus the memory of the runtime.
- The Job Object of a Windows child: the child starts suspended, goes into the job, and then resumes, so no code of it runs outside the job. The parent keeps the only handle of the job. The settings are `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (a parent that crashes ends the child), `JOB_OBJECT_LIMIT_PROCESS_MEMORY` with a completion port of the job (`JobObjectAssociateCompletionPortInformation`) so that `JOB_OBJECT_MSG_PROCESS_MEMORY_LIMIT` ends the job (a violation only fails the allocation), `JOB_OBJECT_LIMIT_ACTIVE_PROCESS` at 1, `JOB_OBJECT_LIMIT_JOB_TIME` for the user CPU time, `JobObjectCpuRateControlInformation` for a hard cap of the CPU rate, `JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION` (no dialog of Windows Error Reporting), and the UI limits (`DESKTOP`, `HANDLES`, `READCLIPBOARD`, `WRITECLIPBOARD`, `GLOBALATOMS`, `SYSTEMPARAMETERS`, `EXITWINDOWS`). Nested jobs work on Windows 10 and later, so a parent in a job of its own still works.
- `total_compute` and `total_mem` of the group: the parent gives each child its part in `START`, and counts `USAGE`. The parent cannot trust the `USAGE` of a hostile child, so at the `process` level it also reads the counts of the system (the cgroup, the rusage of the process, and on Windows `JobObjectBasicAccountingInformation` and the `PeakProcessMemoryUsed` of `JobObjectExtendedLimitInformation`).
- `max_queue` applies to the proxy worker in the parent, and the child refuses a send past its own queue limit with the same error as today.
- A cancel is `CANCEL`. When the child does not end within 2 seconds of a cancel with `-unwind`, or of the end of the group, the parent ends it: `SIGKILL` of the process or its cgroup, `TerminateJobObject` with the exit code 137 (the code of a killed `exec` on Windows), or a stop of the guest.
- A connection that closes with no `EXIT` is the end of the thread with the error `ZTCL ISOLATION LOST`, which goes to `thread::join` and to `thread::errorproc`.

## Versions

- `HELLO` gives the range of versions of the parent, and `WELCOME` the version that the child picked: the highest of both. This page is version 1.
- A new kind of frame that a receiver can ignore has the flag `skip`, and needs no new version. A change of an existing frame, of the byte form, or of the handshake is a new version.
- `features` in `WELCOME` lists the optional parts, such as `plain` (no encryption) and `fd` (descriptor passing), so the parent knows what the child supports before it sends.

## Steps

1. This plan, reviewed by the sessions of each platform.
2. `src/isoproto.zig`: the frames, the byte form, the handshake, and the sealing, with tests over a socket pair and a test of random bytes into the reader (done, ztcl#223).
3. The proxy worker in `thread.zig` and the child in `src/isothread.zig`, with a test transport in the same process, and `thread::create -isolation process` on macOS with no sandbox (done). The messages of this step: `START`, `READY`, `SEND`, `RESULT`, `CANCEL`, `RELEASE`, `OUTPUT`, `BGERROR`, `EXIT`, and `GOODBYE`.
4. The `process` level on each platform, each with its sandbox (ztcl#209: namespaces, seccomp, and Landlock on Linux; a sandbox profile and limits on macOS; a Job Object and an AppContainer on Windows).
5. The `vm` level on the agent of `ztcl::vm`, then `wasm`, then `vm-confidential`.
6. The Thread package tests at each level, and `docs/isolation.md` with the numbers.

### The sandbox of Windows (step 4, first part)

`src/isolate_windows.zig` has `spawn`, `Child.wait`, `Child.kill`, and `Child.usage` for the Windows `process` level. Its tests run the ztcl runner in the sandbox: the child reads and writes its root folder, gets `permission denied` for the folder next to it, and cannot start a process. `kill` ends it with 137, the CPU and memory limits of the job end it, and the job counts its CPU time. What the work found:

- An AppContainer needs a profile. With a SID from `DeriveAppContainerSidFromAppContainerName` and no profile, `CreateProcessW` gives `ERROR_FILE_NOT_FOUND`. Each child gets a profile of its own (`CreateAppContainerProfile`), and its end deletes it.
- An AppContainer needs the folders of the user in its environment. With only `SystemRoot`, `CreateProcessW` gives `ERROR_ENVVAR_NOT_FOUND`. The child gets `APPDATA`, `LOCALAPPDATA`, `SystemDrive`, `SystemRoot`, `TEMP`, `TMP`, and `USERPROFILE`, and Windows puts the folders of its container in their place.
- An AppContainer cannot read the runner under the folder of a user, so the first spawn copies the runner into `%TEMP%\ztcl-iso`, a folder that each AppContainer can read and run.
- A child with a root folder starts in it, so a relative path of a script names a file in the root.
- The job of a child of `thread::create -isolation process` ends it past the memory limit of the thread plus 64 MiB for the runtime (`isothread.sandboxMem`). A thread with no memory limit gets a job with no memory limit.
- A creator with a root folder and the capability `file` or `channels` gives its root and its current folder in `START`, and the parent gives the AppContainer of the child read and write access to that folder only. The child opens it as its jail (`fsroot.setRoot`).

### The sandbox of Linux (step 4, second part)

`src/isolate_linux.zig` has `spawn`, `Child.wait`, `Child.kill`, `Child.usage`, and `enter` for the Linux `process` level. The sources are the man pages `namespaces(7)`, `user_namespaces(7)`, `cgroups(7)`, `clone(2)`, `pivot_root(2)`, `mount_setattr(2)`, `seccomp(2)`, and `landlock(7)`, and the cgroup v2 documentation of the kernel.

- `clone3` starts the child in new user, PID, mount, IPC, UTS, and cgroup namespaces, and a new network namespace without `socket`. `CLONE_INTO_CGROUP` puts it in its group at its start, and `CLONE_PIDFD` gives the descriptor of `wait` and `kill`.
- Between `clone3` and `execveat` the child uses raw system calls only. It maps its user and group ids to the same ids, makes each mount private, builds the new root on a tmpfs on `/tmp`, enters it with `pivot_root`, and makes the tmpfs read-only. It sets `PR_SET_NO_NEW_PRIVS` and `PR_SET_PDEATHSIG`, then runs the runner from a descriptor, so the runner needs no file in the new root. A failed step writes its number and errno on a pipe with `O_CLOEXEC`, and `spawn` gives an error that names the feature.
- The child opens the source of each bind itself, after `clone3`: a bind of a mount of the parent namespace gives `EINVAL`.
- `enter` runs in the child after `START`. Landlock limits the files to the root folder and the read-only files of the binds, TCP to the `socket` capability, and signals and abstract sockets to the sandbox (ABI 6). With `-files host` the ruleset handles no file right. The seccomp filter is made at compile time from a list of names. `clone` needs `CLONE_THREAD`, `clone3` gives `ENOSYS`, `socket` needs the capability, and the default is `EPERM`. The filter has the flag `TSYNC`.
- The cgroup: the highest ancestor of the group of the parent that the user owns (with systemd, `user@UID.service`), then `ztcl-iso/PID-N`. The limits are `memory.max` (the limit of the thread plus `runtime_mem`), `memory.swap.max` 0, `pids.max` 32, `cpu.max` at one CPU, `cpu.weight`, and `io.max` when a caller gives a device. `usage` reads `cpu.stat`, `memory.peak`, and `memory.events`. `kill` writes `cgroup.kill` and sends SIGKILL through the pidfd.
- The tests run a function of the test in the child in place of the runner: it cannot read the folder next to its root or `/etc/passwd`, open a socket, or start a program, it sees one process in `/proc`, and `memory.max` ends it. The tests of `thread::create` run the runner. CI allows unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns=0`) and runs the tests in a cgroup that the user owns.
- The Thread package tests with each `thread::create` at the level `process` (`tests/thread/*.tcl` with the flags of each file, after a `thread::create` that adds `-isolation process`), in one run on Linux: `churn.tcl` 2 of 2, `commands.tcl` 74 of 74 (the proxy passes `-head` to the child, and `-unwindonerror` ends the thread), `collect.tcl` 4 of 5 (`events-1` needs `socket`), `limits.tcl` 19 of 19, `owned.tcl` 10 of 10, `steps.tcl` 4 of 4, `sync.tcl` 39 of 39, `tpool.tcl` 33 of 33, and `tsv.tcl` 107 of 107. `totals.tcl` fails `steps-3` and `mem-2` and stops at a thread that does not exist. `chan.tcl` stops at `thread::detach`, since `thread::transfer` is not yet available in the child.

The transport (`isoproto.Transport` over the pipe) and the child side of the protocol come with steps 2 and 3. Until then the runner skips `--iso-handle`.

## Questions

These are the defaults of this plan. Each can change in review.

1. A send from a child to the parent runs as today unless `-sendback` limits it. Default: allowed, for the scripts that exist today. The other choice is to refuse it by default at each level past `interp`, which stops hostile scripts and breaks the scripts that send results back.
2. The frames are sealed at the `process`, `vm`, and `vm-confidential` levels, and `-encrypt 0` turns the sealing off for `process` and `vm`. The kernel already keeps a socket pair private, so the sealing of `process` protects only against a reader of the memory of the kernel. Default: sealed, as ztcl#203 asks for each thread that leaves the process, with the cost in `docs/isolation.md`.
3. The parent is the broker of `tsv`, the mutexes, and the conditions, with a round trip for each command. The other choice is a copy of an array in the child with a protocol of invalidation: faster, and much more complex. Default: the broker.
4. The largest payload of a frame is 1 MiB. Default: as written.
5. Version 1 uses X25519, HKDF-SHA256, and ChaCha20-Poly1305 only, with no choice of ciphers. Default: no choice, so no one can downgrade the handshake.
