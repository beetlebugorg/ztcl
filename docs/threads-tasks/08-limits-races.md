# Task 08: the tests of the capability, the limits, the teardown, and the races

Platform: shared.

## Goal

Tests that show the capability and its limits hold under load.

## Files

- `tests/thread/` and a runner for them in `build.zig` or `tools/`.

## Tests

1. The capability is absent by default, in a safe child, and in a child of a thread.
2. `max_threads`: the next `thread::create` fails, and the count comes back after a join.
3. The step limit and the memory limit of one thread stop only that thread. The error goes to `thread::errorproc` and to the joiner.
4. `total_mem` and `total_steps` stop a thread and leave the others running.
5. A thread that passes its memory limit while 7 others run.
6. `thread::cancel` of a thread in a bytecode loop, in a native loop, in `vwait`, in a mutex wait, and in a condition wait.
7. Teardown of the host with threads in each of these states, and with sends in the queues.
8. 64 threads that start and end in a loop, 200 times.
9. 8 threads on one `tsv` element, and 8 threads on 8 arrays.
10. Each test with the JIT on (`--jit --jit-threshold 0`) and with `--gc-stress 1`.

## Acceptance

Each test passes 20 runs in a row under `timeout`. No run leaves a thread or a process.
