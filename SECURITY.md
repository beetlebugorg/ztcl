# Security

ztcl is experimental. Do not use it as the only barrier around hostile scripts.

## The sandbox

- By default, a script has no command for files, sockets, processes, timers, or the clock.
- An embedder can turn on capabilities. `file` and channels stay inside one root folder. `socket` reaches only the addresses that the network policy of the embedder allows. The default policy is loopback only.
- The capability `exec` is not part of the sandbox. A process that a script starts is outside the root folder and outside each limit. Turn it on only for scripts that you trust as much as the user account.
- The step limit bounds the steps of a script. The embedder must set `step_limit`. The default has no limit.
- `mem_limit` limits memory. One command can go above the limit by the size of its own result. With the collector on, the place of the error can differ between two runs. A collection runs only at a safe point. If it cannot run, no block is freed, and the limit still stops the script.
- Nesting limits protect the native stack.

The time of `lsort` and of a dict with many keys has no separate limit.

## Report a problem

Use a private report through the GitHub **Security** tab of [beetlebugorg/ztcl](https://github.com/beetlebugorg/ztcl/security/advisories/new). Include a script that shows the problem.
