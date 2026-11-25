# Task 09: two runtimes, the counts, threads, and the docs

Platform: shared/wasi.

## Goal

The suite runs under two component runtimes, and the docs publish both counts. The WASI build has no `thread` command, and the docs say why.

## Files

- `tools/wasi-run.sh`: an option for the second runtime that the user picked (question 3). The runtime must run WASI 0.3 components: jco supports WASI 0.3, and wasmtime 46 and later run them with no flag.
- `.github/workflows/ci.yml`: the `wasi` job runs the core suite under wasmtime.
- `docs/wasi.md`: the counts, the flags of the runner, the preopen, the network flags, and the embed world.
- `docs/webassembly.md`: the section "Later" points to `docs/wasi.md`.
- `docs/threads.md`: one line: the WASI build has no `thread` command until WASI has a stable thread interface. WASI 0.3 adds async concurrency in one thread, and no thread interface. Threads task 14 is for the browser library.
- `src/thread.zig`: no change. A test in `tools/wasi-smoke.sh` proves that `thread` is absent.

## Acceptance

```sh
CAP tools/suite.sh -a -r 'tools/wasi-run.sh --component'
CAP tools/suite.sh -a -r 'tools/wasi-run.sh --component --runtime <second>'
```

Gate: the two runtimes give the same pass count for each file. Report each file that is lower than the native count, with the cause.
