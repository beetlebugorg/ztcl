# Tasks for DOM access from Tcl

Issue #85 has the goal: the capability `dom`, which gives a Tcl script in the browser access to the DOM of the page under a root element. Do the tasks in the order of their numbers. One task is one branch and one review.

## The module

The commands go into `ztcl-host.wasm`, the module with imports of [the host API tasks](../wasm-host-tasks/README.md) (#26). The imports of the DOM are the set `ztcl_dom_*`. `ztcl.wasm` keeps no imports and has no `dom`. Task 04 of the host API (events that the host drives) comes before task 03 here.

## The model

- A handle is a small integer in a table of `web/ztcl.mjs`. The table holds the elements. Tcl gets the text `dom1`, `dom2`, and so on, and never a pointer.
- `allow: ["dom"]` turns on the capability, and `domRoot: el` sets the root (the default is `document.body`). Each import checks that the element of a handle is the root or below it. A handle of an element that left the root, or that `dom remove` removed, gives the error `invalid DOM handle "domN"`.
- No command runs JavaScript from Tcl.
- `dom html el value` sets the HTML only with the separate grant `dom-html`. Without it, the command gives an error.

## Tasks

| Task | Result |
|---|---|
| 01 | The handle table, the root check, and `dom query`, `dom queryAll`, `dom text`, and `dom attr`. A test proves that `dom` is absent by default and in `ztcl.wasm`. |
| 02 | `dom class`, `dom style`, `dom value`, `dom focus`, `dom create`, `dom append`, `dom remove`, and `dom html` with the grant `dom-html`. |
| 03 | `dom on el event script` and `dom off el event`. The host puts each DOM event in the event queue of the interpreter, and the script runs from `runEvents` with the substitutions `%x`, `%y`, `%key`, `%value`, and `%target`. Each callback has its own compute limit (`domComputeLimit`, 1,000,000 by default), so a handler that does not end stops alone with `compute limit reached`. |
| 04 | Tests in headless Chromium (`npm/test/run.mjs browser`): each command, the root check, a removed handle, a callback at its compute limit, and the memory limit in a callback. |
| 05 | Docs and a preset: a section in `docs/webassembly.md`, a playground preset with a counter and a to-do list, and the npm types. |

`fetch` with an allowlist of origins stays out of these tasks. It is a separate capability for a later issue.

## State

- Task 01: `src/wasmdom.zig` and the import `ztcl_host.dom` of `web/ztcl.mjs`. `dom` exists only in `ztcl-host.wasm` after `allow: ["dom"]` (the export `ztcl_dom_allow`). `tools/wasm-host.mjs` checks the commands, the root check, and a handle of an element that left the root, on a small DOM of plain objects in Node.js. The tests in Chromium are task 04.

## Rules for each task

1. Follow the rules of [the host API tasks](../wasm-host-tasks/README.md#rules-for-each-task).
2. A command of `dom` uses one compute unit, and a text or a list that it returns counts in the memory limit.
3. The same commands work for an interpreted script and for a bundle of `ztcl build --wasm`. Code compiled by #3 level 3 calls the same imports.
