# Metering

A host that runs scripts for its customers needs to know what each customer used. ztcl counts the use of each thread and child interpreter in a meter: compute units, wall time, CPU time, memory, and I/O. [ztcl::meter](modules/meter.md) has the commands.

## Bill by compute units

A compute unit is one command, one loop pass, or the work on 4,096 bytes of data ([Limits](limits.md#the-compute-limit)). The count depends only on the script and its inputs:

- The same script uses the same units on a laptop and on a server, under load and idle.
- The JIT and the interpreter count the same units. The tests run one script with the JIT on and off and compare the counts.
- A thread in a child process (`-isolation process`) counts the same units as a thread in the same process.

CPU seconds change with the machine, the load, the cache, and the JIT. A bill in compute units is the same each time the customer runs the same job, and a customer can check it: the customer runs the script on their own machine and counts the same units.

The meter also counts wall time, CPU time, and memory. Use them for a second price, such as a price for memory over time (`mem_byte_ms`), or to check the cost of a customer against the cost of the machine.

## A hosting example

The service runs each job of a customer in a thread of the level `process`. Each tenant has a meter with a budget for the month. After each job, the service appends a signed record of the meter of the tenant to a log.

```tcl
# The embedder sets Interp.meter_key, so the script signs with -sign.
proc run_job {tenant script} {
    if {$tenant ni [ztcl::meter list]} {
        ztcl::meter create $tenant -tenant $tenant -budget 50000000
    }
    set t [thread::create -joinable -isolation process -meter $tenant -compute 5000000 $script]
    thread::join $t
    set log [open usage.jsonl a]
    puts $log [ztcl::meter record $tenant -script $script -sign]
    close $log
    return [dict get [ztcl::meter get $tenant] left]
}

# At the start of each month, after the last record of the month:
proc new_month {} {
    foreach m [ztcl::meter list] {ztcl::meter reset $m}
}
```

The parts:

- The thread runs in a child process in the sandbox of the system ([Isolated threads](isolation.md)). A crash of the customer script ends only the child.
- `-compute 5000000` caps one job. The budget of the meter caps all the jobs of the tenant, also jobs that run at the same time. A job that starts with no units left ends at its first command with the compute-limit error.
- `thread::join` waits for the end of the job. Then the counts of the child are in the meter.
- `record` writes one line of JSON with the counts of the month to now, the SHA-256 of the script, a link to the record before it, and an Ed25519 signature. The use of one job is the difference of two records in a row.
- `reset` sets the counts to zero, so the budget is full again.

## What a customer can check

A record has the SHA-256 of the script, the units, and the signature of the host. The customer can:

- check the signature with the public key of the host (`ztcl::meter verify`, or Ed25519 in any language: the signed text is the record before `,"sig"`, then `}`);
- check the chain: the `prev` of each record is the SHA-256 of the record before it, so the host cannot remove a record or change one with no break in the chain;
- run the same script with the same inputs and count the units with `ztcl::meter run`.

The signature shows that the host made the record. It does not show that the host ran the script with the counts of the record: a host can sign any counts. On attested hardware ([ztcl#180](https://github.com/beetlebugorg/ztcl/issues/180)) a record can come with the attestation of the code that counted. This version has no such record.

## Trust at each level

| Level | Where the counts come from |
|---|---|
| `interp` | The interpreter of the thread, in the process of the host. |
| `process` | The child reports its compute units, CPU time, memory, and I/O at its end. The parent measures the wall time, the start time, and the messages and bytes of the transport, and reads the counts of the system: the cgroup on Linux, the Job Object on Windows, and `wait4` on macOS. |
| A child interpreter (`interp create -meter`) | The child, in the process of the host. |

A child process with a bad C package can report wrong counts. The counts of the system come from the kernel, so bill such work by `process os_cpu_us` and `process os_mem_peak`, or check the units of the child against them.

## Not in this version

- The units of C packages and wasm modules.
- A callback at each N units, and a budget per period.
- The levels `wasm` and `vm` of `thread::create`, and counts of `ztcl::vm` guests.
- The counts of `net` of a child process.
