# Module ztcl::disasm

`ztcl::disasm` shows the bytecode of a proc, a lambda, or a script: each instruction under the source line of its command. Use it to see what a body compiled to, and why a body is fast or slow. It reads only: it changes no proc and runs no code of the target.

The bytecode is the form of this release. It can change with any release, so do not parse it in a program that must work with the next release.

The module needs no capability. It is in each native build and in the WebAssembly shell of the site (`ztcl-shell.wasm`). The WebAssembly library `ztcl.wasm` leaves it out, for its size limit.

<!-- run -->
```tcl
package require ztcl::disasm
proc twice {x} {
    set y [expr {$x * 2}]
    return $y
}
puts [lindex [split [ztcl::disasm proc twice] \n] 0]
```

```text
twice: instructions 15, literals 1, slots 2, stack 2, jit after more calls
```

## Try it

<!-- shell -->
```tcl
package require ztcl::disasm
proc twice {x} {
    set y [expr {$x * 2}]
    return $y
}
```

Type `ztcl::disasm proc twice`, or `ztcl::disasm script {foreach i {1 2 3} {incr n $i}}`.

## Commands

### ztcl::disasm proc name

Gives the listing of the body of the proc. A proc that did not run yet compiles now, as at its first call. The listing has these lines:

- The head: the name, the count of instructions, of literals, and of slots, the depth of the stack, and the state of the JIT: `compiled`, `after more calls`, `not compiled` (the JIT cannot compile the body), `off (probes)` (a probe is on the proc, so the body runs in the bytecode interpreter), or `none in this build` (WebAssembly has no JIT).
- One line for each slot: its number and its variable. The parameters come first.
- `# line n: "text"` before the first instruction of each command: the line of the command in its own script, and its text. The line counts from the start of the body. A command in another command, such as the `expr` in `set y [expr ...]`, has its own line.
- One line for each instruction: its number, its operation, and its three operands. A note after `#` gives the literal of a `push`, the variable of a slot, the command of an `invoke`, or the target of a jump.

### ztcl::disasm lambda lambda

Gives the listing of a lambda of `apply`: a list of the parameters and the body, and an optional namespace.

### ztcl::disasm script text

Gives the listing of a script that runs outside a proc, as the body of `eval` or `uplevel`. Its variables are names, so it has no slot of a local variable.

### ztcl::disasm machine proc|lambda|script arg

Gives the machine code of the JIT for the body, under each instruction of the bytecode. The JIT assembles the body again for the listing, into memory that never runs, so the command works also for a body that did not run yet. The listing is for the target of the host, x86-64 or arm64. The listing has these parts:

- The head: the name, `tier 1`, the target, the count of bytes, and the state of the JIT, as in the bytecode listing.
- `# entry and exit` before the code of the entry and the exit of the function.
- Each command line and each instruction of the bytecode, as in the bytecode listing, with its machine code under it. A line of machine code has the offset, the bytes, and the instruction. A call of a helper of the JIT names the helper after `;`.
- `# out of line: n op` before a part of instruction `n` that is out of the main path: a slow path, an error stub, or the check of a cell.
- After the tier 1 code, the tier 2 code of each loop that tier 2 can compile, with the head `tier 2, the loop at n`. Tier 2 compiles a loop for the kinds of its variables at the entry of the loop, and the listing uses an integer in each variable.

The disassembler decodes only the instruction forms that the JIT emits, and it checks each instruction: it encodes the instruction again with the assembler of the JIT and compares the bytes. A byte that is not a form of the JIT shows as `.byte` (x86-64) or `.word` (arm64). A build with no JIT, such as WebAssembly, gives an error.

```tcl
ztcl::disasm machine proc twice
```

## ::tcl::unsupported::disassemble

`::tcl::unsupported::disassemble proc|lambda|script arg` gives the same bytecode in the shape of the output of Tcl: the `ByteCode` head, `Source`, the counts, the `Proc` line with the slots, the table of `Commands` with the range of instructions and the range of bytes of the source of each command, and the instructions under each `Command n:`. The names of the instructions are the ones of ztcl, so the instructions differ from Tcl. The command exists after `package require ztcl::disasm`. Tcl has no stable form of this output either.

## Not yet

- The tier 2 code of a loop for the kinds of its variables in a run, in place of an integer in each variable.
- `::tcl::unsupported::assemble` and `ztcl::asm`.
