# Interpreter spike: superinstructions and quickening

This page has the results of the spike of issue #130: a profile of the bytecode loop of `src/vm.zig`, and two measured changes to the dispatch. Neither change is on `main`.

## Method

- Build: `zig build`, the runner in ReleaseFast, Zig 0.16.0, x86-64 Linux, on the commit before #134.
- Programs: `bench/sum.tcl`, `fib.tcl`, `foreach.tcl`, `nested.tcl`, `strbuild.tcl`, `dict.tcl`, `dictgrow.tcl`, `dsum.tcl`, `readloop.tcl`, and the kostya programs `bf.tcl bench.b` and `base64/test.tcl` (`tools/fetch-kostya.sh`).
- Op counts: a local patch (not on `main`) counts each dispatch, each pair, and each triple of ops. The tables give the mean share over the 11 programs, so a long program does not hide a short one.
- Instructions: `valgrind --tool=callgrind`, the total `Ir`. `bf.tcl` runs with a compute limit of 200,000,000, about 3 % of the full run, because the full run is 85 s natively.
- Time: the best of 7 runs with `--time --repeat 7`, natively. In wasm, the best of 7 `eval` calls in Node.js with `web/ztcl.mjs`.

## Profile

The share of the dispatch lines (`i = &ins[pc]`, `continue :sw i.op`, `pc += 1`, and the switch) and of the limit checks (the compute limit and the memory trip point) in the total `Ir`:

| Program | Total Ir | Dispatch | Limit checks |
|---|---|---|---|
| sum | 283,780,336 | 21.1 % | 11.3 % |
| fib | 151,315,334 | 12.2 % | 5.9 % |
| foreach | 206,867,490 | 23.3 % | 8.9 % |
| nested | 333,096,207 | 20.8 % | 9.6 % |
| strbuild | 280,153,534 | 13.7 % | 4.3 % |
| bf (part) | 33,720,398,503 | 17.0 % | 4.8 % |
| base64 | 20,506,156,059 | 0.0 % | 0.0 % |

`base64/test.tcl` spends its time in the native code of `binary encode` and `binary decode`, so the loop of the interpreter does not show. In `bf`, `exec` has 63 % of `Ir`, and `callProcFast`, `Heap.alloc`, and `lsetOwned` have most of the rest.

The hottest ops (mean share of the dispatches):

| Op | Share |
|---|---|
| guard | 24.6 % |
| load | 9.9 % |
| jump | 8.1 % |
| push | 7.6 % |
| pop | 6.3 % |
| step | 6.2 % |
| incr_drop | 6.1 % |
| jf_vv | 5.5 % |
| incr_value | 3.2 % |
| invoke | 2.4 % |

The hottest pairs:

| Pair | Share |
|---|---|
| step guard | 6.2 % |
| guard incr_drop | 6.1 % |
| incr_drop jump | 6.1 % |
| guard guard | 5.7 % |
| jump jf_vv | 5.5 % |
| jf_vv step | 5.5 % |
| guard load | 4.7 % |
| pop guard | 4.5 % |
| guard push | 3.2 % |
| incr_value pop | 3.2 % |
| push load | 3.1 % |
| guard bin_vv | 2.4 % |
| store_pop guard | 2.2 % |
| push push | 2.0 % |
| load push | 1.9 % |
| guard bin_vi | 1.7 % |
| pop jump | 1.6 % |
| jump foreach_next | 1.6 % |
| foreach_next guard | 1.6 % |
| load load | 1.5 % |

The hottest triples:

| Triple | Share |
|---|---|
| guard incr_drop jump | 6.1 % |
| incr_drop jump jf_vv | 5.5 % |
| jf_vv step guard | 5.5 % |
| jump jf_vv step | 5.5 % |
| step guard guard | 4.1 % |
| pop guard incr_drop | 3.7 % |
| step guard push | 2.0 % |
| guard guard bin_vv | 1.9 % |
| guard guard load | 1.8 % |
| incr_value pop guard | 1.8 % |
| store_pop guard incr_drop | 1.7 % |
| pop jump foreach_next | 1.6 % |
| foreach_next guard load | 1.5 % |
| jump foreach_next guard | 1.5 % |
| guard push load | 1.4 % |
| guard push push | 1.4 % |
| push push load | 1.4 % |
| load incr_value pop | 1.3 % |
| guard load incr_value | 1.3 % |
| incr_value pop jump | 1.3 % |

One quarter of the dispatches go to `guard`, the check before each inline command. The loop of `for` is the sequence `jf_vv step guard ... guard incr_drop jump`, and it is the top of the pairs and the triples.

## Experiments

**E1. Direct dispatch after a jump.** The taken paths of `guard`, `jump`, `jump_false`, `jump_true`, `jf_vv`, `jf_vi`, and `foreach_next` go to the top of the `while` loop with `continue`. E1 made each of them dispatch at its own site with `continue :sw`.

| Program | Base Ir | E1 Ir | Change |
|---|---|---|---|
| sum | 283,784,867 | 288,784,866 | +1.8 % |
| fib | 151,319,913 | 152,533,828 | +0.8 % |
| foreach | 206,867,490 | 209,567,553 | +1.3 % |
| nested | 333,096,207 | 340,102,787 | +2.1 % |
| strbuild | 280,153,534 | 283,153,534 | +1.1 % |

**E2. `guard` and `incr_drop` in one handler.** After the compute unit of `guard`, the handler runs `incr_drop` in place when it is the next op, with no dispatch between them. This form of a superinstruction adds no op, so the JIT, its verifier, and the wasm compiler need no change.

| Program | Base Ir | E2 Ir | Change | Native base | Native E2 | Wasm base | Wasm E2 |
|---|---|---|---|---|---|---|---|
| sum | 283,784,867 | 309,785,605 | +9.2 % | 19.9 ms | 20.9 ms | 39.4 ms | 37.4 ms |
| fib | 151,319,913 | 157,511,624 | +4.1 % | 13.7 ms | 14.1 ms | 30.1 ms | 29.4 ms |
| foreach | 206,867,490 | 215,068,394 | +4.0 % | 15.1 ms | 17.2 ms | 33.7 ms | 33.6 ms |
| nested | 333,096,207 | 357,158,235 | +7.2 % | 27.8 ms | 31.1 ms | 77.6 ms | 75.9 ms |
| strbuild | 280,153,534 | 288,654,280 | +3.0 % | | | | |
| bf (part) | 33,720,398,503 | 34,927,074,356 | +3.6 % | | | | |

With the JIT on (tier 1, base build), the native times are 7.5 ms (sum), 7.9 ms (fib), 9.2 ms (foreach), and 18.2 ms (nested).

E2 saves one dispatch for each `guard incr_drop` pair, but each program runs more instructions. The `Ir` grows in the other handlers too. A change to one handler changes the register allocation and the code of the whole `exec` function. The comment on `opGuard` in `src/vm.zig` records the same effect for the joined form of `guard`. In wasm, E2 is 2 % to 5 % faster on three programs, a change of the same size as the noise between two runs.

## Decision

- Superinstructions in the handlers of `exec` do not pay on x86-64. The two experiments add instructions, and E2 also adds time.
- A superinstruction as a new op has the same problem in `exec`, and also needs a change to the verifier, to tier 1 and tier 2 on x86-64 and arm64, and to the wasm compiler. The spike did not build one.
- Quickening (an op that rewrites itself to a typed form) needs a write to the bytecode at run time. The bytecode is `[]const Ins` and the JIT reads it, so a rewrite is a larger change than this spike. The spike did not build it.
- The JIT is 1.5 to 2.7 times faster than the interpreter on these programs. For hot code, the JIT is the path to more speed.
- The limit checks are 4 % to 11 % of `Ir`. A variant of `exec` with no checks changes the count of compute units only when no limit is set, and the `--report` line and the JIT compare need that count. The spike did not build it.

Next step, if the interpreter needs more speed: split the cold parts of the large handlers out of `exec` (`noinline` and `@branchHint(.cold)`), measure the `Ir` of `exec` after each split, and try E2 again on the smaller function.
