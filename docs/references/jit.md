# References for the memory work and the JIT

[The JIT design](../jit.md) uses these sources. ztcl has no code of any of them. The plan cites public papers, articles, and documentation. For each project with source code, the authors read only its public articles and documentation for this plan, and no source file.

## Compilers

### A baseline compiler with the frame of the interpreter

Leszek Swirski, "Sparkplug, a non-optimizing JavaScript compiler", the V8 blog, 2021-05-27. https://v8.dev/blog/sparkplug

**License:** Article. V8 is BSD-3-Clause.

**How ztcl uses it:** Tier 1 follows the idea of the article: compile each bytecode instruction in one pass with no intermediate form, keep the state of the interpreter at each instruction boundary, and call shared routines for most of the work. So a switch between the interpreter and the machine code needs no translation of the frame.

### Baseline compilers and speculation with exits

Filip Pizlo, "Speculation in JavaScriptCore", the WebKit blog, 2020-07-29. https://webkit.org/blog/10308/speculation-in-javascriptcore/

**License:** Article. JavaScriptCore is BSD-2-Clause and LGPL.

**How ztcl uses it:** The terms and the structure of tier 2: a guess about a type, a guard, an exit to a lower tier at an instruction boundary, and a record for each exit that gives the place of each value.

### Deoptimization

Urs Hölzle, Craig Chambers, David Ungar, "Debugging Optimized Code with Dynamic Deoptimization", PLDI 1992. https://doi.org/10.1145/143095.143114

**License:** Paper

**How ztcl uses it:** The method of tier 2 exits: compiled code keeps a map to the state of the interpreter at fixed points, and a failed guess makes that state and continues in the lower tier.

### Copy-and-patch

Haoran Xu, Fredrik Kjolstad, "Copy-and-Patch Compilation", OOPSLA 2021. https://doi.org/10.1145/3485513

Brandt Bucher, Savannah Ostrowski, PEP 744, "JIT Compilation", 2024. https://peps.python.org/pep-0744/

**License:** Paper. The PEP is public domain or CC0.

**How ztcl uses it:** Not used. The plan compares it with a template compiler by hand. Copy-and-patch needs Clang or LLVM tools at build time to make the templates, and ztcl builds with the Zig toolchain alone.

### Trace compilers

Andreas Gal and others, "Trace-based Just-in-Time Type Specialization for Dynamic Languages", PLDI 2009. https://doi.org/10.1145/1542476.1542528

Mike Pall, LuaJIT. https://luajit.org/ (MIT)

**License:** Paper. LuaJIT is MIT.

**How ztcl uses it:** Not used. Tier 2 compiles a whole loop with type guesses and records no trace. US patent 8,769,511, "Dynamic incremental compiler and method" (Franz and Gal, filed 2007-02-16, granted 2014-07-01, The Regents of the University of California) describes a trace compiler. The authors of this plan did not check its claims or its legal status. https://patents.google.com/patent/US8769511

### Tcl and types

Brian T. Lewis, "An On-the-fly Bytecode Compiler for Tcl", USENIX Tcl/Tk Workshop 1996. https://www.usenix.org/legacy/publications/library/proceedings/tcl96/lewis.html

**License:** Paper

**How ztcl uses it:** Background for the inline forms of the bytecode and their guards against a redefined command. `docs/design.md` describes the forms of ztcl.

### Floating-point arithmetic

IEEE, "IEEE Standard for Floating-Point Arithmetic", IEEE 754-2019. https://doi.org/10.1109/IEEESTD.2019.8766229

**License:** Standard

**How ztcl uses it:** The cases where `+`, `-`, `*`, and `/` give a NaN from operands that are not a NaN: two infinities of opposite signs for a sum, zero and an infinity for a product, and two zeros or two infinities for a quotient. `nanFree` in `src/jit/tier2_lower.zig` leaves out the NaN check of tier 2 only where none of these cases can happen.

## Memory

### Conservative collection

Hans-Juergen Boehm, Mark Weiser, "Garbage Collection in an Uncooperative Environment", Software: Practice and Experience 18(9), 1988. https://doi.org/10.1002/spe.4380180902

**License:** Paper

**How ztcl uses it:** The method of milestone 0: a collector that does not move a block and treats each word of the stack, the registers, and the live blocks as a possible pointer. ztcl writes its own heap and reads no code of the Boehm collector.

### Mark and sweep

John McCarthy, "Recursive Functions of Symbolic Expressions and Their Computation by Machine, Part I", Communications of the ACM 3(4), 1960. https://doi.org/10.1145/367177.367199

**License:** Paper

**How ztcl uses it:** The mark phase and the sweep phase of the heap.

## Security

### JIT spraying

Dionysus Blazakis, "Interpreter Exploitation: Pointer Inference and JIT Spraying", Black Hat DC 2010.

Michalis Athanasakis and others, "The Devil is in the Constants: Bypassing Defenses in Browser JIT Engines", NDSS 2015. https://doi.org/10.14722/ndss.2015.23209

**License:** Papers

**How ztcl uses it:** The threat model of constants in executable memory. The second paper shows that blinding of only large constants is not enough. The plan puts no value of a script in an instruction.

### JIT memory on Apple systems

Apple, "Porting just-in-time compilers to Apple silicon". https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon

Apple, the manual page `pthread_jit_write_protect_np(3)`.

**License:** Documentation

**How ztcl uses it:** The calls and the rules of the macOS ports: `MAP_JIT`, the write switch of the thread, `sys_icache_invalidate`, and the entitlement `com.apple.security.cs.allow-jit`. The authors read summaries of the first page, because the page did not load as text. Tasks 27 and 28 test each rule on a Mac.

### JIT memory and unwinding on Windows

Microsoft, the documentation of `VirtualAlloc`, `VirtualProtect`, `FlushInstructionCache`, and `RtlAddFunctionTable`, and "x64 exception handling". https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64

**License:** Documentation

**How ztcl uses it:** The calls of the Windows port and the form of the unwind records. Task 29 tests them.

### Memory protection on Linux

The Linux manual pages `mmap(2)`, `mprotect(2)`, and `prctl(2)` (`PR_SET_MDWE`). https://man7.org/linux/man-pages/

**License:** Documentation

**How ztcl uses it:** The calls of the Linux ports and the case of a process that refuses new executable memory.

## Caches of the interpreter

### Method caches

L. Peter Deutsch, Allan M. Schiffman, "Efficient Implementation of the Smalltalk-80 System", POPL 1984. https://doi.org/10.1145/800017.800542

**License:** Paper

**How ztcl uses it:** A method call of TclOO keeps the last call chains of each object, with a number that changes at each change of a class or an object (`oo.zig`). A command site keeps the command of a name word that is not a literal, with the epoch of the command table (`Interp.resolve`). The paper caches the method of a call site and checks the class of the receiver at each call. The idea dates from 1984, so no patent on it is active.

## Calling conventions and instruction sets

"System V Application Binary Interface, AMD64 Architecture Processor Supplement". https://gitlab.com/x86-psABIs/x86-64-ABI

Microsoft, "x64 calling convention". https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention

Arm, "Procedure Call Standard for the Arm 64-bit Architecture (AAPCS64)". https://github.com/ARM-software/abi-aa

Apple, "Writing ARM64 code for Apple platforms". https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms

Intel, "Intel 64 and IA-32 Architectures Software Developer's Manual", volume 2.

Arm, "Arm Architecture Reference Manual for A-profile architecture" (DDI 0487).

**License:** Specifications and manuals

**How ztcl uses it:** The registers, the stack rules, and the instruction encodings of `src/jit/abi.zig`, `src/jit/x64.zig`, and `src/jit/a64.zig`. The assembler of `zig cc` checks each encoding in the tests.

## Tests

### Random programs for differential tests

Xuejun Yang and others, "Finding and Understanding Bugs in C Compilers", PLDI 2011. https://doi.org/10.1145/1993498.1993532

**License:** Paper

**How ztcl uses it:** The method of `tools/jit-fuzz.zig`: make random programs that always end and have defined results, run them in two implementations, and compare.

### A small generator of random numbers

Guy L. Steele Jr., Doug Lea, Christine H. Flood, "Fast Splittable Pseudorandom Number Generators", OOPSLA 2014. https://doi.org/10.1145/2660193.2660195

**License:** Paper

**How ztcl uses it:** `tools/jit-fuzz.zig` makes each choice of a program with the splitmix64 function of the paper. The function is a fixed formula, so a seed gives the same program with each version of the Zig standard library.

### The outside benchmark programs

Kostya M. and contributors, "benchmarks". https://github.com/kostya/benchmarks, commit `5bc68b3705`: `brainfuck/bf.tcl`, `brainfuck/bf_oo.tcl`, `brainfuck/bench.b`, and `base64/test.tcl`.

**License:** MIT

**How ztcl uses it:** `tools/kostya.sh` runs the programs as a performance gate against `tclsh`. The files are not in the ztcl repository. `tools/fetch-kostya.sh` gets them at the commit above.
