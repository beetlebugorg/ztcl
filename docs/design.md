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
| `dict.zig` | The `dict` command. |
| `more.zig` | `lset`, `lsort`, `binary`, and `scan`. |
| `regex.zig` | The regular expressions: `regexp`, `regsub`, and the matcher. |
| `ns.zig` | The `namespace` command. |
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
- A dict is a list of keys and values in insert order. It has no hash table yet, so a lookup reads the pairs in order. A list object can have a mark that says its pairs are a valid dict, so a read does not check the keys again.
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

`vm.zig` compiles a parsed script to a flat list of instructions. An instruction has 16 bytes: the operation, a small operand `x`, and three numbers `a`, `b`, and `c`. `run` executes the list on a small stack of values.

What compiles:

- A proc body compiles at the first call. Each plain local name has a slot: its index in `Frame.vars`. The parameters come first. The call makes the other cells with no value.
- A script outside a proc compiles at its second run. Its variables use names, each with a hint, because the frame is not known.
- Each command with a literal name and a known form runs inline: `set`, `incr`, `append`, `lappend`, `expr`, `if`, `while`, `for`, `foreach` with one list, `return`, `break`, `continue`, `dict incr`, and `dict set`.
- A braced expression becomes stack instructions with an integer fast path. The functions and the array elements use the tree of `expr.zig`.
- All other commands push their words and use `invoke`. A word with `{*}` uses the general path.

The instructions:

| Group | Instructions |
|---|---|
| Stack | `push`, `push_empty`, `pop`, `concat` |
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
- An error has a code (`errorCode`). `error msg info code`, `throw`, and `return -code error -errorcode` set it. An error of a core command has the code `NONE`; Tcl gives codes such as `ARITH DIVZERO` there.
- `catch` and `try` use one function (`runCaught`). It gives the code, the result, and the options dict (`-code`, `-level`, `-errorcode`, `-errorinfo`, `-errorline`). `try` selects a handler (`on`, `trap`), runs `finally`, and gives the end of the script again when no handler matches.

## Namespaces

A namespace is a prefix of names (`ns.zig`).

- The command `a::b::f` has the key `a::b::f` in the one command table. The variable `a::b::x` is a global cell with the name `a::b::x`.
- The interpreter has a current namespace. A proc runs in the namespace of its name. A command name is looked up in the current namespace first, then in the global namespace.
- `namespace eval` runs a script in a frame of the namespace. A name that the frame does not have is the variable of the namespace, then the global variable, as in Tcl. A new name becomes a variable of the namespace.
- `uplevel` switches to the namespace of the frame that it goes to.
- A command site keeps the namespace of its lookup, so a script that runs in two namespaces looks its commands up again.
- `namespace import` copies the commands that the source namespace exports. `namespace ensemble create` makes a command that calls the exported commands, the `-subcommands`, or the `-map` words.
- Not there: `namespace path`, `namespace unknown`, `namespace forget`, `namespace ensemble configure`, and the `tcl::mathfunc` and `tcl::mathop` namespaces. `info commands` and `info procs` do not filter by namespace.

## Regular expressions

`regex.zig` compiles a pattern to a small program (`char`, `any`, `set`, `assert`, `save`, `split`, `jmp`, `backref`, `match`). A backtracking matcher runs the program with a stack of its own, so a pattern does not use the native stack.

- Each 32 steps of the matcher use one step of the step limit. `(a*)*b` on a long string stops with the step limit error.
- The backtrack stack has a limit of about one million entries.
- A loop whose body matched no character does not run again, so `(a*)*` ends.
- A repeat count is at most 255, and a program has at most 20 000 instructions.
- Known differences from Tcl: the first alternative that matches wins, where Tcl prefers the longest match; the indexes of `-indices` and `-start` are byte offsets; `-expanded`, lookahead, and the `***` prefixes are not there. A cache with 64 places keeps the compiled patterns.

`regexp`, `regsub`, `switch -regexp` (with `-matchvar` and `-indexvar`), and `lsearch -regexp` use it.

## Strings

A string is UTF-8 bytes. `string length`, `index`, `range`, `replace`, `first`, `last`, and `reverse` count characters. A string of ASCII uses the byte offsets directly. Other strings need a pass over the bytes for each call, so `string index` in a loop over a long string that is not ASCII is slow. `string match`, `string map`, `string tolower`, `string is`, `string wordend`, the regular expressions, and `format %c` still work on bytes.

`binary format` and `binary scan` see a string as bytes: a character below 256 is one byte.

## expr

`expr.zig` parses an expression into a tree and walks the tree. Two integers use a fast path with no string work. Integers are 64 bits and wrap; Tcl continues with big integers, and this interpreter does not. An overflow error was tried and removed, because the passes of `expr.test` fell from 14034 to 1981.

The functions are those of Tcl 8.6, and four additions for zslice: `clamp`, `lerp`, `noise2`, and `noise3`. `rand()` uses a fixed seed.

## Safety and determinism

- The commands `open`, `socket`, `exec`, `file`, `clock`, `source`, `exit`, `cd`, `glob`, `load`, and `after` do not exist. A test checks this.
- `puts` writes to a callback of the embedder.
- Step limit: each command and each loop pass uses one step. At zero, the script stops with an error. `catch` cannot catch this error.
- The nesting of scripts in scripts has a limit (2000 levels): `eval`, a loop body, a command substitution, `try`, `catch`. Before, `set s {eval $s}; eval $s` used up the native stack and crashed the process.
- `lsort` uses a merge sort with its buffer in the arena, so a compare command that sorts again uses little native stack.
- The nested scripts can use at most 5 MiB of native stack (`max_native`). A frame of the bytecode loop is large in a debug build, so the count of levels alone is not safe.
- The nesting of calls has a limit (600 levels). The nesting of command substitutions and of an expression has a limit (200 levels), and an expression has at most 2000 nodes. A deep script gives an error and does not use up the native stack.
- A glob match goes back only to the last `*`. Its time is at most the pattern length times the string length. `string match`, `switch -glob`, `lsearch -glob`, and `dict filter` pay one step of the step limit for each 4096 units of that product.
- A regular expression uses the step limit (see above).
- All memory comes from one arena on the allocator that the embedder gives. `deinit` frees it in one step. The interpreter frees no memory before `deinit` or `reset`, so a script that makes many strings grows the arena.
- A memory limit (`mem_limit`). A counter between the arena and the allocator of the embedder counts the bytes. When the count is above the limit, the next command or loop pass stops the script with the error `the script used too much memory`. `catch` and `try` cannot catch it. One command can go above the limit by the size of its own result, for example one `string repeat`.
- `reset` makes the interpreter new and frees the arena. The limits, the output, the seed, and the data of the embedder stay. The embedder loads its scripts again after a reset. A reset that keeps the commands and frees only the values of one evaluation is not there yet.
- Not bounded yet: the size of one string or list below the fixed limits of `string repeat` and `lrepeat`, and the time of `lsort` and of a dict with many keys (a dict has no hash table).
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

The embedder changes the numbers in `Points.limits`. The seed of `noise2` and `noise3` is `Points.seed` on both paths, and `Interp.noise_seed` for a normal script. The vector code has 4 lanes; 8 lanes were not tried.

Known differences of the two paths: an integer division by zero is an error on the slow path and gives Inf or NaN on the fast path, and integers above 2^53 lose bits on the fast path.
