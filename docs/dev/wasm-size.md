# The size of the WebAssembly library

This page shows where the bytes of `ztcl.wasm` are, and ranks 8 changes that make the download smaller. The page changes no code of the library. Each change has an issue with the same text. [perf-ideas.md](perf-ideas.md) is the page for speed.

## Method

- Date: 2026-11-26. Commit: `cb80459`. Zig 0.17.0, `zig build wasm` (ReleaseSmall, wasm32-freestanding).
- `tools/wasm-size.py` reads a module and prints the sections, the exports, the code bytes for each group of functions, the largest functions, and the data segments. It is in this change. A group is the first part of a function name: the source file for the code of ztcl (`cmds` is `src/cmds.zig`), or the first namespace of a library (`terminal` is libghostty-vt, `fmt` is `std.fmt`).
- The build strips the name section. For the tables below, the module was built one time with `.strip = false` in `addWasmForm` of `build.zig`. The code section of that build has 80 bytes fewer than the code of the stripped build.
- Compressed sizes: `gzip -9`, `brotli -q 11`, and `zstd -19`.
- `wasm-opt` 133 of Binaryen measured what a post-link pass can save. It is a reference for the measure only. ztcl does not use it in a build.

```sh
zig build wasm
python3 -I tools/wasm-size.py zig-out/lib/ztcl.wasm
python3 -I tools/wasm-size.py zig-out/lib/ztcl.wasm --match fmt.
```

## The baseline

| Library | Bytes | gzip -9 | Brotli 11 |
|---|---|---|---|
| `ztcl.wasm` | 1,475,011 | 504,650 | 378,061 |
| `ztcl.wasm` with `-Dbatteries=core` (no `vt`, no `json`, no `hello`) | 852,460 | 306,493 | 237,920 |
| `ztcl-shell.wasm` | 1,532,618 | 527,242 | 395,440 |

`zstd -19` gives 406,258 bytes for `ztcl.wasm`. The libraries with threads were not built for this page.

### Sections of `ztcl.wasm`

| Section | Bytes |
|---|---|
| code | 1,204,400 |
| data | 267,371 |
| function, type, element, export, and the rest | 3,206 |

The module has 1,738 functions and 20 exports (17 functions, the memory, the stack pointer, and one global).

### Code for each group

| Group | Bytes | Share of the code | Functions |
|---|---|---|---|
| `terminal` (libghostty-vt) | 252,118 | 21.0 % | 363 |
| `cmds` | 122,378 | 10.2 % | 69 |
| `json` | 95,232 | 7.9 % | 58 |
| `vm` | 83,911 | 7.0 % | 48 |
| `interp` | 77,406 | 6.4 % | 183 |
| `oo` | 76,689 | 6.4 % | 63 |
| `ns` | 42,328 | 3.5 % | 16 |
| `regex` | 37,839 | 3.1 % | 47 |
| `vt` (the commands of `ztcl::vt`) | 36,024 | 3.0 % | 11 |
| `more` | 30,170 | 2.5 % | 15 |
| `expr` | 30,024 | 2.5 % | 31 |
| `trace` | 24,923 | 2.1 % | 20 |
| `pkg` | 24,217 | 2.0 % | 12 |
| `dict` | 24,080 | 2.0 % | 20 |
| `fmt` (`std.fmt`, the part that is not inlined) | 23,183 | 1.9 % | 70 |
| `extra` | 21,198 | 1.8 % | 13 |
| `math` | 20,875 | 1.7 % | 58 |
| `array_hash_map` | 20,664 | 1.7 % | 53 |
| `mathns` | 17,480 | 1.5 % | 55 |
| Each other group | 140,673 | 11.7 % | 533 |

### The largest functions

| Function | Bytes |
|---|---|
| `json.build.Stream.refill` | 47,842 |
| `cmds.cmdInfo` | 32,627 |
| `vm.exec` (two forms) | 54,716 |
| `ns.cmdNamespace` | 23,810 |
| `cmds.cmdString` | 20,691 |
| `vt.cmd` | 19,579 |
| `terminal.stream.Stream(...).nextNonUtf8` | 18,456 |
| `pkg.cmdPackage` | 17,693 |
| `dict.cmdDict` | 15,163 |
| `terminal.osc.Parser.end` | 14,965 |
| `vt.Term.write` | 14,307 |
| `oo.defineOne` | 13,687 |
| `more.cmdBinary` | 13,004 |
| `ns.ensembleCall` | 12,827 |
| `format.cmdFormat` | 12,227 |

### Data

The data section has 267,272 bytes in one segment. 97,332 of them are zero. Only 13,329 zero bytes are in runs of 64 bytes or more, so most zero bytes are inside tables. Printable text has 72,435 bytes in 2,022 runs: 232 messages start with `wrong # args`. The text has no panic message and no source path. The build with `-Dbatteries=core` has 77,440 bytes of data, so the modules own 189,832 bytes of data.

### Facts that change the list of the request

- The clock zone data and the Tcl encodings are not in `ztcl.wasm`. The module has no function of `src/clock.zig` or `src/enc.zig`. `clock` reads the zone of the host through `hostZone` (`src/wasm.zig`). `ucd.zig` has 2,796 bytes of code. So these tables have no bytes to save today. Idea 7 has the rule for the day that they come.
- The module exports only the 17 functions of `src/wasm.zig`. `rdynamic` adds no other function. So an export list saves no bytes (idea 8).
- The module already uses these features: `bulk-memory-opt`, `sign-ext`, `multivalue`, `nontrapping-fptoint`, `mutable-globals`, `extended-const`, and `call-indirect-overlong` (the custom section `target_features`). So only tail calls are left to measure (idea 8).
- A generic function with a type in its name has 100,149 bytes in 200 instances. The largest families are `terminal.stream.Stream` (28,589), `array_hash_map.Custom` (20,329 in 48 instances), `json.build.Parser` (11,567), and `array_list.Aligned` (8,845 in 47 instances).

## Summary

| Rank | Idea | Bytes of `ztcl.wasm` | gzip -9 | Risk |
|---|---|---|---|---|
| 1 | Serve Brotli next to gzip | 0 | 126,589 fewer bytes on the wire (378,061 against 504,650) | Low |
| 2 | `ztcl::vt` as a module that loads on demand | About 470,000 fewer (estimate) | About 150,000 fewer (estimate) | Medium |
| 3 | Only the scalar form of JSON stage 1 in a build with no SIMD | About 40,000 fewer (estimate) | Not measured | Low |
| 4 | A post-link pass of our own that writes short numbers | 70,097 fewer (measured with a reference tool) | 7,245 fewer | Medium |
| 5 | Error messages with no format code at each call | Not measured. `cmdInfo`, `cmdNamespace`, `cmdString`, `cmdPackage`, and `cmdDict` have 110,000 bytes | Not measured | Low |
| 6 | The size tool in CI, with a table for each PR | 0 | 0 | Low |
| 7 | A rule for data tables: a file that loads on demand | 0 today | 0 today | Low |
| 8 | Small items: `f128`, two exports, tail calls | Under 10,000 | Not measured | Low |

The issues are #291 to #296 for ideas 1 to 6, and #297 for idea 8. Idea 7 is a rule for later work and has no issue.

The rules for each idea: the behavior and the count of compute units of a script do not change, and a command that a script uses is never absent. A part that loads on demand loads before the command runs, with no step of the script.

## 1. Serve Brotli next to gzip

### Evidence

| Form of `ztcl.wasm` | Bytes |
|---|---|
| No compression | 1,475,011 |
| `gzip -9` | 504,650 |
| `zstd -19` | 406,258 |
| `brotli -q 5` | 434,893 |
| `brotli -q 11` | 378,061 |

Brotli at quality 11 is 25.1 % smaller than gzip. For `ztcl-shell.wasm` it gives 395,440 bytes against 527,242.

### Design

1. The site build makes `ztcl.wasm.br` and `ztcl.wasm.gz` next to each `.wasm` file, at quality 11 and at level 9.
2. The server sends the `.br` file with `Content-Encoding: br` and `Content-Type: application/wasm` when the request has `br` in `Accept-Encoding`. It sends the `.gz` file in the other case. `WebAssembly.instantiateStreaming` needs the content type.
3. The size gate (`tools/size-report.sh --check`) keeps its gzip number, and gets a second number for Brotli.
4. The npm package has the plain file. The CDN of npm compresses it.

I did not check which server the site uses and which compression it applies today. Check that first: a server that compresses at request time uses a low Brotli quality, and the table shows 434,893 bytes at quality 5.

### Risk

Low. A browser with no Brotli gets gzip. Question for the user: the build needs a Brotli compressor, and the rule "own the stack" allows no third-party library. A compressor in the deploy job is a tool and is not linked. The default in the issue is the `brotli` program in the deploy job.

## 2. `ztcl::vt` as a module that loads on demand

### Evidence

The groups `terminal` and `vt` have 288,142 bytes of code, 23.9 % of the code section. The modules together (`vt`, `json`, `hello`) cost 622,551 bytes: `ztcl.wasm` has 1,475,011 bytes and the core build has 852,460. They cost 198,157 bytes with gzip. `json` has 95,232 bytes of code. Estimate: `vt` has about 290,000 bytes of code and about 180,000 bytes of data. `tools/size-report.sh` gives the exact number for each module.

### Design

1. `ztcl.wasm` keeps the core and the small modules. `vt` becomes a package module, `ztcl-vt.wasm`, that imports the memory of the main module.
2. The load path is the one of task 04w of the C packages (`docs/dev/cext-tasks/04w-wasm-bridge.md`): `Interp.loadPackage(bytes)` in `web/ztcl.mjs`. A module written in Zig needs a smaller interface than a C package: it calls the functions of the interpreter through a table of imports (register a command, allocate in the heap, read and make values).
3. The trigger: `package require ztcl::vt`, or the first call of a command of the namespace `ztcl::vt`, calls an import of the host, `ztcl_need(name)`.
4. In a worker (`web/ztcl-worker.mjs`), the host loads the file with a synchronous request and instantiates it before `ztcl_need` returns. The script sees no difference.
5. On the main thread a script cannot wait. `web/ztcl.mjs` starts the fetch of each module when the interpreter starts, and `eval` of a script that names `ztcl::vt` waits for that fetch before it runs (an `await` before the call). When `ztcl_need` runs before the module is ready, the error names the module and says to use `ready()` first. That case must be in the docs of `web/ztcl.mjs`.
6. The compute units of a `vt` command stay the same: the count is in the command code, and the load uses no unit.
7. The same split then serves `json` (95,232 bytes of code), `regexp`, and `clock`, when a measure shows the gain. Start with `vt` alone.

### Expected gain

Estimate: 470,000 bytes of `ztcl.wasm` (32 %), and about 150,000 bytes with gzip, for each page that does not use a terminal.

### Risk

Medium. The interface between two modules is new. The collector must scan the memory of the module: with one shared memory and one heap, the roots of the module are in the heap and on the one stack. The precise roots of the WebAssembly build need a check for values that the module holds in its globals. A page that needs `vt` downloads two files.

## 3. Only the scalar form of JSON stage 1 in a build with no SIMD

### Evidence

`json.build.Stream.refill` has 47,842 bytes. It is the largest function of the module. `Stream` (`src/json/build.zig`) has a field `scalar` and calls `s.sca` or `s.vec` at run time. The vector form uses `@Vector(32, u8)` (`build.zig:642`). `ztcl.wasm` has no `simd128`, so the compiler turns each vector operation into code for 32 single bytes.

### Design

Make the choice at compile time: a constant `has_vectors` that is false for `wasm32` with no `simd128`. With the constant false, `Stream` has no `vec` field and each `if (s.scalar)` becomes the scalar branch. `ztcl-simd.wasm` and the native builds keep both forms.

### Expected gain

Estimate: about 40,000 bytes of code. The scalar form must give the same values, the same errors, and the same compute units as the vector form: `tools/json-fuzz.zig` and `tools/json-test.zig` compare them today. The speed of `ztcl::json parse` in `ztcl.wasm` can change. Measure it with `tools/bench-stdlib.py --only json` on the wasm build before and after.

### Risk

Low.

## 4. A post-link pass of our own that writes short numbers

### Evidence

A read and a write of the module with a reference tool, with no optimization pass, changes the code section from 1,204,400 to 1,134,300 bytes. The other sections do not change.

| Form | Bytes | gzip -9 | Brotli 11 |
|---|---|---|---|
| `ztcl.wasm` | 1,475,011 | 504,650 | 378,061 |
| Written again, no pass | 1,404,914 | 497,405 | 374,231 |
| The same, and identical functions merged | 1,402,880 | 496,214 | 374,044 |
| The same, and similar functions merged | 1,364,258 | 494,504 | 374,767 |
| The same, and unused elements removed | 1,404,623 | 497,314 | 374,647 |
| The full size optimization of the reference tool | 1,307,564 | 489,061 | 371,215 |

So 70,097 bytes come from the encoding alone. The probable cause: the linker writes each number that it relocates (a function index of a `call`, a memory address, a global index) as a LEB128 number padded to 5 bytes. I did not read the bytes to confirm the cause. Identical functions save 2,034 bytes. Unused elements save 291 bytes. The full optimizer saves 15,589 bytes with gzip, 3.1 %.

### Design

1. First check for a linker option. The LLVM linker has an option that compresses the relocated numbers. If `zig build` can pass it, or if the linker of Zig has the same switch, use it and write no pass.
2. If no option exists, write `tools/wasm-pack.zig`: a pass over the code section.
   - Read each function body. Walk the instructions with a table of the operand kinds of each opcode (the table is the hard part: about 200 opcodes and the prefix groups `0xFC` and `0xFD`).
   - Write each LEB128 operand again in its shortest form.
   - Fix the size field of each body and of the section. No index changes, so no other section changes.
   - A second step merges identical bodies: hash each body, and for two equal bodies with equal types, point each `call` and each element entry of the second to the first. This step changes indexes, and it saves only 2,034 bytes, so leave it out of the first version.
3. The build runs the pass after the link, and the tests of the wasm library (`tools/wasm-web.mjs`, `tools/wasm-shell.mjs`) run on its output.
4. A check mode validates the output: each body ends with `end`, and the sizes add up.

### Expected gain

Measured: 70,097 bytes (4.8 %), 7,245 bytes with gzip (1.4 %), 3,830 with Brotli. The gain on the wire is small, because a compressor already packs the padding.

### Risk

Medium for a pass of our own: a wrong operand table makes a module that does not validate, and the browser refuses it at load. The check mode and the tests find that. Low for a linker option.

### Status

Done in #294. Zig 0.17.0 has no option for the linker that compresses the relocated numbers, so `tools/wasm-pack.zig` is the pass. `installWasm` in `build.zig` runs it on each library of `zig-out/lib`, and `-Dwasm-pack=false` installs the output of the linker. The pass also writes the size of each section and of each body in the shortest form. Each build packs the output a second time and compares the bytes. An opcode that is not in the table fails the build.

Measured on commit `43cda77`, 2026-11-27:

| Form | Bytes | gzip -9 | Brotli 11 |
|---|---|---|---|
| `ztcl.wasm` from the linker | 1,488,640 | 507,742 | 379,762 |
| `ztcl.wasm` after the pass | 1,417,631 | 501,986 | 375,905 |

## 5. Error messages with no format code at each call

### Evidence

Five command functions have 110,000 bytes: `cmdInfo` 32,627, `cmdNamespace` 23,810, `cmdString` 20,691, `cmdPackage` 17,693, and `cmdDict` 15,163. Each one is an ensemble with many error paths. `it.fail` and `it.failCode` have a format string and a tuple of arguments known at compile time, so each call can make its own copy of the format code, inlined in the caller. The functions with `fmt.`, `print`, or `Writer` in their names have 75,665 bytes in 133 functions (that number includes `format.cmdFormat`, and `format` needs that function). I did not measure how many bytes of the five functions are format code.

### Design

1. Measure first: change the error calls of `cmdInfo` only, build, and read the size of `cmdInfo` with `tools/wasm-size.py --match cmdInfo`.
2. The change: a function `failParts(it, parts: []const []const u8)` that is not generic and not inlined. A call with only `{s}` arguments becomes `it.failParts(&.{ "bad option \"", name, "\": must be ..." })`. The message bytes are equal.
3. Idea 5 of `perf-ideas.md` changes the dispatch of `cmdInfo` to one `switch`. Do both in one change of `cmdInfo`, then measure.
4. If the gain is above 5,000 bytes for `cmdInfo`, do the same in the other four functions and in `oo.zig`.

### Risk

Low. Each message must stay byte for byte equal: the Tcl suite compares the messages.

## 6. The size tool in CI

`tools/wasm-size.py` is in this change. The work that is left:

1. A build option `-Dwasm-names` that sets `.strip = false` for the wasm libraries, so the tool can name the functions. The name section and the debug sections must not be in a release file: a module with them has 5,517,902 bytes.
2. A CI step that builds with the option, runs the tool, and writes the group table to the job summary. A second step compares the code bytes of each group with a table in the repository (`tools/wasm-groups.tsv`) and fails when a group grows by more than 5 % with no change of the table.
3. `tools/size-report.sh` prints the Brotli size next to the gzip size.

The tool is in Python, as `tools/bench.py` and `tools/build-docs.py` are. It imports only the standard library.

## 7. A rule for data tables

The zone data and the encodings are not in the module today. `docs/dev/stdlib.md` plans the IANA zone file (104,917 bytes, 24,532 with gzip) and the encodings. The rule for that work:

1. A table of more than 4,096 bytes that only some scripts need is a file next to the module, in the form that the module reads, compressed by the server.
2. The module asks the host for the file through `ztcl_need(name)` (idea 2) at the first use: `clock format` with a named zone, `encoding convertfrom` with a name that is not built in.
3. The built-in set stays: UTF-8, ASCII, ISO 8859-1, and the zone of the host.
4. The Unicode tables of `ucd.zig` are a model of a few blocks today (2,796 bytes of code). Full tables, when they come, use a two-level table with shared blocks, built by a script from the Unicode data files.

## 8. Small items

- `src/format.zig:309` calls `std.fmt.parseFloat(f128, ...)`. It brings `Decimal(f128)` (1,319 bytes), `__divtf3` (1,711), `__multf3` (1,092), and the other 128-bit float helpers. Estimate: 5,000 to 9,000 bytes. Check if the rounding of `format` can use the exact decimal code of `value.formatDouble` in its place.
- `web/ztcl.mjs` does not call the exports `ztcl_compute_left` and `ztcl_set_gc_stress`. They are small. An explicit export list in `build.zig` in place of `rdynamic = true` makes the list a decision, and saves no bytes today.
- Tail calls: the module does not have the feature. `vm.exec` uses a labeled switch, so the feature can change the two forms of `exec` (54,716 bytes). Not measured. The support in browsers must be checked first: I did not check it.
- 13,329 zero bytes are in runs of 64 bytes or more. A segment that leaves them out saves those bytes in the file, and almost no bytes after compression.
