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
| `mem_limit` | The memory limit in bytes. |
| `output` | The callback of `puts`. With no callback, the output is dropped. |
| `noise_seed` | The seed of `noise2` and `noise3`. |
| `user` | A pointer for the embedder. |
| `register(name, fn)` | Adds a native command. |
| `reset()` | Frees the arena and makes the interpreter new. The limits, output, seed, and `user` stay. |
| `compact(roots, opts)` | Frees the memory of past evaluations and keeps the commands, procs, namespaces, and point programs. `.vars = .clear` also drops the variables. Each value in `roots` gets a new address. All other values from before the call are invalid. Call it between evaluations. |

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

`tools/wasm-smoke.mjs` is a working example for Node.js.
