# Tcl 8.6 and Tcl 9

This page compares Tcl 8.6.16 and Tcl 9.1.0 for the commands that ztcl has. It is the record of the probes before issue 201. ztcl now follows Tcl 8.6 by default and Tcl 9.1 with `--tcl 9.1`. [Tcl 9.1](../tcl91.md) lists what the switch changes and what is not done. The tables below are the results of the probes, and some rows are out of date.

## Method

- `tclsh` 8.6.16 is the system package. `tclsh` 9.1.0 is tag `core-9-1-0`, built with its default `configure` options and `gcc -O2` into a local prefix. The two builds can differ in compiler flags, so a small time difference between them has no meaning.
- Each row below comes from one script that ran on both versions and on ztcl. A row covers only the inputs in its example.
- The list is not complete. It has 111 probe scripts, and other differences can exist.

## Suite results

`tools/suite.sh` runs the same 37 files of each release on ztcl.

| Test files | Pass | Fail | Skip |
|---|---|---|---|
| Tcl 8.6.16 | 19 877 | 423 | 532 |
| Tcl 9.1.0 | 9 298 | 2 799 | 529 |

The two totals do not compare directly, because the files differ. For example, `expr.test` has about 14 200 tests in 8.6.16 and about 2 200 in 9.1.0. In 9.1.0, `lreplace.test` also tests `ledit`, and ztcl has no `ledit`. Those tests are 1 789 of the 2 823 failures.

## Benchmarks

CPU milliseconds, best of 11 runs of the whole process, `ReleaseFast`, on an Intel Core i7-6700K.

| Benchmark | ztcl | tclsh 8.6.16 | tclsh 9.1.0 |
|---|---|---|---|
| `sum.tcl` | 20.2 | 58.3 | 57.8 |
| `fib.tcl` | 14.4 | 50.8 | 49.4 |
| `nested.tcl` | 31.8 | 73.7 | 84.7 |
| `strbuild.tcl` | 23.0 | 63.8 | 99.2 |
| `foreach.tcl` | 16.2 | 33.2 | 38.6 |
| `dict.tcl` | 22.8 | 48.6 | 58.5 |
| `dictgrow.tcl` | 61.4 | 104.9 | 144.2 |
| `readloop.tcl` | 17.7 | 27.9 | 32.7 |

## The state of the choices

Where Tcl 8.6 and Tcl 9 differ, ztcl keeps the behavior of 8.6 as the default, and `--tcl 9.1` selects the behavior of 9.1 for the parts that [Tcl 9.1](../tcl91.md) lists. The work on the 152 test files of 8.6.16 added the event loop, `socket`, `exec`, TclOO, and `encoding`. These commands are the same in both versions for the inputs of the tests that ran, so they needed no choice. The owner of the project decides each proposal below.

## Differences and proposed choices

"ztcl now" is the result of ztcl before the work on the 8.6.16 test suite. Some rows are out of date.

### Numbers

| Input | 8.6.16 | 9.1.0 | ztcl now | Proposal |
|---|---|---|---|---|
| `expr {010}` | 8 | 10 | 8 | Use 9: a leading zero is decimal. |
| `expr {08}` | error | 8 | 8.0 | Use 9. The ztcl result is a bug in both modes. |
| `lindex $l 010` | index 8 | index 10 | index 10 | Use 9. ztcl is mixed today. |
| `expr {0d10}` | error | 10 | error | Add. |
| `expr {1_000+1}` | error | 1001 | error | Add. |
| `string is integer 08` | 0 | 1 | 0 | Use 9. |
| `string is integer 99999999999999999999` | 0 | 1 | 0 | Use 9. |
| `expr {int(1e30)}` | low 64 bits | the whole value | low 64 bits | Use 9. |
| `format %x -1` | `ffffffffffffffff` | `ffffffff` | `ffffffffffffffff` | Use 9, with `%llx` for the whole value. |
| `format %a 1.0` | error | `0x1p+0` | error | Add. |

### Operators and commands

| Input | 8.6.16 | 9.1.0 | ztcl now | Proposal |
|---|---|---|---|---|
| `expr {"a" lt "b"}`, also `le`, `gt`, `ge` | error | 1 | error | Add. |
| `lseq`, `lpop`, `lremove`, `ledit` | absent | present | absent | Add. None reaches the host. |
| `string insert` | absent | present | absent | Add. |
| `string is dict` | absent | present | absent | Add. |
| `dict getdef`, `dict getwithdefault` | absent | present | absent | Add. |
| `array default`, `array for` | absent | present | absent | Add. |

### Strings and bytes

| Input | 8.6.16 | 9.1.0 | ztcl now | Proposal |
|---|---|---|---|---|
| `scan \U1F600 %c` | 65533 | 128512 | 128512 | Keep the result of 9. |
| `string reverse a\U1F600` | a broken character | correct | correct | Keep the result of 9. |
| `binary scan Ā c x` | 1 | error | 1 | Use 9: a character above 255 is an error. |

### Variables

| Input | 8.6.16 | 9.1.0 | ztcl now | Proposal |
|---|---|---|---|---|
| `namespace eval q {set tcl_version 1}` | writes the global | makes `q::tcl_version` | writes the global | Use 9: a relative name stays in the namespace. |
| `set tcl_precision` | 0 | no such variable | no such variable | Keep the result of 9. |

## Same in both versions, and different in ztcl

These results are the same in 8.6.16 and 9.1.0, so they need no choice. They are gaps of ztcl:

- The error codes of core commands, for example `ARITH DIVZERO` and `TCL LOOKUP VARNAME`.
- `tcl::prefix`.
- `set a::b 1` with no namespace `a` is an error in Tcl. ztcl sets the variable.
- `string totitle`, `string tolower`, `string trim`, and `string is space` outside ASCII.
- `string range` and `string first` on text with a character above U+FFFF.
- Lookahead in regular expressions.
- A negative base with a fractional power is a domain error in Tcl. ztcl gives NaN.
- The message of `llength {a {b}c}`.
