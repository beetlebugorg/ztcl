# Debug a script

This lesson finds two bugs in a small script. The first bug gives a wrong number, and a probe shows why. The second bug stops the script, and `ztcl debug` explains it. The procs are code from an agent: you add no `puts` to them, and you change only the line with the bug.

<!-- checkpoint -->
```tcl
set notes [list [dict create text "buy milk" done 1] [dict create text "call Sam" done 0]]
```

## A wrong number

`progress` gives the percent of the notes that are done, with the helper `percent`. One of the two notes is done, so the answer must be 50.

<!-- define -->
```tcl
proc percent {part whole} {
    expr {$part / $whole * 100}
}
proc progress {notes} {
    set done 0
    foreach note $notes {
        if {[dict get $note done]} { incr done }
    }
    return [percent $done [llength $notes]]
}
```

[`progress $notes`](run: "0") gives 0.

## Look inside with a probe

A probe records values at a line of a proc, with no change to the proc. The line numbers start at the `proc` line, so line 2 of `percent` is its `expr`.

1. [`package require ztcl::probe`](run: "1.0") loads the module.
2. [`ztcl::probe add -proc percent -line 2 -capture {part whole}`](run: "p1") adds the probe `p1`.
3. [`progress $notes`](run: "0") runs the proc again.
4. [`dict get [lindex [ztcl::probe records] 0] values`](run: "part 1 whole 2") reads the record of that call.

The inputs are right, so the bug is in the `expr`. `$part / $whole` is `1 / 2`, and the division of two integers gives an integer: 0. Multiply first: [`proc percent {part whole} {expr {100 * $part / $whole}}`](run: "") puts the fix in the shell, and [`progress $notes`](run: "50") gives 50.

The probe stays on the new proc, because a probe follows the name. [`ztcl::probe remove all`](run: "") removes it. [ztcl::probe](../modules/probe.md) has the other kinds: a probe on a command, on a variable, and on each error, and `-where` to keep only some records.

## An error: ask ztcl debug

[`progress {}`](run: "error: divide by zero") stops with an error. On your computer, put the two procs and the call `progress {}` in `progress.tcl`, and run `ztcl debug --explain progress.tcl`. The report has the error, the command that failed, and the stack with the locals of each frame:

```text
status: error
error: divide by zero
code: ARITH DIVZERO {divide by zero}
at: expr {100 * $part / $whole}
stack, innermost first (2 frames):
  percent 0 0
    part = 0
    whole = 0
  progress {}
    notes = 
    done = 0
```

`whole` is 0 because `notes` is empty. The fix goes in `progress` or in `percent`: an empty list is 0 percent done, or an error with a code. [Errors](06-errors.md) has the error codes.

## Other tools

- **A run that reads the clock or the network.** `ztcl debug --record run.tape` writes each input of the host to a tape, and `--replay run.tape` runs the script again with the same inputs and new probes.
- **An agent.** `ztcl debug --mcp` gives an agent the tools `ztcl_run`, `ztcl_explain`, `ztcl_records`, and `ztcl_eval`. The agent reads the report and the records, and does not add `puts` to your code.
- **An editor.** `ztcl debug --dap` is a debugger for VS Code and other editors: breakpoints, steps, the locals, and hot reload of procs.

[Debugging](../debugging.md) has each option, the tape, and the setup of the MCP server and the editor.

## Reading code an agent wrote

- Each `expr` with a `/` names its number type. `100 * $a / $b` keeps the integer part of a percent. `double($a) / $b` gives a fraction.
- A proc that divides by the length of a list has a check for an empty list, or a doc line that says that the list is never empty.
- The fix of a bug has a test that fails before the fix.

A prompt for an agent: "Find the bug with `ztcl debug --explain` or a probe of `ztcl::probe`. Do not add `puts` to the code. Show the record that proves the cause."

## Try this

- Add a probe on each error: `ztcl::probe add -error -capture {part whole}`, then run `progress {}` and read the records.
- Change `percent` to `expr {double($part) / $whole * 100}`, and see that the result is the double `50.0`.
