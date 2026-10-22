const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library: canonical format, segments, journal, verify, LLM view.
    const core = b.addModule("zephyr_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
    });

    // MCP server (Phase 6): read-only AI access over stdio; depends on core.
    const mcp = b.addModule("zephyr_mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });

    // Phase 8: the embedding engine. Default build: the pinned llama.cpp
    // submodule is configured and built with cmake and linked statically
    // into the CLI. --no-embed skips all of it; the embedding surface then
    // reports EngineUnavailable while everything else works. `zig build
    // test` never needs the engine (the core-side tests use a
    // deterministic fake).
    const embed_enabled = !(b.option(bool, "no-embed", "build without the embedding engine (Phase 8)") orelse false);
    const embed_options = b.addOptions();
    embed_options.addOption(bool, "has_embed", embed_enabled);
    const embed = b.createModule(.{
        .root_source_file = b.path("src/embed.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
            .{ .name = "embed_options", .module = embed_options.createModule() },
        },
    });

    // Key module (spec/encryption.md): the master key's stores — the macOS
    // keychain or the 0600 key file — and resolution. Depends on core for
    // the vault format. On macOS the Security and CoreFoundation
    // frameworks back the keychain store; off macOS the module is a stub.
    const key = b.addModule("zephyr_key", .{
        .root_source_file = b.path("src/key.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    if (target.result.os.tag == .macos) {
        key.linkFramework("Security", .{});
        key.linkFramework("CoreFoundation", .{});
    }

    const exe = b.addExecutable(.{
        .name = "zephyr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zephyr_core", .module = core },
                .{ .name = "zephyr_mcp", .module = mcp },
                .{ .name = "zephyr_embed", .module = embed },
                .{ .name = "zephyr_key", .module = key },
            },
        }),
    });
    b.installArtifact(exe);

    if (embed_enabled) {
        // Native build of the pinned submodule (b11609): static library,
        // no tools/tests/examples, Metal on Apple Silicon, CPU elsewhere.
        const metal_flag = std.fmt.allocPrint(b.graph.arena, "-DGGML_METAL={s}", .{if (target.result.os.tag == .macos) "ON" else "OFF"}) catch
            @panic("OOM");
        // Apple Silicon: with GGML_NATIVE on (the default), ggml-cpu runs
        // the ARM feature probes via check_cxx_source_runs — the SVE and
        // SME probes compile, but their binaries never terminate on macOS
        // arm64 (the first SVE instruction faults into a spin instead of
        // killing the process), so cmake hangs forever. Pre-seed the check
        // variables: check_* skips a probe already in the cache, and the
        // fallback then builds with +nosve/+nosme, which is what Apple
        // silicon needs anyway. (dotprod/i8mm probes exit cleanly and run.)
        const base_args = [_][]const u8{
            "cmake",                   "-G",                         "Ninja",
            "-S",                      "third_party/llama.cpp",      "-B",
            "zig-out/llama",           "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
            metal_flag,                "-DLLAMA_BUILD_COMMON=OFF",   "-DLLAMA_BUILD_TESTS=OFF",
            "-DLLAMA_BUILD_TOOLS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF", "-DLLAMA_BUILD_SERVER=OFF",
            "-DLLAMA_BUILD_APP=OFF",
            // OpenMP: off everywhere, so the static link set never depends
            // on which OpenMP runtime the host toolchain ships (libgomp on
            // Linux, none on the macOS runners). ggml's internal thread
            // pool still parallelizes; this also keeps the distributed
            // Linux binaries free of a libgomp runtime dependency.
              "-DGGML_OPENMP=OFF",
        };
        var configure_args = std.ArrayList([]const u8).empty;
        for (base_args) |a| configure_args.append(b.graph.arena, a) catch @panic("OOM");
        if (target.result.cpu.arch == .aarch64 and target.result.os.tag == .macos) {
            configure_args.append(b.graph.arena, "-DGGML_MACHINE_SUPPORTS_sve=0") catch @panic("OOM");
            configure_args.append(b.graph.arena, "-DGGML_MACHINE_SUPPORTS_sme=0") catch @panic("OOM");
        }
        const llama_configure = b.addSystemCommand(configure_args.items);
        const llama_build = b.addSystemCommand(&.{
            "cmake", "--build", "zig-out/llama", "--target", "llama",
        });
        llama_build.step.dependOn(&llama_configure.step);

        if (target.result.os.tag == .linux) {
            // On Linux the engine must be compiled by the same toolchain that
            // links it. The 0.17 build system always links the C++ stdlib as
            // -lc++ (LLVM libc++; there is no API to select libstdc++), so
            // archives built by the host g++ fail to link (the __cxx11 ABI
            // symbols are undefined). Build them with this toolchain's own
            // clang instead: `zig cc` / `zig c++` (CMAKE_<LANG>_COMPILER_ARG1
            // is prepended to the compiler invocation, turning `zig` into the
            // cc/c++ driver), and `zig c++` links the bundled libc++
            // statically, so the shipped binary has no host C++ runtime
            // dependency.
            const zig_exe = std.Build.LazyPath.zig_exe;
            llama_configure.addFileArg2(zig_exe, .{
                .prefix = "-DCMAKE_C_COMPILER=",
                .make_absolute = true,
            });
            llama_configure.addFileArg2(zig_exe, .{
                .prefix = "-DCMAKE_CXX_COMPILER=",
                .make_absolute = true,
            });
            llama_configure.addArgs(&.{
                "-DCMAKE_C_COMPILER_ARG1=cc",
                "-DCMAKE_CXX_COMPILER_ARG1=c++",
            });
        }

        // The engine module links the static library set. The order is the
        // pinned build's own CMake dependency graph (zig-out/llama/
        // llama-config.cmake and ggml/ggml-config.cmake): llama -> ggml ->
        // ggml-base -> every built backend; ld64 resolves static archives
        // left to right, so this order is load-bearing. The archives live
        // in the cmake build tree (only libllama.a is "installed").
        // Backend archives only exist when their GGML_<BACKEND> option is
        // on (ggml/src/CMakeLists.txt ggml_add_backend): the pinned cmake
        // defaults BLAS and Metal to ON only on Apple, so Linux links the
        // core set and macOS links the full set.
        const llama_libs: []const []const u8 = if (target.result.os.tag == .macos)
            &[_][]const u8{ "llama", "ggml", "ggml-base", "ggml-cpu", "ggml-blas", "ggml-metal" }
        else
            &[_][]const u8{ "llama", "ggml", "ggml-base", "ggml-cpu" };
        embed.addLibraryPath(b.path("zig-out/llama/src"));
        embed.addLibraryPath(b.path("zig-out/llama/ggml/src"));
        // The blas/metal archives only exist on macOS (the pinned cmake
        // defaults build them only on Apple). Entries for missing
        // directories make the linker warn on every artifact that imports
        // this module, so mirror the library set above.
        if (target.result.os.tag == .macos) {
            embed.addLibraryPath(b.path("zig-out/llama/ggml/src/ggml-blas"));
            embed.addLibraryPath(b.path("zig-out/llama/ggml/src/ggml-metal"));
        }
        for (llama_libs) |name| {
            embed.linkSystemLibrary(name, .{ .use_pkg_config = .no, .preferred_link_mode = .static });
        }
        // C++ stdlib: the build system links it as -lc++ (LLVM libc++)
        // wherever C++ objects are present. On macOS the host clang built the
        // engine against libc++; on Linux the engine is built with `zig c++`
        // (above), which links this same bundled libc++. The name only sets a
        // flag — 0.17 emits -lc++ either way.
        embed.linkSystemLibrary("c++", .{});
        if (target.result.os.tag == .macos) {
            embed.linkFramework("Accelerate", .{});
            embed.linkFramework("Metal", .{});
            embed.linkFramework("MetalKit", .{});
            embed.linkFramework("Foundation", .{});
        }
        exe.step.dependOn(&llama_build.step);
    }

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Tests: unit tests (one artifact per source file; the runner discovers
    // test blocks across each artifact's whole module), plus the Phase 0
    // vector suite.

    const options = b.addOptions();
    options.addOptionPath("vectors", b.path("spec/vectors/journals.json"));
    options.addOptionPath("anchors", b.path("spec/vectors/anchors.json"));
    options.addOptionPath("ots_vectors", b.path("spec/vectors/ots.json"));
    const vector_module = b.createModule(.{
        .root_source_file = b.path("test/vectors.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
            .{ .name = "std_options", .module = options.createModule() },
        },
    });
    const vector_tests = b.addTest(.{ .root_module = vector_module });
    const run_vector_tests = b.addRunArtifact(vector_tests);

    // Phase 2: views, amendments, tombstones, search (fixture journal on disk).
    const phase2_module = b.createModule(.{
        .root_source_file = b.path("test/phase2.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase2_tests = b.addTest(.{ .root_module = phase2_module });
    const run_phase2_tests = b.addRunArtifact(phase2_tests);

    // Phase 3 (fast): cross-segment round trip and sealed-segment tamper
    // detection on a real on-disk journal.
    const phase3_module = b.createModule(.{
        .root_source_file = b.path("test/phase3.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase3_tests = b.addTest(.{ .root_module = phase3_module });
    const run_phase3_tests = b.addRunArtifact(phase3_tests);

    // Phase 3 (slow): the 100k-entry round trip and the bytes-per-entry
    // measurement. Kept out of `test` because the whole-file rewrite per
    // append makes the run take minutes.
    // Phase 4: LLM export gate (private exclusion, refusal, tokens).
    // The verbose-report flag reads the process environment via a C
    // `environ` extern, so the module declares its libc dependency
    // (mandatory for Linux targets in 0.17; a no-op on macOS).
    const phase4_module = b.createModule(.{
        .root_source_file = b.path("test/phase4.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase4_tests = b.addTest(.{ .root_module = phase4_module });
    const run_phase4_tests = b.addRunArtifact(phase4_tests);
    // Always re-run rather than trust the run cache: the suite is
    // in-memory and costs seconds, and a fresh run on every invocation
    // keeps the gate measurement honest (0.17 caches run steps whose
    // manifest is unchanged).
    run_phase4_tests.has_side_effects = true;

    // Phase 5: anchor vectors — RFC 8032 known answers plus the pinned 190-byte
    // artifacts, re-derived from their inputs with std.crypto Ed25519.
    const anchors_module = b.createModule(.{
        .root_source_file = b.path("test/anchors.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
            .{ .name = "std_options", .module = options.createModule() },
        },
    });
    const anchors_tests = b.addTest(.{ .root_module = anchors_module });
    const run_anchors_tests = b.addRunArtifact(anchors_tests);

    // Phase 5: redaction and anchor gates on an on-disk journal.
    const phase5_module = b.createModule(.{
        .root_source_file = b.path("test/phase5.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase5_tests = b.addTest(.{ .root_module = phase5_module });
    const run_phase5_tests = b.addRunArtifact(phase5_tests);

    // Phase 6: MCP server gates (lifecycle, tool behavior, privacy, write
    // gating, refusal on corruption) driven in-process over in-memory I/O.
    const phase6_module = b.createModule(.{
        .root_source_file = b.path("test/phase6.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
            .{ .name = "zephyr_mcp", .module = mcp },
        },
    });
    const phase6_tests = b.addTest(.{ .root_module = phase6_module });
    const run_phase6_tests = b.addRunArtifact(phase6_tests);

    // Phase 7: derived layer gates (rebuild determinism, staleness, oracle
    // agreement, migration, status/rebuild) on an in-memory-I/O journal.
    const phase7_module = b.createModule(.{
        .root_source_file = b.path("test/phase7.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase7_tests = b.addTest(.{ .root_module = phase7_module });
    const run_phase7_tests = b.addRunArtifact(phase7_tests);

    // Phase 8: semantic layer gates (ZDE1 layout, rebuild determinism,
    // staleness, visible-only, fusion exactness) with a deterministic fake
    // engine; never links llama.cpp.
    const phase8_module = b.createModule(.{
        .root_source_file = b.path("test/phase8.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase8_tests = b.addTest(.{ .root_module = phase8_module });
    const run_phase8_tests = b.addRunArtifact(phase8_tests);

    // Encryption gate (spec/encryption.md): born-encrypted round trip,
    // verify with the key, LLM-view invariance vs a v1 twin.
    const vault_module = b.createModule(.{
        .root_source_file = b.path("test/vault.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const vault_tests = b.addTest(.{ .root_module = vault_module });
    const run_vault_tests = b.addRunArtifact(vault_tests);

    // Phase 5b: OpenTimestamps proof format (pinned vectors + corruption
    // suite), and the stamp/verify/redaction gates on an on-disk journal.
    const ots_module = b.createModule(.{
        .root_source_file = b.path("test/ots.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
            .{ .name = "std_options", .module = options.createModule() },
        },
    });
    const ots_tests = b.addTest(.{ .root_module = ots_module });
    const run_ots_tests = b.addRunArtifact(ots_tests);

    const phase5b_module = b.createModule(.{
        .root_source_file = b.path("test/phase5b.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const phase5b_tests = b.addTest(.{ .root_module = phase5b_module });
    const run_phase5b_tests = b.addRunArtifact(phase5b_tests);

    const roundtrip_module = b.createModule(.{
        .root_source_file = b.path("test/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zephyr_core", .module = core },
        },
    });
    const roundtrip_tests = b.addTest(.{ .root_module = roundtrip_module });
    const run_roundtrip_tests = b.addRunArtifact(roundtrip_tests);
    b.step("roundtrip", "Phase 3 gate: 100k-entry round trip (slow)").dependOn(&run_roundtrip_tests.step);

    const test_step = b.step("test", "Run tests");
    const core_test_files = [_][]const u8{
        "src/core/records.zig",
        "src/core/segment.zig",
        "src/core/journal.zig",
        "src/core/vault.zig",
        // Key module: the key file store's disk paths (the keychain store
        // is smoke-tested manually; it cannot run in CI).
        "src/key/keyfile.zig",
        "src/core/view.zig",
        "src/core/nfc.zig",
        "src/core/timezone.zig",
        "src/core/mark_ranges.zig",
        "src/core/search.zig",
        "src/core/tokens.zig",
        "src/core/derived.zig",
        "src/core/dstore.zig",
        // Phase 6: pure wire protocol (self-contained; no core imports).
        "src/mcp/protocol.zig",
        // Phase 8: the C binding's layout tests (no engine link needed).
        "src/embed/llama.zig",
        // Distribution: the model fetcher's network-free paths.
        "src/embed/fetch.zig",
        // CLI layer: the TTY styled renderers' tests (style-off identity,
        // SGR shape), pulled in through a shared-directory test root.
        "src/cli/render_tests.zig",
    };
    for (core_test_files) |path| {
        const module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            // The CLI-layer files in this list import the project modules
            // by name (the key command reaches cli's error union, which
            // names every surface); the rest simply don't use them. The
            // engine is never instantiated here: the test graph references
            // only the embed module's error type, so no llama link.
            .imports = &.{
                .{ .name = "zephyr_core", .module = core },
                .{ .name = "zephyr_mcp", .module = mcp },
                .{ .name = "zephyr_embed", .module = embed },
                .{ .name = "zephyr_key", .module = key },
            },
        });
        const core_tests = b.addTest(.{ .root_module = module });
        const run_core_tests = b.addRunArtifact(core_tests);
        test_step.dependOn(&run_core_tests.step);
    }
    test_step.dependOn(&run_vector_tests.step);
    test_step.dependOn(&run_phase2_tests.step);
    test_step.dependOn(&run_phase3_tests.step);
    test_step.dependOn(&run_phase4_tests.step);
    test_step.dependOn(&run_anchors_tests.step);
    test_step.dependOn(&run_phase5_tests.step);
    test_step.dependOn(&run_ots_tests.step);
    test_step.dependOn(&run_phase5b_tests.step);
    test_step.dependOn(&run_phase6_tests.step);
    test_step.dependOn(&run_phase7_tests.step);
    test_step.dependOn(&run_phase8_tests.step);
    test_step.dependOn(&run_vault_tests.step);

    const fmt_step = b.step("fmt", "Run format checks");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = b.pathList(&.{ "src", "test", "build.zig" }),
        .check = true,
    }).step);
}
