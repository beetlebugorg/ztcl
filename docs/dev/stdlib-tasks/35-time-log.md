# Task 35: Zones, `ztcl::time`, and `ztcl::log`

Platform: shared.

## Depends on

Decision 4 of the user.

## Goal

The embedded zone data of decision 4, `ztcl::time`, `ztcl::log`, and the tcllib `logger` subset.

## Files

- `src/tz.zig` (new): the zone data and, for `tzdata.zi`, the rule compiler to TZif.
- `src/time.zig`, `src/log.zig` (new).
- `build.zig`: `-Dtzdata`.
- `tools/tzdata-update.sh` (new): fetches a tz release, checks its signature, and makes the embedded file.

## Test sources

- The core file `clock.test`. The IANA tz release. The zone tests of the tz release (`zdump` output of each zone for 1900 to 2100 as the reference).

## Acceptance

```sh
CAP tools/suite.sh clock.test
CAP zig build tz-test
CAP zig-out/bin/ztcl tests/stdlib/time.test
```

Gates:

- The offset and the abbreviation of each zone at each transition from 1900 to 2100 equal the `zdump` reference.
- `clock.test` keeps its pass count with the embedded data in place of the host files.
- Size: the `time` row of the design.
