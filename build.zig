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
    // `-Djit_bug=true` plants a known bug: the `bin_vv` template of tier 1
    // skips its overflow check. The test of the fuzzer uses it.
    gc_options.addOption(bool, "jit_bug", b.option(bool, "jit_bug", "Plant a known bug in tier 1 for the fuzzer test") orelse false);
    // The built-in modules: `-Dbatteries` gives the preset, and
    // `-Dmod-NAME` puts one module in or leaves it out after the preset.
    const batteries = b.option(Batteries, "batteries", "The modules: core (none), std (the default), or full") orelse .std;
    const on = moduleFlags(b, batteries);
    addModuleOptions(b, gc_options, on);
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

    // The census of loops for tier 2.
    const census_exe = b.addExecutable(.{ .name = "jit-census", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/jit-census.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    }) });
    const census_run = b.addRunArtifact(census_exe);
    census_run.setCwd(b.path("."));
    if (b.args) |args| census_run.addArgs(args);
    b.step("jit-census", "Count the loops that tier 2 can compile").dependOn(&census_run.step);

    // The differential fuzzer of the JIT. It uses the mode of -Doptimize.
    const fuzz_exe = b.addExecutable(.{ .name = "jit-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/jit-fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    }) });
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| fuzz_run.addArgs(args);
    b.step("jit-fuzz", "Run the differential fuzzer of the JIT").dependOn(&fuzz_run.step);

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
    wasm_options.addOption(bool, "jit_bug", false);
    addModuleOptions(b, wasm_options, on);
    wasm.root_module.addOptions("build_options", wasm_options);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // The interpreter can use 5 MiB of native stack (`max_native`).
    wasm.stack_size = 8 << 20;
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } });
    b.step("wasm", "Build the WebAssembly library").dependOn(&wasm_install.step);
}

const Batteries = enum { core, std, full };

/// A row of the module table. `std` is true when `-Dbatteries=std` puts
/// the module in. `needs` lists the modules that it needs.
const Mod = struct {
    name: []const u8,
    std: bool,
    needs: []const []const u8 = &.{},
};

/// The modules. src/modules.zig reads the flag `mod_NAME` of each one.
const all_modules = [_]Mod{
    .{ .name = "hello", .std = true },
};

/// The flag of each module after the preset, the flags, and the rule
/// that a module that another module needs is in the build too.
fn moduleFlags(b: *std.Build, batteries: Batteries) [all_modules.len]bool {
    var on: [all_modules.len]bool = undefined;
    for (all_modules, 0..) |m, i| {
        on[i] = switch (batteries) {
            .core => false,
            .std => m.std,
            .full => true,
        };
        const flag = b.fmt("mod-{s}", .{m.name});
        if (b.option(bool, flag, b.fmt("Put the module {s} in the build or leave it out", .{m.name}))) |v| on[i] = v;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (all_modules, 0..) |m, i| {
            if (!on[i]) continue;
            for (m.needs) |need| {
                const j = for (all_modules, 0..) |n, k| {
                    if (std.mem.eql(u8, n.name, need)) break k;
                } else @panic("a module needs an unknown module");
                if (!on[j]) {
                    on[j] = true;
                    changed = true;
                    std.debug.print("the module {s} is in the build because {s} needs it\n", .{ need, m.name });
                }
            }
        }
    }
    return on;
}

/// Adds `mod_NAME` for each module and `modules`, the names in the build.
fn addModuleOptions(b: *std.Build, opts: *std.Build.Step.Options, on: [all_modules.len]bool) void {
    var names: std.ArrayList(u8) = .empty;
    for (all_modules, on) |m, v| {
        opts.addOption(bool, b.fmt("mod_{s}", .{m.name}), v);
        if (!v) continue;
        if (names.items.len > 0) names.append(b.allocator, ' ') catch @panic("OOM");
        names.appendSlice(b.allocator, m.name) catch @panic("OOM");
    }
    opts.addOption([]const u8, "modules", names.items);
}
