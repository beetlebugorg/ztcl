# Task 33: `zlib`, `ztcl::zstd`, and HTTP content encodings

Platform: shared.

## Depends on

Task 12 for the HTTP part. The rest has no dependency.

## Goal

The core `zlib` command on `std.compress.flate`, `ztcl::zstd` with a new encoder for levels 1 to 3, and `Content-Encoding` in the HTTP client and server.

## Files

- `src/compress/zlib.zig` (new): the `zlib` command.
- `src/compress/zstd_enc.zig` (new): the encoder after RFC 8878.
- `src/compress/cmd.zig` (new).
- `src/http/`: `Accept-Encoding` and `Content-Encoding`, and the bound of the design on the output size.

## Test sources

- The core file `zlib.test`. RFC 1950, 1951, 1952, and 8878. The zstd test data of `std.compress.zstd`. The reference `zstd` program for round trips.

## Acceptance

```sh
CAP tools/suite.sh zlib.test
CAP zig-out/bin/ztcl tests/stdlib/zstd.test
CAP zig build zstd-fuzz -- --seconds 600
```

Gates:

- `zlib.test` passes each test that does not need a feature of the design list of differences.
- Each zstd frame of the encoder decodes with the reference `zstd` program, and the reverse.
- Speed: level 1 at least 0.5 of the reference `zstd -1` on the Silesia corpus, and decode at least 0.7 of `zstd -d`.
- A zip bomb input stops at the bound with an error.
- Size: the `compress` row of the design.
