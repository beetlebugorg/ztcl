# Task 05: `lset` in place on an owned list

## Goal

A cell can own a list, and a write of one item to an owned list is in place. Today each call copies the list: 2460 bytes for a list of 100 items.

## Background

`Var.v` has the form `.owned` for a dict that only the cell can see (`docs/design.md`, "The bytecode"). `dict_update_drop` makes it after a write that gave a new buffer, and each general read turns it back to `.val` first (`Var.settle`). This task uses the same form for a list.

## Files

- `src/more.zig`: `cmdLset` gets a path for a plain local or global cell.
- `src/interp.zig`: a helper `ownList(cell)`.
- `src/tests.zig`.

## Rules

- After `lset` copies the buffer of a list in a plain cell (`.val` or `.owned`, no trace, no link to an element), the new buffer has one holder: the cell. The cell gets the form `.owned`.
- The next `lset` on an `.owned` cell writes the item in place. It makes no copy.
- The result of `lset` is the new list value, and the caller can keep it. So the general command `lset` ends the ownership after its write: it gives the cell the form `.val` again before it returns the value. Only a form with a dropped result keeps the ownership. That form is the bytecode instruction `lset_drop` of task 08.
- In this task, add the ownership code and a test command `testlsetdrop name index value` in `tools/suite_cmds.zig` that runs the dropped form. The unit tests use the same function directly.
- Each read through `settle` ends the ownership, as for a dict. `lappend` on an owned list keeps the ownership when it writes in place.
- A nested index (`lset var 1 2 value`) and `end` forms copy as today.

## Acceptance

```sh
CAP zig build test       # new tests below
CAP tools/mem-flat.sh    # lset.tcl still grows in this task. Task 08 makes it flat.
CAP tools/suite.sh lset.test lindex.test list.test upvar.test trace.test
```

New tests:

- `set a {1 2 3}; set b $a; lset a 0 9` leaves `b` as `1 2 3`.
- `set b [lset a 0 9]; lset a 1 8` leaves `b` as `9 2 3`.
- A proc gets a list as an argument, writes to it with `lset` in a loop, and returns it. The list of the caller does not change.
- `upvar` to the variable, a read trace, and `foreach` over the variable while `lset` writes to it give the results of `tclsh` 8.6.16.

## Must not change

The pass count of `lset.test` (0 pass, 89 skip today) and of each other file. The instruction counts of `bench/`.
