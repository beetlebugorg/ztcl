# Task 32: TOML, MessagePack, and CBOR

Platform: shared.

## Goal

`ztcl::toml`, `ztcl::msgpack`, and `ztcl::cbor`, with the schema and the typed tree of `ztcl::json`.

## Files

- `src/fmt/toml.zig`, `src/fmt/msgpack.zig`, `src/fmt/cbor.zig` (new).

## Test sources

- The `toml-test` suite (valid and invalid cases of TOML 1.0). RFC 8949 appendix A. The MessagePack specification.

## Acceptance

```sh
CAP tools/toml-test.sh
CAP zig-out/bin/ztcl tests/stdlib/cbor.test
CAP zig build fmt-fuzz -- --seconds 600
```

Gates:

- Each `toml-test` case of TOML 1.0 passes.
- Each vector of RFC 8949 appendix A round-trips.
- Size: the `formats` row of the design.
