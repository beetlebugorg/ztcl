# Task 06: the gates of milestone 0

## Goal

Prove milestone 0 on the outside programs and record the numbers.

## Files

- `docs/testing.md`: a section for the memory tests and the outside programs, with the measured table.
- `docs/jit.md`: the final gate numbers of the two `bf` rows, after the user sets them.
- `docs/roadmap.md`: remove the item about the arena if it is solved.

## Acceptance

```sh
CAP tools/mem-flat.sh                 # exit code 0
CAP tools/kostya.sh                   # all three programs, default memory limit of 2 GiB
CAP tools/suite.sh -a -r zig-out/bin/ztcl-suite    # pass 37383
CAP tools/suite.sh -g 64 -a -r zig-out/bin/ztcl-suite   # pass 37383
```

Gates:

- `bf.tcl bench.b`, `bf_oo.tcl bench.b`, and `base64/test.tcl` end. The output of each equals the output of `tclsh` 8.6.16, with the two time fields of `base64` removed.
- The peak of `memUsed` of each program is at most 64 MiB.
- Report the instruction count of ztcl and of `tclsh` for each program, and the ratio. These are the first full numbers. The user sets the final `bf` gates of milestone B and of the JIT from them.

A full run of `bench.b` on `tclsh` needs about six minutes on the reference machine. Run each program one time.

## Must not change

The benchmark files.
