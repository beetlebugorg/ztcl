# Task 05b: JSON with the JIT

Platform: Linux (x86-64 first, arm64 after the port of the JIT).

## Goal

The JIT of ztcl specializes JSON work to the shapes and paths that a script uses again and again. simdjson parses each document with the same code, and it does not see the code that reads the result. The JIT sees both. Each item below is off unless the runner has `--jit` (the embedder: `Interp.enableJit`), and each item lands and measures on its own.

## Rules

1. The rules of [the JIT plan](../jit.md) apply: the verifier checks the generated code, no page is writable and executable at once, and no value of a script or of the data is an immediate operand. Key bytes, shape tables, and paths are in data memory that the code reads.
2. Each specialized path falls back to the general parser of `src/json/build.zig` at the first mismatch, and the result is the same value, the same error, the same step count, and the same memory count as the interpreter.
3. `tools/jit-diff.sh` and `zig build json-fuzz` run in each JIT mode. The fuzzer adds a mode that learns a shape and then sends mutated documents of that shape.
4. Each item measures against the path without the JIT and against simdjson On-Demand on the same work, and reports where simdjson stays ahead and why.

## Items

1. **Shape-specialized parse.** After N parses of documents with one shape (the same keys in the same order and the same kinds of values), the JIT compiles a parser for the shape. It checks each key in order against the key table, writes each value into the dict of the shape, and goes to the general parser at the first mismatch.
2. **Compiled path queries.** `ztcl::json get $doc a b 3`, and a set of paths that a script reads again and again, compile to one scan over the stage 1 index for the path.
3. **Shape-specialized encode.** `ztcl::json encode` of dicts with one repeated shape compiles a writer that copies the key bytes from a table and formats only the values.
4. **Tier 2 reads.** In a tier 2 loop, a read of a field of a JSON value of a known shape becomes a load with a shape guard and a side exit.
5. **Parse for the reads of the consumer.** The profiles of tier 1 and tier 2 give the fields that the code reads. The parser of a shape skips the other subtrees at the speed of stage 1: no number, no unescape, and no value for a field that no code reads. A guard makes the rest when a later read needs it.
6. **A fused parse and loop.** A tier 2 loop over a JSON array that reads a few number fields, for example `foreach row [ztcl::json get $doc rows] { incr total [dict get $row amount] }`, compiles to one pass over the stage 1 index that parses only those numbers into registers and makes no Tcl value. A mismatch exits to the general path.

## Acceptance

```sh
CAP zig build test
CAP tools/jit-diff.sh
CAP zig build json-fuzz -- --seconds 600 --jit
CAP python3 -I tools/bench-stdlib.py --only json --jit
```

Measures, each with and without `--jit`:

- An API response of one shape parsed 100 000 times.
- A JSON-lines log file of 1 GB with one shape for each line.
- Item 6: the sum of one field over an array of 10 000 000 objects, against simdjson On-Demand in C++ and the idiom of Python and Node.
