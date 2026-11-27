# FAQ

## Is ztcl a drop-in replacement for Tcl?

Not yet. ztcl passes 38,054 of the 47,133 tests of the Tcl 8.6.16 suite. Most scripts that use the core commands run unchanged. [The language](language.md) lists the differences. C extensions and Tk are out of scope. For a Tk replacement on ztcl, see [ztk](https://beetlebug.org/ztk/).

## Does it support Tcl 9?

Yes, on request. ztcl follows Tcl 8.6 by default, and `ztcl --tcl 9.1` follows Tcl 9.1: the new list commands, strict encodings, decimal numbers with a leading zero, and variable lookup in namespaces. [Tcl 9.1](tcl91.md) has the parts that are done and the parts that are not done yet.

## Why is `open` an invalid command?

A script has no host access by default. Turn on the capabilities that the script needs, for example `ztcl --allow channels,file --root DIR script.tcl`. See [Limits and capabilities](limits.md).

## Is it safe to run scripts from untrusted users?

That is the main use of ztcl. Set a compute limit and a memory limit, and turn on only the capabilities that you need. Never turn on `exec` for untrusted scripts: it is not sandboxed. [Security](../SECURITY.md) has the threat model and how to report a problem.

## Which platforms does it run on?

Linux and macOS on x86-64 and arm64, Windows on x86-64, and WebAssembly in browsers and Node.js. The JIT runs on x86-64 Linux, x86-64 Windows, arm64 Linux, and arm64 macOS. Coroutines need a stack switch, which exists for x86-64 Linux, arm64 Linux, arm64 macOS, and x86-64 Windows.

## Is the JIT on by default?

Yes, where the build and the system have it. Turn it off with `--no-jit`, `ZTCL_JIT=off`, or `Interp.disableJit`. See [The JIT](jit.md).

## Can I load C extensions?

No. Add native commands from Zig with `Interp.register`. See [Embed in Zig](embedding.md).

## Who wrote ztcl?

ztcl is a project of [beetlebug](https://github.com/beetlebugorg), built for the [zslice](https://github.com/beetlebugorg/zslice) slicer. The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it.

## Where is the roadmap?

The [issues](https://github.com/beetlebugorg/ztcl/issues) and the [milestones](https://github.com/beetlebugorg/ztcl/milestones) on GitHub. Contributors find the plans and the task lists in [`docs/dev/`](dev/README.md).
