# Debugging

ztcl has five tools to find a bug:

- `ztcl::probe` records values at a proc, a line, a command, a variable, or an error, with no change to the script. [The module page](modules/probe.md) has each option.
- `ztcl debug` runs a script with probes and writes a short report: the error, the stack with the locals of each frame, the probes, and the last records. `--explain` also gives the last changes of the variables of the failed command.
- `ztcl debug --mcp` gives the same tools to an agent over the Model Context Protocol.
- `ztcl debug --dap` is a debugger for an editor: breakpoints, steps, the stack, the locals, watches, and hot reload.
- `ztcl::disasm` shows the bytecode of a proc or a script under the source line of each command. [The module page](modules/disasm.md) has the format.

The lesson [Debug a script](learn/91-debug-a-script.md) finds two bugs with a probe and with `ztcl debug`, in the shell of the page.

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

With no capability, a script is deterministic: each run gives the same output and uses the same compute units. A script with capabilities reads inputs from the host: the clock, the event loop, files, folders, sockets, pipes, and programs. `--record FILE` writes these inputs to a tape, and `--replay FILE` runs the script again with the inputs of the tape. A replay can add probes, because a probe uses no compute units, so the run reads each input at the same compute unit.

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
| `stat` | The data of a path: `file exists`, `file mtime`, `file size`, `file stat`, and the other queries of a path. |
| `list` | The names in a folder, for `glob`. |
| `command` | The result or the error of `exec` and `pid`. A replay does not run the programs of `exec`. |
| `random`, `env` | Bytes of entropy from the system, and a read of an environment variable. No command of the core reads them now. The commands of the Batteries milestone use these entries. |

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

## A debugger in the editor (DAP)

`ztcl debug --dap` serves a debugger on stdin and stdout with the Debug Adapter Protocol, the protocol of the debuggers of VS Code and other editors. The runner options after `--dap` set the capabilities and the limits of the run. The program is the script after the options, or the argument `program` of the request `launch`.

```sh
ztcl debug --dap --allow clock job.tcl
```

The debugger has these parts:

| Part | Requests |
|---|---|
| Breakpoints on lines of the program file, with an optional condition (a Tcl expression in the frame of the line). | `setBreakpoints` |
| Breakpoints on procs: the run stops at the entry of the proc. | `setFunctionBreakpoints` |
| Steps: step in, step over, and step out. `stopOnEntry` in `launch` stops at the first command. | `next`, `stepIn`, `stepOut`, `continue` |
| The stack, with the line of each frame. | `stackTrace` |
| The locals of each frame, and the globals. | `scopes`, `variables` |
| Tcl code in a frame: a watch, a hover, or a command of the console. | `evaluate` |
| Error breakpoints: with the exception filter `error`, the run stops at the start of each error, also an error that `catch` or `try` catches. The stop has the message and the command. The error goes on after `continue`. | `setExceptionBreakpoints` |
| Pause: the run stops at its next line. A request in a run is read within 256 lines, so `setBreakpoints` works in a run too. A long native command, such as `after 5000` or `vwait`, ends first. | `pause` |
| Hot reload: the debugger reads the program file again and runs each `proc` command of its top level. A frame that runs keeps the old body until it returns. | `ztclReload` (a custom request, with an optional `path`) |

A stop happens at each line of a proc, at each command of the top level of the program file, and at each line of a body of the top level, such as the body of a `while` or a `foreach`. Such a body runs in the bytecode interpreter while the debugger runs. The output of `puts` goes to the event `output`, because stdout has the protocol. An editor gets the debugger with a launch entry that starts `ztcl debug --dap`. In VS Code, an extension of the type `ztcl` with this entry in `package.json` is enough:

```json
{"debuggers": [{"type": "ztcl", "label": "ztcl", "program": "ztcl", "args": ["debug", "--dap"]}]}
```

## From Zig

`src/debug.zig` has the functions of `ztcl debug` for an embedder: `debug.run(it, text, options)` gives a `Report`, and `debug.writeText` and `debug.writeJson` write it. A report owns its strings, so it stays valid after `reset`. Call `report.deinit()` to free it.
