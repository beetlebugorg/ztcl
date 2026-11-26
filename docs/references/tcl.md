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

**How ztcl uses it:** `tools/suite.sh` runs the test files on the Zig interpreter and prints the counts for each file. The files are not in the ztcl repository; the script reads them from a copy of the Tcl source. `tools/tcltest.tcl` is a new, small stand-in for the `tcltest` package (the `test`, `testConstraint`, `customMatch`, and `cleanupTests` commands). It has no code of the package. `tools/suite-count.tcl` counts the tests of each file with a `tclsh`.

### The commands added for the test files

The manual pages `trace.n`, `namespace.n`, `mathop.n`, `mathfunc.n`, `prefix.n`, `array.n`, `subst.n`, `try.n`, and `binary.n` of Tcl 8.6.16.

**License:** Tcl/Tk License (BSD style)

**How ztcl uses it:** `src/trace.zig`, `src/ns.zig`, `src/mathns.zig`, `src/extra.zig`, and `src/more.zig` follow the behavior in these pages, the results of `tclsh` 8.6.16, and the expected results of the test files. They have no C code of Tcl.

### Unicode character classes

The Unicode Character Database. https://www.unicode.org/ucd/

**License:** Unicode License

**How ztcl uses it:** `src/ucd.zig` is a small hand-written model of the classes and the simple case maps for the common blocks. It has no copy of the data files.

## Methods

### Gradient noise

Ken Perlin, "Improving Noise", SIGGRAPH 2002. https://doi.org/10.1145/566654.566636

**License:** Paper

**How ztcl uses it:** `src/noise.zig` uses the method of the paper: a gradient at each corner of the cell from 12 edge directions, and the fade curve 6t^5 - 15t^4 + 10t^3. ztcl has its own code, and uses a hash of the corner in place of the table of the paper.

### Longest match and the split of a span

Henry Spencer, the regular expression package of Tcl, described in `re_syntax.n` and in `generic/regexp` documentation of the Tcl source.

**License:** BSD style

**How ztcl uses it:** `src/regex.zig` uses the idea of two phases: find the span of the match, then split the span over the parts of the pattern. It has its own code and no code of that package.

### A regular expression as a small program

Russ Cox, "Regular Expression Matching: the Virtual Machine Approach", 2009. https://swtch.com/~rsc/regexp/regexp2.html

**License:** Article

**How ztcl uses it:** `src/regex.zig` compiles a pattern to a program of the kind in the article (`char`, `split`, `jmp`, `match`) and runs it with a Thompson simulation. ztcl has its own code. It adds the sets, the assertions, lookahead, and the compute limit. The syntax follows the manual page `re_syntax.n` of Tcl.

### Copying collection

C. J. Cheney, "A Nonrecursive List Compacting Algorithm", Communications of the ACM 13(11), 1970. https://doi.org/10.1145/362790.362798

**License:** Paper

**How ztcl uses it:** `src/compact.zig` uses the idea of the paper: it copies the reachable objects to a new space with no recursion and keeps a map from each old object to its copy. ztcl has its own code, and uses a work list in place of the scan pointer of the paper.

### Hash tables with linear probing

Donald E. Knuth, The Art of Computer Programming, Volume 3, section 6.4.

**License:** Book

**How ztcl uses it:** `src/dict.zig` uses open addressing with linear probing. ztcl has its own code. The hash function is `std.hash.Wyhash` of the Zig standard library.

### Copy on write with one holder

The manual page `Object.3` of Tcl 8.6 (`Tcl_IsShared`, `Tcl_DuplicateObj`). https://www.tcl-lang.org/man/tcl8.6/TclLib/Object.htm

**License:** Tcl/Tk License (BSD style)

**How ztcl uses it:** Tcl counts the references of a value and changes a list in place when the count is one. ztcl has no counts. A cell owns its list after the first `lset`, and the compiler keeps the ownership when the bytecode proves that no other place gets the list: a load that an `access` reads at once, and a result that no code reads (`src/vm.zig`). The authors read the manual page and copied no code.

### Big integer arithmetic

`std.math.big.int` of the Zig standard library.

**License:** MIT. The text is in `licenses/zig-std-MIT.txt`.

**How ztcl uses it:** `src/bigint.zig` calls it for the arithmetic. The results and the error messages follow `tclsh` 8.6.16.

### Substring search

R. Nigel Horspool, "Practical fast searching in strings", Software: Practice and Experience 10(6), 1980.

**License:** Paper

**How ztcl uses it:** `string first` and `string last` in `src/cmds.zig` use the skip table of the paper, forward and in reverse. ztcl has its own code. Each compare of the needle uses units of the compute limit.

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
