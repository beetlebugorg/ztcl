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
