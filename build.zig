// SPDX-License-Identifier: BSD-2-Clause
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `-Dgc-precise=true` builds the root rules of WebAssembly on a
    // native target, so the stress tests run them with safety checks.
    const gc_options = b.addOptions();
    // The options of libztcl: the same values, with `cext` on.
    const lib_options = b.addOptions();
    const gc_precise = b.option(bool, "gc-precise", "Use the precise roots of WebAssembly") orelse false;
    gc_options.addOption(bool, "gc_precise", gc_precise);
    lib_options.addOption(bool, "gc_precise", gc_precise);
    cext_on = b.option(bool, "cext-wasm", "Add the exports of C packages in WebAssembly to the wasm libraries") orelse false;
    // The runtime of `ztcl compile --wasm` is only a WebAssembly build.
    gc_options.addOption(bool, "aot", false);
    lib_options.addOption(bool, "aot", false);
    // `-Djit=false` builds no JIT code. The default is true on a target
    // with a backend: x86-64 Linux, x86-64 Windows, arm64 Linux, and arm64 macOS.
    const t = target.result;
    // `-Dcext=true` builds `load` of Tcl C packages and links the C
    // library. The default build has no code of it.
    const cext = b.option(bool, "cext", "Build load of Tcl C packages (not sandboxed)") orelse false;
    gc_options.addOption(bool, "cext", cext);
    lib_options.addOption(bool, "cext", true);
    const jit_backend = (t.cpu.arch == .x86_64 and (t.os.tag == .linux or t.os.tag == .windows)) or (t.cpu.arch == .aarch64 and (t.os.tag == .linux or t.os.tag == .macos));
    const jit_on = b.option(bool, "jit", "Build the JIT compiler") orelse jit_backend;
    gc_options.addOption(bool, "jit", jit_on);
    lib_options.addOption(bool, "jit", jit_on);
    // `-Djit_bug=true` plants a known bug: the `bin_vv` template of tier 1
    // skips its overflow check. The test of the fuzzer uses it.
    const jit_bug = b.option(bool, "jit_bug", "Plant a known bug in tier 1 for the fuzzer test") orelse false;
    gc_options.addOption(bool, "jit_bug", jit_bug);
    lib_options.addOption(bool, "jit_bug", jit_bug);
    // The built-in modules: `-Dbatteries` gives the preset, and
    // `-Dmod-NAME` puts one module in or leaves it out after the preset.
    const batteries = b.option(Batteries, "batteries", "The modules: core (none), std (the default), or full") orelse .std;
    const on = moduleFlags(b, batteries);
    addModuleOptions(b, gc_options, on);
    addModuleOptions(b, lib_options, on);
    // `-Dsize-plant=N` adds N bytes of data to the test module hello. The
    // size report uses it to show that its check fails.
    const size_plant = b.option(usize, "size-plant", "Add bytes to the test module hello") orelse 0;
    gc_options.addOption(usize, "size_plant", size_plant);
    lib_options.addOption(usize, "size_plant", size_plant);
    // `-Dstrip=true` strips the runner, for the size report.
    const strip = b.option(bool, "strip", "Strip the runner") orelse false;
    // `-Drunner-optimize` sets the mode of the runner and the suite runner.
    const runner_optimize = b.option(std.builtin.OptimizeMode, "runner-optimize", "The mode of the runners") orelse .fast;
    // `-Dtsan=true` builds each module with ThreadSanitizer and libc, so
    // `std.Thread` uses pthreads, which ThreadSanitizer sees. It needs a
    // target with a libc, for example `-Dtarget=x86_64-linux-gnu`. Run
    // with `TSAN_OPTIONS=suppressions=tools/tsan/tsan.supp`, or run
    // `tools/tsan.sh`.
    const tsan = b.option(bool, "tsan", "Build with ThreadSanitizer") orelse false;
    // `-Dtsan-plant=true` plants a race for the check of `tools/tsan.sh`:
    // each `tsv::incr` adds 1 to one global word with no lock.
    // The test key of the signed guest images (src/vmimage.zig) in a build
    // that is not a test: for the check of a signature of the test key in
    // the CI of the image.
    const vm_test_key = b.option(bool, "vm-test-key", "Trust the test key of the VM images (Debug builds only)") orelse false;
    // Anyone can sign with the test key, which is in the repository, so a
    // release build never trusts it.
    if (vm_test_key and optimize != .debug) {
        std.debug.print("-Dvm-test-key needs -Doptimize=Debug: a release build never trusts the test key of the VM images\n", .{});
        std.process.exit(1);
    }
    gc_options.addOption(bool, "vm_test_key", vm_test_key);
    lib_options.addOption(bool, "vm_test_key", vm_test_key);
    // The download of `ztcl::vm image fetch` in the runner: std.http and
    // its TLS add about 650 KB, past the size budget of the full runner,
    // so it is off until the TLS of src/tls (ztcl#312).
    const vm_fetch = b.option(bool, "vm-fetch", "Give the runner the download of ztcl::vm image fetch (std.http)") orelse false;
    gc_options.addOption(bool, "vm_fetch", vm_fetch);
    lib_options.addOption(bool, "vm_fetch", vm_fetch);
    const tsan_plant = b.option(bool, "tsan-plant", "Plant a race for the ThreadSanitizer check") orelse false;
    gc_options.addOption(bool, "tsan_plant", tsan_plant);
    lib_options.addOption(bool, "tsan_plant", tsan_plant);
    const libc: ?bool = if (tsan or cext) true else null;

    // The module that other packages import.
    const ztcl = b.addModule("ztcl", .{
        .root_source_file = b.path("src/ztcl.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .link_libc = libc,
    });
    ztcl.addOptions("build_options", gc_options);
    addVt(b, ztcl, target, optimize);

    const tests = b.addTest(.{ .root_module = ztcl });
    const test_step = b.step("test", "Run the tests of the interpreter and the shell");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The TLS record layer and key schedule against RFC 8448, RFC 5869,
    // and RFC 8439. `zig build test` runs them too.
    const tls_run = b.addRunArtifact(b.addTest(.{ .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/vectors.zig"),
        .target = target,
        .optimize = optimize,
    })) }));
    b.step("tls-vectors", "Check the TLS record layer and key schedule with the RFC vectors").dependOn(&tls_run.step);
    test_step.dependOn(&tls_run.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/crypto.zig"),
        .target = target,
        .optimize = optimize,
    })) })).step);
    // The Wycheproof sets of the TLS primitives, from tools/fetch-wycheproof.sh.
    const wp = b.addRunArtifact(b.addExecutable(.{ .name = "tls-wycheproof", .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/wycheproof.zig"),
        .target = target,
        .optimize = optimize,
    })) }));
    wp.addPassthruArgs();
    b.step("tls-wycheproof", "Run the Wycheproof sets of the TLS primitives: zig build tls-wycheproof -- DIR").dependOn(&wp.step);
    // The x509-limbo cases of the chain checks, from tools/fetch-x509-limbo.sh.
    const limbo = b.addRunArtifact(b.addExecutable(.{ .name = "tls-x509-test", .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/limbo.zig"),
        .target = target,
        .optimize = optimize,
    })) }));
    limbo.addPassthruArgs();
    const x509_fuzz = b.addRunArtifact(b.addExecutable(.{ .name = "x509-fuzz", .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/x509_fuzz.zig"),
        .target = target,
        .optimize = .safe,
    })) }));
    x509_fuzz.addPassthruArgs();
    b.step("x509-fuzz", "Fuzz the DER, X.509, PEM, and chain code: zig build x509-fuzz -- --seconds N").dependOn(&x509_fuzz.step);
    // The test client of tools/tls-interop.sh.
    const interop = b.addExecutable(.{ .name = "tls-interop", .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/interop.zig"),
        .target = target,
        .optimize = optimize,
    })) });
    b.step("tls-interop", "Build the test client of tools/tls-interop.sh").dependOn(&b.addInstallArtifact(interop, .{}).step);
    // The server side of RFC 8448 and the client of client.zig against
    // the server in memory. `zig build test` runs them too.
    b.step("tls-server-test", "Run the tests of the TLS server").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/server_vectors.zig"),
        .target = target,
        .optimize = optimize,
    })) })).step);
    // The speed of the record layer (tools/tls-bench.sh). Always
    // ReleaseFast; -Dcpu picks the CPU features.
    b.step("tls-bench", "Print the speed of the TLS record layer for each suite").dependOn(&b.addRunArtifact(b.addExecutable(.{ .name = "tls-bench", .root_module = withCrypto(b, b.createModule(.{
        .root_source_file = b.path("src/tls/bench.zig"),
        .target = target,
        .optimize = .fast,
    })) })).step);
    b.step("tls-x509-test", "Run the x509-limbo cases of the chain checks: zig build tls-x509-test -- limbo.json").dependOn(&limbo.step);
    const tls_test = b.step("tls-test", "Run the unit tests of the TLS code");
    test_step.dependOn(tls_test);
    inline for (.{ "src/tls/aead.zig", "src/tls/record.zig", "src/tls/der.zig", "src/tls/x509.zig", "src/tls/pem.zig", "src/tls/chain.zig", "src/tls/roots.zig", "src/tls/messages.zig", "src/tls/client_vectors.zig", "src/tls/server_vectors.zig" }) |f| {
        tls_test.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = withCrypto(b, b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
        })) })).step);
    }
    // HPACK of RFC 7541 (task 28) and the HTTP/2 connection (task 29):
    // the tests in `zig build test` (conn.zig has the HPACK tests too),
    // the HPACK fuzz run in ReleaseSafe, and the h2c test server.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/h2/conn.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);
    if (target.result.os.tag == .linux) {
        const hpack_fuzz = b.addRunArtifact(b.addExecutable(.{ .name = "hpack-fuzz", .root_module = b.createModule(.{
            .root_source_file = b.path("src/h2/hpack_fuzz.zig"),
            .target = target,
            .optimize = .safe,
        }) }));
        hpack_fuzz.addPassthruArgs();
        b.step("hpack-fuzz", "Fuzz HPACK: zig build hpack-fuzz -- --seconds N").dependOn(&hpack_fuzz.step);
        const hpack_bench = b.addRunArtifact(b.addExecutable(.{ .name = "hpack-bench", .root_module = b.createModule(.{
            .root_source_file = b.path("src/h2/hpack_bench.zig"),
            .target = target,
            .optimize = .fast,
        }) }));
        b.step("hpack-bench", "Print the speed of HPACK").dependOn(&hpack_bench.step);
        const h2_serve = b.addRunArtifact(b.addExecutable(.{ .name = "h2-serve", .root_module = b.createModule(.{
            .root_source_file = b.path("src/h2/serve.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "aio", .module = b.createModule(.{ .root_source_file = b.path("src/aio/aio.zig"), .target = target, .optimize = .fast }) }},
        }) }));
        h2_serve.addPassthruArgs();
        b.step("h2-serve", "Run the h2c test server: zig build h2-serve -- --port N").dependOn(&h2_serve.step);
        const h2_load = b.addRunArtifact(b.addExecutable(.{ .name = "h2-load", .root_module = b.createModule(.{
            .root_source_file = b.path("src/h2/load.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "aio", .module = b.createModule(.{ .root_source_file = b.path("src/aio/aio.zig"), .target = target, .optimize = .fast }) }},
        }) }));
        h2_load.addPassthruArgs();
        b.step("h2-load", "Load an h2c server: zig build h2-load -- --port N --conns C --streams S --seconds T").dependOn(&h2_load.step);
    }
    // The I/O loop of task 06 on io_uring and epoll (Linux) and of task
    // 09 on kqueue (macOS). The tests run on each backend.
    if (target.result.os.tag == .linux or target.result.os.tag.isDarwin()) {
        const aio_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/aio/aio.zig"),
            .target = target,
            .optimize = optimize,
        }) }));
        b.step("aio-test", "Run the tests of the aio loop on io_uring and epoll, or kqueue").dependOn(&aio_tests.step);
        test_step.dependOn(&aio_tests.step);
        const stress = b.addRunArtifact(b.addExecutable(.{ .name = "aio-stress", .root_module = b.createModule(.{
            .root_source_file = b.path("src/aio/stress.zig"),
            .target = target,
            .optimize = .safe,
        }) }));
        stress.addPassthruArgs();
        b.step("aio-stress", "Run the stress test of aio: zig build aio-stress -- --conns N --seconds S").dependOn(&stress.step);
    }
    // The tests of C packages only, for a build with `-Dcext=true`.
    const cext_tests = b.addTest(.{ .root_module = ztcl, .filters = &.{"cext:"} });
    b.step("test-cext-native", "Run the tests of the native loader of C packages").dependOn(&b.addRunArtifact(cext_tests).step);

    // libztcl (ztcl#246): a shared library with the C API of Tcl 8.6 and
    // the file name of libtcl8.6: libtcl8.6.so (also the SONAME),
    // libtcl8.6.dylib, or tcl86.dll. docs/dev/libztcl.md has the steps.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/libztcl.zig"),
        .target = target,
        .optimize = runner_optimize,
        .link_libc = true,
        .pic = true,
    });
    lib_mod.addOptions("build_options", lib_options);
    addVt(b, lib_mod, target, runner_optimize);
    const libztcl = b.addLibrary(.{
        .name = if (t.os.tag == .windows) "tcl86" else "tcl8.6",
        .linkage = .dynamic,
        .root_module = lib_mod,
    });
    if (t.os.tag == .macos) libztcl.install_name = "@rpath/libtcl8.6.dylib";
    const lib_step = b.step("libztcl", "Build libztcl, the drop-in library for libtcl8.6");
    // The loader of C packages has no Windows port yet, and Zig 0.17 has
    // no std.builtin.VaList with LLVM on x86-64 Windows for the variadic
    // slots, so the step fails there with this reason.
    if (t.os.tag == .windows) {
        lib_step.dependOn(&b.addFail("libztcl does not build for Windows yet: the C package code has no Windows port, and Zig 0.17 has no VaList with LLVM on x86-64 Windows").step);
    } else {
        lib_step.dependOn(&b.addInstallArtifact(libztcl, .{}).step);
        addKit(b, lib_step, target);
    }
    // The interactive shell of the runner.
    const shell_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shell/all.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(shell_tests).step);
    b.step("test-shell", "Run the tests of the shell").dependOn(&b.addRunArtifact(shell_tests).step);

    // The stubs table of a C package in WebAssembly (docs/dev/cext-tasks/04w-wasm-bridge.md).
    // It links into the package and is never part of ztcl.
    // Zig 0.17 has no std.builtin.VaList with LLVM on x86-64 Windows and
    // on arm64 Linux, and the variadic slots use it, so these tests skip
    // those targets.
    const stubs_step = b.step("test-cext", "Run the tests of the stubs table of C packages");
    const no_valist = (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) or
        (target.result.os.tag == .linux and target.result.cpu.arch == .aarch64);
    if (!no_valist) {
        const stubs_tests = b.addTest(.{ .root_module = addCextStubs(b, target, optimize) });
        test_step.dependOn(&b.addRunArtifact(stubs_tests).step);
        stubs_step.dependOn(&b.addRunArtifact(stubs_tests).step);
    }
    const stubs_lib = b.addLibrary(.{ .name = "ztclstubs", .linkage = .static, .root_module = addCextStubs(
        b,
        b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
        .ReleaseFast,
    ) });
    b.step("cext-stubs", "Build zig-out/lib/libztclstubs.a for C packages in WebAssembly").dependOn(&b.addInstallArtifact(stubs_lib, .{}).step);

    // The check of the async canonical ABI of WASI 0.3 (docs/dev/wasi-tasks/04-async-abi.md).
    // `wasm-tools` makes the component from the core module and the WIT files.
    // `-Dwasi-lift=callback` builds the form with the async lift and a callback.
    const lift = b.option(enum { sync, callback }, "wasi-lift", "The lift of run in wasi-spike: sync (default) or callback") orelse .sync;
    const spike_mod = b.createModule(.{
        .root_source_file = b.path(if (lift == .sync) "tools/wasi-spike/spike.zig" else "tools/wasi-spike/callback.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    spike_mod.addImport("async", b.createModule(.{ .root_source_file = b.path("src/wasi/async.zig") }));
    const spike_core = b.addExecutable(.{ .name = "wasi-spike", .root_module = spike_mod });
    spike_core.entry = .disabled;
    spike_core.root_module.export_symbol_names = if (lift == .sync)
        &.{ "wasi:cli/run@0.3.2#run", "cabi_realloc" }
    else
        &.{ "[async-lift]wasi:cli/run@0.3.2#run", "[callback][async-lift]wasi:cli/run@0.3.2#run", "cabi_realloc" };
    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", "spike" });
    embed.addDirectoryArg(b.path("tools/wasi-spike/wit"));
    embed.addArtifactArg(spike_core);
    embed.addArg("-o");
    const embedded = embed.addOutputFileArg("wasi-spike.embed.wasm");
    const new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    new.addFileArg(embedded);
    new.addArg("-o");
    const component = new.addOutputFileArg("wasi-spike.component.wasm");
    b.step("wasi-spike", "Build zig-out/bin/wasi-spike.component.wasm, the check of WASI 0.3 (needs wasm-tools)")
        .dependOn(&b.addInstallBinFile(component, "wasi-spike.component.wasm").step);

    // The bindings generator of WASI 0.3 (docs/dev/wasi-tasks/05-wit-bindings.md).
    // `zig build witgen` writes src/wasi/p3.zig, and `zig build test` checks
    // that the file is the output of the generator.
    const witgen_exe = b.addExecutable(.{ .name = "witgen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/witgen/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const witgen_run = b.addRunArtifact(witgen_exe);
    witgen_run.setCwd(b.path("."));
    witgen_run.addArgs(&.{ "wit", "tools/witgen/needed.txt", "src/wasi/p3.zig" });
    b.step("witgen", "Write src/wasi/p3.zig from wit/ and tools/witgen/needed.txt").dependOn(&witgen_run.step);
    const witgen_check = b.addRunArtifact(witgen_exe);
    witgen_check.setCwd(b.path("."));
    witgen_check.addArgs(&.{ "--check", "wit", "tools/witgen/needed.txt", "src/wasi/p3.zig" });
    witgen_check.has_side_effects = true;
    test_step.dependOn(&witgen_check.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/witgen/witgen.zig"),
        .target = b.graph.host,
    }) })).step);
    // The generator of the table of the Web IDL (#251 task 04). `zig build
    // webidl` writes web/webidl-table.mjs, and `zig build test` checks that
    // the file is the output of the generator.
    const webidl_exe = b.addExecutable(.{ .name = "webidl", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/webidl/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const webidl_run = b.addRunArtifact(webidl_exe);
    webidl_run.setCwd(b.path("."));
    webidl_run.addArgs(&.{ "tools/webidl/idl", "web/webidl-table.mjs" });
    b.step("webidl", "Write web/webidl-table.mjs from tools/webidl/idl/").dependOn(&webidl_run.step);
    const webidl_check = b.addRunArtifact(webidl_exe);
    webidl_check.setCwd(b.path("."));
    webidl_check.addArgs(&.{ "--check", "tools/webidl/idl", "web/webidl-table.mjs" });
    webidl_check.has_side_effects = true;
    test_step.dependOn(&webidl_check.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/webidl/webidl.zig"),
        .target = b.graph.host,
    }) })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/wasm-pack.zig"),
        .target = b.graph.host,
    }) })).step);
    // The check of the bindings: a component that imports each function
    // of src/wasi/p3.zig (needs wasm-tools).
    const bind_mod = b.createModule(.{
        .root_source_file = b.path("tools/witgen/check.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    bind_mod.addImport("p3", b.createModule(.{ .root_source_file = b.path("src/wasi/p3.zig") }));
    const bind_core = b.addExecutable(.{ .name = "wasi-bindings", .root_module = bind_mod });
    bind_core.entry = .disabled;
    bind_core.root_module.export_symbol_names = &.{ "wasi:cli/run@0.3.2#run", "cabi_realloc" };
    const bind_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", "ztcl:cli/command" });
    bind_embed.addDirectoryArg(b.path("wit"));
    bind_embed.addArtifactArg(bind_core);
    bind_embed.addArg("-o");
    const bind_embedded = bind_embed.addOutputFileArg("wasi-bindings.embed.wasm");
    const bind_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    bind_new.addFileArg(bind_embedded);
    bind_new.addArg("-o");
    const bind_component = bind_new.addOutputFileArg("wasi-bindings.component.wasm");
    b.step("wasi-bindings", "Build zig-out/bin/wasi-bindings.component.wasm, the check of src/wasi/p3.zig (needs wasm-tools)")
        .dependOn(&b.addInstallBinFile(bind_component, "wasi-bindings.component.wasm").step);

    // The `ztcl` command component of WASI 0.3.2 (docs/dev/wasi-tasks/06-native.md):
    // the core module of src/wasi/run.zig imports only WASI 0.3.2
    // functions, and `wasm-tools` makes the component (needs wasm-tools).
    const p3_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const p3_lib = b.createModule(.{ .root_source_file = b.path("src/ztcl.zig"), .target = p3_target, .optimize = .ReleaseFast });
    p3_lib.addOptions("build_options", gc_options);
    addVt(b, p3_lib, p3_target, .ReleaseFast);
    const p3_core = b.addExecutable(.{ .name = "ztcl-p3", .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasi/run.zig"),
        .target = p3_target,
        .optimize = .ReleaseFast,
        .strip = true,
        .imports = &.{
            .{ .name = "ztcl", .module = p3_lib },
            .{ .name = "runner", .module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = p3_target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "ztcl", .module = p3_lib }},
            }) },
        },
    }) });
    p3_core.entry = .disabled;
    p3_core.stack_size = 8 << 20;
    p3_core.root_module.export_symbol_names = &.{ "wasi:cli/run@0.3.2#run", "cabi_realloc" };
    const p3_embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", "ztcl:cli/command" });
    p3_embed.addDirectoryArg(b.path("wit"));
    p3_embed.addArtifactArg(p3_core);
    p3_embed.addArg("-o");
    const p3_embedded = p3_embed.addOutputFileArg("ztcl.embed.wasm");
    const p3_new = b.addSystemCommand(&.{ "wasm-tools", "component", "new" });
    p3_new.addFileArg(p3_embedded);
    p3_new.addArg("-o");
    const p3_component = p3_new.addOutputFileArg("ztcl.component.wasm");
    const p3_install = b.addInstallBinFile(p3_component, "ztcl.component.wasm");
    b.step("wasi-component", "Build zig-out/bin/ztcl.component.wasm, the command component of WASI 0.3.2 (needs wasm-tools)")
        .dependOn(&p3_install.step);
    // `-Dwasi=p3` with a WASI target: `zig build` installs the command
    // component of WASI 0.3.2 in place of the preview 1 module.
    const wasi_abi = b.option(enum { p1, p3 }, "wasi", "The WASI of -Dtarget=wasm32-wasi: p1 (default, zig-out/bin/ztcl.wasm) or p3 (zig-out/bin/ztcl.component.wasm, needs wasm-tools)") orelse .p1;
    const p3_default = t.os.tag == .wasi and wasi_abi == .p3;

    // The runner and the benchmark always build in ReleaseFast.
    const fast = b.createModule(.{
        .root_source_file = b.path("src/ztcl.zig"),
        .target = target,
        .optimize = runner_optimize,
        .sanitize_thread = tsan,
        .link_libc = libc,
    });
    fast.addOptions("build_options", gc_options);
    addVt(b, fast, target, runner_optimize);

    const exe = b.addExecutable(.{ .name = "ztcl", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = runner_optimize,
        .strip = if (strip) true else null,
        .sanitize_thread = tsan,
        .link_libc = libc,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    // The interpreter can use 5 MiB of native stack (`max_native`), as
    // in the WebAssembly library.
    if (t.os.tag == .wasi) exe.stack_size = 8 << 20;
    if (t.os.tag == .macos) exe.headerpad_size = 0x1000;
    if (t.os.tag == .macos) {
        // The macOS ztcl gets a new ad hoc signature with the entitlement
        // of `ztcl::vm`, from the signer of `ztcl build` (src/macho.zig).
        const signer = b.addExecutable(.{ .name = "macho-sign", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/macho-sign/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "macho", .module = b.createModule(.{ .root_source_file = b.path("src/macho.zig"), .target = b.graph.host }) }},
        }) });
        const run = b.addRunArtifact(signer);
        run.addArtifactArg(exe);
        const signed = run.addOutputFileArg("ztcl");
        run.addArgs(&.{ "ztcl", "com.apple.security.virtualization", "com.apple.security.cs.allow-jit" });
        b.getInstallStep().dependOn(&b.addInstallBinFile(signed, "ztcl").step);
    } else if (p3_default) {
        b.getInstallStep().dependOn(&p3_install.step);
    } else b.installArtifact(exe);

    // `zig build runtimes`: the runner of each target of `ztcl build`,
    // in ReleaseSmall and stripped, in lib/ztcl/runtime/TARGET/.
    const runtimes = b.step("runtimes", "Build the runtime binary of each target of ztcl build");
    var rt_mods: [runtime_targets.len]*std.Build.Module = undefined;
    for (runtime_targets, 0..) |name, ri| {
        const rt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = name }) catch unreachable);
        const r = rt.result;
        const opts = b.addOptions();
        opts.addOption(bool, "gc_precise", false);
        opts.addOption(bool, "aot", false);
        opts.addOption(bool, "jit", (r.cpu.arch == .x86_64 and (r.os.tag == .linux or r.os.tag == .windows)) or (r.cpu.arch == .aarch64 and (r.os.tag == .linux or r.os.tag == .macos)));
        opts.addOption(bool, "jit_bug", false);
        addModuleOptions(b, opts, on);
        opts.addOption(usize, "size_plant", 0);
        opts.addOption(bool, "tsan_plant", false);
        const lib = b.createModule(.{ .root_source_file = b.path("src/ztcl.zig"), .target = rt, .optimize = .small });
        lib.addOptions("build_options", opts);
        addVt(b, lib, rt, .small);
        rt_mods[ri] = lib;
        const rexe = b.addExecutable(.{ .name = "ztcl", .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = rt,
            .optimize = .small,
            .strip = true,
            .imports = &.{.{ .name = "ztcl", .module = lib }},
        }) });
        // Space after the load commands, for the code signature that
        // `ztcl build` adds to a Mach-O file.
        if (r.os.tag == .macos) rexe.headerpad_size = 0x1000;
        const inst = b.addInstallArtifact(rexe, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("lib/ztcl/runtime/{s}", .{name}) } } });
        runtimes.dependOn(&inst.step);
    }

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run a script: zig build run -- script.tcl").dependOn(&run.step);

    const bench_exe = b.addExecutable(.{ .name = "ztcl-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.addPassthruArgs();
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
    census_run.addPassthruArgs();
    b.step("jit-census", "Count the loops that tier 2 can compile").dependOn(&census_run.step);

    // The differential fuzzer of the JIT. It uses the mode of -Doptimize.
    const fuzz_exe = b.addExecutable(.{ .name = "jit-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/jit-fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    }) });
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    fuzz_run.addPassthruArgs();
    b.step("jit-fuzz", "Run the differential fuzzer of the JIT").dependOn(&fuzz_run.step);

    // `zig build vm-image-verify -- DIR`: the check of a guest image
    // release with the verifier of ztcl (tools/vm-image-verify).
    const vmiv_exe = b.addExecutable(.{ .name = "vm-image-verify", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/vm-image-verify/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    }) });
    const vmiv_run = b.addRunArtifact(vmiv_exe);
    vmiv_run.addPassthruArgs();
    b.step("vm-image-verify", "Check a signed guest image release").dependOn(&vmiv_run.step);
    b.step("vm-image-verify-exe", "Build vm-image-verify").dependOn(&b.addInstallArtifact(vmiv_exe, .{}).step);

    // The JSON tools: JSONTestSuite and the fuzzer. They use the mode of
    // -Doptimize.
    inline for (.{ .{ "json-test", "tools/json-test.zig", "Run the files of JSONTestSuite: zig build json-test -- DIR" }, .{ "json-fuzz", "tools/json-fuzz.zig", "Run the fuzzer of the JSON parser" } }) |jt| {
        const e = b.addExecutable(.{ .name = jt[0], .root_module = b.createModule(.{
            .root_source_file = b.path(jt[1]),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ztcl", .module = ztcl }},
        }) });
        const r = b.addRunArtifact(e);
        r.addPassthruArgs();
        b.step(jt[0], jt[2]).dependOn(&r.step);
    }
    // The probe of executable memory: `zig build jit-probe`.
    const probe_exe = b.addExecutable(.{ .name = "jit-probe", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/jit-probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    }) });
    b.step("jit-probe", "Print the state of the executable memory of the JIT").dependOn(&b.addRunArtifact(probe_exe).step);
    // The probe has no meaning on WASI, which has no executable memory.
    if (t.os.tag != .wasi) b.installArtifact(probe_exe);

    addPointRuntime(b, &(.{ ztcl, fast } ++ rt_mods), fast);

    // The WebAssembly library: zig-out/lib/ztcl.wasm.
    const wasm = addWasm(b, "ztcl", .none, gc_precise, size_plant, on, false, false);
    b.step("wasm", "Build the WebAssembly library").dependOn(installWasm(b, wasm));

    // The library with the shell of the runner (src/wasm_shell.zig):
    // zig-out/lib/ztcl-shell.wasm, for the shell of the site.
    const wasm_shell = addWasm(b, "ztcl-shell", .none, gc_precise, size_plant, on, false, true);
    b.step("wasm-shell", "Build the WebAssembly library with the shell").dependOn(installWasm(b, wasm_shell));

    // The library with wasm SIMD: zig-out/lib/ztcl-simd.wasm. `ztcl.wasm`
    // stays the strict form for a runtime with no SIMD.
    const wasm_simd = addWasmSimd(b, "ztcl-simd", .none, gc_precise, size_plant, on, false, false, true);
    b.step("wasm-simd", "Build the WebAssembly library with SIMD").dependOn(installWasm(b, wasm_simd));

    // The library with the imports of the host: zig-out/lib/ztcl-host.wasm.
    const wasm_host = addWasmForm(b, "ztcl-host", .none, gc_precise, size_plant, on, false, false, false, true);
    b.step("wasm-host", "Build the WebAssembly library with the imports of the host").dependOn(installWasm(b, wasm_host));

    // The runtime of `ztcl compile --wasm`: zig-out/lib/ztcl-aot.wasm.
    // It is the library with the helpers of the JIT as exports.
    const wasm_aot = addWasm(b, "ztcl-aot", .none, gc_precise, size_plant, on, true, false);
    b.step("wasm-aot", "Build the runtime of ztcl compile --wasm").dependOn(installWasm(b, wasm_aot));

    // The core of the VBS enclave of Windows: zig-out/lib/ztcl-enclave-core.lib.
    // See docs/dev/enclave.md.
    const enclave_core = addEnclaveCore(b, size_plant);
    b.step("enclave-core", "Build the library of the VBS enclave of Windows").dependOn(&b.addInstallFile(enclave_core.getEmittedBin(), "lib/ztcl-enclave-core.lib").step);

    // The libraries of the capability `thread` on the web (task 14):
    // ztcl-threads.wasm shares one memory between the workers, and
    // ztcl-async.wasm gives each worker its own memory.
    const threads_step = b.step("wasm-threads", "Build the WebAssembly libraries with threads");
    for ([_]struct { []const u8, WebThreads }{ .{ "ztcl-threads", .shared }, .{ "ztcl-async", .async } }) |wt| {
        const w = addWasm(b, wt[0], wt[1], gc_precise, size_plant, on, false, false);
        threads_step.dependOn(installWasm(b, w));
    }
}

/// The host program of tools/wasm-pack.zig, made on the first call of
/// `installWasm`.
var wasm_pack_exe: ?*std.Build.Step.Compile = null;
var wasm_pack_on: ?bool = null;

/// Installs a WebAssembly library to zig-out/lib after the pass of
/// tools/wasm-pack.zig, which writes the numbers of the code section in
/// their shortest form (#294). `-Dwasm-pack=false` installs the output
/// of the linker.
fn installWasm(b: *std.Build, wasm: *std.Build.Step.Compile) *std.Build.Step {
    if (wasm_pack_on == null) wasm_pack_on = b.option(bool, "wasm-pack", "Write short numbers in the code of the WebAssembly libraries (default true)") orelse true;
    if (!wasm_pack_on.?) return &b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .lib } }).step;
    const exe = wasm_pack_exe orelse blk: {
        const e = b.addExecutable(.{ .name = "wasm-pack", .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wasm-pack.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }) });
        wasm_pack_exe = e;
        break :blk e;
    };
    const run = b.addRunArtifact(exe);
    run.addArtifactArg(wasm);
    const name = b.fmt("{s}.wasm", .{wasm.name});
    const out = run.addOutputFileArg(name);
    return &b.addInstallFileWithDir(out, .lib, name).step;
}

/// The runtime of compiled point procs: `src/point_rt.zig` for wasm32
/// with no imports, in a SIMD form and a scalar form. The modules embed
/// the bytes for `ztcl compile`. `zig build point-rt` installs both and
/// the native reference tool of `tools/point-rt-diff.mjs`.
fn addPointRuntime(b: *std.Build, mods: []const *std.Build.Module, fast: *std.Build.Module) void {
    const step = b.step("point-rt", "Build the runtime of compiled point procs");
    for ([_]struct { []const u8, bool }{ .{ "point_rt", true }, .{ "point_rt_scalar", false } }) |form| {
        var query: std.Target.Query = .{ .cpu_arch = .wasm32, .os_tag = .freestanding };
        if (form[1]) query.cpu_features_add = std.Target.wasm.featureSet(&.{.simd128});
        if (!form[1]) query.cpu_features_sub = std.Target.wasm.featureSet(&.{.simd128});
        const rt = b.addExecutable(.{ .name = form[0], .root_module = b.createModule(.{
            .root_source_file = b.path("src/point_rt.zig"),
            .target = b.resolveTargetQuery(query),
            .optimize = .fast,
            .single_threaded = true,
            .strip = true,
        }) });
        rt.entry = .disabled;
        rt.rdynamic = true;
        rt.stack_size = 64 << 10;
        for (mods) |m| m.addAnonymousImport(b.fmt("{s}.wasm", .{form[0]}), .{ .root_source_file = rt.getEmittedBin() });
        step.dependOn(&b.addInstallArtifact(rt, .{ .dest_dir = .{ .override = .lib } }).step);
    }
    const ref = b.addExecutable(.{ .name = "point-rt-ref", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/point-rt-ref.zig"),
        .target = fast.resolved_target.?,
        .optimize = .fast,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    step.dependOn(&b.addInstallArtifact(ref, .{}).step);
    // The native side of tools/point-wasm-diff.mjs.
    const wasm_ref = b.addExecutable(.{ .name = "point-wasm-ref", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/point-wasm-ref.zig"),
        .target = fast.resolved_target.?,
        .optimize = .fast,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    step.dependOn(&b.addInstallArtifact(wasm_ref, .{}).step);
    // The differential fuzzer: zig build point-wasm-fuzz -- --count N.
    const fuzz = b.addExecutable(.{ .name = "point-wasm-fuzz", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/point-wasm-fuzz.zig"),
        .target = fast.resolved_target.?,
        .optimize = .fast,
        .imports = &.{.{ .name = "ztcl", .module = fast }},
    }) });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.setCwd(b.path("."));
    fuzz_run.addPassthruArgs();
    b.step("point-wasm-fuzz", "Run the differential fuzzer of compiled point procs").dependOn(&fuzz_run.step);
}

/// The thread model of a WebAssembly build. `none` has no thread
/// command. `shared` runs each thread in a worker on one shared memory.
/// `async` runs each thread in a worker with its own memory, and only
/// the commands that do not wait work.
const WebThreads = enum { none, shared, async };

fn addWasm(b: *std.Build, name: []const u8, threads: WebThreads, gc_precise: bool, size_plant: usize, on: [all_modules.len]bool, aot: bool, shell: bool) *std.Build.Step.Compile {
    return addWasmSimd(b, name, threads, gc_precise, size_plant, on, aot, shell, false);
}

/// `addWasm` with the SIMD instructions of wasm (`simd128`) when `simd`
/// is true, so the compiler can use them in the loops of `Program.run`.
fn addWasmSimd(b: *std.Build, name: []const u8, threads: WebThreads, gc_precise: bool, size_plant: usize, on: [all_modules.len]bool, aot: bool, shell: bool, simd: bool) *std.Build.Step.Compile {
    return addWasmForm(b, name, threads, gc_precise, size_plant, on, aot, shell, simd, false);
}

/// `addWasmSimd` with the imports of the module `ztcl_host` when `host`
/// is true (docs/dev/wasm-host-tasks/README.md).
/// The value of `-Dcext-wasm`. The bridge of C packages is off by default
/// (docs/dev/cext-tasks/04w-wasm-bridge.md).
var cext_on = false;

fn addWasmForm(b: *std.Build, name: []const u8, threads: WebThreads, gc_precise: bool, size_plant: usize, on: [all_modules.len]bool, aot: bool, shell: bool, simd: bool, host: bool) *std.Build.Step.Compile {
    var query: std.Target.Query = .{ .cpu_arch = .wasm32, .os_tag = .freestanding };
    if (simd) query.cpu_features_add = std.Target.wasm.featureSet(&.{.simd128});
    if (threads == .shared) query.cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory });
    const wasm = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(query),
        .optimize = .small,
        .single_threaded = threads != .shared,
    }) });
    // The WebAssembly build has no JIT.
    const wasm_options = b.addOptions();
    wasm_options.addOption(bool, "gc_precise", gc_precise);
    wasm_options.addOption(bool, "jit", false);
    wasm_options.addOption(bool, "aot", aot);
    wasm_options.addOption(bool, "shell", shell);
    wasm_options.addOption(bool, "jit_bug", false);
    wasm_options.addOption(bool, "tsan_plant", false);
    wasm_options.addOption(usize, "size_plant", size_plant);
    wasm_options.addOption(WebThreads, "web_threads", threads);
    // The point procs of task 01 of #26, in the SIMD form and the host
    // form only: they do not fit in the size limit of ztcl.wasm.
    wasm_options.addOption(bool, "wasm_point", simd or host);
    wasm_options.addOption(bool, "wasm_host", host);
    wasm_options.addOption(bool, "cext", cext_on);
    // libghostty-vt uses `std.heap.wasm_allocator`, which has no form for
    // a shared memory, so the build with shared threads has no `ztcl::vt`.
    var mods_on = on;
    if (threads == .shared) mods_on[moduleIndex("vt")] = false;
    // ztcl.wasm has a size limit (tools/size-report.sh), so `ztcl::probe`
    // is only in the shell build of the site, which has the live examples.
    if (!shell) mods_on[moduleIndex("probe")] = false;
    if (!shell) mods_on[moduleIndex("disasm")] = false;
    // The browser has no TCP sockets, so no wasm build has `ztcl::tls`.
    mods_on[moduleIndex("tls")] = false;
    addModuleOptions(b, wasm_options, mods_on);
    wasm.root_module.addOptions("build_options", wasm_options);
    if (threads != .shared) addVt(b, wasm.root_module, wasm.root_module.resolved_target.?, .small);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    // The interpreter can use 5 MiB of native stack (`max_native`).
    wasm.stack_size = 8 << 20;
    if (threads == .shared) {
        // The host makes the memory and gives it to each instance.
        wasm.import_memory = true;
        wasm.shared_memory = true;
        // web/ztcl-threads.mjs makes the memory with these sizes.
        wasm.initial_memory = 32 << 20;
        wasm.max_memory = 2 << 30;
    }
    return wasm;
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
    .{ .name = "json", .std = true },
    .{ .name = "vt", .std = true },
    .{ .name = "probe", .std = true },
    .{ .name = "disasm", .std = true },
    .{ .name = "tls", .std = true },
    .{ .name = "agent", .std = true },
};

/// The flag of each module after the preset, the flags, and the rule
/// that a module that another module needs is in the build too.
/// Adds the import `ghostty-vt`: the terminal module of libghostty-vt,
/// built from source with `-Dsimd=false`, so it needs no libc and no
/// C++ code. The module is Zig code in the program, so each target
/// links it statically. `src/vt.zig` is the only user.
/// The module of `src/cext/wasm_stubs.zig`, with its root in
/// `src/cext_stubs.zig`. It uses only the value helpers of
/// `src/value.zig` and the C library of the target.
fn addCextStubs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/cext_stubs.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    return m;
}

/// The development kit of libztcl (docs/libztcl.md): the headers of Tcl
/// 8.6.16 in include and include/tcl8.6, the stub library
/// lib/libtclstub8.6.a, lib/tclConfig.sh for TEA, and
/// lib/pkgconfig/tcl.pc and ztcl.pc. tclConfig.sh finds the prefix from
/// TCL_BIN_DIR, else uses `-Dkit-prefix`. The .pc files find the prefix
/// from their own folder.
fn addKit(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget) void {
    const os = target.result.os.tag;
    const stub = b.addLibrary(.{ .name = "tclstub8.6", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tclstub.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .pic = true,
        .strip = true,
    }) });
    step.dependOn(&b.addInstallArtifact(stub, .{}).step);
    // Debian and Homebrew put the headers in include/tcl8.6, and Arch and
    // the build of Tcl in include. A configure script of TEA looks in
    // both, so the kit has both.
    for ([_][]const u8{ "tcl8.6", "" }) |sub| {
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = b.path("packaging/libztcl/include"),
            .install_dir = .header,
            .install_subdir = sub,
        }).step);
    }
    step.dependOn(&b.addInstallFileWithDir(b.path("licenses/tcl-license.txt"), .prefix, "share/doc/libztcl/tcl-license.txt").step);

    const prefix = b.option([]const u8, "kit-prefix", "The prefix of libztcl that lib/tclConfig.sh names when TCL_BIN_DIR is not set (default /usr/local)") orelse "/usr/local";
    const mac = os == .macos;
    const so = if (mac) ".dylib" else ".so";
    const cfg = b.fmt(
        \\# tclConfig.sh of libztcl: ztcl {[ztcl]s} with the C API of Tcl 8.6.
        \\# The build of ztcl writes this file (build.zig, addKit). TEA sets
        \\# TCL_BIN_DIR to the folder of the file before it sources it, so the
        \\# prefix is the parent of that folder. Else it is {[p]s}.
        \\if [ -n "${{TCL_BIN_DIR:-}}" ] && [ -f "${{TCL_BIN_DIR}}/tclConfig.sh" ]; then
        \\    ztcl_prefix=$(cd "${{TCL_BIN_DIR}}/.." && pwd)
        \\else
        \\    ztcl_prefix='{[p]s}'
        \\fi
        \\TCL_VERSION='8.6'
        \\TCL_MAJOR_VERSION='8'
        \\TCL_MINOR_VERSION='6'
        \\TCL_PATCH_LEVEL='.16'
        \\TCL_CC='cc'
        \\TCL_DEFS='-DTCL_THREADS=1'
        \\TCL_DBGX=
        \\TCL_CFLAGS_DEBUG='-g'
        \\TCL_CFLAGS_OPTIMIZE='-O2'
        \\TCL_LDFLAGS_DEBUG=''
        \\TCL_LDFLAGS_OPTIMIZE=''
        \\TCL_SHARED_BUILD=1
        \\TCL_LIB_FILE='libtcl8.6{[so]s}'
        \\TCL_LIBS='{[libs]s}'
        \\TCL_PREFIX="${{ztcl_prefix}}"
        \\TCL_EXEC_PREFIX="${{ztcl_prefix}}"
        \\TCL_SHLIB_CFLAGS='-fPIC'
        \\TCL_CFLAGS_WARNING='-Wall'
        \\TCL_EXTRA_CFLAGS=''
        \\TCL_SHLIB_LD='{[shlib_ld]s}'
        \\TCL_STLIB_LD='${{AR}} cr'
        \\TCL_SHLIB_LD_LIBS='${{LIBS}}'
        \\TCL_SHLIB_SUFFIX='{[so]s}'
        \\TCL_DL_LIBS=''
        \\TCL_LD_FLAGS=''
        \\TCL_CC_SEARCH_FLAGS='{[search]s}'
        \\TCL_LD_SEARCH_FLAGS='{[search]s}'
        \\TCL_COMPAT_OBJS=''
        \\TCL_RANLIB='ranlib'
        \\TCL_LIB_FLAG='-ltcl8.6'
        \\TCL_BUILD_LIB_SPEC="-L${{ztcl_prefix}}/lib -ltcl8.6"
        \\TCL_LIB_SPEC="-L${{ztcl_prefix}}/lib -ltcl8.6"
        \\TCL_INCLUDE_SPEC="-I${{ztcl_prefix}}/include/tcl8.6"
        \\TCL_LIB_VERSIONS_OK='ok'
        \\TCL_SHARED_LIB_SUFFIX='${{VERSION}}{[so]s}'
        \\TCL_UNSHARED_LIB_SUFFIX='${{VERSION}}.a'
        \\TCL_SRC_DIR="${{ztcl_prefix}}/include/tcl8.6"
        \\TCL_PACKAGE_PATH="${{ztcl_prefix}}/lib"
        \\TCL_SUPPORTS_STUBS=1
        \\TCL_STUB_LIB_FILE='libtclstub8.6.a'
        \\TCL_STUB_LIB_FLAG='-ltclstub8.6'
        \\TCL_BUILD_STUB_LIB_SPEC="-L${{ztcl_prefix}}/lib -ltclstub8.6"
        \\TCL_STUB_LIB_SPEC="-L${{ztcl_prefix}}/lib -ltclstub8.6"
        \\TCL_BUILD_STUB_LIB_PATH="${{ztcl_prefix}}/lib/libtclstub8.6.a"
        \\TCL_STUB_LIB_PATH="${{ztcl_prefix}}/lib/libtclstub8.6.a"
        \\TCL_THREADS=1
        \\TCL_BIN_DIR="${{ztcl_prefix}}/lib"
        \\
    , .{
        .ztcl = ztcl_version,
        .so = so,
        .p = prefix,
        .libs = if (mac) "" else "-lpthread -lm",
        .shlib_ld = if (mac) "${CC} -dynamiclib ${CFLAGS} ${LDFLAGS} -Wl,-single_module" else "${CC} ${CFLAGS} ${LDFLAGS} -shared",
        .search = if (mac) "" else "\"-Wl,-rpath,${LIB_RUNTIME_DIR}\"",
    });
    const wf = b.addWriteFiles();
    step.dependOn(&b.addInstallFileWithDir(wf.add("tclConfig.sh", cfg), .lib, "tclConfig.sh").step);
    for ([_][2][]const u8{ .{ "tcl", "Tool Command Language, as ztcl" }, .{ "ztcl", "ztcl with the C API of Tcl 8.6" } }) |pc| {
        const text = b.fmt(
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include/tcl8.6
            \\libfile=libtcl8.6{[so]s}
            \\
            \\Name: {[name]s}
            \\Description: {[desc]s}
            \\URL: https://github.com/beetlebugorg/ztcl
            \\Version: {[v]s}
            \\Libs: -L${{libdir}} -ltcl8.6 -ltclstub8.6
            \\Cflags: -I${{includedir}}
            \\
        , .{ .so = so, .name = pc[0], .desc = pc[1], .v = if (std.mem.eql(u8, pc[0], "tcl")) "8.6.16" else ztcl_version });
        step.dependOn(&b.addInstallFileWithDir(wf.add(b.fmt("{s}.pc", .{pc[0]}), text), .lib, b.fmt("pkgconfig/{s}.pc", .{pc[0]})).step);
    }
}

/// The version of ztcl in build.zig.zon.
const ztcl_version = @import("build.zig.zon").version;

/// Gives a module of the interpreter the VT module and the modules of
/// src/crypto (addCrypto), so each module that can reach src/tls has
/// them.
fn addVt(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    addCrypto(b, m);
    const dep = b.dependency("ghostty", .{ .target = target, .optimize = optimize, .simd = false, .@"emit-lib-vt" = true, .@"vt-features" = @as([]const u8, "-kitty_graphics") });
    m.addImport("ghostty-vt", dep.module("ghostty-vt"));
}

/// The modules of src/crypto, compiled with more CPU features than the
/// target (src/tls/aead.zig checks the CPU at run time). Each module
/// that has src/tls gets them.
fn withCrypto(b: *std.Build, m: *std.Build.Module) *std.Build.Module {
    addCrypto(b, m);
    return m;
}

fn addCrypto(b: *std.Build, m: *std.Build.Module) void {
    const t = m.resolved_target orelse return;
    // The CPU of the target, with its model, and more features.
    var q = std.Target.Query.fromTarget(&t.result);
    if (t.result.cpu.arch == .x86_64) {
        const F = std.Target.x86.Feature;
        q.cpu_features_add.addFeatureSet(std.Target.x86.featureSet(&[_]F{ .sse3, .ssse3, .sse4_1, .sse4_2, .popcnt, .pclmul, .aes, .avx, .avx2, .bmi, .bmi2 }));
    }
    if (t.result.cpu.arch == .aarch64) {
        q.cpu_features_add.addFeatureSet(std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{.aes}));
    }
    const kt = b.resolveTargetQuery(q);
    m.addImport("crypto_x86_avx2", b.createModule(.{
        .root_source_file = b.path("src/crypto/x86_avx2.zig"),
        .target = kt,
        .optimize = m.optimize,
    }));
    m.addImport("crypto_arm_aes", b.createModule(.{
        .root_source_file = b.path("src/crypto/arm_aes.zig"),
        .target = kt,
        .optimize = m.optimize,
    }));
}

/// The targets of `zig build runtimes` and `ztcl build --target`.
const runtime_targets = [_][]const u8{ "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows" };

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

/// The index of a module in `all_modules`.
/// The interpreter with no capability as one COFF library for x86_64 with
/// no import, for `ztcl-enclave.dll`. The target is UEFI, so the
/// library calls no function of Windows.
fn addEnclaveCore(b: *std.Build, size_plant: usize) *std.Build.Step.Compile {
    const obj = b.addLibrary(.{ .name = "ztcl-enclave-core", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/enclave_core.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi }),
        .optimize = .ReleaseSmall,
        .single_threaded = true,
        .stack_check = false,
        .red_zone = false,
    }) });
    const opts = b.addOptions();
    opts.addOption(bool, "gc_precise", true);
    opts.addOption(bool, "jit", false);
    opts.addOption(bool, "aot", false);
    opts.addOption(bool, "shell", false);
    opts.addOption(bool, "jit_bug", false);
    opts.addOption(bool, "tsan_plant", false);
    opts.addOption(usize, "size_plant", size_plant);
    opts.addOption(WebThreads, "web_threads", .none);
    opts.addOption(bool, "wasm_point", false);
    opts.addOption(bool, "wasm_host", false);
    var off: [all_modules.len]bool = @splat(false);
    off[moduleIndex("json")] = true;
    addModuleOptions(b, opts, off);
    obj.root_module.addOptions("build_options", opts);
    // The enclave CRT has no helpers of 128-bit floats.
    obj.bundle_compiler_rt = true;
    return obj;
}

fn moduleIndex(comptime name: []const u8) usize {
    inline for (all_modules, 0..) |m, i| {
        if (comptime std.mem.eql(u8, m.name, name)) return i;
    }
    @compileError("no module " ++ name);
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
