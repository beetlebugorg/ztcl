# Modules

The `ztcl::` modules are built into ztcl. A module loads with `package require`, for example `package require ztcl::json`. A module that reaches the host needs a capability, and only an embedder or a flag of the `ztcl` program turns it on. [Limits and capabilities](../limits.md) tells how.

| Module | What it does | Capability | Platforms |
|---|---|---|---|
| [ztcl::json](json.md) | Parses and writes JSON. | none | each target, and WebAssembly |
| [ztcl::vt](vt.md) | Keeps the state of a terminal: the cells, the cursor, the modes, and the scrollback. | none | each target, and WebAssembly except `ztcl-threads.wasm` |
| [ztcl::probe](probe.md) | Records the values of a running script at a proc, a line, a command, a variable, or an error, with no change to the script. | none | each target, and the WebAssembly shell (`ztcl-shell.wasm`) |
| [ztcl::disasm](disasm.md) | Shows the bytecode of a proc, a lambda, or a script under the source line of each command, and gives `::tcl::unsupported::disassemble`. | none | each target, and the WebAssembly shell (`ztcl-shell.wasm`) |
| [ztcl::wasm](wasm.md) | Runs WebAssembly modules, and WASI programs of C, Zig, Rust, or Go, in the limits of the interpreter. | none; `file`, `clock`, and `random` for WASI | each native target |
| [ztcl::tls](tls.md) | Opens a TLS 1.3 connection to a server, as a channel. | `socket`, `channels` | Linux, macOS, x86-64 Windows |
| [ztcl::pty](pty.md) | Runs a program on a pseudo-terminal, as a channel. | `exec` | Linux, macOS, x86-64 Windows |
| [ztcl::watch](watch.md) | Gives the changes of the files below a folder. | `file` | Linux, macOS, x86-64 Windows |
| [ztcl::open](open.md) | Opens a URL or a file in the default app of the system. | `launch` | macOS, Windows; Linux with a host callback |
| [ztcl::notify](notify.md) | Shows a notification of the system. | `notify` | macOS; the others with a host callback |
| [ztcl::vm](vm.md) | Starts a small Linux guest on the hypervisor of the host. | `vm` | macOS |
| [ztcl::meter](meter.md) | Counts the compute units, the time, the memory, and the I/O of threads, for billing. | `meter` | each target with threads |
| [ztcl::win](win.md) | The registry, the credentials, and the known folders of Windows. | `registry`, `credential`, `env` | Windows |
| [web](web.md) | The Web APIs of the page, such as Web Serial, through the table of the Web IDL. | a group of `web:` in `allow` | `ztcl-host.wasm` in a browser |
| [ztcl::agent](agent.md) | Runs an LLM agent loop in an isolated thread with only the data and the tools of the host. | `thread`, and `socket` and `channels` for the endpoint | each target with threads |
| [ztcl::mac](mac.md) | The keychain and the defaults of macOS. | `keychain`, `defaults` | macOS |

[Targets](../targets.md) lists the features of each target.
