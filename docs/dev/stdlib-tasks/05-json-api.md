# Task 05: `zt::json`, the tcllib names, and the JSON gates

Platform: shared.

## Goal

The full JSON module of the design: `parse` with its options, `get`, `exists`, `valid`, `encode` with a schema or a typed tree, the builders, `pretty`, `stream`, and the tcllib names.

## Files

- `src/json/cmd.zig` (new): the `zt::json` ensemble.
- `src/json/encode.zig` (new): the encoder, the schema check, and the builders.
- `src/json/compat.tcl` (new, embedded): `json::json2dict`, `json::many-json2dict`, `json::validate`, and the `json::write` commands, when the native form is not needed.
- `tests/stdlib/json.test` (new).
- `docs/modules/json.md` (new): the manual page.

## Test sources

- JSONTestSuite `test_transform/` for round trips.
- The tcllib test files `json.test` and `json_write.test`, run as outside files with the license check of rule 9. Each expected result that differs is listed in the manual.

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/json.test
CAP tools/tcllib-tests.sh json json_write
CAP python3 -I tools/bench-stdlib.py --only json --check bench/stdlib/gates.tsv
```

Gates:

- The JSON gates of the design: validate, parse, path query, and encode on the three files.
- `zt::json get` of one value in `citm_catalog.json` reads no more than the index and the path: its memory peak is below 2 times the input size.
- Size: the `json` row of the design.
