# Task 06: `thread::transfer`, `thread::detach`, and `thread::attach`

Platform: Linux. The channel capability exists only on Linux.

## Goal

A file or socket channel moves between threads with its name and its options.

## Files

- `src/tchan.zig` (new).
- `src/chan.zig`: one function that removes a channel from a table and one that adds it.

## Rules

1. A detached channel is a descriptor and its options in group memory.
2. A server socket, a command pipeline, and a channel with a handler of `fileevent` give an error.
3. Buffered output goes out before the move. Buffered input moves with the channel.
4. `endGroup` closes each detached channel.

## Acceptance

New tests in `tests/thread/`: a file channel and a loopback socket move to a thread and back, and each refused kind gives its error.
