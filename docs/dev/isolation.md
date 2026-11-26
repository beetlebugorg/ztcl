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
| `TSV` | child | stream, the command, its arguments | A `tsv::*` command. The broker of the parent runs it on the arrays of the group and answers with `RESULT`. |
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

- At the `process` level on Linux and macOS, `thread::transfer id chan` and `thread::attach` move the descriptor itself: the parent sends `FD` with the descriptor in `SCM_RIGHTS` and the configuration of the channel (the translation, the encoding, the buffering, and the blocking mode). On Windows:
  - A file, a pipe, or a console: the parent calls `DuplicateHandle` into the child with `DUPLICATE_CLOSE_SOURCE`, then sends the value in `FD`. A child that ends before it reads the frame closes the handle at its end, so no handle leaks.
  - A socket: the documentation of `DuplicateHandle` says to use `WSADuplicateSocketW`. The parent calls it with the pid of the child and sends the `WSAPROTOCOL_INFOW` in `FD`. The child calls `WSASocketW` with `FROM_PROTOCOL_INFO`, and the parent closes its socket.
  - From the child to the parent: the child gets no handle of the parent with `PROCESS_DUP_HANDLE`, and an AppContainer child cannot. The child sends the value of its handle in `FD`, and the parent pulls it with `DuplicateHandle(child, value, self, &h, 0, FALSE, DUPLICATE_SAME_ACCESS | DUPLICATE_CLOSE_SOURCE)`. A hostile child can name any handle of its own table, so the parent checks the object (`GetFileType`, and for a socket its protocol structure) against the configuration of `FD` before it makes a channel.
  - The flag for an overlapped handle tells the channel code of the receiver how to read it.

  The channel then belongs to the receiver, as with threads today.
- At the `vm`, `vm-confidential`, and `wasm` levels a descriptor cannot cross, so the channel stays in the parent and the child gets a proxy channel: each read and write of the child is `CHAN data`, with credits (`CHAN credit`, 256 KiB to start) so a fast writer cannot fill the memory of the other side. `fileevent` on a proxy channel works from the credits and the data that arrived.
- A server socket and a command pipeline stay with their thread, as today. A transfer of one gives `ZTCL ISOLATION TRANSFER`, with a message that names the level.

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
2. `src/isoproto.zig`: the frames, the byte form (moved out of `webasync.zig`), the handshake, and the sealing, with tests over a socket pair and a fuzz test of the reader.
3. The proxy worker in `thread.zig`, with a test transport in the same process.
4. The `process` level on each platform, each with its sandbox (ztcl#209: namespaces, seccomp, and Landlock on Linux; a sandbox profile and limits on macOS; a Job Object and an AppContainer on Windows).
5. The `vm` level on the agent of `ztcl::vm`, then `wasm`, then `vm-confidential`.
6. The Thread package tests at each level, and `docs/isolation.md` with the numbers.

## Questions

These are the defaults of this plan. Each can change in review.

1. A send from a child to the parent runs as today unless `-sendback` limits it. Default: allowed, for the scripts that exist today. The other choice is to refuse it by default at each level past `interp`, which stops hostile scripts and breaks the scripts that send results back.
2. The frames are sealed at the `process`, `vm`, and `vm-confidential` levels, and `-encrypt 0` turns the sealing off for `process` and `vm`. The kernel already keeps a socket pair private, so the sealing of `process` protects only against a reader of the memory of the kernel. Default: sealed, as ztcl#203 asks for each thread that leaves the process, with the cost in `docs/isolation.md`.
3. The parent is the broker of `tsv`, the mutexes, and the conditions, with a round trip for each command. The other choice is a copy of an array in the child with a protocol of invalidation: faster, and much more complex. Default: the broker.
4. The largest payload of a frame is 1 MiB. Default: as written.
5. Version 1 uses X25519, HKDF-SHA256, and ChaCha20-Poly1305 only, with no choice of ciphers. Default: no choice, so no one can downgrade the handshake.
