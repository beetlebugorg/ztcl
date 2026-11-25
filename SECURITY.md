# Security

ztcl is experimental. Do not use it as the only barrier around hostile scripts.

## The sandbox

- By default, a script has no command for files, sockets, processes, timers, or the clock.
- An embedder can turn on capabilities. `file` and channels stay inside one root folder. `socket` reaches only the addresses that the network policy of the embedder allows. The default policy is loopback only.
- The capability `exec` is not part of the sandbox. A process that a script starts is outside the root folder and outside each limit. Turn it on only for scripts that you trust as much as the user account. See [the rules of `exec`](#the-rules-of-exec).
- The step limit bounds the steps of a script, and so its CPU time. See [the CPU time of a step](#the-cpu-time-of-a-step). The embedder must set `step_limit`. The default has no limit.
- `mem_limit` limits memory. The heap of an interpreter and its children has a hard cap: twice the `mem_limit` of the root interpreter. The counter of the heap refuses each request that goes above the cap, so a command that builds a large result stops before the allocation. Each command and loop pass checks the limit itself. So one command can go above the limit by at most the limit. Both cases stop the script with the same error, and `catch` cannot catch it. A memory error can leave live data above the limit. The next top-level eval then runs with only the hard cap until a collection brings the count below the limit. With the collector on, the place of the error can differ between two runs. A collection runs only at a safe point. If it cannot run, no block is freed, and the limit still stops the script.
- Nesting limits protect the native stack.
- The JIT is off by default, and only the embedder can turn it on. It makes machine code from bytecode that a script shapes, so it adds risk. A verifier checks each bytecode before a compile. No page is writable and executable at once, no value of a script is an immediate operand, and the step limit and the memory limit hold in machine code. See [the JIT plan](docs/jit.md#security).
- Tests check each security rule of the JIT. `tools/jit-scan.sh` searches the machine code for the constants of a script, checks the bounds and the JIT memory limit, and checks that no mapping is writable and executable after a test file. Unit tests check the entry checks of `jit.enter`, the size of the JIT frame, code with no absolute address, and the free of the region. `zig build jit-fuzz` compares random programs in the interpreter and in the JIT, and fuzzes the assembler and the verifier. The stress modes of `--jit-stress` force the rare paths of the compiler.

## The rules of `exec`

`exec` is not sandboxed, but these rules hold for each program that it starts:

- Before any process starts, the first word of each program becomes one full host path. A word with a `/` must be a full path. It names a host file, and `exec` does not look below the root folder for it. A bare name goes through the `PATH` of `exec_host.env`, or `/usr/bin:/bin` with no `PATH`. An empty or relative entry of that `PATH` is an error, `ZTCL EXEC PATH`.
- Each symlink, `.`, and `..` of the path is resolved on the host. The allowlist check uses that path, and the child runs only that path with `execve`. The child does no search of its own.
- An entry of `exec_host.allow` with a `/` matches each word that resolves to the same host file. An entry with no `/` matches only that bare word, and the program is the `PATH` match of the embedder.
- A file below the root folder never runs from `exec_host.allow`, also when a `PATH` entry, a symlink, or a bind mount leads to it. The check compares the device and inode of each folder of the resolved path with the root.
- `exec_host.allow_root` lists files below the root folder by their path in the root, for example `/tool`. Only a listed file below the root runs. A script with `file` can write each listed file, so each entry lets the script run its own code.
- Each pipeline is one process tree. On Linux the tree is a cgroup below the cgroup of the embedder, when the embedder can make one. Each child joins the cgroup before `execve`, so each descendant is in it, also after `setsid` or a double fork. At the time limit, at a memory error of the output, at a failed start, and when the interpreter ends, a write to `cgroup.kill` kills each process of the tree. A tree that still has a process after its programs end stays on a list until it is empty, so the time limit and the end of the interpreter also reach it.
- With no cgroup, the kill sends SIGSTOP to the process group, to each program, and to each process that a scan of /proc finds below them, until a scan finds no new process. Then each one gets SIGKILL. A process whose parent ended before the kill is no longer below the pipeline. Without a cgroup, a double fork can leave a process that this kill does not find.
- A program has the power of the user, so it can still leave the tree on purpose, for example with a write to a cgroup file of the user or a request to a service manager.
- macOS and Windows have no `exec` in this version. The plan for them: on macOS, the process group plus a scan of the descendants of each program at each wait and at the kill, with the same limit as the Linux scan. On Windows, a job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, where each process starts suspended, joins the job, and then resumes. `TerminateJobObject` kills the tree.

## The CPU time of a step

One step is one command, one loop pass, or one guard of the bytecode. A step that does more work uses more steps. So the CPU time of a script is at most the step limit times a bound on the work of one step. The bound has two parts:

- A command that reads or makes a value does work that grows with the size of the value. The memory limit bounds that size. For example, `string length` of a large string uses one step.
- Work that grows with a table, with the count of compares, or with the product of two sizes uses more steps, by the rule below. The commands in the table use the rule.

The rule for a command whose work grows with a table, a list, or its result: it uses one step for each 4096 units of that work. One byte is one unit. One entry of a table, one element of a list, and one compare of a sort are 64 units each. A command pays for its work before it does the work when it knows the size. These commands use the rule:

| Command | The work it pays for |
|---|---|
| `info commands`, `info procs`, `info functions` | Each command of the table. |
| `info vars`, `info globals`, `info locals` | Each variable of the frame. |
| `namespace delete` | Each namespace, each command, and each global variable. |
| `namespace forget`, `namespace import`, `namespace children`, a call of an ensemble with no map | Each command or namespace of the table, and each export pattern that it tests. |
| `rename` to the empty name, the destroy of an object | Each command of the table, and each object. |
| `interp delete`, `interp aliases` | Each command of each interpreter that it scans. |
| `array get`, `array names`, `array unset` with a pattern | Each element of the array. |
| `lsort` of n keys | n times the base 2 logarithm of n compares. |
| `string repeat`, `lrepeat` | Each byte or element of the result. |
| `string first`, `string last` | The needle length for each position that it compares. |
| `string map` | The key length for each compare of a key. |
| `trace add`, `trace remove`, and each run of the traces of a variable or a command | Each trace of the list. |
| `file delete -force`, `file copy` of a folder | Each entry of the tree: the units of one entry and one unit for each byte of its path. `file copy` also pays one entry for each folder of the target path that it checks. |

`file delete -force` and `file copy` walk a tree with a list of folders on the heap. They use no native stack for each level, so a deep tree is safe in a coroutine, and the memory limit counts the list. A walk stops with the error `ZTCL TREE DEPTH` at 2048 folder levels below the path that the script gives. `file copy` gives the error `POSIX EINVAL` before it copies when the target is the source folder or a folder below it. The check compares the device and inode of each folder of the target path with the source, so a second name of the source also fails.

A glob pattern in these commands pays for the pattern length times the string length, as in `string match`. A regular expression uses one step for each 32 steps of its matcher. An operation on big integers uses steps by the square of its size.

Two lookups have a fixed cost. After each change of the command table, the guard of the bytecode does one lookup for each inlined command name. A frame with 32 or more variables has a hash index, so a search of the frame does not read each variable.

A collection of the collector reads the live blocks. The next collection waits until the heap grows to twice the live bytes. So the work of the collector is linear in the bytes that the script allocates.

These cases have no separate limit: a dict with many keys, `split` with many split characters, and `string trim` with many characters. Their work grows with the product of two sizes, and the memory limit bounds each size.

## Report a problem

Use a private report through the GitHub **Security** tab of [beetlebugorg/ztcl](https://github.com/beetlebugorg/ztcl/security/advisories/new). Include a script that shows the problem.
