# Task 31: CSV, URLs, encodings, and the tcllib names

Platform: shared.

## Goal

`ztcl::csv`, `ztcl::url`, `ztcl::encode`, and the tcllib names of `csv`, `uri`, `base64`, `base32`, and `uuencode`.

## Files

- `src/fmt/csv.zig`, `src/fmt/url.zig`, `src/fmt/encode.zig` (new).
- `src/fmt/compat.tcl` (new, embedded).

## Test sources

- RFC 4180. The WHATWG `urltestdata.json`. RFC 4648 vectors. The tcllib test files of `csv`, `uri`, `base64`, and `base32` as outside files (rule 9).

## Acceptance

```sh
CAP zig-out/bin/ztcl tests/stdlib/formats.test
CAP tools/tcllib-tests.sh csv uri base64 base32 uuencode
```

Gates:

- Each case of `urltestdata.json` passes, or the PR lists the IDNA cases that need a Unicode table that the binary does not have.
- Size: part of the `formats` row of the design.
