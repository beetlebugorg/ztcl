# CI times

This file records the wall times of the CI workflow (`.github/workflows/ci.yml`) for pull requests, before and after each change of issue #270. The wall time of a pull request is the time from the start of the run to the end of its last job. The slowest job sets it.

## Before (2026-11-26)

Runs of three pull requests on main at 346dc5c, in minutes:

| Job | iso-thread-fixes (code) | perf-ideas (docs and tools) | wasi-06-native (wasm) |
|---|---|---|---|
| WebAssembly | 13.1 | 13.5 | 10.8 |
| ztcl build (ubuntu-latest) | 5.5 | 6.2 | 4.9 |
| C packages (Linux) | 3.1 | 3.4 | 4.7 |
| Test (ubuntu-latest) | 3.9 | 4.0 | 3.3 |
| Tcl 8.6.16 suite | 2.0 | 4.1 | 3.7 |
| WASI | 2.0 | 2.1 | 1.9 |
| docs | 1.5 | 1.3 | 1.1 |
| Run wall time | 13.9 | 17.0 | 13.4 |

The perf-ideas PR changed files in `tools/`, so all the code jobs ran.

The steps of the WebAssembly job in the iso-thread-fixes run, in seconds:

| Step | Time |
|---|---|
| `zig build wasm` | 112 |
| `zig build wasm-shell` | 23 |
| `zig build wasm-host` | 25 |
| `zig build enclave-core` | 15 |
| `zig build` (native) | 133 |
| Procs compiled to wasm (`zig build wasm-aot` and the checks) | 191 |
| Point procs compiled to wasm | 218 |
| `zig build wasm-threads` and its checks | 42 |

Facts from the logs of these runs:

- `mlugg/setup-zig` caches the Zig toolchain and the Zig cache today. It sets `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to `.zig-cache`, restores the cache of the last run of the same job, and saves a new cache at the end of each job. The WebAssembly job restored 263 MB.
- A change in `src/` changes the input of each artifact, so each artifact compiles again with a warm cache too. The cache helps the build runner and the artifacts that do not use the changed files.
- The Actions cache of the repository is at its limit of 10 GB (44 caches). Each pull request saves a cache for each job, and GitHub deletes the oldest caches first, so the caches of main go out after a few hours.
- The concurrency group was `ci-<ref>` with cancel-in-progress for each event. A push to main cancelled the run of the push before it, so its jobs saved no cache. The scheduled run of 2026-11-26 21:42 was cancelled in the same way.

## Changes

1. The WebAssembly job is three jobs that run at the same time: the libraries (`wasm`), the compiled procs (`wasm-aot`), and the point procs (`wasm-point`). Each job builds all of its steps with one `zig build`. A run on main or a scheduled run is no longer cancelled by a later push.
2. The Test, C packages, and ztcl build jobs each build with one `zig build` (`zig build install test`, `zig build install runtimes`).
3. The changes job has a `wasm` output. The three WebAssembly jobs and the WASI job run only when a pull request changes a file that they build or run (`src/`, the build files, `wit/`, `web/`, `npm/`, `enclave/`, `bench/`, and the tests and tools of WebAssembly). Pushes and the scheduled run run them always.
4. The Test job on Linux saves the Zig cache only on a push to main, with `actions/cache` and a key of the Zig version, the build files, and the commit. A pull request restores the newest cache of main. The other jobs keep the cache of `mlugg/setup-zig`.

## After

| Change | Pull request | Slowest job | Run wall time |
|---|---|---|---|
| 1 (three WebAssembly jobs) | #303 (CI files) | ztcl build, 6.5 | 7.8 |
| 2 (one `zig build` for each job) | #305 (CI files) | WebAssembly, point procs, 8.9 | 11.4 (the Size workflow) |

In the #303 run, the WebAssembly jobs took 1.8, 6.0, and 5.8 minutes. In the #305 run, the ztcl build job took 4.7 minutes (6.5 in #303) and the Test job 5.2 minutes. Many pull requests of other agents ran at the same time, so the times of single jobs change by 2 or 3 minutes from run to run. The Size workflow (`size.yml`) ran seven builds in sequence and took 11.4 minutes. #306 starts them in parallel, but the job took 11.4 minutes after it too (report 6.7 and plant check 4.7, against 5.8 and 5.4 before). Each `zig build` already uses the 4 cores of the runner.

## Incremental compilation (not used)

Zig 0.17.0 has `-fincremental`. It is a flag of the build runner, so it applies to each compile step of the build, also to the steps that use LLVM: the ReleaseFast ztcl of `install` and the generators of the ghostty package (`-fllvm`). Times of `zig build install test -fincremental -j2` on a development machine with other builds at the same time, in seconds:

| Build | Time | Result |
|---|---|---|
| Empty cache | 396 | pass |
| One function changed (`coreFn` in src/cmds.zig) | 324 | pass |
| No change | 129 | fail: `ld.lld: props-unigen_zcu.o: section header string table index 1 does not exist` |
| No change, again | 378 | pass |

The incremental state gave a broken object file on a build with no change, and the builds after a change were not much faster than a build from an empty cache. A fallback to a full build after a failure would add a full build to each such run. The CI jobs do not use `-fincremental`. Check it again with the next version of Zig.

## Areas of a pull request (2026-11-27)

Measured over the 278 CI runs of 2026-11-25 to 2026-11-27: a pull request run took 26.2 minutes from the push to the end of its last job (median; 52.9 at the 90th percentile). A job waited 7 minutes in the queue (median), because each run started about 13 jobs and many pull requests ran at the same time. The JIT job on arm64 Linux took 14.4 minutes, and it used the most job time (2,724 of 12,061 job-minutes).

`tools/ci-changes.sh` puts each changed file of a pull request in the first area that it matches. A file that matches no area is in the area core. A change of a workflow, `build.zig`, `build.zig.zon`, or `tools/ci-changes.sh` runs each job. Pushes to main and the full runs run each job.

| Area | Files |
|---|---|
| docs | `docs/`, the `.md` files at the top, `licenses/`, `specs/`, the tools of the site and of the reference pages |
| jit | `src/jit/`, `src/jit.zig`, `src/disasm.zig`, `tests/jit/`, `tools/jit-*` |
| vm | `src/vm/` (virtio, NAT), `src/kvm.zig`, `src/microvm.zig`, the other files of the microVMs, `src/uk/`, `tools/vm-guest/` |
| wasm engine | `src/wasmrt/`, `src/wasm_spec.zig`, `src/wasm_fuzz.zig`, `tests/wasm/` |
| cext | `src/cext/`, libztcl, the stubs, `tests/cext/`, `tools/cext/`, `tools/libztcl/` |
| web | `web/`, `npm/`, `wit/`, `enclave/`, the wasm and WASI files of `src/`, `tests/web/`, `tests/point/`, the wasm tools |
| stdlib | `src/tls/`, `src/crypto/`, `src/h2/`, `src/json/`, `src/text/` and their tools |
| native | the files of one host OS, the unit test files, `src/shell/reference.txt`, `packaging/` |
| core | each other file (the interpreter, `src/vm.zig`, channels, aio, `tools/`) |

| Job | Runs when these areas change |
|---|---|
| Test, ztcl build, WebAssembly | each area except docs |
| JIT (ubuntu-24.04-arm), unit tests | core, jit, vm, wasm engine, cext, stdlib, native |
| JIT (ubuntu-24.04-arm), differential test and fuzzer | core, jit |
| Tcl 8.6.16 suite | core, jit |
| C packages (Linux) | core, jit, cext |
| C packages (WebAssembly) | core, cext, web |
| WebAssembly, compiled procs and point procs | core, jit, web |
| WASI | core, web, stdlib, cext |
| wasm engine | core, wasm engine, cext |
| docs (the site, the examples of the pages, the format check) | docs |

The JIT job on arm64 also skips the times of the JIT on pull requests: that step checks nothing.

The job `Linux ok` needs each job of the run. It passes when each job passed or was skipped, and it fails when a job failed or was cancelled.

## Pull requests: the quick check and QA (2026-11-27)

The gate of a pull request is the commit status `qa/linux` (required), and `qa/macos` and `qa/windows` when the change touches their code. The QA agents test the head commit of each pull request on our machines and post these statuses. The release agent merges on them. The process is in the workflow pipeline of the project specs.

GitHub CI on a pull request is advisory. It runs only:

- `changes`. Its log shows the jobs that the changed files pick (`tools/ci-changes.sh` with the table above), so that QA runs the same set.
- `Quick check`: `zig fmt --check build.zig src`, `zig build`, and one script.
- `Linux ok`.

Each push to main runs the full Linux set, and the scheduled run every 6 hours runs the full matrix of each OS. Both are the same as before. When main goes red, the release agent stops the merges and opens a fix.

## Our own runners (2026-11-27)

The account can run a fixed number of jobs on the runners of GitHub at one time, and the runs of all the repositories wait for these slots. Our own runner adds a slot. It runs the Linux x64 jobs of a push to main that run in a container: the C packages, the suite, the wasm compile jobs, WASI, the wasm engine, and the Linux ztcl build. The Test job needs user namespaces and a cgroup of its own, the WebAssembly job needs Chrome, and the docs job needs the Python of setup-python, so these jobs stay on GitHub.

### Routing

The variable `CI_SELF_HOSTED` of the repository picks where the jobs of a push to main run: `main` for our runner, `off` or no value for GitHub. Pull requests, the scheduled full run, runs by hand, `ci-image.yml`, `release.yml`, `npm.yml`, the VM image release, and the environment `vm-release` always run on GitHub. A push that changes `ci/runner/` also runs on GitHub, because the image of its Dockerfile is not published yet.

GitHub has no fallback from a busy or offline runner to its own runners, and the `GITHUB_TOKEN` of a job cannot read the state of the runners. When our runner is offline, set the variable to `off`:

```sh
gh variable set CI_SELF_HOSTED -R beetlebugorg/ztcl -b off
```

The 6-hourly full run always runs on GitHub, so it also checks main when our runner is offline.

### The image

`ci/runner/Dockerfile` builds the image: Ubuntu 24.04 (pinned by digest), Zig 0.17.0 and Node.js 22 (each pinned by SHA-256), Tcl 8.6.16 built from its source release (`ci/runner/build-tcl.sh`, pinned by SHA-256) with its headers, stub library, and `/usr/local/lib/tclConfig.sh`, qemu-user, Python 3, git, and curl. `ci-image.yml` builds it for x86-64 and arm64 on a push to main that changes `ci/runner/`, and publishes `ghcr.io/beetlebugorg/ztcl-ci:<tag>`. The tag is the first 16 digits of the SHA-256 of the Dockerfile, and `ci.yml` computes the same tag. The jobs that compare with tclsh on the runners of GitHub build Tcl 8.6.16 with the same script, because Ubuntu 24.04 has 8.6.14 and the tests expect 8.6.16.

### Threat model

- The repositories are public. A pull request can have any code, so no pull request runs on our runner: only pushes to main do, and only collaborators can push to main. The workflows of a fork need an approval.
- Each job runs in a new container of the image. The container drops each capability, has `no-new-privileges`, and runs as the user `ci` (uid 1000, the uid of the runner, in no other group). It has a limit of 4 CPUs, 8 GB of memory, and 4,096 processes, and a CPU share of 256.
- The runner of GitHub mounts the socket of Docker into each job container. The socket on the host is `root:docker`, mode 660, and the user `ci` is not in that group, so a job cannot open it. The runner refuses a job with no `container:` (`ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=true`).
- The Zig cache is the volume `ztcl-zig-main`. Only pushes to main write it. The QA agents keep their caches of pull requests apart from it.
- No job on our runners has a secret: release, signing, npm, and the VM image release run on GitHub.
- No job gets `/dev/kvm` or a privileged container. The KVM tests stay in `vm-guest.yml` on GitHub.

### Set up a runner on a Linux host

Run these commands as the user that owns the runner (not root). The user must be in the group `docker`. Get the token from Settings, Actions, Runners, New self-hosted runner, of the repository. Do not keep the token in a file.

```sh
repo=ztcl   # also ztk and dockyard
v=2.329.0   # the version that the settings page shows
mkdir -p ~/.local/share/gh-runners/$repo && cd ~/.local/share/gh-runners/$repo
curl -sSfLO https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-x64-$v.tar.gz
tar -xzf actions-runner-linux-x64-$v.tar.gz
./config.sh --url https://github.com/beetlebugorg/$repo --name linux-x64-1 \
  --labels docker,trusted --unattended --token <TOKEN>
echo ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=true >> .env
systemctl --user enable --now gh-runner@$repo
loginctl enable-linger "$USER"
```

The unit `~/.config/systemd/user/gh-runner@.service` runs `run.sh` with `Nice=10`, `CPUWeight=20`, `IOWeight=20`, and `MemoryMax=6G`. The containers are children of dockerd, so their limits come from the options of the job.

Then turn on the runner for the repository:

```sh
gh variable set CI_SELF_HOSTED -R beetlebugorg/ztcl -b main
```

The package `ztcl-ci` on GitHub must be public, so that a runner pulls it with no token: Packages, ztcl-ci, Package settings, Change visibility, Public.

State on 2026-11-28: the package is public, and `CI_SELF_HOSTED` is `main` for ztcl. The runner `linux-x64-1` runs the Linux container jobs of each push to main.

### Set up a runner on a Mac

The runner of GitHub runs job containers only on Linux. On a Mac, the runner runs in a Linux arm64 container of Docker Desktop, and it starts the job containers next to it through the socket of Docker Desktop. The work directory must have the same path in the runner container and in the VM of Docker Desktop. The labels are `self-hosted`, `Linux`, `ARM64`, `docker`, and `trusted`. No job of `ci.yml` uses the label `ARM64` yet: the JIT job on arm64 moves there in a later change.
