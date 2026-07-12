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

    // Which domain package drives the presenter (src/demos/<demo>/domain.zig).
    const demo = b.option([]const u8, "demo", "Demo/domain to build: lisi, molecule, polytope") orelse "lisi";
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "demo", demo);

    const exe = b.addExecutable(.{
        .name = "e8-explorer",
        .use_llvm = true, // match zengine: 0.16 self-hosted backend miscompile in extern calls
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zengine", .module = zengine_mod },
                .{ .name = "zrame", .module = zrame_dep.module("zrame") },
                .{ .name = "build_options", .module = build_opts.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |a| run_cmd.addArgs(a);
    const run_step = b.step("run", "Run the E8 explorer");
    run_step.dependOn(&run_cmd.step);

    // Tests: the root-system math is exact Lie theory — every invariant is checked.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demos/lisi/e8.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the E8 root-system unit tests");
    test_step.dependOn(&run_tests.step);
}
