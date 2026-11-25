# Task 43: The modules of the wasm build and `fetch`

Platform: shared.

## Depends on

Issue 26 for the host imports.

## Goal

The wasm build with the modules of the design table, the capability `fetch`, and the no-import build of issue 26.

## Files

- `build.zig`: the module list of each wasm build.
- `src/wasm.zig`: the `fetch` import and its capability.
- `web/ztcl.mjs`: the `fetch` option.
- `docs/webassembly.md`: the modules of the build.

## Test sources

- The tests of each pure module under Node.js.

## Acceptance

```sh
CAP zig build wasm && node tools/wasm-web.mjs zig-out/lib/ztcl.wasm
CAP node tools/wasm-modules.mjs
```

Gates:

- The wasm size gates of the design.
- The no-import build has no import, as a check of the module shows.
