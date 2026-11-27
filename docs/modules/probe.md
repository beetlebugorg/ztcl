# Module ztcl::probe

`ztcl::probe` records the state of a running script at the places that you choose, with no change to the code of the script. A probe has a target: a proc, a line of a proc body, a command, a variable, or each error. Each time the target runs, the probe can test a condition and capture values. The records go in a ring buffer, and a query gives them back as Tcl dicts or as lines of JSON.

The module needs no capability. It reads no file and gives a script no access to the host. It is in each native build and in the WebAssembly shell of the site (`ztcl-shell.wasm`). The WebAssembly library `ztcl.wasm` leaves it out, because that file has a size limit.

[Debugging](../debugging.md) has `ztcl debug`, which runs a script with probes and writes a report, and its tools for agents.

<!-- run -->
```tcl
package require ztcl::probe
proc parse {n} {
    set toks {}
    for {set i 0} {$i < $n} {incr i} {
        lappend toks t$i
    }
    return [llength $toks]
}
ztcl::probe add -proc parse -line 4 -if {$i % 2 == 0} -capture {i [llength $toks]}
parse 5
foreach r [ztcl::probe records -where {i > 1}] {
    puts [dict get $r values]
}
```

```text
i 2 {[llength $toks]} 2
i 4 {[llength $toks]} 4
```

## Try it

The shell below has the module and the proc `parse` of the example. Type `ztcl::probe add -proc parse -capture n`, then `parse 3`, and then `ztcl::probe records -json`.

<!-- shell -->
```tcl
package require ztcl::probe
proc parse {n} {
    set toks {}
    for {set i 0} {$i < $n} {incr i} {
        lappend toks t$i
    }
    return [llength $toks]
}
```

## Commands

### ztcl::probe add target ?option value ...?

Adds a probe and gives its id, such as `p1`. The target is one of these options:

| Target | The probe records |
|---|---|
| `-proc name` | At each call of the proc, before the first command of the body. The record has the words of the call. |
| `-proc name -line n` | Before the first command of line `n` of the body, each time it runs. A command inside it on the same line, such as `incr n` in `if {$x} {incr n}`, does not run the probe again. Line 1 is the text after the open brace, as in the error trace. |
| `-command name` | At each call of the command. With `-leave`, at its return, with the result and the return code. A proc gets the probe of `-proc`. |
| `-var name ?-ops list?` | At each operation of `-ops` on a global or namespace variable: `read`, `write`, `unset`. The default is `write`. A name with no `::` is in the current namespace. |
| `-error` | At the start of each error, also an error that `catch` or `try` catches. The record has the message, the `errorCode`, and the command that failed. |

The other options:

| Option | What it does |
|---|---|
| `-if expr` | The probe records only when the expression is true. The expression runs in the frame of the target. |
| `-capture list` | Each word of the list is a value of the record. A plain name is a variable. Each other word goes through `subst`, so `[llength $toks]` and `$a,$b` work. The key of a value is its word. |
| `-stack` | The record has the call stack: one list of words for each frame, the innermost first. |
| `-locals` | As `-stack`, and each frame is a list of two: the words, and a dict of its local variables. A value has at most `-maxlen` bytes. |
| `-count n` | The probe makes at most `n` records. |
| `-every n` | The probe records each `n`th hit. |
| `-rate {n units}` | The probe makes at most `n` records in each window of `units` compute units. |
| `-leave` | With `-command`: record at the return. |

A probe on a proc or a line waits when no proc has the name. A new `proc` of the name gets the probe. A probe on a variable makes the variable as `trace add variable` does. An `unset` of the variable removes the probe from it, and `ztcl::probe list` then shows the state `waiting`.

### ztcl::probe records ?option value ...?

Gives the records in order, the oldest first, as a list of dicts. The options:

| Option | What it does |
|---|---|
| `-probe id` | Only the records of one probe. |
| `-since seq` | Only the records with a sequence number of at least `seq`. Use it to read only the new records. |
| `-where expr` | Only the records where the expression is true. A bare name in the expression is a field of the record or a captured value: `-where {n > 10}`. A record with no such field does not match. |
| `-first n`, `-last n` | Only the first or the last `n` records that match. |
| `-json` | Gives one line of JSON for each record in place of the list. |

A record has these fields:

| Field | Value |
|---|---|
| `seq` | The sequence number of the record in the interpreter. |
| `units` | The compute units that the interpreter used before the record. It is the time of the record, and a run gives the same times each time. |
| `thread` | The id of the thread of `thread::create`, or 0. |
| `probe`, `kind` | The id of the probe, and its kind: `proc`, `line`, `command`, `variable`, or `error`. |
| `proc` | The words of the current call, as `info level 0` gives them, or an empty string at the global level. |
| `line`, `words`, `var`, `op`, `value`, `code`, `result`, `cmd`, `message`, `errorcode`, `stack` | The fields of the kind. |
| `probe_error` | The error of the condition, when it failed. |
| `values` | A dict of the captured values. |

A captured value of more than `-maxlen` bytes keeps its first bytes and gets the count of all its bytes, such as `abc... (5000 bytes)`.

### ztcl::probe list

Gives a dict for each probe: `id`, `kind`, `target`, `line`, `state` (`active` or `waiting`), `hits`, `records`, `dropped` (the hits that a limit did not record), and `errors` (the errors of the condition and the captures).

### ztcl::probe remove id|all

Removes a probe, or each probe. The records stay.

### ztcl::probe clear

Removes each record.

### ztcl::probe configure ?-size n? ?-budget n? ?-maxlen n?

With no option, gives the settings. `-size` is the count of records that the ring keeps (default 1,000, at most 1,000,000). `-budget` is the count of compute units of one hit, with its condition and its captures (default 100,000). `-maxlen` is the most bytes of a captured value (default 256).

## Costs and limits

- With no probe, no code of the module runs. The compiled code of the procs has no probe instruction, and no variable or command has a probe entry.
- A probe uses no compute units of the script. The condition and the captures run with their own budget, and the interpreter gets its count back after them. An error of a condition or a capture goes in the record or in the error count, and the script does not see it. The result, the error state, and `errorInfo` of the script stay the same.
- A probe on a proc or a line compiles the body of that proc again with probe instructions, at its next call. Such a body runs in the bytecode interpreter: the JIT does not compile it. Each other proc keeps its machine code. When the last probe of the proc goes, the body compiles again with no probe.
- A probe on a variable uses the general path for the operations on that variable only. Other code keeps its inline forms, because a probe entry is not a trace of `trace add variable`.
- A probe on a command that is not a proc uses the wrapper of the execution traces. A probe on an inlined core command, such as `set` or `string`, turns the inline forms off while it exists.
- The records are in the memory of the embedder, outside the memory limit of the script. The probes themselves are small, and they are in the heap of the script. A capture runs in the heap of the script, so the memory count of the script can go up by the size of the captured values until the next collection.
- A probe does not run inside another probe.
- A line probe finds the commands of the body, of the bodies of `if`, `while`, `for`, `foreach`, and `switch`, and of each braced word with a space or a newline, such as the body of `catch`. A script that the body makes at run time, such as the text of `eval $cmd`, gets no line probe.
- `reset` and `compact` remove each probe and each record. `compact` inside a running script keeps them.

## The embedder API

ztk and other embedders use the engine from Zig, in `src/probe.zig`:

| Function | What it does |
|---|---|
| `probe.add(it, spec) !u32` | Adds a probe. `Spec` has the fields of the options above. |
| `probe.remove(it, id) bool` | Removes a probe. |
| `probe.select(it, query) ![]const *const Record` | The records that match a `Query`: `probe`, `since`, `where`, `first`, `last`. |
| `probe.writeJson(a, out, record)` | Writes one record as one line of JSON. |
| `probe.toDict(it, record) !Value` | A record as a Tcl dict. |
| `probe.state(it) !*State` | The state. Set `sink` to get each new record at once, for a live view. |
| `probe.clear(state)`, `probe.setSize(state, n)` | Remove the records, or change the size of the ring. |

A `Record` has `seq`, `units`, `thread`, `probe`, `kind`, `fields` (key and value pairs), and `values` (the captured values). Its strings belong to the state. A record in the ring stays valid until the ring drops it, or until `clear`, `setSize`, `reset`, `compact`, or `deinit`. A sink gets a record that is valid only during the call.
