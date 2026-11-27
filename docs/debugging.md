# Debugging

ztcl has three tools to find a bug:

- `ztcl::probe` records values at a proc, a line, a command, a variable, or an error, with no change to the script. [The module page](modules/probe.md) has each option.
- `ztcl debug` runs a script with probes and writes a short report: the error, the stack with the locals of each frame, the probes, and the last records. `--explain` also gives the last changes of the variables of the failed command.
- `ztcl debug --mcp` gives the same tools to an agent over the Model Context Protocol.

## Probes in a running program

A probe is a `puts` that you add from outside the code. The shell below has the proc `average` with a bug: the second call divides by zero. Run the commands of the box, then `ztcl::probe records -where {x < 0}`.

<!-- shell -->
```tcl
package require ztcl::probe
proc average {items} {
    set total 0
    set n 0
    foreach x $items {
        incr total $x
        if {$x < 0} { set n 0 } else { incr n }
    }
    return [expr {$total / $n}]
}
ztcl::probe add -proc average -line 6 -capture {x n total}
catch {average {3 -3}}
ztcl::probe records
```

The records show that `n` goes back to 0 at the negative item, so the line 6 is the bug.

## ztcl debug

Give the options of `ztcl debug` first, then the options of the runner, then the script.

```sh
ztcl debug --explain average.tcl
```

```text
avg 6
status: error
error: divide by zero
code: ARITH DIVZERO {divide by zero}
at: expr {$total / $n}
stack, innermost first (2 frames):
  average {3 -3}
    items = 3 -3
    total = 0
    n = 0
    x = -3
  report
changes in the last call (second run; each change is between the two lines):
  total: <no value> -> 0 (line 2 to 3)
  total: 0 -> 3 (line 5 to 6)
  total: 3 -> 0 (line 5 to 6)
  n: <no value> -> 0 (line 3 to 4)
  n: 0 -> 1 (line 6 to 5)
  n: 1 -> 0 (line 6 to 8)
  x: <no value> -> 3 (line 4 to 5)
  x: 3 -> -3 (line 6 to 5)
```

The change of `n` from 1 to 0 is between line 6 and line 8, so the command on line 6 made it. The file `average.tcl` of this example is:

```tcl
proc average {items} {
    set total 0
    set n 0
    foreach x $items {
        incr total $x
        if {$x < 0} { set n 0 } else { incr n }
    }
    return [expr {$total / $n}]
}
proc report {} {
    puts "avg [average {4 6 8}]"
    puts "avg [average {3 -3}]"
}
report
```

| Option | What it does |
|---|---|
| `--probe SPEC`, `-p SPEC` | Adds a probe. SPEC is the words of `ztcl::probe add`, such as `-proc parse -line 4 -capture {i [llength $toks]}`. Give the option again for each probe. |
| `--explain` | After an error, runs the script again with a probe on each line of the proc of the error. The probes capture the variables of the failed command and the locals of that frame. The report gives the last 5 changes of each one, with the line of the command that made the change. |
| `--json` | Writes the report as one JSON object. |
| `--budget N` | The most bytes of the report. The default is 4,000. The last line tells how many bytes it left out. |
| `--detail PART` | `summary` (the default), `stack` (each frame), `records` (each record), or `all`. |
| `--last N` | The count of records in the report. The default is 10. |

The output of the script comes first, then the report. The exit code is 0 for a run with no error, 1 for an error, and 2 for a bad probe.

The second run of `--explain` is equal to the first run when the script has no capability, because such a script is deterministic. With a capability, such as `--allow clock`, the second run can differ, and the report says so in a `note` line.

## Record and replay

With no capability, a script is deterministic: each run gives the same output and uses the same compute units. A script with capabilities reads inputs from the host: the clock, the event loop, files, sockets, and pipes. `--record FILE` writes these inputs to a tape, and `--replay FILE` runs the script again with the inputs of the tape. A replay can add probes, because a probe uses no compute units, so the run reads each input at the same compute unit.

```sh
ztcl debug --record run.tape --allow clock,channels,file job.tcl
ztcl debug --replay run.tape --allow clock,channels,file -p "-proc pick -capture {x k}" job.tcl
```

The tape has these inputs:

| Input | From |
|---|---|
| `clock` | The time of `clock seconds`, `clock milliseconds`, and `clock microseconds`. |
| `ticks` | The clock of the event loop: `after`, `vwait`, and `update`. A replay does not sleep. |
| `poll` | The channels that the event loop found ready. |
| `read` | The bytes of each read of a channel: a file, a socket, or a pipe. |

A replay opens the same files and sockets as the run, and their data comes from the tape. When the script asks for an input in another order or at another compute unit, the replay stops with the error code `ZTCL TAPE DIVERGED`, and the report has a `tape` line that names the entry. With `--explain`, the second run replays the inputs of the first run, so the changes are exact also for a script with capabilities.

The tape is text: the line `ztcl-tape 1`, then one line for each input: the kind, the compute units before it, a number, and the data in base64.

## Questions over a run

These options of `ztcl debug` add probes and give one `answer` line each. They work in a normal run and in a replay.

| Option | The answer |
|---|---|
| `--who-set VAR` | The last write of the global or namespace variable: its value, its time in compute units, and the stack. |
| `--when VAR VALUE` | The first write of VALUE to the variable. |

The report also has a `first error` line when an error came before the last error, for example an error that `catch` caught.

For this script, `ztcl debug --who-set x --when x 8 steps.tcl` gives the lines below.

```tcl
proc step {k} { global x; set x [expr {$x * 2 + $k}] }
set x 1
foreach k {1 2 3 4} { step $k }
catch {error early}
error late
```

```text
first error: early (at error early, unit 25)
answer: x: was last set to 42 at unit 23 (record #5), stack: {step 4}
answer: x: got the value 8 at unit 13 (record #2), stack: {step 2}
```

## Tools for agents (MCP)

`ztcl debug --mcp` serves four tools on stdin and stdout, one JSON-RPC message on each line. The runner options after `--mcp` set the capabilities and the limits of each run. An agent with a JSON file of MCP servers gets the tools with this entry:

```json
{"mcpServers": {"ztcl": {"command": "ztcl", "args": ["debug", "--mcp"]}}}
```

| Tool | What it does |
|---|---|
| `ztcl_run` | Runs a script (`path` or `script`) with `probes`, and gives the report and the output of `puts`. |
| `ztcl_explain` | As `ztcl_run`, with the second run of `--explain`. |
| `ztcl_records` | Gives the records of the last run as JSON lines, with `where`, `probe`, `since`, and `last`. |
| `ztcl_eval` | Evaluates Tcl code in the interpreter of the last run, for example to read a variable or to add a probe. |

Each tool has the argument `budget`, the most bytes of its answer (default 4,000). The answer starts with the summary, so an agent reads the status and the error first, and asks for more with `detail`, `last`, or `ztcl_records`.

## From Zig

`src/debug.zig` has the functions of `ztcl debug` for an embedder: `debug.run(it, text, options)` gives a `Report`, and `debug.writeText` and `debug.writeJson` write it. A report owns its strings, so it stays valid after `reset`. Call `report.deinit()` to free it.
