# Module ztcl::meter

`ztcl::meter` counts the use of threads and child interpreters: compute units, wall time, CPU time, memory, and I/O. A host that runs scripts for its customers reads the counts and bills them. [Metering](../metering.md) is the guide, with a hosting example.

```tcl
ztcl::meter create acme -tenant acme -budget 5000000
set t [thread::create -joinable -isolation process -meter acme $customer_script]
thread::join $t
puts [dict get [ztcl::meter get acme] units]
puts [ztcl::meter record acme -script $customer_script -sign]
```

The command is not a package: it exists when the embedder turns on the capability `meter`, and it is absent otherwise. The same capability turns on the option `-meter` of `thread::create` and of `interp create`. The counts of time depend on the host, so the capability is off by default, as the clock is.

## Commands

```tcl
ztcl::meter create NAME ?-budget UNITS? ?-tenant TEXT?
ztcl::meter get NAME
ztcl::meter list
ztcl::meter reset NAME
ztcl::meter delete NAME
ztcl::meter run NAME SCRIPT
ztcl::meter record NAME ?-tenant TEXT? ?-script TEXT? ?-sign? ?-key SEED?
ztcl::meter verify RECORD PUBLICKEY
ztcl::meter pubkey SEED
```

- `create` makes the meter `NAME`, or sets the options of the meter `NAME`, and gives the name. `-budget` caps the compute units of all the work of the meter. An empty budget removes the cap. `-tenant` is a text for the records.
- `thread::create -meter NAME` and `interp create -meter NAME` make the meter when it does not exist.
- `get` gives the dict of the counts (below).
- `reset` sets each count to zero, and the start time of the next record to now.
- `delete` removes the name. A thread that counts in the meter goes on to count in it until the thread ends.
- `run` runs `SCRIPT` in the current interpreter and counts it in `NAME`. The budget of the meter caps the units of the script. At the end of the budget, the script gets the error `compute limit reached`, and the caller can catch it.
- `record` gives the usage record of the meter (below).
- `verify` gives 1 when the signature of a record matches the hex public key, and 0 otherwise.
- `pubkey` gives the hex Ed25519 public key of a hex seed of 32 bytes.

All the threads of a thread group share the names of the meters.

## The counts

| Key | What it counts |
|---|---|
| `units` | Compute units. [Limits](../limits.md#the-compute-limit) defines a unit. |
| `wall_us` | The wall time of each thread and child, in microseconds, added up. |
| `cpu_us` | The CPU time of each thread, in microseconds, added up. |
| `mem_peak` | The highest count of bytes of one thread or child. |
| `mem_avg` | The bytes in use, on average over `wall_us`. |
| `mem_byte_ms` | The bytes in use times the milliseconds: the area under the memory curve. |
| `threads` | A dict: the threads of each level, `interp` and `process`. |
| `io` | A dict of `file`, `socket`, and `pipe`, each a dict of the bytes of `read` and `write`. |
| `connections` | The sockets that a script opened. |
| `net` | A dict of host words, each a dict of `read`, `write`, and `connections`. The host is the word of `socket`. After 256 hosts, the bytes go to the word `other`. |
| `process` | A dict for the threads of the level `process`: `messages` and `bytes` of the transport, `start_us` (the time to the ready child), and the counts of the system, `os_cpu_us` and `os_mem_peak`. |
| `vm` | A dict for guests of `ztcl::vm`: `guests`, `run_us`, and `mem_byte_ms`. This version has no count of guests, so each value is 0. |
| `budget` | The budget, or an empty string. |
| `left` | The units left in the budget, or an empty string. |

The counts of a thread come in at its safe points, at the end of each script that `thread::send` runs in it, and at its end. A read from another thread sees the counts of the last such point. A thread of the level `process` adds its counts at its end only.

A compute unit is the same on each machine, with the JIT on or off, and at each isolation level. The tests run one script in a thread with the JIT on, with the JIT off, and in a child process, and get the same units.

## Budgets

A thread that starts with a meter that has a budget gets at most the units that are left, and the meter holds them until the thread ends. Two threads that run at the same time therefore cannot spend more than the budget. At the end of its units, a thread gets the compute-limit error, which no script can catch, and ends. `thread::create -compute UNITS` caps one thread.

## Records

`record` gives one line of JSON:

```json
{"version":1,"meter":"acme","tenant":"acme","seq":1,"start_ms":1795400000000,"end_ms":1795400000250,"script_sha256":"...","units":184467,"wall_us":2510,...,"prev":"0000...","key":"...","sig":"..."}
```

- `seq` counts the records of the meter, from 1.
- `prev` is the SHA-256 of the previous record of the meter, as hex, or 64 zeros for the first. A removed or changed record breaks the chain.
- `script_sha256` is the SHA-256 of the text of `-script`.
- With `-key SEED` or `-sign`, the record ends with `"key"`, the hex public key, and `"sig"`, the hex Ed25519 signature. The signed text is the record with `,"sig":"..."` removed: everything before `,"sig"`, then `}`.
- `-sign` uses the key that the embedder sets in `Interp.meter_key`, so the script never has the key. `-key` is for tests and for a host script that holds its own key.

A customer checks a record in any language: cut off the last field, add `}`, and check the Ed25519 signature with the public key of the host.

## Embedding

An embedder uses `src/meter.zig` directly:

- `meter.attach(it, m, 0)` counts an interpreter in the meter `m`, and `meter.detach(it)` ends it.
- `meter.sync(it)` adds the use since the last sync. The collector calls it at each safe point.
- `m.snapshot(a)` copies the counts at any time, from any thread.
- `meter.record(a, m, .{ .tenant = ..., .key = ... })` writes a record.
- `Interp.meter_key` is the Ed25519 key pair of `-sign`.

## Errors

| `errorCode` | When |
|---|---|
| `ZTCL METER NAME` | No meter has the name. |
| `ZTCL METER BUSY` | `run` in an interpreter that already counts in a meter. |
| `ZTCL METER KEY` | A seed or a public key is not 64 hex digits, or `-sign` with no key of the host. |

## Limits of this version

- The wasm and WASI builds and the UEFI enclave read no clock, so `wall_us`, `cpu_us`, `mem_avg`, and `mem_byte_ms` are 0 there. `web/ztcl-threads.mjs` does not give the capability `meter` yet.

- The units of a C package (`load`) and of a wasm module are not counted.
- A child process of the level `process` reports its own units. The system counts (`os_cpu_us`, `os_mem_peak`) come from the cgroup on Linux, the Job Object on Windows, and `wait4` on macOS. The counts of `net` of a child process are not sent to the parent.
- There is no callback at each N units, and no budget per period. A host resets a meter at the start of each period.
