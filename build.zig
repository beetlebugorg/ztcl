// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `-Dgc-precise=true` builds the root rules of WebAssembly on a
    // native target, so the stress tests run them with safety checks.
    const gc_options = b.addOptions();
    const gc_precise = b.option(bool, "gc-precise", "Use the precise roots of WebAssembly") orelse false;
    gc_options.addOption(bool, "gc_precise", gc_precise);
    // `-Djit=false` builds no JIT code. The default is true on a target
    // with a backend: x86-64 Linux.
    const t = target.result;
    const jit_backend = t.cpu.arch == .x86_64 and t.os.tag == .linux;
    gc_options.addOption(bool, "jit", b.option(bool, "jit", "Build the JIT compiler") orelse jit_backend);
    // `-Drunner-optimize` sets the mode of the runner and the suite runner.
    const runner_optimize = b.option(std.builtin.OptimizeMode, "runner-optimize", "The mode of the runners") orelse .ReleaseFast;

    // The module that other packages import.
    const ztcl = b.addModule("ztcl", .{
        .root_source_file = b.path("src/ztcl.zig"),
        .target = target,
        .optimize = optimize,
    });
    ztcl.addOptions("build_options", gc_options);

    const tests = b.addTest(.{ .root_module = ztcl });
    b.step("test", "Run the tests of the interpreter").dependOn(&b.addRunArtifact(tests).step);

    // The runner and the benchmark always build in ReleaseFast.
    const fast = b.createModule(.{
        .root_source_file = b.path("src/ztcl.zig"),
        .target = target,
        .optimize = runner_optimize,
    });
    fast.addOptions("build_options", gc_options);

    const exe = b.addExecutable(.{ .name = "ztcl", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = runner_optimize,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run a script: zig build run -- script.tcl").dependOn(&run.step);

    const bench_exe = b.addExecutable(.{ .name = "ztcl-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run the benchmark of the point procs").dependOn(&bench_run.step);

    // The suite runner: the runner with the test commands of
    // tools/suite_cmds.zig. Only `zig build suite-runner` builds it.
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = runner_optimize,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    });
    const suite_exe = b.addExecutable(.{ .name = "ztcl-suite", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/suite_cmds.zig"),
        .target = target,
        .optimize = runner_optimize,
        .imports = &.{ .{ .name = "ztcl", .module = fast }, .{ .name = "runner", .module = runner_mod } },
    }) });
    b.step("suite-runner", "Build the runner with the test commands").dependOn(&b.addInstallArtifact(suite_exe, .{}).step);

    // The WebAssembly library: zig-out/lib/ztcl.wasm.
    const wasm = b.addExecutable(.{ .name = "ztcl", .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    }) });
    // The WebAssembly build has no JIT.
    const wasm_options = b.addOptions();
    wasm_options.addOption(bool, "gc_precise", gc_precise);
    wasm_options.addOption(bool, "jit", false);
    wasm.root_module.addOptions("build_options", wasm_options);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // The interpreter can use 5 MiB of native stack (`max_native`).
    wasm.stack_size = 8 << 20;
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } });
    b.step("wasm", "Build the WebAssembly library").dependOn(&wasm_install.step);
}
