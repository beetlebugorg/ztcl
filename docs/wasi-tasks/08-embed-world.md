# Task 08: the `ztcl:embed` world for the library

Platform: shared/wasi.

## Goal

`zig build wasi-lib` makes `zig-out/lib/ztcl.component.wasm`, the library as a component with the world `ztcl:embed/interp` of the design. A host in any language that runs components can make an interpreter, evaluate a script, and give it commands.

## Files

- `wit/embed.wit`: the world, on WASI 0.3.2. The `interp` resource, `eval`, `call`, the `error` record, and the import `host-command`. `eval` and `call` are plain functions: a script runs to its end on the task of the call. `host-command` is an `async func`, so a host can answer a command with work of its own, and the interpreter waits for the result.
- `src/wasi/embed.zig`: the exports with the lifting and lowering of the canonical ABI. Written by `tools/witgen` where the types allow it.
- `tools/wasi-embed-test.sh`: calls the exports with `wasmtime run --invoke` and a small test host.

## Rules

- The step limit and the memory limit come from `new`. A script over a limit gives the error of the native library.
- A host command runs only when the embedder listed its name at `new`.
- Each capability import is in the world only when the build turns the capability on. The default build imports only `host-command`.
- Use the form of the lift and the lowering that task 04 measured.

## Acceptance

```sh
CAP zig build wasi-lib
wasm-tools component wit zig-out/lib/ztcl.component.wasm      # the default build imports only host-command
CAP tools/wasi-embed-test.sh      # eval, call, an error with errorInfo, a host command, the step limit, the memory limit
```
