# Tcl 8.6 and Tcl 9

This page compares Tcl 8.6.16 and Tcl 9.1.0 for the commands that ztcl has. ztcl still follows Tcl 8.6. The choices below are proposals, and no choice is in the code yet.

## Method

- `tclsh` 8.6.16 is the system package. `tclsh` 9.1.0 is tag `core-9-1-0`, built with its default `configure` options and `gcc -O2` into a local prefix. The two builds can differ in compiler flags, so a small time difference between them has no meaning.
- Each row below comes from one script that ran on both versions and on ztcl. A row covers only the inputs in its example.
- The list is not complete. It has 111 probe scripts, and other differences can exist.

## Suite results

`tools/suite.sh` runs the same 37 files of each release on ztcl.

| Test files | Pass | Fail | Skip |
|---|---|---|---|
| Tcl 8.6.16 | 19 288 | 997 | 544 |
| Tcl 9.1.0 | 8 756 | 3 326 | 541 |

The two totals do not compare directly, because the files differ. For example, `expr.test` has about 14 200 tests in 8.6.16 and about 2 200 in 9.1.0. In 9.1.0, `lreplace.test` also tests `ledit`, and ztcl has no `ledit`. Those tests are 1 789 of the 3 326 failures.

## Benchmarks

CPU milliseconds, best of 9 runs of the whole process, `ReleaseFast`, on an Intel Core i7-6700K.

| Benchmark | ztcl | tclsh 8.6.16 | tclsh 9.1.0 |
|---|---|---|---|
| `sum.tcl` | 24.8 | 58.4 | 57.9 |
| `fib.tcl` | 16.7 | 51.0 | 49.2 |
| `nested.tcl` | 36.4 | 73.5 | 84.8 |
| `strbuild.tcl` | 35.2 | 63.7 | 98.7 |
| `foreach.tcl` | 19.6 | 33.4 | 38.5 |
| `dict.tcl` | 30.5 | 48.7 | 58.4 |
| `dictgrow.tcl` | 84.5 | 104.2 | 143.3 |

## Differences and proposed choices

"ztcl now" is the result of ztcl today.

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
