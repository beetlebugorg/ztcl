# Task 08: `lassign` and `lset` as bytecode

## Goal

`lassign list name ...` and `lset name index value` run inline.

## Files

- `src/vm.zig`, `src/tests.zig`, `docs/design.md`.

## `lassign`

- Compiles when each name is a literal plain name and the count of names is 1 to 8.
- A new instruction `lassign`: table `a` has the slots. It reads the list on the top of the stack (`it.readList` for a string), stores item k in slot k with the store rules of `foreach_next` (a plain cell inline, each other cell through `setVar`), stores the empty string in a slot with no item, and replaces the top of the stack with the list of the items that are left.
- When the result is dropped and no item is left, the instruction makes no list. A form `lassign_drop` does this, as `store_pop` does for `store`.

## `lset`

- Compiles for `lset name index value` with one index word, in a proc body.
- A new instruction `lset` and its form `lset_drop`. With an integer index inside the list and an `.owned` cell, `lset_drop` writes in place. Each other case calls `cmdLset` and then applies the ownership rule of task 05.
- An index that is not an integer (`end`, `end-1`, a list of indexes) calls `cmdLset`.

## Acceptance

```sh
CAP zig build test
CAP tools/suite.sh lset.test lindex.test list.test foreach.test
CAP tools/mem-flat.sh                 # lassign.tcl and lset.tcl: 0 bytes for each pass
CAP perf stat -e instructions:u zig-out/bin/ztcl tests/mem/lassign.tcl 1000000
CAP perf stat -e instructions:u zig-out/bin/ztcl tests/mem/lset.tcl 200000
```

Gates: `lassign.tcl` at most 741 M instructions for one million passes. `lset.tcl` at most 150 M for 200 000 passes. Both numbers are the counts of `tclsh` 8.6.16 on 2026-11-23.

New tests: more names than items, more items than names, a traced name, an array element name (general path), a name that is an `upvar` link, `lset` out of range (the error of `tclsh`), `lset` on a shared list, and `rename lassign`.

## Must not change

The results of task 05. The pass counts.
