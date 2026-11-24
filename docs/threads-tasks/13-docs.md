# Task 13: the counts and the docs

Platform: shared.

## Goal

The docs give the state after tasks 01 to 12.

## Files

- `docs/compatibility.md`: the counts of `thread.test`, `socket.test`, and `unixNotfy.test` from `tools/suite.sh -a`, and the move of `thread.test` out of "Cannot apply".
- `tools/suite-scope.tsv`: the scope of `thread.test` and `unixNotfy.test`.
- `docs/design.md`: the new files.
- `docs/embedding.md`: the capability, `thread_limits`, and the rule that the allocator of the embedder is safe for threads.
- `SECURITY.md`: the limits of threads and the stop flag.
- `docs/threads.md`: the state of each part.

## Acceptance

`python3 tools/suite-table.py` gives the same table as `docs/compatibility.md`.
