# Task 33: the loops and the type pass

## Goal

Find each loop that tier 2 can compile and give a type to each value in it. This task emits no machine code.

## Files

- `src/jit/tier2.zig` (new), `src/jit/tier2_types.zig` (new).

## Contract

```zig
pub const Kind = enum { int, double, any };
pub const LoopPlan = struct {
    head: u32, back: u32,            // bytecode addresses
    slots: []const SlotUse,          // each slot of the loop: read, written, the entry kind
    kinds: []const []const Kind,     // for each instruction: the kind of each stack place
    slot_kinds: []const []const Kind,
    parts: []const Part,             // straight parts with no call and no branch target: first, last, steps
    exits: []const u32,              // each address where a guard can fail
};
pub fn plan(a: Allocator, code: *const vm.Code, info: verify.Info, head: u32, entry: []const Kind) Allocator.Error!?LoopPlan;
```

## Rules

- A loop is the range from a loop head of `verify.Info` to the last backward jump to it. An inner loop is planned first. A loop with an inner loop is not eligible in this version.
- The instruction set of an integer loop: `guard`, `step`, `jump`, `jump_false`, `jump_true`, `jf_vv`, `jf_vi`, `to_bool`, `push` of an `.int` or a `.double` literal, `push_empty`, `pop`, `load`, `store`, `store_pop`, `incr`, `incr_drop`, `incr_value`, `bin_vv`, `bin_vi`, and `binary` with `+`, `-`, `*`, and the compares.
- Calls out (task 36): `invoke`, `lappend`, `access`, `foreach_next`, `eval_cmd` of a cold block, and each other helper.
- The entry kind of a slot is the kind of its cell at the moment of the plan: `.int`, `.double`, or `any`.
- A forward pass gives the kinds. `+`, `-`, `*` of two `int` give `int` with an overflow exit. A compare gives `int`. An operation with an `any` operand gives `any` and is a call of the tier 1 helper.
- At the backward jump, the kind of each slot must equal its kind at the head. If a slot differs, plan again one time with that slot as `any`. If the second plan differs, the loop is not eligible.
- A `guard` instruction of the bytecode stays in each part: the epoch can change only in a call, so the plan marks each `guard` after the first in a part with no call as proven.

## Acceptance

```sh
CAP zig build test
CAP zig build jit-census -- --plan bench/*.tcl      # prints the plan of each loop
```

New tests: the plan of the loop of `sum.tcl` has `i`, `s`, `n` as `int`, one part with 4 compute units, and exits at `bin_vv` and `incr_drop`; the loop of `strbuild.tcl` has `s` as `any`; a loop whose variable changes from `int` to a string in the body is planned with that slot as `any`; a loop with `upvar` inside is a loop with a call.

## Must not change

Tier 1 and each gate.
