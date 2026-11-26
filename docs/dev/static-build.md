# Plan: static binaries and a virtual file system (`ztcl build`)

Issue #40 asks for one native binary from a Tcl program, as `go build` gives, with the program compiled to machine code. The work has two phases on one binary layout:

1. Bundles: a prebuilt runtime binary of ztcl with the scripts and the files of the program in it. The interpreter runs the scripts at start, and the JIT runs where the target has one. This is the first deliverable.
2. Compiled code (AOT): the code generators of the JIT run at build time over each proc and each top-level script, and the machine code goes into the text segment of the runtime binary. See "Phase 2: compiled code".

The build runs in the `ztcl` CLI and in the browser. The build core (the payload, the patch of the runtime binary, the Mach-O signature, and in phase 2 the code generators) is Zig code on byte slices with no file system and no system call, so it also goes into `ztcl.wasm`. A page of the docs site builds an app and gives a native binary for Linux, macOS, or Windows, on x86-64 or arm64, to download. The site publishes the runtime binary of each target next to the docs.

## The command

```sh
ztcl build -o app main.tcl lib/util.tcl
ztcl build -o app-arm64 --target aarch64-linux main.tcl
ztcl build -o app.exe --target x86_64-windows --embed assets/ main.tcl
ztcl build --wasm -o app.wasm main.tcl          # the form of today
```

| Option | What it does |
|---|---|
| `-o FILE` | The output file. Required. |
| `--target TRIPLE` | The target: `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows`. The default is the host. |
| `--embed PATH` | Adds a file, or each file below a folder, under the mount `//zipfs:/app/`. The option can repeat. |
| `--runtime FILE` | The runtime binary to use in place of the one that ships with ztcl. |
| `--allow LIST` | The capabilities of the program, with the names of `ztcl --allow`. The default is `embedded`: the program reads its own files and has no access to the host. |
| `--root PATH` | Puts `file` and channels in the jail at run time, with `PATH` as the root folder. Without it, a program with `file` is in host mode (#122), as the `ztcl` runner is. |
| `--jit` | Turns on the JIT in the program, on a target with a JIT. |
| `--compress` | Stores each file with deflate. The default is stored entries, which the runtime reads with no copy. |
| `--wasm` | The form of today (`src/buildcmd.zig`), with no change. |

The scripts run in order, as `ztcl a.tcl b.tcl` does. Each script is also a file under the mount, so `source [file join [file dirname [info script]] util.tcl]` works. The words after the program name go to `$argv`. The binary reads no option of the runner, so a program has all of its words.

## The binary layout

The output is a copy of the runtime binary with one more part: a zip archive, the payload. The runtime binary has a slot, an exported 32-byte array: an 8-byte marker, the offset of the payload in the file, and its length (each a u64 in little endian). `ztcl build` finds the marker, writes the offset and the length, and adds the payload. This is the form of the wasm bundle (`src/wasmbundle.zig`), so the command patches a file and needs no Zig toolchain.

| Format | Where the payload goes |
|---|---|
| ELF (Linux) | At the end of the file, after the last section. The loader does not map it. |
| PE (Windows) | At the end of the file, as an overlay. A later Authenticode signature covers it. |
| Mach-O (macOS) | At the end of `__LINKEDIT`, before a new code signature. The command moves the old signature out, makes `__LINKEDIT` larger by the payload, and writes a new ad hoc signature (see "Signing"). |

At start the runtime reads the slot. With a zero length it is the plain `ztcl` runner. With a length it opens its own file (`std.process.executablePath`), maps the payload read-only, and mounts it. The runner with a payload is the program, so the `ztcl` binary of each target is also its runtime binary.

The zip has one entry the build makes, `.ztcl/manifest`, with one line for each setting:

```
script main.tcl
script lib/util.tcl
allow embedded
jit on
```

The build sorts the entries and writes a fixed time in each header, so the same input gives the same bytes on each host.

## The virtual file system

`src/vfs.zig` has a table of mounts for each interpreter. A mount has a prefix (such as `//zipfs:/app/`) and a source: an archive in memory (the payload of the binary, or a zip file the program read) or, later, a script handler (tclvfs `vfs::mount`). `src/zipread.zig` reads the central directory of a zip and gives each entry by name, with stored and deflate entries. `src/inflate.zig` decodes deflate. The decoder of the Zig standard library ends with an integer overflow panic on some bad input, so a new decoder checks each bound and gives an error.

The table gets each path first. The jail of `fsroot.zig`, or the host in host mode, gets the paths that no mount has:

| Command | On a mount |
|---|---|
| `open` | Read only. A write mode is the error `EROFS`. The channel has the bytes of the entry in its read buffer, so `read`, `gets`, `seek`, `tell`, and `eof` work with no file descriptor. |
| `source` | Reads the entry. |
| `file exists`, `isfile`, `isdirectory`, `size`, `stat`, `type`, `readable`, `mtime` | From the central directory. A folder is a prefix of entry names. |
| `file writable`, `delete`, `mkdir`, `rename`, `copy` to a mount | The error `EROFS`. `file copy` from a mount to the real tree is a later step. |
| `glob` | Lists the names below a folder of the mount. |
| `load` | Scripts only. A shared library in a mount is an error, and stays one: a binary library needs a real file. |

### The jail and host mode

The `file` capability has two modes: the jail of `fsroot.zig` (a root folder seen as `/`) and host mode of #122 (real host paths, as in tclsh). Embedders get the jail by default. The `ztcl` runner and a binary of `ztcl build` are programs, so they get host mode by default, and `--root` turns the jail on. The embedded mounts of a binary are visible in both modes. The mount table is outside both modes. The lookup runs on the path of the script before the jail or the host gets it, so a mount is at the same path in either mode. A mount prefix of the form `//zipfs:/...` is not a valid path in the jail or on a host, so a mount never hides a real file. In host mode a program can also mount a zip at a host folder path, such as `zipfs mount data.zip /opt/app/data`, and the files of the mount then hide the real files below that path for that interpreter. The mount table does not depend on the code of `fsroot*.zig`, so host mode and the VFS can merge in either order.

The `zipfs` command follows Tcl 9: `zipfs mount ?zipfile? ?mountpoint?`, `zipfs unmount mountpoint`, `zipfs list ?pattern?`, `zipfs info file`, `zipfs exists file`, and `zipfs root`. A mount of a zip file at run time reads the file through the jail, so the archive is a file inside the root. `zipfs mkzip`, scripted mounts, and overlays on a real folder are later steps of #40.

### Capabilities and limits

- A new capability, `embedded`, gives `open` for reading, `source`, `glob`, `file` queries, and `zipfs list`, `info`, `exists` on the mounts only. A path outside a mount is the error "permission denied". It gives no access to the host, so a sandboxed program can read its own files.
- `file` gives the full table: the mounts and the jail. `zipfs mount` of a file needs `file`.
- With no capability on, the commands are absent, as now. A test proves it.
- A child interp sees the mounts of its parent only with `embedded` or `file`.
- An entry is decompressed whole at the first open. The size of the central directory is the limit of the output, and the decompressor stops at that size. The memory limit applies before the allocation, so an entry larger than the free memory is the error "not enough memory" (a zip bomb stops there). Each byte of output is work by the rule of `cmds.chargeWork`.
- A path is normalized as text before the lookup, so `..` above the mount root is an error, as in the jail.
- A malformed archive is an error at mount time: offsets past the end, overlapping entries, names with `..` or a leading `/`, encryption, and methods other than stored and deflate. A fuzz test feeds random bytes to the reader.

## Cross-compiling

The release archive of ztcl gets a folder `lib/ztcl/runtime/` with one runtime binary for each target, made by `zig build -Dtarget=... -Doptimize=ReleaseSmall` in the release job. `ztcl build --target T` patches the binary of `T`, so each host builds each target with no toolchain. The order of the search:

1. `--runtime FILE`.
2. The environment variable `ZTCL_RUNTIME_DIR`, then `T/ztcl` (or `T/ztcl.exe`) in it.
3. `../lib/ztcl/runtime/T/` next to the folder of the program.
4. For the host target only: the program itself.

A source checkout makes the runtimes with `zig build runtimes` (a new step), which cross-compiles the runner for each target into `zig-out/lib/ztcl/runtime/`. A missing runtime is an error that names the path and the `zig build` command. A Zig backend that compiles the program at build time comes with the AOT phase of #40, when the build makes machine code.

The patch reads only the file formats, so the output depends only on the runtime binary and the input. CI builds each target on Linux, compares the hash of a build on macOS with it, runs the Linux x86-64 output, runs the Linux arm64 output under qemu where the runner has it, and runs the macOS and Windows output on those runners.

## The JIT on each target

The runtime of each target has the JIT of its back end: x86-64 on Linux, macOS, and Windows, and arm64 on Linux and macOS. `jit on` in the manifest turns it on at start, with the default options. On arm64 macOS the JIT uses `MAP_JIT`, which an ad hoc signed binary with no hardened runtime has. A program with the hardened runtime needs the entitlement `com.apple.security.cs.allow-jit`, and the docs say so. A target with no JIT runs the interpreter, and `--jit` gives a warning.

## Phase 2: compiled code

### The compiler

The AOT compiler is the JIT code generators of `src/jit/` (tier 1 and tier 2, x86-64 and arm64), run at build time over each proc and each top-level script of the program. Tier 2 gets the types from static guesses with guards, or from a profile of a training run (`ztcl run --profile`). Each guard that fails exits to the bytecode, as in the JIT. The bytecode of each proc stays in the payload as the fallback, so `eval`, `uplevel` of a string, `source`, a proc defined again, and a trace run in the interpreter, and the compiled code of a proc defined again is not used. The compute limit and the memory limit stay exact, because the compiled code makes the step checks of the JIT tiers.

The code generators are Zig that writes bytes into a buffer, with no `mmap` and no call to the code. A build of them goes into `ztcl.wasm`, so the browser and the CLI run the same compiler and give the same bytes. A JIT target and an AOT target are separate options of the code generators: AOT code is position independent. It reaches the helpers of the runtime through a table of addresses in the data region (a PC-relative load), and it reaches its constants with PC-relative addresses in its own region.

### Slot linking

The build uses no general linker. Each runtime binary has three reserved parts, made by the Zig linker when CI builds the runtime:

| Part | Where | What the build writes |
|---|---|---|
| The code region | A section in the text segment (read and execute), filled with trap instructions | The machine code of each proc and script. |
| The data region | A section in a read-only data segment | The table of the helper addresses, the constants of the code, and the relocations. |
| The table | The slot of "The binary layout", made larger | The offset and the length of the code and the data, and one record for each compiled proc: the name, the bytecode hash, and the entry offset. |

The build writes the code and the data into the regions, applies the relocations of each proc (offsets inside the regions only), and patches the table. At start the runtime reads the table and points each proc with a matching bytecode hash at its entry. The code is in the text segment of the file, so the program needs no JIT, no writable and executable page, and no `MAP_JIT` on macOS. A position-independent runtime (PIE, ASLR) needs no change, because the code uses only PC-relative addresses and the helper table, which the loader relocates as a normal data symbol.

### Region size

The AOT runtime is a separate variant of the runtime of each target, so a bundle of phase 1 has no reserved space. Its default form has a code region of 1 MiB and a data region of 256 KiB, and the regions add their full size to each binary. The JIT tiers give about 20 to 60 bytes of code for each bytecode instruction, so 1 MiB holds a program of about 25,000 bytecode instructions. These numbers are a guess, and step 6 measures them on the corpus. A program that does not fit gets the error "the program needs N bytes of code and the runtime has 1 MiB: use --runtime-size large", and the large variant has 16 MiB of code and 4 MiB of data. A program can also compile only some procs (`--aot-procs PATTERN`) and run the others in the interpreter.

### Targets

- Linux and macOS use the System V calling convention of the code generators. arm64 macOS keeps x18 free, as the arm64 JIT does now.
- Windows x86-64 uses the Win64 calling convention: the arguments in rcx, rdx, r8, and r9, 32 bytes of shadow space, and rdi, rsi, and xmm6 to xmm15 saved by the callee. The x86-64 code generator needs a Win64 form of its prologue, its epilogue, and its helper calls before AOT works on Windows. Unwind data (`.pdata`) for each proc goes in the data region.
- Microcontrollers (#9): the same compiler with a target that has no bytecode fallback (`--no-eval`), and a runtime with no interpreter. It is a later target of this compiler.

## The API of the build in the browser

The ztk docs site has a download panel for a native app (`web/download.js` of ztk, and "Download your app" in `docs/dev/interactive-docs.md` of ztk). It calls the build through one module, `ztcl-build.js`, next to the playground files:

```js
import { build } from "./ztcl-build.js";
// runtime: the bytes of the runtime binary of the target, with the slot.
// files: { name: text } for the payload. main: the first script.
// target: "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos",
// "x86_64-windows", or "aarch64-windows".
const bytes = await build({ runtime, files, main, target }); // a Uint8Array
```

The function throws an Error with the text of the build error. The site serves the runtimes in `runtimes/`, with `runtimes/manifest.json`: `{"targets": {"x86_64-linux": {"file": "...", "size": N, "sha256": "..."}}}`. The panel shows only when both files exist. The runtime of a ztk app is the `ztk` program of each target with the same slot, so the slot format stays the same for ztk. This section is a request of the ztk docs, and the step "the build page of the docs site" can change it.

## Signing

- macOS: arm64 macOS runs only signed code. The build writes an ad hoc signature in Zig, so the signature works from the CLI on each host and from the browser: a code directory with a SHA-256 hash of each 4 KiB page of the file up to the signature, the identifier of the output name, and no requirements. This is the format that the Zig linker writes for an ad hoc signature, and the reference names it. A developer ID signature and notarization stay a step on a Mac (`codesign`, then `notarytool`), after the build.
- Windows: no signature. `signtool` or `osslsigncode` signs the output after the build, and the signature covers the payload overlay.
- Linux: no signature.

## Size

The binary is the runtime plus the payload. The runtime builds with `ReleaseSmall`, and the size job (`size.yml`) reports each target. The goals:

- Hello world: at most 1.5 MB on Linux x86-64 with the interpreter and the JIT. The 1 MB goal of #40 is for the AOT phase, with `--no-eval` and a region size fit to the program, which needs a rewrite of the section headers after the code region (a later step).
- A JSON HTTP service with the batteries: at most 6 MB.
- The payload: at most the zip of the input plus 1 KiB.

## Steps

1. This plan.
2. `src/zipread.zig` and `src/vfs.zig`: the zip reader (stored and deflate), the mount table, the hooks in `open`, `source`, `glob`, and `file`, the `embedded` capability, and the `zipfs` command. Tests: zip files from Python's `zipfile` and Info-ZIP, deflate entries, a zip bomb at the memory limit, malformed archives, and the absent commands with no capability.
3. `ztcl build` native on Linux x86-64: the slot, the payload, the manifest, and the start path in `src/main.zig`. Then the other targets by cross-compile: the ELF of Linux arm64, the PE of Windows x86-64, and the Mach-O with the ad hoc signature of macOS x86-64 and arm64. A CI job builds each target on Linux and runs each output on a runner of its OS.
4. The user page `docs/build.md` with examples that ran, and a line in the README.

Phase 2, after step 4 ([the task list](aot-tasks/README.md)):

5. An AOT target in the code generators: position-independent code, the helper table, and the relocations, with a test that compares AOT code with JIT code on `tests/jit/`.
6. The reserved regions in the runtime, the table at start, and `ztcl build --aot` on Linux x86-64, checked with `tools/jit-diff.sh` against the interpreter.
7. arm64 Linux and macOS, then Win64 for Windows x86-64.
8. The code generators and the build core in `ztcl.wasm`, and the build page of the docs site.

The macOS and Windows parts of step 3 can go to a session on those machines. Each part is in new files (`src/buildnative.zig`, `src/macho_sign.zig`) with small hooks in `src/buildcmd.zig` and `src/main.zig`.
