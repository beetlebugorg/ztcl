# The sandbox

A ztcl interpreter starts with no access to the host: no files, network, processes, clock, or environment. The host turns on each capability by name. Two limits bound the work of a script: the compute limit, in compute units, and a memory limit. This lesson runs `jot` with only `file`, and stops a loop at the compute limit.

<!-- checkpoint -->
```tcl
proc count_to {n} {
    set i 0
    while {$i < $n} { incr i }
    return $i
}
```

## Capabilities

A command of a capability that is off does not exist. [`info commands exec`](run: "") is empty, and [`catch {exec ls} msg`](run: "1") gives an error. [`set msg`](run: "invalid command name \"exec\"") has the message. A script cannot turn a capability on: only the host can.

The shell of this page has read-only files in memory and no other capability. The `ztcl` program on your computer also starts with no capability. `--allow` turns capabilities on, `--root` keeps the paths in one folder, and `--compute` sets the limit:

```sh
ztcl --allow file,channels --root ./notes --compute 50000000 jot.tcl
```

That `jot` reads and writes files in `./notes` and nowhere else, has no network and no `exec`, and stops after 50,000,000 compute units. [Limits and capabilities](../limits.md) lists each capability and each flag.

## The compute limit

One compute unit is about one Tcl command. Each command of this shell can use 10,000,000 compute units, and the bar under the shell shows the units of the last command. [`count_to 1000`](run: "1000") uses a few thousand. [`count_to 100000000`](run: "error: compute limit reached") stops at the limit.

`catch` and `try` cannot stop the error of the limit, so a script cannot keep a loop going past it: [`catch {while 1 {}}`](run: "error: compute limit reached"). The count uses no clock, so a slow machine stops a script at the same point as a fast one.

Deep recursion stops at the nesting limit with an error: [`proc down {n} {down [incr n]}; down 0`](run: "error: too many nested evaluations (infinite loop?)"). The host does not crash.

## Reading code an agent wrote

- List the capabilities that the script needs, and turn on only those. A script that needs `exec` gets the full power of the user: `exec` is outside the sandbox.
- A file path goes under `--root`. Look for paths with `..` or from input.
- The compute limit fits the job: a few times the units of a normal run. `ztcl --report` prints the units of a run.
- An error of the limit stops the script. Look for code that expects `catch` to keep it going.

## Ask an agent

> Run this script under ztcl with only the capabilities it needs. List each capability with the line that needs it, and give a compute limit with the units of one normal run, from `ztcl --report`.

## Try this

- Find the largest `n` for `count_to` under the limit of this shell.
- Run `info commands` and look for `open`, `socket`, and `clock`.
- On your computer, run `ztcl --report` on a script, and read the units.
