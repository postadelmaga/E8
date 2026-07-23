const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Everything is math + per-pixel software fallback; Debug can't hold 60 Hz,
    // so optimized is the default (same policy as zrame/zengine live demos).
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse .ReleaseFast;

    // zrame: the glass window. Its zicro is the path dep ../Zicro; we request the
    // SAME package with the SAME args so the two dedup into one module — zengine
    // is then built against that very zicro instance (below), keeping exactly one
    // zicro in the link (its stb_truetype impl must not appear twice).
    const zrame_dep = b.dependency("zrame", .{ .target = target });
    const zicro_dep = b.dependency("zicro", .{ .target = target, .optimize = .ReleaseFast });

    // zengine, assembled here from its sources instead of via its own build():
    // upstream pins zicro as a git dependency, which would be a SECOND zicro next
    // to zrame's path one. Same module shape as zengine/build.zig's
    // `configureNative`, with paths rooted in the zengine package.
    const zengine_dep = b.dependency("zengine", .{ .target = target, .optimize = .ReleaseFast });
    const zb = zengine_dep.builder;
    const zengine_mod = b.createModule(.{
        .root_source_file = zb.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true, // meshoptimizer's default allocator uses operator new/delete
        .imports = &.{
            .{ .name = "zicro", .module = zicro_dep.module("zicro") },
        },
    });
    zengine_mod.linkSystemLibrary("zstd", .{});
    zengine_mod.addCSourceFiles(.{
        .root = zb.path("."),
        .files = &.{
            "third_party/meshoptimizer/allocator.cpp",
            "third_party/meshoptimizer/clusterizer.cpp",
            "third_party/meshoptimizer/simplifier.cpp",
            "third_party/meshoptimizer/partition.cpp",
            "third_party/meshoptimizer/indexgenerator.cpp",
        },
        .flags = &.{ "-fno-exceptions", "-fno-rtti" },
    });
    zengine_mod.addIncludePath(zb.path("third_party/ufbx"));
    zengine_mod.addCSourceFiles(.{
        .root = zb.path("."),
        .files = &.{
            "third_party/stb/stb_image_impl.c",
            "third_party/ufbx/ufbx.c",
            "third_party/ufbx/ufbx_shim.c",
        },
        .flags = &.{"-fno-sanitize=undefined"},
    });
    zengine_mod.linkSystemLibrary("webp", .{});
    zengine_mod.addIncludePath(zb.path("third_party/basisu"));
    zengine_mod.addCSourceFiles(.{
        .root = zb.path("."),
        .files = &.{
            "third_party/basisu/basisu_transcoder.cpp",
            "third_party/basisu/basisu_shim.cpp",
        },
        .flags = &.{
            "-fno-exceptions",
            "-fno-rtti",
            "-O2",
            "-DBASISD_SUPPORT_KTX2=1",
            "-DBASISD_SUPPORT_KTX2_ZSTD=1",
        },
    });
    zengine_mod.linkSystemLibrary("vulkan", .{});
    const shaders = [_]struct { stage: []const u8, src: []const u8, import: []const u8, include: bool = false, include_gpu: bool = false, target: []const u8 = "vulkan1.0" }{
        .{ .stage = "compute", .src = "src/gpu/voxel_march.comp", .import = "voxel_march_spv" },
        .{ .stage = "vertex", .src = "src/gpu/cluster.vert", .import = "cluster_vert_spv" },
        .{ .stage = "fragment", .src = "src/gpu/cluster.frag", .import = "cluster_frag_spv" },
        .{ .stage = "vertex", .src = "src/gpu/fsr_fullscreen.vert", .import = "fsr_vert_spv" },
        .{ .stage = "fragment", .src = "src/gpu/fsr_easu.frag", .import = "fsr_easu_spv", .include = true },
        .{ .stage = "fragment", .src = "src/gpu/fsr_rcas.frag", .import = "fsr_rcas_spv", .include = true },
        .{ .stage = "fragment", .src = "src/gpu/fsr_easu_h.frag", .import = "fsr_easu_h_spv", .include = true, .target = "vulkan1.1" },
        .{ .stage = "fragment", .src = "src/gpu/fsr_rcas_h.frag", .import = "fsr_rcas_h_spv", .include = true, .target = "vulkan1.1" },
        .{ .stage = "vertex", .src = "src/gpu/taa_fullscreen.vert", .import = "taa_vert_spv" },
        .{ .stage = "fragment", .src = "src/gpu/taa.frag", .import = "taa_frag_spv" },
        .{ .stage = "vertex", .src = "src/gpu/bloom_fullscreen.vert", .import = "bloom_vert_spv" },
        .{ .stage = "fragment", .src = "src/gpu/bloom_bright.frag", .import = "bloom_bright_spv" },
        .{ .stage = "fragment", .src = "src/gpu/bloom_blur.frag", .import = "bloom_blur_spv" },
        .{ .stage = "fragment", .src = "src/gpu/bloom_composite.frag", .import = "bloom_composite_spv" },
        .{ .stage = "fragment", .src = "src/gpu/sky.frag", .import = "sky_frag_spv" },
        .{ .stage = "fragment", .src = "src/gpu/ssao.frag", .import = "ssao_frag_spv" },
        .{ .stage = "fragment", .src = "src/gpu/field_preview.frag", .import = "field_preview_spv", .include_gpu = true },
    };
    for (shaders) |s| {
        const glslc = b.addSystemCommand(&.{"glslc"});
        glslc.addArg(b.fmt("-fshader-stage={s}", .{s.stage}));
        glslc.addArg("-O");
        glslc.addArg(b.fmt("--target-env={s}", .{s.target}));
        if (s.include) glslc.addPrefixedDirectoryArg("-I", zb.path("src/gpu/amd"));
        if (s.include_gpu) glslc.addPrefixedDirectoryArg("-I", zb.path("src/gpu"));
        glslc.addFileArg(zb.path(s.src));
        glslc.addArg("-o");
        const spv = glslc.addOutputFileArg("shader.spv");
        zengine_mod.addAnonymousImport(s.import, .{ .root_source_file = spv });
    }

    // ONE EXECUTABLE PER DEMO.
    //
    // The domain is a comptime seam (src/domain.zig): a demo's `Point` type and its
    // `dim` are baked into the binary — `geom.Vec = [dim]f32` — so a single process
    // cannot switch demo. It does not need to: the launcher (e8-menu, below) is a
    // separate program that SPAWNS the one the user picked. Every demo is therefore
    // its own executable, `e8-<name>`, differing only in the `build_options.demo`
    // string. The heavy modules — zengine, zrame, the compiled shaders — are shared,
    // so what is repeated is src/main.zig and the plugins, not the engine.
    const demos = [_][]const u8{
        "lisi",  "mtheory", "polytope", "molecule", "data",
        "embed", "chem",    "graph",    "astro",
    };

    const zrame_mod = zrame_dep.module("zrame");

    var exes: [demos.len]*std.Build.Step.Compile = undefined;
    for (demos, 0..) |name, i| {
        const opt = b.addOptions();
        opt.addOption([]const u8, "demo", name);
        exes[i] = b.addExecutable(.{
            .name = b.fmt("e8-{s}", .{name}),
            .use_llvm = true, // match zengine: 0.16 self-hosted backend miscompile in extern calls
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zengine", .module = zengine_mod },
                    .{ .name = "zrame", .module = zrame_mod },
                    .{ .name = "build_options", .module = opt.createModule() },
                },
            }),
        });
        b.installArtifact(exes[i]);
    }

    // The launcher: pick a demo, or author a new one. It has NO domain — it never
    // imports app.zig or domain.zig — so it pays none of the comptime seam, and it
    // does not link zengine either: it is a window, a list and a process spawner.
    // The one piece of the demo it does share: the ZON writer. The launcher writes a
    // deck.zon and a manifest.zon with the author's own name in them, and escaping a
    // string literal is not a thing to have two opinions about. `deck_write` is
    // std-only, so importing it costs the launcher nothing.
    const deck_write_mod = b.createModule(.{
        .root_source_file = b.path("src/deck_write.zig"),
        .target = target,
        .optimize = optimize,
    });

    const menu = b.addExecutable(.{
        .name = "e8-menu",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/menu/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrame", .module = zrame_mod },
                .{ .name = "deck_write", .module = deck_write_mod },
            },
        }),
    });
    b.installArtifact(menu);

    // `zig build run` opens the launcher — the way in for someone who is not
    // holding a build command.
    const run_menu = b.addRunArtifact(menu);
    if (b.args) |a| run_menu.addArgs(a);
    const run_step = b.step("run", "Open the launcher (pick a demo, or author one)");
    run_step.dependOn(&run_menu.step);

    // `zig build run-demo -Ddemo=mtheory -- --gpu` runs ONE demo straight, which is
    // the tighter loop while developing a domain.
    const demo = b.option([]const u8, "demo", "Demo to run with `run-demo`: lisi, mtheory, molecule, polytope, data (any CSV/TSV), embed (.npy/CSV embeddings), chem (PDB/XYZ), graph (GraphML/edge list), astro (star catalogs)") orelse "lisi";
    const run_one = b.step("run-demo", "Run one demo directly (-Ddemo=<name>)");
    for (demos, 0..) |name, i| {
        if (!std.mem.eql(u8, name, demo)) continue;
        const rc = b.addRunArtifact(exes[i]);
        if (b.args) |a| rc.addArgs(a);
        run_one.dependOn(&rc.step);
    }

    // `zig build web -Ddemo=lisi` — the interactive paper in a browser tab.
    //
    // wasm32-freestanding: no libc, no Wayland, and NO ZENGINE — the engine is
    // Vulkan, and a tab has none. It costs nothing to leave out, because the
    // figure was always drawn by `render_cpu.zig`, which is pure Zig arithmetic;
    // the GPU path is an accelerator, not the renderer. Everything else in the
    // frame — the projection, the plugins, the deck, the HUD — is the very same
    // code the native build runs (see src/web.zig, src/platform.zig).
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

        // Size, not speed — and that is a measurement, not a preference.
        //
        // The tab has ONE thread (native `render_cpu` splits the frame across a
        // pool of band workers; wasm freestanding has none to give it), so the
        // guess was that -Os was starving a scalar per-pixel loop of the
        // inlining it lives on, and that -OReleaseFast would pay for itself.
        // Benchmarked instead of assumed — both builds instantiated in one page,
        // driven round-robin, scored on the MINIMUM frame so the machine's own
        // load lands on both — the E8 atlas at 1584×990 came out:
        //
        //     ReleaseSmall  0.94 MB   194 ms/frame
        //     ReleaseFast   3.31 MB   164 ms/frame     → 1.19×
        //
        // 19% of a frame for 3.5× the download is a bad trade for a page whose
        // first act is to fetch this file, and it does not rescue 6 fps anyway:
        // the frame is dominated by per-pixel work, not by the code quality of
        // the inner loop (a 24-point scene costs 100 ms at the same size a
        // 240-point, 6720-edge one costs 153 ms). The lever that matters is
        // resolution, or a real thread pool. `-Dweb-fast` opts in regardless.
        const web_fast = b.option(bool, "web-fast", "Build the wasm for speed (-OReleaseFast, ~1.2x the frames, ~3.5x the download)") orelse false;
        const web_optimize: std.builtin.OptimizeMode = if (web_fast) .ReleaseFast else .ReleaseSmall;
        const zicro_dep_web = b.dependency("zicro", .{ .target = wasm_target, .optimize = web_optimize });
        const zicro_web = b.createModule(.{
            .root_source_file = zicro_dep_web.builder.path("src/web_root.zig"),
            .target = wasm_target,
            .optimize = web_optimize,
        });
        zicro_web.addIncludePath(zicro_dep_web.builder.path("vendor/stb"));
        zicro_web.addCSourceFile(.{
            .file = zicro_dep_web.builder.path("vendor/stb/stb_truetype_web.c"),
            .flags = &.{ "-O2", "-fno-sanitize=undefined" },
        });
        const zrame_web = b.createModule(.{
            .root_source_file = zrame_dep.builder.path("src/web_root.zig"),
            .target = wasm_target,
            .optimize = web_optimize,
            .imports = &.{.{ .name = "zicro", .module = zicro_web }},
        });

        // The engine, in name only: `still.zig` calls its image decoder, and the
        // tab has no Vulkan to link one out of (src/zengine_web.zig).
        const zengine_stub = b.createModule(.{
            .root_source_file = b.path("src/zengine_web.zig"),
            .target = wasm_target,
            .optimize = web_optimize,
        });

        const web_step = b.step("web", "Build every demo for the browser into zig-out/web");

        // ONE WASM PER DEMO — the same reason there is one executable per demo, and
        // the same answer. The domain is a comptime seam, so a module cannot switch
        // demo at runtime; natively the launcher spawns the right process, and a tab
        // cannot spawn anything. So it FETCHES the right module instead: the gallery
        // (web/index.html) lists them, and `demo.html?d=<name>` instantiates exactly
        // one — which is also what a browser wants, since nobody downloads nine
        // demos to look at one.
        // ALL NINE. The four that generate their points always could; the five profiles
        // now ship a real dataset each (demos/SAMPLES.md), embedded, so a tab that has
        // no file to give them still has something to show — and a visitor can drop
        // their own file on the page to replace it.
        for (demos) |name| {
            const web_opt = b.addOptions();
            web_opt.addOption([]const u8, "demo", name);

            const web_mod = b.createModule(.{
                .root_source_file = b.path("src/web.zig"),
                .target = wasm_target,
                .optimize = web_optimize,
                .imports = &.{
                    .{ .name = "zrame", .module = zrame_web },
                    .{ .name = "zengine", .module = zengine_stub },
                    .{ .name = "build_options", .module = web_opt.createModule() },
                    // The rasterizer this build does NOT have. `web.zig` is one file
                    // with two, and the build picks which one answers to the name —
                    // here the off switch, so `scene.enabled` is comptime false and the
                    // wgpu modules (emscripten-only) are never named at all.
                    .{ .name = "scene_gpu", .module = b.createModule(.{
                        .root_source_file = b.path("src/scene_gpu_off.zig"),
                        .target = wasm_target,
                        .optimize = web_optimize,
                    }) },
                },
            });
            const web_exe = b.addExecutable(.{ .name = b.fmt("e8-{s}", .{name}), .root_module = web_mod });
            web_exe.entry = .disabled;
            web_exe.rdynamic = true;
            const install_wasm = b.addInstallArtifact(web_exe, .{
                .dest_dir = .{ .override = .{ .custom = "web/wasm" } },
            });
            web_step.dependOn(&install_wasm.step);
        }

        inline for (.{ "index.html", "demo.html" }) |page| {
            const copy = b.addInstallFileWithDir(b.path("web/" ++ page), .{ .custom = "web" }, page);
            web_step.dependOn(&copy.step);
        }
    }

    // `zig build web-gpu` — the atlas drawn by the GPU, in a tab.
    //
    // A SECOND web build, not a replacement, and the target is why: the software path
    // above is `wasm32-freestanding` (no libc, its own hand-rolled JS harness), while a
    // browser's WebGPU is not something a freestanding wasm can link — it is Dawn's JS
    // bindings, and emcc generates them. So this one is `wasm32-emscripten`, emcc is the
    // LINKER, and the two builds share source but not a toolchain.
    //
    // Worth the second build because the frame is per-pixel work on the tab's ONE thread
    // (see the note in demo.html): the atlas is ~6 fps at 1584×990 no matter how the
    // rasterizer is tuned. Zengine's `ze_wgpu.MeshPresent` (its issue #88) hands the
    // whole figure to the GPU as two instanced draws.
    //
    // The seam arrives from the PACKAGE (Zengine issue #89): `ze_wgpu_web` and
    // `zicro_wgpu_web` are published modules, fully wired — zicro's webgpu.h binding
    // built from Zengine's own zicro (no second zicro to collide with), the
    // emdawnwebgpu include path, and every shader `rhi_wgpu.zig` @embedFiles already
    // compiled (glslc) and transpiled (naga) inside the dependency. This block used to
    // rebuild all of that by hand; what is left is E8's own modules and the emcc link.
    {
        const emcc = b.findProgram(&.{"emcc"}, &.{}) catch null;
        const gpu_step = b.step("web-gpu", "Build the GPU (WebGPU) web build into zig-out/web/gpu");
        if (emcc) |emcc_path| {
            const em_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
            // Zig ships no libc for this target — emcc does, and emcc links, so the
            // headers have to be pointed at by hand. Same for Dawn's `webgpu.h`, which
            // the emdawnwebgpu port drops in the emsdk cache.
            const emsdk = std.fs.path.dirname(emcc_path).?;
            const sysroot = b.pathJoin(&.{ emsdk, "cache", "sysroot", "include" });

            const Em = struct {
                b: *std.Build,
                target: std.Build.ResolvedTarget,
                sysroot: []const u8,
                fn make(self: @This(), root: std.Build.LazyPath) *std.Build.Module {
                    const m = self.b.createModule(.{
                        .root_source_file = root,
                        .target = self.target,
                        .optimize = .ReleaseFast,
                        // Mandatory: without it `std.start` tries to synthesize `_start`
                        // and dies on wasm. emcc owns the entry here.
                        .link_libc = true,
                    });
                    m.addIncludePath(.{ .cwd_relative = self.sysroot });
                    return m;
                }
            };
            const em = Em{ .b = b, .target = em_target, .sysroot = sysroot };

            // The seam, from the package. Everything the cut-out hand-wiring used to
            // build — zicro_wgpu from source with Dawn's include, ze_rhi, ze_wgpu, six
            // shaders through glslc + naga (WGSL and the es300 pair for the WebGL2
            // twin) — now arrives as two published modules. See `ze_wgpu.zig`'s header
            // in Zengine for the whole recipe, including why the wasm root must own
            // its logFn and panic (web.zig already does).
            const zw = zengine_dep.module("zicro_wgpu_web");
            const ze_wgpu = zengine_dep.module("ze_wgpu_web");

            // The scene's GPU rasterizer — the module `web.zig` names `scene_gpu`.
            const scene_gpu = em.make(b.path("src/scene_gpu.zig"));
            scene_gpu.addImport("zicro_wgpu", zw);
            scene_gpu.addImport("ze_wgpu", ze_wgpu);

            // …and the tool itself, THE SAME `web.zig` the software build compiles. The
            // window, the input, the plugins, the deck and the HUD come along for free
            // because they were never copied; only the rasterizer differs, and it differs
            // at comptime. zrame/zicro have to be rebuilt for wasm32-emscripten (the
            // software build targets wasm32-freestanding) — same sources, other target.
            const zicro_em = em.make(zicro_dep.builder.path("src/web_root.zig"));
            zicro_em.addIncludePath(zicro_dep.builder.path("vendor/stb"));
            zicro_em.addCSourceFile(.{
                .file = zicro_dep.builder.path("vendor/stb/stb_truetype_web.c"),
                .flags = &.{ "-O2", "-fno-sanitize=undefined" },
            });
            const zrame_em = em.make(zrame_dep.builder.path("src/web_root.zig"));
            zrame_em.addImport("zicro", zicro_em);

            const zengine_em = em.make(b.path("src/zengine_web.zig"));

            // ONE WASM PER DEMO, like the software build above and for the same
            // reason: the domain is a comptime seam. The heavy modules — the GPU
            // rasterizer, zicro, zrame — are shared; what repeats is web.zig and
            // the plugins, plus one emcc link each.
            for (demos) |name| {
                const gpu_opt = b.addOptions();
                gpu_opt.addOption([]const u8, "demo", name);

                const gpu_mod = em.make(b.path("src/web.zig"));
                gpu_mod.addImport("zrame", zrame_em);
                gpu_mod.addImport("zengine", zengine_em);
                gpu_mod.addImport("build_options", gpu_opt.createModule());
                gpu_mod.addImport("scene_gpu", scene_gpu);

                const gpu_lib = b.addLibrary(.{ .name = b.fmt("e8gpu-{s}", .{name}), .linkage = .static, .root_module = gpu_mod });
                const link = b.addSystemCommand(&.{emcc_path});
                link.addFileArg(gpu_lib.getEmittedBin());
                link.addArgs(&.{
                    "--use-port=emdawnwebgpu", // the WebGPU JS bindings answering webgpu.h
                    // The twin's half of the link: emscripten's GL-on-WebGL2 JS library.
                    // Both devices are linked in and the wasm picks at runtime — a browser
                    // whose `requestAdapter` answers null still has a GPU path.
                    "-lGL",
                    "-sMIN_WEBGL_VERSION=2",
                    "-sMAX_WEBGL_VERSION=2",
                    "-sENVIRONMENT=web",
                    // A fixed heap, cut once and large enough. NOT growth: when the heap
                    // grows, wasm hands back a NEW ArrayBuffer and every view the page holds
                    // — the pixels it blits, the scene rect it reads — is detached and throws
                    // on the next frame. The page would have to re-derive its views each tick
                    // and would still race the growth that happened mid-frame. 256 MB costs
                    // nothing until touched and removes the whole class.
                    "-sINITIAL_MEMORY=268435456",
                    "-sALLOW_MEMORY_GROWTH=0",
                    // The tool's whole ABI: zicro's window seam (frame, input, the pixel
                    // buffer) plus web.zig's own. emcc strips what is not named here, and a
                    // missing name is a page that boots into a dead canvas — so this list is
                    // the two `export fn` sets, not a guess.
                    "-sEXPORTED_FUNCTIONS=" ++
                        "_zicroFrame,_zicroPixels,_zicroResize,_zicroKey,_zicroPointerMove," ++
                        "_zicroPointerButton,_zicroScroll,_zicroSetTouch,_zicroTouch," ++
                        "_zicroWidth,_zicroHeight," ++
                        "_zicroBoot,_zicroTap,_zicroCamera,_zicroOptions,_zicroOptionsLen," ++
                        "_zicroSceneScale,_zicroSceneRect,_zicroSceneDevice,_zicroForceGl," ++
                        "_zicroOpenFile,_zicroFileBuffer,_zicroFileName,_zicroAddImage," ++
                        "_zicroDeckBuffer,_zicroDeckZon,_zicroDeckZonLen,_zicroApplyDeck," ++
                        "_malloc,_free",
                    // HEAPU8 is not on `Module` unless it is named here, and without it the
                    // page cannot reach the pixels the software canvas paints — the frame
                    // loop throws on its first tick and the tab goes quiet.
                    "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString,HEAPU8",
                    "-sINVOKE_RUN=0", // no main: the page calls _ze_boot
                    "-sEXIT_RUNTIME=0",
                    "-O3",
                    "-o",
                });
                const js = link.addOutputFileArg(b.fmt("e8-{s}.js", .{name}));
                link.step.dependOn(&gpu_lib.step);
                gpu_step.dependOn(&b.addInstallFileWithDir(js, .{ .custom = "web/gpu" }, b.fmt("e8-{s}.js", .{name})).step);
                gpu_step.dependOn(&b.addInstallFileWithDir(js.dirname().path(b, b.fmt("e8-{s}.wasm", .{name})), .{ .custom = "web/gpu" }, b.fmt("e8-{s}.wasm", .{name})).step);
            }
            gpu_step.dependOn(&b.addInstallFileWithDir(b.path("web/gpu.html"), .{ .custom = "web/gpu" }, "index.html").step);
        } else {
            // Not an error: the CPU web build is the one that always works, and a
            // machine without Emscripten should still be able to build everything else.
            const msg = b.addFail("emcc not found — the GPU web build needs Emscripten (source emsdk_env.sh). The software build, `zig build web`, needs nothing.");
            gpu_step.dependOn(&msg.step);
        }
    }

    // Tests: the root-system math is exact Lie theory — every invariant is checked.
    // E8 (Lisi's 240 roots) and E10 (the M-theory demo: the Lorentzian lattice,
    // the Dynkin diagram recovered from the simple roots, the BKL billiard).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const test_step = b.step("test", "Run the root-system unit tests (E8 and E10)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
