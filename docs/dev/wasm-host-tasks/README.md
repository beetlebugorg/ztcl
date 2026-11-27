# Tasks for the WebAssembly host API

Issue #26 has the goal: point procs from JavaScript, live output, and capabilities that a page grants. Do the tasks in the order of their numbers. One task is one branch and one review.

## The two modules

- `ztcl.wasm` stays as it is: no imports, and only the capability `file` for the files of a bundle. A host that wants the strict module keeps it.
- `ztcl-host.wasm` is a new build (`zig build wasm-host`) with the imports of the module `ztcl_host`. `web/ztcl.mjs` gives the imports when the module asks for them. Each import is a call into JavaScript, so the module needs no `SharedArrayBuffer` and no worker.

A wasm module cannot have an optional import: the host must give each import that the module declares. So the imports go into a second module, and the strict module keeps no imports.

## Tasks

| Task | Module | Result |
|---|---|---|
| 01 | both | `point` in the wasm build. The command is installed, and the exports `ztcl_point_compile(h, name)` and `ztcl_point_run(h, prog, ptr, count, seed, in_mask, out_mask)` run a compiled point proc over a typed array in the memory of the module. The SIMD path builds with `-mcpu=+simd128` and the scalar path stays for the strict target. Test: `tools/wasm-web.mjs` compares the result with the native runner on the point tests. |
| 02 | host | Live output. The import `ztcl_host.output(ptr, len)` gets each `puts` at the time of the call. `onOutput` of `web/ztcl.mjs` gets the text at each call with `ztcl-host.wasm`, and at the end of the script with `ztcl.wasm`. Test: a script that writes 3 lines gives 3 calls in order. |
| 03 | host | The capability `clock`. The import `ztcl_host.now_ms() f64` and the zone data from the host. `allow: ["clock"]` turns it on. Test: `clock milliseconds` follows a fake clock of the test. |
| 04 | host | Events that the host drives. `after`, `after idle`, and `update` run. `vwait` returns an error with the name of the missing wait, because a call into wasm cannot wait for the page. The export `ztcl_run_events(h, now_ms)` runs the due events, and `Interp.runEvents()` of `web/ztcl.mjs` calls it from `setTimeout`. Test: `after 10 {set x 1}` sets `x` after one call of `runEvents` with a time 10 ms later. |
| 05 | host | A file system that the page gives. `Interp.files` is a map of paths to bytes (`Uint8Array`) that the host can change between calls. `allow: ["file"]` with `files` mounts it at `/` in read and write mode, inside the root folder rules of `src/fsroot.zig`. Test: a script writes a file, and the map has the new bytes after the `eval`. |
| 06 | both | Docs and examples. `docs/webassembly.md` lists the two modules and each import and export. `examples/web/point.html` runs a point proc over a canvas. The npm package has `ztcl-host.wasm` and the types of the new options. |

## State

- Task 01: `ztcl_point_install`, `ztcl_point_compile`, `ztcl_point_outputs`, and `ztcl_point_run` in `ztcl-simd.wasm` (with them, `ztcl.wasm` was 1,532,277 bytes, over its limit of 1,500,000 in `tools/size-report.sh`), `pointProc` of `web/ztcl.mjs`, `zig build wasm-simd`, and `tools/wasm-point.mjs`. `point` is installed only with the option `point: true`, so the commands `offset`, `width`, `speed`, and the others do not appear in each interpreter.

- Task 02: `zig build wasm-host` makes `ztcl-host.wasm` with the import `ztcl_host.output`. `web/ztcl.mjs` gives the import, and `onOutput` gets each `puts` at the time of the call. Each write costs one compute unit in both forms. `tools/wasm-host.mjs` checks both.
- Task 03: `allow: ["clock"]` in `ztcl-host.wasm` calls the export `ztcl_clock_allow`. The imports `ztcl_host.now_ms` and `ztcl_host.zone` give the time and the TZif bytes of a zone. `Interp.create` has the options `now` (Date.now by default) and `zone(name)`. `tools/wasm-host.mjs` checks a fake clock and a zone of the system.
- Task 04: `allow: ["event"]` in `ztcl-host.wasm` calls the export `ztcl_events_allow`. The clock of the events is the import `ztcl_host.now_ms`, or the time of `ztcl_run_events(h, now_ms)` during a run. `Interp.runEvents(now)` calls `ztcl_run_events`, and a timer of `setTimeout` calls it at the time of `ztcl_next_event`. The field `sleep` of `event.Host` can be null: then `vwait` and `after ms` with no script give an error. `tools/wasm-host.mjs` checks a fake clock and the timer.

## Rules for each task

1. Read AGENTS.md, WRITING.md, `docs/dev/design.md`, `docs/webassembly.md`, and `docs/embedding.md` first.
2. Run each build and test under the memory cap of AGENTS.md.
3. The default interpreter stays without host access. A capability of `ztcl-host.wasm` is off until the host turns it on with `allow`. A test proves that each one is absent by default.
4. A task is done when `zig build test`, `zig build wasm`, `node tools/wasm-web.mjs zig-out/lib/ztcl.wasm`, and the test of the task pass. Put the output in the PR body.
5. Count each import call in the compute limit as one compute unit, so a script that writes in a loop stops at the same point in each module.
