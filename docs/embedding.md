# Embedding in Zig

## Add the package

```sh
zig fetch --save git+https://github.com/beetlebugorg/ztcl
```

```zig
// build.zig
const dep = b.dependency("ztcl", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ztcl", dep.module("ztcl"));
```

## Run a script

An `Interp` must not move after `init`. Set the limits before you run a script from an untrusted source.

```zig
var it: ztcl.Interp = undefined;
try it.init(gpa);
defer it.deinit();
it.step_limit = 1_000_000;
it.mem_limit = 64 << 20;
const v = try it.eval("expr {6 * 7}");
const text = try it.str(v);
```

On `error.TclError`, `it.result` holds the message and `it.error_line` holds the line.

| Field or function | Use |
|---|---|
| `step_limit` | The steps left. The default has no limit. |
| `mem_limit` | The memory limit in bytes. A request fails when the heap then holds more than twice this count. A memory error can leave live data above the limit. A top-level `eval` that starts above the limit runs a collection first. While the live data stays above the limit, only the hard cap applies to that `eval`. |
| `output` | The callback of `puts`. With no callback, the output is dropped. |
| `noise_seed` | The seed of `noise2` and `noise3`. |
| `user` | A pointer for the embedder. |
| `register(name, fn)` | Adds a native command. |
| `reset()` | Frees the heap and makes the interpreter new. The limits, output, seed, and `user` stay. |
| `hold(v)`, `release(v)` | `hold` keeps a value and each block that it reaches until `release`. A value from `eval` is valid until the next call into the interpreter. Hold it for longer. `compact` ends each hold. |
| `addRoot(bytes)`, `removeRoot(bytes)` | Registers a range of memory of the embedder that holds values. The collector reads each aligned word of the range as a possible pointer. |
| `collect()` | Runs a collection now. Between evaluations, only the roots keep a value. |
| `enterHost()`, `leaveHost()` | Let the collector run during host calls of `evalCmd`, `call`, or `callWords`, and scan the frame of the calling function. With no `enterHost`, these calls run with no collection, and the memory limit stops a long script. `eval` needs neither call. |
| `gc_on` | False turns the collector off. The memory limit is then exact. |
| `compact(roots, opts)` | Frees the memory of past evaluations and keeps the commands, procs, namespaces, and point programs. `.vars = .clear` also drops the variables. Each value in `roots` gets a new address. All other values from before the call are invalid. Call it between evaluations. It returns `error.InterpBusy` for an interpreter with a capability, a child, a coroutine, or a TclOO object. |

## The JIT

On x86-64 Linux, the default build has a compiler from bytecode to machine code. It is off until the embedder turns it on:

```zig
if (!it.enableJit(.{})) {
    // The build or the system has no JIT. The interpreter runs each script.
}
```

| Option | Use |
|---|---|
| `threshold` | The calls of a proc before it compiles (default 2). 0 compiles before the first run. A body with a loop compiles at its first call. |
| `mem_limit` | The most bytes of executable memory and JIT data of the interpreter and its children (default 16 MiB). It is outside the `mem_limit` of the interpreter. |

- A script cannot turn the JIT on or see it. With the JIT on, a script gives the same output, the same steps, and the same memory count.
- `enableJit` returns false when the build has `-Djit=false`, the target has no backend, the layout probe fails, or the system refuses executable memory (for example SELinux `execmem` rules, a seccomp filter, or `PR_SET_MDWE`). A build with `-Dgc-precise=true` has no JIT.
- A child interpreter gets the JIT only when its parent has it.
- `reset`, `compact`, and `deinit` free the machine code.
- The JIT is not a capability, so `compact` accepts an interpreter with the JIT on.

## Point procs

`point.install` adds the `point` command. This complete program runs a point proc over two points:

```zig
const std = @import("std");
const ztcl = @import("ztcl");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var state: ztcl.point.State = .{};
    var it: ztcl.Interp = undefined;
    try it.init(gpa);
    defer it.deinit();
    it.step_limit = 1_000_000;
    it.mem_limit = 64 << 20;
    try ztcl.point.install(&it, &state);

    _ = try it.eval(
        \\point proc fuzzy {x y z feature} {
        \\    if {$feature ne "outer_wall"} { return }
        \\    set n [noise3 $x $y [expr {$z * 4}]]
        \\    offset [expr {$n * 0.3}]
        \\}
    );
    const program = state.program("fuzzy").?;

    const x = [_]f64{ 1.5, 2.5 };
    const y = [_]f64{ 0.5, 0.25 };
    const z = [_]f64{ 0.2, 0.2 };
    const feature = [_]u8{ 0, 1 }; // outer_wall, inner_wall
    var offset = [_]f64{ 0, 0 };

    var points: ztcl.point.Points = .{ .len = 2, .feature = &feature };
    points.in[@intFromEnum(ztcl.point.Field.x)] = &x;
    points.in[@intFromEnum(ztcl.point.Field.y)] = &y;
    points.in[@intFromEnum(ztcl.point.Field.z)] = &z;
    points.out[@intFromEnum(ztcl.point.Out.offset)] = &offset;

    const scratch = try gpa.alloc(f64, program.scratchLen());
    defer gpa.free(scratch);
    program.run(&points, scratch);
    std.debug.print("{d} {d}\n", .{ offset[0], offset[1] });
}
```

A program is read-only when it runs. Two threads can run one program if each thread has its own scratch memory.

## Capabilities

The default interpreter has no host access. `Interp.allow` turns on optional commands, and each one needs data from the embedder:

```zig
const cap = ztcl.interp.Capability;
try it.allow(@intFromEnum(cap.channels) | @intFromEnum(cap.event) | @intFromEnum(cap.socket));
it.event_host = .{ .now = myTicks, .sleep = mySleep }; // the clock of the event loop
it.net = (try ztcl.sock.parsePolicy(gpa, "allow=10.0.0.0/8:443,build.example:8080")).?;
ztcl.sys.ignorePipeSignal(); // a write to a closed peer is an error, with no signal
```

| Capability | Data of the embedder |
|---|---|
| `clock` | `Interp.clock_host`: the time and the zone data. |
| `channels`, `file` | `ztcl.fsroot.setRoot`: the one root folder. |
| `event` | `Interp.event_host`: a clock that does not go back, and a sleep. |
| `socket` | `Interp.net`: the network policy. The default is `loopback`. |
| `exec` | `Interp.exec_host`: the program list, the time limit, and the environment. |

`exec` is not sandboxed. A process that a script starts has the full power of the user. Give a program list and a time limit, and turn `exec` on only for scripts that you trust.

## WebAssembly

`zig build wasm` makes `zig-out/lib/ztcl.wasm`. It exports a small C ABI:

| Export | Use |
|---|---|
| `ztcl_new`, `ztcl_delete` | Make and free an interpreter. |
| `ztcl_alloc`, `ztcl_free` | Manage memory for script text. |
| `ztcl_eval(h, ptr, len)` | Runs a script. Returns 0 or 1. |
| `ztcl_result_ptr`, `ztcl_result_len` | The result or the error message. |
| `ztcl_output_ptr`, `ztcl_output_len`, `ztcl_output_clear` | The text of `puts`. |
| `ztcl_set_step_limit`, `ztcl_set_mem_limit` | The limits. |
| `ztcl_set_gc_stress(h, n)` | A test mode: a collection at each Nth safe point. |

The result pointer is valid until the next `ztcl_eval`. The build reclaims memory while a script runs. A long loop in a native command other than `catch`, `try`, `eval`, `uplevel`, `apply`, `namespace eval`, or a method, for example the body of `lmap`, holds its garbage until that command ends. The memory limit still stops it.

[WebAssembly](webassembly.md) has the JS module `web/ztcl.mjs` and examples for the browser and Node.js. `tools/wasm-smoke.mjs` is a minimal example for Node.js. `tools/wasm-mem.mjs` checks the memory in Node.js or in a browser.
