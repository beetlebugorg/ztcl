# Converted by tools/refdoc.tcl convert from ztcl.txt.

command ztcl::wasm {
    area ztcl
    since TODO
    synopsis {ztcl::wasm subcommand ?arg ...?}
    summary {Runs WebAssembly modules in the sandbox and the limits of the interpreter: decodes and validates a module, links its imports to Tcl commands, other instances, or WASI preview 1, and calls its exports with Tcl values.}
    description {Runs WebAssembly modules in the sandbox and the limits of the interpreter: decodes and validates a module, links its imports to Tcl commands, other instances, or WASI preview 1, and calls its exports with Tcl values. Load it with `package require ztcl::wasm`.}
    cost {one compute unit for each call and each loop pass of the wasm code}
    page {modules/wasm.md}
    subcommand load {
        synopsis {load fileName}
        summary {Reads, decodes, and validates a module file, and gives a module handle.}
        description {Reads, decodes, and validates a module file, and gives a module handle. Needs the capability `file`.}
    }
    subcommand new {
        synopsis {new bytes}
        summary {Decodes and validates the bytes of a module, and gives a module handle.}
        description {Decodes and validates the bytes of a module, and gives a module handle.}
    }
    subcommand instantiate {
        synopsis {instantiate module ?option value ...?}
        summary {Links the imports (`-imports`, `-link`, `-wasi`), runs the start function, and gives an instance handle.}
        description {Links the imports (`-imports`, `-link`, `-wasi`), runs the start function, and gives an instance handle.}
    }
    subcommand call {
        synopsis {call instance function ?-limit units? ?-raw? ?--? ?arg ...?}
        summary {Calls an export and gives its result, a list of its results, or an empty string.}
        description {Calls an export and gives its result, a list of its results, or an empty string.}
    }
    subcommand package {
        synopsis {package fileName ?prefix? ?-wasi dict?}
        summary {Loads a Tcl C package built for `wasm32-wasi` with `libztclstubs.a` and runs its init function.}
        description {Loads a Tcl C package built for `wasm32-wasi` with `libztclstubs.a` and runs its init function. Needs the capability `file`.}
    }
    subcommand run {
        synopsis {run module|fileName ?option value ...?}
        summary {Runs a WASI command (`_start`) and gives its exit code.}
        description {Runs a WASI command (`_start`) and gives its exit code.}
    }
    subcommand memory {
        synopsis {memory instance size|grow|read|write|string ?arg ...?}
        summary {Reads, writes, and grows the linear memory of an instance.}
        description {Reads, writes, and grows the linear memory of an instance.}
    }
    subcommand global {
        synopsis {global instance name ?value?}
        summary {Reads or sets an exported global.}
        description {Reads or sets an exported global.}
    }
    subcommand exports {
        synopsis {exports module|instance}
        summary {A list of name, kind, and type for each export.}
        description {A list of name, kind, and type for each export.}
    }
    subcommand imports {
        synopsis {imports module}
        summary {A list of module, name, kind, and type for each import.}
        description {A list of module, name, kind, and type for each import.}
    }
    subcommand info {
        synopsis {info module}
        summary {A dict of the counts and the features of a module.}
        description {A dict of the counts and the features of a module.}
    }
    subcommand delete {
        synopsis {delete handle ?handle ...?}
        summary {Deletes modules and instances.}
        description {Deletes modules and instances.}
    }
    subcommand jit {
        synopsis {jit ?boolean?}
        summary {Reads or sets the use of the JIT tier for the calls of the interpreter.}
        description {Reads or sets the use of the JIT tier for the calls of the interpreter. Gives 1 when the JIT is on. The JIT is on by default on x86-64 Linux and macOS, and the interpreter runs elsewhere.}
    }
}
