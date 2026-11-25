# Task 03: The outside benchmark harness and the first numbers

Platform: Linux.

## Goal

One harness for the outside comparisons of JSON, HTTP, TLS, and SQLite, and the numbers of the other runtimes on the reference machine type of CI. The user sets the final gates from them (decision 11).

## Files

- `bench/stdlib/` (new): the scripts of each benchmark for ztcl, Node, Go, Python, and `tclsh`, and a fetch script for the data files.
- `tools/bench-stdlib.py` (new): runs each program 5 times, keeps the best, and writes a table and a TSV file. `--check FILE` compares the ratios with a gate file.
- `bench/stdlib/gates.tsv` (new): the targets of the design as ratios.
- `.github/workflows/bench.yml` (new): a manual and a weekly job that runs the harness and keeps the TSV as an artifact.
- `docs/dev/testing.md`: the section of the outside numbers.

## Test sources

- `twitter.json`, `canada.json`, and `citm_catalog.json` of the nativejson-benchmark. The fetch script checks a SHA-256 of each file. The repository has no copy.
- The TechEmpower plaintext and JSON test rules.
- `wrk`, `h2load`, `openssl s_time`, and `openssl speed`.

## Acceptance

```sh
CAP python3 -I tools/bench-stdlib.py --only json,http,tls,sqlite --others-only
CAP python3 -I tools/bench-stdlib.py --check bench/stdlib/gates.tsv --dry-run
```

Gates:

- The table has a row for each other runtime and each benchmark of the design, with the version of each runtime.
- The PR body has the table. The user sets the gates in `gates.tsv` in this PR or the next.

ztcl rows are empty until the module tasks fill them.
