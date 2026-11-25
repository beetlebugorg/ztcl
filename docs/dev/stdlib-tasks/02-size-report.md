# Task 02: The size report and its CI gate

Platform: shared.

## Goal

`tools/size-report.sh` and a CI job that reports the size of each module and fails above the budget.

## Files

- `tools/size-report.sh` (new): the builds of the design (core, full, full without each module), `strip`, and a table in Markdown and TSV.
- `tools/size-budget.tsv` (new): the rows of the size table of the design, in bytes.
- `.github/workflows/size.yml` (new): x86-64 Linux, arm64 macOS, and x86-64 Windows. The summary of the job has the table.
- `docs/dev/testing.md`: a section for the report.

## Test sources

- The budget table of `docs/dev/stdlib.md`.

## Acceptance

```sh
CAP tools/size-report.sh
CAP tools/size-report.sh --check
```

Gates:

- `--check` fails when the full build of x86-64 Linux passes 6 000 000 bytes, or when a module passes its row by more than 10 %. A test run with a planted 7 MB module shows the failure.
- The report of the wasm build: `ztcl.wasm` in `ReleaseSmall`, with the gates of the design (1.5 MB with modules, 1.0 MB with no imports).
