# References

ztcl is a Tcl interpreter in Zig. It has no code of Tcl or of another Tcl implementation. It follows the language rules and the command behavior of Tcl, and the test files of Tcl measure it.

## The language and its tests

### The Tcl language and the core commands

Tcl, John Ousterhout and the Tcl Core Team. https://www.tcl-lang.org/ and https://github.com/tcltk/tcl, tag `core-8-6-16`. The rules of the language are in the manual page `Tcl.n` (the "Dodekalogue").

**License:** Tcl/Tk License (BSD style). The terms are in [`licenses/tcl-license.txt`](../../licenses/tcl-license.txt).

**How ztcl uses it:** `src/interp.zig` implements the 12 rules of `Tcl.n`. The commands of `src/cmds.zig`, `src/expr.zig`, and `src/format.zig` give the results and the error messages of Tcl 8.6, so that a script for Tcl runs the same. The results in `src/tests.zig` come from `tclsh` 8.6.16. The authors read the manual pages and the output of `tclsh`. It copies no C code of Tcl.

### The test files of Tcl

The `tests/*.test` files of the Tcl source. https://github.com/tcltk/tcl/tree/core-8-6-16/tests

**License:** Tcl/Tk License (BSD style)

**How ztcl uses it:** `tools/suite.sh` runs the test files on the Zig interpreter and prints the counts for each file. The files are not in the ztcl repository; the script reads them from a copy of the Tcl source. `tools/tcltest.tcl` is a new, small stand-in for the `tcltest` package (the `test`, `testConstraint`, and `cleanupTests` commands). It has no code of the package.

## Methods

### Gradient noise

Ken Perlin, "Improving Noise", SIGGRAPH 2002. https://doi.org/10.1145/566654.566636

**License:** Paper

**How ztcl uses it:** `src/noise.zig` uses the method of the paper: a gradient at each corner of the cell from 12 edge directions, and the fade curve 6t^5 - 15t^4 + 10t^3. ztcl has its own code, and uses a hash of the corner in place of the table of the paper.

### A regular expression as a small program

Russ Cox, "Regular Expression Matching: the Virtual Machine Approach", 2009. https://swtch.com/~rsc/regexp/regexp2.html

**License:** Article

**How ztcl uses it:** `src/regex.zig` compiles a pattern to the instruction set of the article (`char`, `split`, `jmp`, `save`, `match`) and runs it with a backtracking matcher. ztcl has its own code. It adds the sets, the assertions, the back references, a check that stops an empty loop, and the step limit. The syntax follows the manual page `re_syntax.n` of Tcl.

## Not used

Jim Tcl (https://jim.tcl-lang.org/, BSD 2-Clause) is a small Tcl in C. The authors did not read its source for this interpreter, and ztcl has no code of it.

## Code in the binaries

The ztcl binaries contain the Zig standard library. It has ports of code from other projects. The license texts are in `licenses/`.

| Source | Use | License text |
|---|---|---|
| Zig standard library | All of ztcl | `licenses/zig-std-MIT.txt` |
| musl libc | Math functions of `std.math` | `licenses/musl-MIT.txt` |
| Go | `std.fmt.parseFloat`, `std.math.pow` | `licenses/go-BSD-3-Clause.txt` |
| ARM optimized-routines | `std.math.acos`, `std.math.atan` | `licenses/arm-optimized-routines.txt` |

## Origin

The authors wrote ztcl in the zslice source tree and moved it to this repository. ztcl uses no other zslice code.
