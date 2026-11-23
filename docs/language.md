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
| `expr` | 14122 / 14 / 49 | Big integers up to 2^20 bits. Adds `clamp`, `lerp`, `noise2`, and `noise3`. |
| `for` | 60 / 4 / 24 |  |
| `foreach` | 41 / 2 / 0 |  |
| `format` | 233 / 24 / 9 |  |
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
| `lmap` | 62 / 4 / 0 |  |
| `lrange` | 32 / 0 / 2 |  |
| `lrepeat` | no own test file |  |
| `lreplace` | 1787 / 0 / 0 |  |
| `lreverse` | no own test file |  |
| `lsearch` | 111 / 7 / 0 |  |
| `lset` | 0 / 0 / 89 | These tests need `testevalex`. The suite runner has a stand-in. |
| `lsort` | no own test file |  |
| `namespace` | 233 / 77 / 3 | Has `path`, `unknown`, `forget`, and `ensemble configure`. |
| `noise3` | no own test file | A ztcl addition. |
| `proc` | 26 / 3 / 9 |  |
| `puts` | no own test file | Writes to the embedder callback. |
| `regexp` | 239 / 1 / 4 | Longest match, lookahead, and the ARE, ERE, and BRE syntaxes. |
| `regsub` | no own test file | Uses the matcher of `regexp`. |
| `rename` | 10 / 1 / 8 |  |
| `return` | no own test file |  |
| `scan` | 162 / 18 / 1 |  |
| `set` | 61 / 2 / 1 |  |
| `split` | 16 / 1 / 0 |  |
| `string` | 618 / 6 / 10 | Works on characters. Unicode classes and case maps are a small model. |
| `subst` | no own test file |  |
| `switch` | 106 / 7 / 0 |  |
| `throw` | no own test file |  |
| `tcl::mathop`, `tcl::mathfunc` | see `mathop` in Compatibility | Each operator and math function is a command. |
| `tcl::prefix` | see `string` | |
| `trace` | see `trace` in Compatibility | Variable, command, and execution traces. Step traces do not run. |
| `case` | see `case` in Compatibility | |
| `try` | no own test file |  |
| `unset` | no own test file |  |
| `uplevel` | 49 / 8 / 0 |  |
| `upvar` | 43 / 14 / 8 |  |
| `variable` | no own test file |  |
| `while` | 45 / 1 / 0 |  |

`parse.test` measures the parser: 84 / 6 / 181.

## Embedder commands

`point proc` exists only after `point.install`. See [Embedding](embedding.md) and [Design](design.md).

## Intentionally absent

In the default interpreter, `open`, `socket`, `exec`, `file`, `clock`, `source`, `cd`, `glob`, `after`, `vwait`, and `update` do not exist. `load` and `exit` do not exist in the library. C extensions and Tk are out of scope.

## Optional commands

`package`, `interp`, `clock`, `channels`, `file`, `event`, `socket`, and `exec` are capabilities. The default interpreter does not have them. An embedder turns them on with `Interp.allow`, and the runner with `--allow package,interp,clock,channels,file,event,socket,exec --root DIR`. A child interpreter has at most the capabilities of its parent. A safe child has only the event loop of its parent.

`clock` reads the time and the zone data only through `Interp.clock_host`, a callback of the embedder. Named zones are TZif data from that callback.

`file` and the channel commands exist on Linux and stay inside one root folder from the embedder. A script sees that folder as `/`. Each open uses `openat2` with `RESOLVE_BENEATH` and `RESOLVE_NO_SYMLINKS`, so `..` and symlinks cannot leave it. `file link` is an error.

`event` is the event loop: `after`, `vwait`, `update`, `fileevent`, `interp bgerror`, and the default handler `::tcl::Bgerror`. The time comes only from `Interp.event_host`, a callback of the embedder. One loop serves an interpreter and its children. `clock` also adds the command `time`.

`socket` makes TCP channels on Linux. It needs the channel capability. The embedder sets a network policy in `Interp.net`, and the runner with `--net`:

| Policy | What it allows |
|---|---|
| `loopback` | 127.0.0.0/8 and ::1. This is the default. |
| `allow=LIST` | The rules of the list. A rule is a host name, an address, or an address range such as `10.0.0.0/8` or `[2001:db8::]/32`, with an optional `:port` or `:port-port`. |
| `any` | Each address. |

The command has the options of Tcl: `-server`, `-myaddr`, `-myport`, `-async`, and `fconfigure` with `-sockname`, `-peername`, and `-error`. The policy check runs on each address that a name gives, on the address of the connection after the connect, and on each peer that a server accepts. A server closes a peer that fails the check. With no `-myaddr`, a server with the `loopback` policy listens on both loopback addresses. A child interpreter has the policy of its parent.

A host name resolves through one function. It reads an address literal, the name `localhost`, and the hosts file of the system. It sends no query to a name server yet, so another name is an error.

`exec` adds `exec`, `pid`, and command pipelines (`open "|cmd"`) on Linux. **`exec` is not sandboxed.** A process is outside the root folder and outside the step, memory, and nesting limits, so a script with `exec` has the full power of the user that runs the embedder. `file` does not turn it on. Each program runs directly from its argument list, with no shell. The embedder sets `Interp.exec_host`: a list of allowed programs, a time limit after which the process group is killed, and the whole environment of each program. A background process ends when the interpreter ends. A program name with a `/` names a file below the root folder first.

`coroutine`, `yield`, `yieldto`, and `tailcall` are core commands. `coroutine` needs a stack switch, which exists for x86-64 Linux, arm64 macOS, and x86-64 Windows. On other targets, including WebAssembly, it gives an error.

## Differences from Tcl

- A big integer has at most 2^20 bits.
- `rand()` uses a fixed seed.
- `tcl_platform` has the same fixed values on all platforms.
- `info commands` and `array names` have a fixed order.
- Some errors of core commands still have the error code `NONE`. Arithmetic errors, wrong argument counts, list syntax, and lookups have the codes of Tcl.
- Unicode classes and case maps use a small model of the Unicode tables.
- `Interp.compact` drops traces.
