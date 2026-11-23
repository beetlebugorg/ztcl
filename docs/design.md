# Design

ztcl uses only the Zig standard library. [References](references/tcl.md) lists the sources that it follows.

## The files

| File in `src/` | What it has |
|---|---|
| `ztcl.zig` | The root of the module. |
| `value.zig` | The values, the number forms, and the list form. |
| `interp.zig` | The parser, the parsed form, the frames, and the general evaluator. |
| `vm.zig` | The bytecode: the compiler and the instruction loop. |
| `expr.zig` | The expression language: the parser and the evaluator. |
| `cmds.zig` | The core commands. |
| `format.zig` | The `format` command. |
| `dict.zig` | The `dict` command and its hash table. |
| `bigint.zig` | Integers above 64 bits. |
| `compact.zig` | The reset that keeps the commands. |
| `more.zig` | `lset`, `lsort`, `binary`, and `scan`. |
| `regex.zig` | The regular expressions: `regexp`, `regsub`, and the matcher. |
| `ns.zig` | The `namespace` command, ensembles, and the unknown handler. |
| `mathns.zig` | The commands of `tcl::mathop` and `tcl::mathfunc`. |
| `extra.zig` | `array`, `case`, `tcl::prefix`, and the word boundary procs. |
| `trace.zig` | The `trace` command and the traced cell form. |
| `coro.zig` | `coroutine`, `yield`, `yieldto`, and `tailcall`. |
| `clock.zig` | The optional `clock` command and a small `msgcat`. |
| `fsroot.zig` | The root folder jail of `file` and channels. |
| `fsroot_windows.zig` | The Windows form of that jail. |
| `chan.zig` | The optional channel commands and `source`. |
| `sys.zig` | The platform interface of channels, the event loop, and `socket`. |
| `sys_windows.zig` | The Windows form of that interface, with Winsock. |
| `event.zig` | The optional event loop: `after`, `vwait`, `update`, and `fileevent`. |
| `sock.zig` | The optional `socket` command and its network policy. |
| `enc.zig` | The `encoding` command of the channel capability. |
| `oo.zig` | TclOO: classes, objects, methods, `next`, mixins, and filters. |
| `proc.zig` | The optional `exec`, `pid`, and command pipelines. |
| `filecmd.zig` | The optional `file`, `glob`, `cd`, and `pwd`. |
| `pkg.zig` | The optional `package` command. |
| `child.zig` | The optional `interp` command. |
| `ucd.zig` | A small model of Unicode classes and case maps. |
| `noise.zig` | The gradient noise of `noise3`. |
| `point.zig` | The point procs: the check, the vector program, and both paths. |
| `main.zig` | The runner. |
| `tests.zig` | The tests of the language and the commands. |
| `wasm.zig` | The WebAssembly interface. |

## Values

A value is a tagged union: an integer (64 bits), a double, a string, or a list.

- A script cannot see the tag. Each kind has one exact string form, and `toStr` makes the string only on demand.
- A literal keeps its text. `0x10` stays the string `0x10` until a command reads it as a number. A literal that is a canonical decimal integer becomes an int at parse time, because its string form is the same text.
- A computed number is an int or a double. A double prints with the shortest digits that read back to the same double, as Tcl 8.6 does.
- A list is a view of the first `len` elements of a shared buffer. `lappend` writes after the view when the view ends at the used part of the buffer, so an append is amortized constant time. Other views of the buffer stay correct.
- A dict is a list of keys and values in insert order. A list object can have a mark that says its pairs are a valid dict, so a read does not check the keys again. A shorter view of even length of a marked buffer is also a valid dict.
- A dict with 16 or more keys has a hash table with open addressing and linear probing. The table maps the hash of the string form of a key to its position. A new key goes after the view when the view ends at the used part of the buffer, so a new key is amortized O(1). An older view stays the same value, because a lookup ignores positions past its end. A write to an existing key of a shared dict copies the buffer.
- A big integer is a string with canonical decimal text. An integer that fits in 64 bits is always an `int`. The integer operators check for overflow and call `bigint.zig` only on an overflow. The decimal text comes from repeated division of the limbs by 10^19, with a multiply by the reciprocal in place of a hardware divide. The parse of decimal text multiplies the limbs by 10^19 and adds 19 digits at each step.
- `llength` and `lindex` keep the parse of a string in a table with 16 places. A string of at least 32 bytes goes in the table at its second read at the same address. An entry has a private copy of the text, and each hit compares the string with that copy.
- `append` writes after the string when the string ends at the used part of its buffer. Other views of the buffer stay correct, because their bytes do not change.

## The parser and the compiled form

The parser follows the 12 rules of the Tcl language. It reads a script once and makes a `Script`:

- A `Script` is a list of commands.
- A command is a list of words, the line, and the source text (for the error trace).
- A word is a literal value, one substitution, or a sequence of parts. A part is a literal text, a variable (with the parts of an array index), or a nested script.

Each word of a command has a cache slot. A command such as `while` asks the interpreter for the compiled script or the compiled expression of an argument. If the argument is a literal word, the result stays in the slot. A loop body, a proc body, and a braced `expr` are parsed one time.

A command site also keeps the command that its name gave. The interpreter has an epoch number that changes when a command is added, renamed, or deleted. The site looks the name up again when the epoch differs.

### The direct forms and the slot hints

The general path uses these steps for a command that is not in bytecode:

- A direct form. When a command site with a literal name gives `set`, `incr`, `expr`, or `if`, the site keeps a tag (`Fast`). `evalCmd` then reads the literal words of the site directly. It makes no word stack, no string of the variable name, and no call of the command function. The tag is valid for the same epoch and the same namespace, so a `rename` of `set` still works.
- A slot hint. Each variable reference (`$x` in a word or in an expression, and the name of a direct `set` or `incr`) keeps the slot of the name in the frame at the last use. The reader checks the name of that slot, and searches the frame only when the name differs. A proc makes its variables in the same order on each call, so the hint is correct almost each time.
- An integer operand. A binary operator of `expr` reads an integer constant or an integer variable from its cell. It makes no copy of the value. The copy of a 32-byte value through a small temporary cost about 12 cycles for each operand before.

A string that is not a literal word (for example the argument of `eval`) uses a table from the address and length of the string to the compiled form. Strings live in the arena and do not change, so the address and the length name the text.

## The bytecode

`vm.zig` compiles a parsed script to a flat list of instructions. An instruction has 16 bytes: the operation, a small operand `x`, and three numbers `a`, `b`, and `c`. `run` executes the list on a small stack of values. A labeled switch dispatches the next instruction from the end of most handlers, so each handler has its own indirect branch.

What compiles:

- A proc body compiles at the first call. Each plain local name has a slot: its index in `Frame.vars`. The parameters come first. The call makes the other cells with no value.
- A script outside a proc compiles at its second run. Its variables use names, each with a hint, because the frame is not known.
- Each command with a literal name and a known form runs inline: `set`, `incr`, `append`, `lappend`, `expr`, `if`, `while`, `for`, `foreach` with one list, `return`, `break`, `continue`, `dict incr`, `dict set`, `llength`, `lindex` with one index, `string length`, and `string index`.
- A braced expression becomes stack instructions with an integer fast path. The functions and the array elements use the tree of `expr.zig`.
- All other commands push their words and use `invoke`. A word with `{*}` uses the general path.

The instructions:

| Group | Instructions |
|---|---|
| Stack | `push`, `push_empty`, `pop`, `concat` |
| Reads | `access` |
| Variables | `load`, `store`, `store_pop`, `incr`, `incr_drop`, `incr_value`, `append`, `lappend`, `dict_update`, `dict_update_drop` |
| Operators | `binary`, `unary`, `to_bool`, `number_form`, `bin_vv`, `bin_vi` |
| Control | `guard`, `step`, `jump`, `jump_false`, `jump_true`, `jf_vv`, `jf_vi`, `foreach_init`, `foreach_next`, `ret` |
| General path | `invoke`, `eval_cmd`, `word`, `node` |

The semantics of Tcl stay:

- A guard starts each inline form. It checks that each inlined name is the original core command and that no namespace has a command of that name. The check runs one time for each change of the command epoch.
- When the guard fails, it jumps to a cold block after the end of the code. The cold block runs the command on the general path, so `rename set foo` and a proc named `incr` work.
- `upvar`, `global`, `variable`, `uplevel`, and `info locals` use the same cells in `Frame.vars`. A slot can hold a link to a cell of another frame.
- A table of ranges maps an address to its commands and loops. An error adds each enclosing command to `errorInfo`. A `break` or a `continue` from a general command goes to the innermost loop.
- A cell can own a dict. `dict incr` or `dict set` with a dropped result then writes to the buffer in place. Each general read of the cell ends the ownership first, so a copy of the value never changes.
- The guard, each loop pass, and each `invoke` use one step of the step limit and check the memory limit.

## The evaluator

- The words of a command go on a stack of values, in chunks. A command returns its stack space when it ends. A loop with integer math allocates no memory.
- A proc call makes a frame. A frame is a small array of names and variable cells. Frames and cells go back to a free list when the call ends.
- `upvar` and `global` make a cell that links to another cell.
- The return codes are Zig errors: `TclError`, `TclReturn`, `TclBreak`, and `TclContinue`. The result of the interpreter holds the message or the value. `return -code` and `return -level` set the code and the level of a pending return.
- A return code above 4 (`return -code 5`) is the error `TclCustom`, with the number in `custom_code`.
- An error builds the trace in `errorInfo`, in the form of Tcl: the message, `while executing`, the command, the procedure and line, and `invoked from within`.
- An error has a code (`errorCode`). `error msg info code`, `throw`, and `return -code error -errorcode` set it. Arithmetic errors, wrong argument counts, list syntax errors, and lookups have the codes of Tcl, such as `ARITH DIVZERO`. Other errors of core commands have the code `NONE`.
- `catch` and `try` use one function (`runCaught`). It gives the code, the result, and the options dict (`-code`, `-level`, `-errorcode`, `-errorinfo`, `-errorline`). `try` selects a handler (`on`, `trap`), runs `finally`, and gives the end of the script again when no handler matches.

## Namespaces

A namespace is a prefix of names (`ns.zig`).

- The command `a::b::f` has the key `a::b::f` in the one command table. The variable `a::b::x` is a global cell with the name `a::b::x`.
- The interpreter has a current namespace. A proc runs in the namespace of its name. A command name is looked up in the current namespace first, then in the global namespace.
- `namespace eval` runs a script in a frame of the namespace. A name that the frame does not have is the variable of the namespace, then the global variable, as in Tcl. A new name becomes a variable of the namespace.
- `uplevel` switches to the namespace of the frame that it goes to.
- A command site keeps the namespace of its lookup, so a script that runs in two namespaces looks its commands up again.
- `namespace import` copies the commands that the source namespace exports. `namespace ensemble create` makes a command that calls the exported commands, the `-subcommands`, or the `-map` words.
- `namespace path` adds namespaces to the command lookup. A name with no command goes to the `namespace unknown` handler, and then to `::unknown`.
- An import is a second key in the command table for one `Command`. The `name` field of the command gives its origin, so `namespace origin`, `rename`, and a delete follow the import.
- An ensemble has `-map`, `-subcommands`, `-parameters`, `-prefixes`, `-unknown`, and `configure`.
- `tcl::mathop` and `tcl::mathfunc` are namespaces of native commands. `expr` calls a function that a script defined in `tcl::mathfunc`. The parser selects the function when it compiles the expression, so a replacement after that compile has no effect on that expression.

## Regular expressions

`regex.zig` parses a pattern to a tree. It accepts the advanced, extended, basic, and literal syntaxes of `re_syntax.n`, with the embedded options, lookahead, and back references.

- A Thompson simulation finds the leftmost match and its longest end, or its shortest end when the first quantifier is non-greedy. Its time is the program size times the text length.
- A second pass splits the known span over the tree to find the capture groups. Each part of a concatenation takes the longest or shortest length that leaves a match for the rest. A table of failed spans keeps this pass polynomial.
- A pattern with a back reference has no simulation. It searches with the second pass alone, and the step limit bounds it.
- Each 32 steps of a matcher use one step of the step limit. A repeat count is at most 255, and a program has at most 40 000 instructions.
- Positions count characters. A cache with 64 places keeps the compiled patterns.

`regexp`, `regsub`, `switch -regexp` (with `-matchvar` and `-indexvar`), and `lsearch -regexp` use it.

## Strings

A string is UTF-8 bytes. The `string` subcommands and glob patterns work on characters. A string of ASCII uses the byte offsets directly. Other strings need a pass over the bytes for each call, so `string index` in a loop over a long string that is not ASCII is slow. `string map`, the regular expressions, and `format %c` still work on bytes. `ucd.zig` is a small model of Unicode classes and case maps. It covers ASCII, Latin, Greek, Cyrillic, the space characters, and the common punctuation blocks.

`binary format` and `binary scan` see a string as bytes: a character below 256 is one byte.

## expr

`expr.zig` parses an expression into a tree and walks the tree. Two integers use a fast path with no string work. An integer that overflows 64 bits continues as a big integer, as in Tcl. A big integer has at most 2^20 bits. An operation on big integers uses steps of the step limit by the square of its size.

The functions are those of Tcl 8.6, and four additions for zslice: `clamp`, `lerp`, `noise2`, and `noise3`. `rand()` uses a fixed seed.

## Traces and element links

A variable with a trace has the cell form `.traced`, and `upvar a(i) x` makes the cell form `.elem`. The fast paths of the bytecode read only `.val`, so a read of these forms goes to the general path. A store checks the tag with one compare (`Var.plainStore`). While `var_traces` is above zero, the inline forms are off, and `foreach` stores through `setVar`. A command with an execution trace has a wrapper as its function, so a call of another command has no added cost. `tcl_precision` is a `.traced` cell that does not count in `var_traces`. Its write check sets the precision of the double output.

## Coroutines and tail calls

A coroutine has its own native stack, word stack, and frame chain. An exported assembly routine switches the stack on x86-64 Linux, arm64 macOS, and x86-64 Windows. The resumer swaps the fields of the interpreter around each switch. `max_native` is half of the stack of the coroutine. `compact` gives `InterpBusy` while a coroutine is suspended.

`tailcall` ends the proc with a private return code. The proc call then runs the command in a loop, so a chain of tail calls uses no native stack.

## Capabilities

`Interp.allow` turns on optional commands. The default interpreter has none. A child interpreter allocates through the counter of its parent, so the parent limit counts it. A call into a child passes the step limit, the nesting counts, and the native stack base. A child that is deleted while it runs is freed when the last call leaves it. `compact` gives `InterpBusy` for an interpreter with capabilities.

### The event loop

One loop serves an interpreter and its children (`event.zig`). The state has the timers, the idle scripts, and the channels with a handler. One pass waits until a timer is due or a descriptor is ready, runs the due timers in the order of their times, runs the handlers of the ready channels, and runs the idle scripts when no other script ran. A script of the pass cannot make the pass longer: a new timer or idle script runs in a later pass. Each script runs at the global level of its interpreter. An error goes to the handler of `interp bgerror` as an idle entry. `vwait` adds a trace to the variable that sets a flag and runs no script.

A channel that does not block keeps output that the peer has no room for. The loop writes the rest when the descriptor is ready. A close of such a channel keeps the descriptor under a hidden name until the output is gone.

### Sockets and processes

`sock.zig` has the network policy: `loopback`, a list of rules, or `any`. `sys.resolve` is the only name lookup. `sock.zig` checks each address against the policy before `sys.listenAt` or `sys.connectTo`, checks the peer address of a new connection again, and checks each peer that a server accepts. `proc.zig` starts each pipeline as one process group and keeps the groups of background pipelines. The interpreter sends SIGKILL to each group when it ends, at the time limit of the embedder, and at a failed start. `exec` is not sandboxed.

### The platform interface

`sys.zig` has the host operations of channels, the event loop, and `socket`: read, write, close, seek, poll, the blocking mode, and the loopback socket calls. `fsroot.zig` has the root folder jail, and `proc.zig` has the process calls. These files have the Linux forms. A port to another system writes the same functions again.

## Safety and determinism

- In the default interpreter the commands `open`, `socket`, `exec`, `file`, `clock`, `source`, `cd`, `glob`, `after`, `vwait`, and `update` do not exist. The library has no `exit` and no `load`. A test checks this.
- `puts` writes to a callback of the embedder.
- Step limit: each command and each loop pass uses one step. At zero, the script stops with an error. `catch` cannot catch this error.
- The nesting of scripts in scripts has a limit (2000 levels): `eval`, a loop body, a command substitution, `try`, `catch`. Before, `set s {eval $s}; eval $s` used up the native stack and crashed the process.
- `lsort` uses a merge sort with its buffer in the arena, so a compare command that sorts again uses little native stack.
- The nested scripts can use at most 5 MiB of native stack (`max_native`). A frame of the bytecode loop is large in a debug build, so the count of levels alone is not safe.
- A call of `subst`, an ensemble, or the unknown handler counts as one level of nesting.
- The nesting of calls has a limit (600 levels). The nesting of command substitutions and of an expression has a limit (200 levels), and an expression has at most 2000 nodes. A deep script gives an error and does not use up the native stack.
- A glob match goes back only to the last `*`. Its time is at most the pattern length times the string length. `string match`, `switch -glob`, `lsearch -glob`, and `dict filter` pay one step of the step limit for each 4096 units of that product.
- A regular expression uses the step limit (see above).
- All memory comes from one arena on the allocator that the embedder gives. `deinit` frees it in one step. The interpreter frees no memory before `compact`, `reset`, or `deinit`, so one evaluation that makes many strings grows the arena.
- A memory limit (`mem_limit`). A counter between the arena and the allocator of the embedder counts the bytes. When the count is above the limit, the next command or loop pass stops the script with the error `the script used too much memory`. `catch` and `try` cannot catch it. One command can go above the limit by the size of its own result, for example one `string repeat`.
- `reset` makes the interpreter new and frees the arena. The limits, the output, the seed, and the data of the embedder stay. The embedder loads its scripts again after a reset.
- `compact` frees the memory of past evaluations and keeps the commands, procs, namespaces, point programs, and variables. It copies them to a new arena and frees the old arena. The embedder lists each value that must stay valid in `roots`, and each root gets its new address. All other values from before the call are invalid. The compiled forms stay behind, so a proc compiles again at its next call. A shared list stays shared, and overlapping strings copy once. After an allocation error the interpreter stays as it was. A call inside a running script returns `error.InterpBusy`. During the call, the old and the new arena both exist.
- Not bounded yet: the size of one string or list below the fixed limits of `string repeat` and `lrepeat`, and the time of `lsort`.
- `tcl_platform` has the same fixed values on all platforms.
- `info commands` and `array names` have a fixed order.

## Point procs: the fast path

`point proc name {fields} {body}` makes two things from one body.

1. A normal proc. `point.runSlow` calls it once for each point. This is the slow path, for tests of one point.
2. A vector program. `Program.run` runs it over points in a struct of arrays (`x[]`, `y[]`, `z[]`, the feature numbers, and the output arrays).

The check accepts only numbers, local `set`, `if` / `elseif` / `else`, `return` with no value, `expr` with the math functions, `noise3` and `noise2`, a compare of the feature with a name, and the output commands (`offset`, `move`, `width`, `flow`, `speed`, `skip`). For all other code, it gives an error with the line and the reason when the script loads.

The vector program:

- Each value is a register: one f64 for each point of a block of 1024 points.
- Each operation runs over the whole block, so the cost of the interpreter is paid once for each block. The compiler of Zig turns the simple loops into SIMD code.
- A register of an input field points into the input column, so the field has no copy. When an output column overlaps an input column, the field is copied to its register.
- An `if` makes a mask register. A `set` or an output in a branch is a select between the new value and the old value. A `return` adds the mask of its branch to the mask of the points that returned.
- `noise3` skips the points outside the mask.
- The check tracks if a value is an integer or a double in the normal interpreter. Two integers divide as integers on both paths. The check refuses a division where the kind differs between points.
- A program is read-only when it runs. Two threads can run one program, each with its own scratch memory.

A test runs the fuzzy skin proc, and a second proc with branches, on both paths and compares all outputs bit for bit.

Both paths apply the same limits to the outputs at the end (`point.bound`), so the bits stay equal. The unit is the line width of the point (the `width` input, or 0.4 when the points have no width). The rule, for each point:

- An output that is not finite becomes its start value: 0, or the width input for `width`.
- `offset` stays in -1 to 1 line widths.
- The vector of `move` keeps its direction, and its length is at most one line width.
- `width` stays between 0.25 and 2 times the width input.
- `flow` and `speed` have no limit yet.

The embedder changes the numbers in `Points.limits`. The seed of `noise2` and `noise3` is `Points.seed` on both paths, and `Interp.noise_seed` for a normal script. The noise code has 8 lanes in two AVX2 registers, with each hash in a 64-bit lane. It keeps the 8 corner hashes of the last group of points and uses them again when the next group is in the same cells.

Known differences of the two paths: an integer division by zero is an error on the slow path and gives Inf or NaN on the fast path, and integers above 2^53 lose bits on the fast path.
