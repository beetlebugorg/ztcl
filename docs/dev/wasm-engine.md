# The wasm engine of ztcl (#202)

ztcl is a WebAssembly host: `ztcl::wasm` decodes, validates, and runs wasm modules in the limits of the interpreter. The engine is our own code in Zig, written from the WebAssembly core specification 2.0, the WASI preview 1 documents, and the spec test suite (as data). No other engine is linked or read. wasmtime is a test tool only: it runs the same programs for the output and the speed numbers.

## Files

| File | What it has |
|---|---|
| `src/wasmrt/module.zig` | The decoder and the validator of the binary format. The same pass writes the internal code of each function. |
| `src/wasmrt/exec.zig` | The store, the instantiation, and the interpreter. |
| `src/wasmrt/wasi.zig` | The WASI preview 1 imports, on the capabilities of ztcl. |
| `src/wasmrt/cmd.zig` | The command `ztcl::wasm` (module `ztcl::wasm`, flag `-Dmod-wasmrt`). |
| `src/wasmrt/spec_runner.zig` | The runner of the spec tests: `zig build wasm-spec -- FILE.json...`. |
| `tests/wasm/` | WASI programs in C, Zig, and Go, and `run.sh`, which builds them and compares the output of ztcl with wasmtime. |

The module is in the native builds only: `src/modules.zig` leaves it out of each wasm target, so `ztcl.wasm` does not grow.

## Engine tiers

1. The interpreter. The internal code is an array of instructions of 16 bytes: an opcode, a 32-bit immediate, and a 64-bit immediate. A branch has the index of its target and the height and the arity of its label, so a branch moves its values with no search. `block`, `loop`, and `end` give no instruction. The values of all frames are on one stack of 64-bit slots, and a call of a wasm function puts no frame on the native stack.
2. The JIT tier (next). Hot functions go through the code generators of `src/jit/` for x86-64 and arm64. A function is hot after a count of calls and loop passes. The tier keeps the compute units and the traps of the interpreter exactly, and `docs/dev/jit-review.md` is the review of it. The speed goal is a number against wasmtime on the same programs.

## Memory model

A linear memory is one block of the counting allocator of the interpreter, with a bounds check on each access. `memory.grow` copies the block, and it gives -1 when the new size is above the memory limit of the interpreter. The JIT tier can reserve the address space of 4 GiB plus a guard where the OS has virtual memory, and drop the bounds checks there.

## Limits

- Compute: one unit for each call (wasm, host, or WASI) and each pass of a loop, and one unit for each 4,096 bytes of a bulk instruction. These are the same units as the units of Tcl code, so a C loop stops at the compute limit. Straight code with no loop and no call has a bound of its size, so a unit for each instruction is not needed. `call -limit` caps one call.
- Memory: the modules, the memories, the tables, and the value stack are in the counting allocator.
- Stack: 20,000 frames and 1,048,576 slots, then the trap `call stack exhausted`. A host call into Tcl and back into wasm nests at most 100 times.

## The WASI host

Each function of preview 1 has a host function. [The module page](../modules/wasm.md#wasi) lists the mapping on the capabilities. Files go through `fsroot.zig`, so the jail and host mode work as for `open`. The clock goes through `tape.zig`, so a recorded replay (#178) gives the same values. Standard output goes through `puts`.

WASI 0.2 and 0.3 (the component model) come after the JIT tier. The canonical ABI of `src/wasi/` (the guest side) is the model for the host side.

## The module ABI for C packages (04e)

`docs/dev/cext-tasks/04e-wasm-engine.md` has the plan: a C package built for `wasm32-wasi` with `libztclstubs.a` imports the 6 functions of the module `ztcl` (`cmd_create`, `cmd_delete`, `eval`, `var_get`, `var_set`, `pkg_provide`) and exports `ztcl_cext_dispatch`. In native ztcl, these imports are host functions of `cmd.zig`, and `load FILE.wasm` instantiates the package with them and with WASI.

## State

| Step | State |
|---|---|
| 1. Decoder and validator | Done. All binary tests of the spec suite of 2.0 pass. |
| 2. Interpreter | Done: the instructions of 2.0 with no SIMD. The spec suite of 2.0 (tag `wg-2.0` of WebAssembly/spec): 27,412 commands pass, 0 fail; 585 text-format commands are skipped. |
| 3. Tcl API and the module page | Done: `ztcl::wasm`, `docs/modules/wasm.md`. |
| 4. WASI preview 1 | Done: programs of C (`zig cc`), Zig, and TinyGo run with the same output as wasmtime. Rust: no `wasm32-wasip1` target in the local toolchain. |
| 5. C packages | Done: `ztcl::wasm package FILE ?prefix?` (`src/wasmrt/cext.zig`). The 12 test packages of `tests/cext` that `tools/cext/wasm-check.sh` runs give the output of tclsh (`tools/cext/engine-check.sh`). The SQLite package of the spike loads and runs: 20,000 inserts in one transaction took 2,397 ms with the interpreter. Next: `load FILE.wasm` in the `package` capability calls the same code. |
| 6. JIT tier, component model, WASI 0.3 | Later. |

## Spec tests

```sh
git clone --depth 1 --branch wg-2.0 --filter=blob:none --sparse https://github.com/WebAssembly/spec.git
cd spec && git sparse-checkout set test/core
for f in test/core/*.wast; do n=$(basename $f .wast); mkdir -p json/$n
  wasm-tools json-from-wast $f -o json/$n/$n.json --wasm-dir json/$n; done
zig build wasm-spec -- json/*/*.json
```

The rule of 2.0 for `global.get` in a constant expression is in force: only an imported global. A later release of the specification lets it read any earlier immutable global.

## Open questions

- NaN bits: the float instructions use the instructions of the host, so the bits of a NaN result can differ between x86-64 and arm64. The specification allows this. A script that needs the same bits on each host can be told to canonicalize; the default is no canonicalization.
- The code of a deleted module with instances stays until the end of the interpreter, because a table of another instance can hold its functions.
