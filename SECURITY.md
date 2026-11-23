# Security

ztcl is experimental. Do not use it as the only barrier around hostile scripts.

## The sandbox

- A script has no command for files, sockets, processes, or the clock.
- The step limit bounds the steps of a script. The embedder must set `step_limit`. The default has no limit.
- `mem_limit` limits memory. One command can go above the limit by the size of its own result.
- Nesting limits protect the native stack.

The time of `lsort` and of a dict with many keys has no separate limit.

## Report a problem

Use a private report through the GitHub **Security** tab of [beetlebugorg/ztcl](https://github.com/beetlebugorg/ztcl/security/advisories/new). Include a script that shows the problem.
