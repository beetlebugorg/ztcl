# Task 21: the stress modes and the safety builds

## Goal

Modes that force the rare paths, and a clean run in the builds with safety checks.

## Files

- `src/jit.zig`, `src/jit/mem.zig`, `src/main.zig` (the flag `--jit-stress N`), `tools/jit-diff.sh` (the option `--stress`).

## The modes

The value of `--jit-stress` is a bit set:

| Bit | Mode |
|---|---|
| 1 | Each allocation of the compiler fails in turn: run k of a script fails allocation k. The script still gives its output. |
| 2 | `Region.append` fails at each second call. |
| 4 | A checksum of each function is taken after the copy and checked at each `enter` and at `flush`. A difference aborts the process. |
| 8 | Each `enter` runs `exec` for one instruction first, then enters the machine code at the next address. This tests each entry address. |
| 16 | The JIT memory limit is 64 KiB. |

## Acceptance

```sh
CAP tools/jit-diff.sh --stress        # each mode alone and all together: exit code 0
CAP zig build test -Doptimize=ReleaseSafe
CAP zig build -Doptimize=ReleaseSafe && CAP tools/suite.sh -j -r zig-out/bin/ztcl    # needs a build option for the runner mode
CAP zig build jit-fuzz -Doptimize=Debug -- --count 20000 --stress 31
CAP tools/suite.sh -j -g 64           # the collector stress with the JIT: pass 19877
```

`build.zig` builds the runner in `ReleaseFast` always. Add the option `-Drunner-mode=<mode>` for this task.

- Mode 8 needs the `sp` check of `enter` to pass at each reachable address. If an address fails, the verifier depth and the compiler depth differ. Fix the cause.
- The last command proves the rule of `docs/jit.md`: no pointer to a heap block is only in a register of machine code across a helper call.

## Must not change

With `--jit-stress` 0, each count and each gate.
