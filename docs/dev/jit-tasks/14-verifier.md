# Task 14: the bytecode verifier

## Goal

Prove, before a `Code` compiles, each fact that machine code relies on. Give the static stack depth of each instruction.

## Files

- `src/jit/verify.zig` (new).

## Contract

```zig
pub const Info = struct {
    depth: []const u16,       // the stack depth before each instruction
    reachable: []const bool,
    loop_heads: []const u32,  // each target of a backward jump
    has_loop: bool,
};
pub fn verify(a: Allocator, code: *const vm.Code) Allocator.Error!?Info;
```

`verify` returns null for a `Code` that fails a check.

## The limits

At most 32 768 instructions, 2048 slots, a `max_stack` of 2048, and 65 536 literals, sites, words, nodes, and tables each.

## The stack effect and the successors

| Instruction | Needs | After | Successors |
|---|---|---|---|
| `push`, `push_empty`, `load`, `eval_cmd`, `word`, `node`, `incr`, `bin_vv`, `bin_vi` | 0 | +1 | next |
| `pop`, `store_pop` | 1 | -1 | next |
| `store`, `to_bool`, `unary`, `number_form`, `incr_value`, `lappend` | 1 | 0 | next |
| `access` with `x` 0 or 2 | 1 | 0 | next |
| `access` with `x` 1 or 3 | 2 | -1 | next |
| `binary` | 2 | -1 | next |
| `guard` | 0 | 0 | next, `a` |
| `step`, `incr_drop` | 0 | 0 | next |
| `jump` | 0 | 0 | `a` |
| `jump_false`, `jump_true` | 1 | -1 | next, `a` |
| `jf_vv`, `jf_vi` | 0 | 0 | next, `c` |
| `invoke` | `b` | `-b + 1` | next |
| `concat` | `a` | `-a + 1` | next |
| `append` | `b` | `-b + 1` | next |
| `dict_update` | `1 + x` | `-x` | next |
| `dict_update_drop` | `1 + x` | `-(1 + x)` | next |
| `foreach_init` | 1 | +1 | next |
| `foreach_next` | 2 | 0 | next, `b` |
| `ret` | 1 | | none |

Add a row for each instruction of tasks 07 and 08.

## The checks

1. Each opcode is a member of `Op`. Each `x` is in range: `access` 0 to 3; `binary`, `unary`, `bin_vv`, `bin_vi` a member of the operator enum; `jf_vv` and `jf_vi` one of the six compares; `dict_update` 0 or 1.
2. Each index is in range: a slot below `names.len`, a literal below `lits.len`, a site below `sites.len`, and so on. Each slot of a `foreach_next` table is in range, and the table is not empty.
3. The literal of `bin_vi` and `jf_vi` is an `.int`.
4. `invoke`, `concat`, and `append` have a count of at least 1. `append` has at most 8.
5. The target of a `guard` is an `eval_cmd` with `x` 1 whose `b` is the address of that guard. An `eval_cmd` with `x` 1 has a `b` that is a `guard`.
6. The site of `dict_update` has at least three words, and the first three are literals.
7. A work list from address 0 with depth 0 visits each successor. The depth before an instruction is at least its need and at most `max_stack - 1` after a push. Two paths to one address have the same depth.
8. The two stack places that `foreach_init` makes have a mark. `foreach_next` needs the mark on the top two places. An instruction that pops or replaces a place clears its mark. Two paths to one address have the same marks.
9. No path runs past the last instruction.
10. For each range with a `brk` or `cont` target: the target is reachable, its depth equals `r.depth`, each reachable instruction inside the range has a depth of at least `r.depth`, and the marks below `r.depth` are equal.
11. A `Code` with `named` true fails until task 23.

## Acceptance

```sh
CAP zig build test
```

New tests:

- The `Code` of each proc of `bench/*.tcl` passes. The depth at each `foreach_next` equals the compiler value.
- One test for each check above: a hand-made `Code` that breaks only that check fails.
- A test runs the verifier on the `Code` of each proc that the unit tests of `src/tests.zig` compile (a hook in `compileProc` in test builds only) and counts the failures. The count must be zero: the bytecode compiler of ztcl makes only code that passes.

## Must not change

`src/vm.zig`, except a test-only hook.
