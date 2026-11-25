# Task 44: The docs, the final size table, and the speed report

Platform: shared.

## Goal

The docs of each module, the measured size table, and the speed report of all gates.

## Files

- `docs/dev/stdlib.md`: the measured state of each part.
- `docs/modules/`: one page for each module.
- README.md, `docs/dev/roadmap.md`, and `tools/build-docs.py` (the pages of the site).

## Test sources

- The results of the earlier tasks.

## Acceptance

```sh
CAP tools/size-report.sh
CAP python3 -I tools/bench-stdlib.py --check bench/stdlib/gates.tsv
python3 -I tools/build-docs.py
```

Gates:

- Each number in the docs comes from a run of this task, with its date.
