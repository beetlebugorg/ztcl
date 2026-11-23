# Language and command reference

ztcl follows the 12 language rules of Tcl and the core commands of Tcl 8.6. The status below comes from the test files of Tcl 8.6.16. [Compatibility](compatibility.md) has all 152 files. ztcl makes no claim of Tcl 9 compatibility.

## Commands

The counts are pass / fail / skip for the test file of the command.

| Command | Tests | Notes |
|---|---|---|
| `append` | 42 / 3 / 0 |  |
| `apply` | 33 / 5 / 4 |  |
| `array` | no own test file |  |
| `binary` | 602 / 36 / 79 |  |
| `break` | no own test file |  |
| `catch` | no own test file |  |
| `concat` | 9 / 0 / 0 |  |
| `continue` | no own test file |  |
| `dict` | 311 / 29 / 2 | Has a hash table from 16 keys. |
| `error` | 300 / 9 / 8 |  |
| `eval` | 11 / 1 / 0 |  |
| `expr` | 14121 / 15 / 49 | Big integers up to 2^20 bits. Adds `clamp`, `lerp`, `noise2`, and `noise3`. |
| `for` | 60 / 4 / 24 |  |
| `foreach` | 41 / 2 / 0 |  |
| `format` | 225 / 32 / 9 |  |
| `global` | no own test file |  |
| `if` | 73 / 0 / 0 |  |
| `incr` | 62 / 4 / 0 |  |
| `info` | 97 / 161 / 5 | No `info frame`, `info class`, or `info object`. |
| `join` | 10 / 0 / 0 |  |
| `lappend` | no own test file |  |
| `lassign` | no own test file |  |
| `lindex` | 44 / 2 / 37 |  |
| `linsert` | 28 / 0 / 0 |  |
| `list` | 77 / 1 / 0 |  |
| `llength` | 6 / 0 / 0 |  |
| `lmap` | 60 / 6 / 0 |  |
| `lrange` | 32 / 0 / 2 |  |
| `lrepeat` | no own test file |  |
| `lreplace` | 1787 / 0 / 0 |  |
| `lreverse` | no own test file |  |
| `lsearch` | 111 / 7 / 0 |  |
| `lset` | 0 / 0 / 89 | All 89 tests need the `testevalex` command of the Tcl test binary. |
| `lsort` | no own test file |  |
| `namespace` | 230 / 80 / 3 | Has `path`, `unknown`, `forget`, and `ensemble configure`. |
| `noise3` | no own test file | A ztcl addition. |
| `proc` | 25 / 12 / 1 |  |
| `puts` | no own test file | Writes to the embedder callback. |
| `regexp` | 208 / 31 / 5 | First match wins. No lookahead or `-expanded`. |
| `regsub` | no own test file | Uses the matcher of `regexp`. |
| `rename` | 10 / 1 / 8 |  |
| `return` | no own test file |  |
| `scan` | 145 / 35 / 1 |  |
| `set` | 61 / 2 / 1 |  |
| `split` | 16 / 1 / 0 |  |
| `string` | 618 / 6 / 10 | Works on characters. Unicode classes and case maps are a small model. |
| `subst` | no own test file |  |
| `switch` | 105 / 8 / 0 |  |
| `throw` | no own test file |  |
| `tcl::mathop`, `tcl::mathfunc` | see `mathop` in Compatibility | Each operator and math function is a command. |
| `tcl::prefix` | see `string` | |
| `trace` | see `trace` in Compatibility | Variable, command, and execution traces. Step traces do not run. |
| `case` | see `case` in Compatibility | |
| `try` | no own test file |  |
| `unset` | no own test file |  |
| `uplevel` | 49 / 8 / 0 |  |
| `upvar` | 42 / 15 / 8 |  |
| `variable` | no own test file |  |
| `while` | 45 / 1 / 0 |  |

`parse.test` measures the parser: 84 / 6 / 181.

## Embedder commands

`point proc` exists only after `point.install`. See [Embedding](embedding.md) and [Design](design.md).

## Intentionally absent

`open`, `socket`, `exec`, `file`, `clock`, `source`, `exit`, `cd`, `glob`, `load`, and `after` do not exist. C extensions and Tk are out of scope. `interp` is also absent.

## Differences from Tcl

- A big integer has at most 2^20 bits.
- `rand()` uses a fixed seed.
- `tcl_platform` has the same fixed values on all platforms.
- `info commands` and `array names` have a fixed order.
- The first regular expression alternative that matches wins.
- Some errors of core commands still have the error code `NONE`. Arithmetic errors, wrong argument counts, list syntax, and lookups have the codes of Tcl.
- Unicode classes and case maps use a small model of the Unicode tables.
- `Interp.compact` drops traces.
