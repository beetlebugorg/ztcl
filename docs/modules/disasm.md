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

## ::tcl::unsupported::disassemble

`::tcl::unsupported::disassemble proc|lambda|script arg` gives the same bytecode in the shape of the output of Tcl: the `ByteCode` head, `Source`, the counts, the `Proc` line with the slots, the table of `Commands` with the range of instructions and the range of bytes of the source of each command, and the instructions under each `Command n:`. The names of the instructions are the ones of ztcl, so the instructions differ from Tcl. The command exists after `package require ztcl::disasm`. Tcl has no stable form of this output either.

## Not yet

- The machine code of the JIT (tier 1 and tier 2) with the source lines of each range.
- `::tcl::unsupported::assemble` and `ztcl::asm`.
