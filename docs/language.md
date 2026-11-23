# Language and command reference

ztcl follows the 12 language rules of Tcl and the core commands of Tcl 8.6. The status below comes from the test files of Tcl 8.6.16. ztcl makes no claim of Tcl 9 compatibility.

## Commands

The counts are pass / fail / skip for the test file of the command.

| Command | Tests | Notes |
|---|---|---|
| `append` | 28 / 17 / 0 |  |
| `apply` | 22 / 16 / 4 |  |
| `array` | no own test file |  |
| `binary` | 565 / 72 / 80 |  |
| `break` | no own test file |  |
| `catch` | no own test file |  |
| `concat` | 9 / 0 / 0 |  |
| `continue` | no own test file |  |
| `dict` | 291 / 49 / 2 | No hash table. |
| `error` | 283 / 19 / 15 |  |
| `eval` | 11 / 1 / 0 |  |
| `expr` | 14034 / 100 / 49 | 64-bit integers wrap. Adds `clamp`, `lerp`, `noise2`, and `noise3`. |
| `for` | 60 / 4 / 24 |  |
| `foreach` | 38 / 5 / 0 |  |
| `format` | 224 / 32 / 10 |  |
| `global` | no own test file |  |
| `if` | 72 / 1 / 0 |  |
| `incr` | 61 / 4 / 0 |  |
| `info` | 61 / 188 / 14 | No `info frame`. |
| `join` | 7 / 3 / 0 |  |
| `lappend` | no own test file |  |
| `lassign` | no own test file |  |
| `lindex` | 37 / 9 / 37 |  |
| `linsert` | 27 / 1 / 0 |  |
| `list` | 77 / 1 / 0 |  |
| `llength` | 5 / 1 / 0 |  |
| `lmap` | 55 / 11 / 0 |  |
| `lrange` | 30 / 2 / 2 |  |
| `lrepeat` | no own test file |  |
| `lreplace` | 1787 / 0 / 0 |  |
| `lreverse` | no own test file |  |
| `lsearch` | 109 / 9 / 0 |  |
| `lset` | 0 / 0 / 89 | All 89 tests of the file skip. |
| `lsort` | no own test file |  |
| `namespace` | 161 / 149 / 3 | No `path`, `unknown`, `forget`, or `ensemble configure`. |
| `noise3` | no own test file | A ztcl addition. |
| `proc` | 20 / 17 / 1 |  |
| `puts` | no own test file | Writes to the embedder callback. |
| `regexp` | 207 / 32 / 5 | First match wins. No lookahead or `-expanded`. |
| `regsub` | no own test file | Uses the matcher of `regexp`. |
| `rename` | 8 / 3 / 8 |  |
| `return` | no own test file |  |
| `scan` | 145 / 35 / 1 |  |
| `set` | 61 / 2 / 1 |  |
| `split` | 14 / 3 / 0 |  |
| `string` | 455 / 169 / 10 | Some subcommands work on bytes. See the design. |
| `subst` | no own test file |  |
| `switch` | 93 / 20 / 0 |  |
| `throw` | no own test file |  |
| `try` | no own test file |  |
| `unset` | no own test file |  |
| `uplevel` | 40 / 17 / 0 |  |
| `upvar` | 34 / 23 / 8 |  |
| `variable` | no own test file |  |
| `while` | 45 / 1 / 0 |  |

`parse.test` measures the parser: 65 / 25 / 181.

## Embedder commands

`point proc` exists only after `point.install`. See [Embedding](embedding.md) and [Design](design.md).

## Intentionally absent

`open`, `socket`, `exec`, `file`, `clock`, `source`, `exit`, `cd`, `glob`, `load`, and `after` do not exist. C extensions and Tk are out of scope. `interp` and `trace` are also absent.

## Differences from Tcl

- Integers are 64 bits and wrap.
- `rand()` uses a fixed seed.
- `tcl_platform` has the same fixed values on all platforms.
- `info commands` and `array names` have a fixed order.
- The first regular expression alternative that matches wins.
- Errors of core commands have the error code `NONE`.
