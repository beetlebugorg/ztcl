# Task 04: The JSON parser: the SIMD index and the builder

Platform: shared.

## Goal

A parser from JSON text to Tcl values in the heap of the interpreter, in two stages, with a scalar path that gives the same result.

## Files

- `src/json/index.zig` (new): the structural index with `@Vector(64, u8)`, the UTF-8 check, and the scalar path.
- `src/json/build.zig` (new): values from the index. Numbers follow the rules of `expr`: a canonical integer is an int, an integer above 64 bits is a big integer, and other numbers are doubles with the shortest form.
- `src/json/tests.zig` (new).
- `tools/json-fuzz.zig` (new): random and mutated inputs; the SIMD path, the scalar path, and `std.json.Scanner` must agree on accept or reject, and the two ztcl paths must give the same value.

## Test sources

- JSONTestSuite (`test_parsing/`): each `y_` file is accepted, each `n_` file is rejected, and the result of each `i_` file is listed.
- The `std.json.Scanner` as a reference.

## Acceptance

```sh
CAP zig build test
CAP zig build json-test -- path/to/JSONTestSuite/test_parsing
CAP zig build json-fuzz -- --seconds 600
CAP zig build test -Dcpu=baseline
```

Gates:

- All `y_` and `n_` files pass on both paths.
- A depth of 512 and the number limit of the design give the error, with no crash at depth 100 000.
- The compute limit and the memory limit stop a parse of a 1 GB input at a bounded point. A test checks the point.
- Speed: `canada.json`, `twitter.json`, and `citm_catalog.json` parse to a Tcl value at the target of the design against Python and Node. Report the instruction count for each file too.
- Size: the `json` row of the design.
