//! GPU renderer for the E8 figure on zengine's cluster mesh raster: one baked
//! unit sphere (the 240 roots) + one baked unit tube (the 6720 edges), drawn as
//! instances with per-instance PBR materials (emissive per physics class) and
//! the HDR bloom + ACES chain, presented zero-copy as a dmabuf.
//!
//! Follows the recipe of zengine's examples/mesh_view.zig: procedural mesh →
//! `bake.bakeMesh` cluster DAG → `anunite.packMesh` into one GearPak archive →
//! every page uploaded up front (the whole scene is a few pages) → `MeshRaster`.

const std = @import("std");
const ze = @import("zengine");

pub const Gpu3d = struct {
    gpa: std.mem.Allocator,
    gpu: ze.gpu.Gpu,
    raster: ze.gpu_mesh.MeshRaster,
    imgs: [2]ze.gpu.Gpu.ExportImage,
    pages: [][]const u8,
    refs: []ze.gpu_mesh.ClusterRef,
    /// [start, end) slices of `refs` for each of the two meshes.
    sphere_range: [2]u32,
    tube_range: [2]u32,
    total_pages: u32,
    w: u32,
    h: u32,

    pub fn destroy(self: *Gpu3d) void {
        const gpa = self.gpa;
        for (&self.imgs) |*im| self.gpu.destroyExportImage(im);
        self.raster.deinit();
        self.gpu.deinit();
        gpa.free(self.pages);
        gpa.free(self.refs);
        gpa.destroy(self);
    }

    /// Heap-allocated because `MeshRaster` keeps a pointer to the `Gpu` — the
    /// struct must never move once the raster is initialized.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, w: u32, h: u32, max_instances: u32) !*Gpu3d {
        const self = try gpa.create(Gpu3d);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.w = w;
        self.h = h;

        self.gpu = try ze.gpu.Gpu.init();
        errdefer self.gpu.deinit();
        if (!self.gpu.can_export_dmabuf) return error.NoDmabufExport;

        var builder = ze.pak.Builder.init(gpa, ze.pak.default_page_size);
        defer builder.deinit();
        var refs: std.ArrayList(ze.gpu_mesh.ClusterRef) = .empty;
        defer refs.deinit(gpa);
        var handle_pages: std.ArrayList(u32) = .empty;
        defer handle_pages.deinit(gpa);

        var sphere_range: [2]u32 = undefined;
        var tube_range: [2]u32 = undefined;

        // Mesh 0: unit UV sphere.
        {
            var verts: std.ArrayList(f32) = .empty;
            defer verts.deinit(gpa);
            var indices: std.ArrayList(u32) = .empty;
            defer indices.deinit(gpa);
            const stacks: u32 = 12;
            const slices: u32 = 18;
            for (0..stacks + 1) |i| {
                const phi = std.math.pi * @as(f32, @floatFromInt(i)) / stacks;
                for (0..slices + 1) |j| {
                    const th = 2.0 * std.math.pi * @as(f32, @floatFromInt(j)) / slices;
                    const x = @sin(phi) * @cos(th);
                    const y = @cos(phi);
                    const z = @sin(phi) * @sin(th);
                    try verts.appendSlice(gpa, &.{
                        x, y, z, x, y, z,
                        @as(f32, @floatFromInt(j)) / slices,
                        @as(f32, @floatFromInt(i)) / stacks,
                    });
                }
            }
            for (0..stacks) |i| {
                for (0..slices) |j| {
                    const a: u32 = @intCast(i * (slices + 1) + j);
                    const b = a + slices + 1;
                    try indices.appendSlice(gpa, &.{ a, b, a + 1, a + 1, b, b + 1 });
                }
            }
            sphere_range = try bakeInto(gpa, &builder, &refs, &handle_pages, "sphere", verts.items, indices.items);
        }

        // Mesh 1: unit tube along z (radius 1, z ∈ [-1, 1]), open ends — the edge.
        {
            var verts: std.ArrayList(f32) = .empty;
            defer verts.deinit(gpa);
            var indices: std.ArrayList(u32) = .empty;
            defer indices.deinit(gpa);
            const seg: u32 = 10;
            for ([2]f32{ -1, 1 }) |z| {
                for (0..seg + 1) |j| {
                    const th = 2.0 * std.math.pi * @as(f32, @floatFromInt(j)) / seg;
                    const x = @cos(th);
                    const y = @sin(th);
                    try verts.appendSlice(gpa, &.{
                        x, y, z, x, y, 0,
                        @as(f32, @floatFromInt(j)) / seg,
                        (z + 1) * 0.5,
                    });
                }
            }
            for (0..seg) |j| {
                const a: u32 = @intCast(j);
                const b = a + seg + 1;
                try indices.appendSlice(gpa, &.{ a, b, a + 1, a + 1, b, b + 1 });
            }
            tube_range = try bakeInto(gpa, &builder, &refs, &handle_pages, "tube", verts.items, indices.items);
        }

        // One tiny archive; every page resident from frame zero.
        const new_index = try builder.writeTo(io, .cwd(), "e8-scene.gpak", 3);
        defer gpa.free(new_index);
        for (refs.items, handle_pages.items) |*r, hp| r.page = new_index[hp];

        var archive = try ze.pak.Pak.open(gpa, io, .cwd(), "e8-scene.gpak");
        defer archive.deinit();
        self.total_pages = @intCast(archive.pages.len);
        self.sphere_range = sphere_range;
        self.tube_range = tube_range;

        self.pages = try gpa.alloc([]const u8, self.total_pages);
        errdefer gpa.free(self.pages);
        for (self.pages) |*dst| dst.* = "";

        self.refs = try refs.toOwnedSlice(gpa);
        errdefer gpa.free(self.refs);

        self.raster = try ze.gpu_mesh.MeshRaster.init(&self.gpu, gpa, self.pages, self.refs, max_instances, w, h);
        errdefer self.raster.deinit();
        for (0..self.total_pages) |p| {
            const bytes = try archive.readPageAlloc(gpa, @intCast(p));
            defer gpa.free(bytes);
            self.raster.uploadPage(@intCast(p), bytes);
        }

        self.imgs[0] = try self.gpu.createExportImage(w, h, ze.gpu.vk.image_usage_color_attachment);
        errdefer self.gpu.destroyExportImage(&self.imgs[0]);
        self.imgs[1] = try self.gpu.createExportImage(w, h, ze.gpu.vk.image_usage_color_attachment);
        self.raster.enableBloom(.{ .intensity = 0.45 }) catch |e| {
            std.debug.print("bloom unavailable ({s}) — flat tonemap\n", .{@errorName(e)});
        };
        return self;
    }

    fn bakeInto(
        gpa: std.mem.Allocator,
        builder: *ze.pak.Builder,
        refs: *std.ArrayList(ze.gpu_mesh.ClusterRef),
        handle_pages: *std.ArrayList(u32),
        name: []const u8,
        verts: []const f32,
        indices: []const u32,
    ) ![2]u32 {
        var baked = try ze.bake.bakeMesh(gpa, verts, indices, .{});
        defer baked.deinit();
        const info = try ze.anunite.packMesh(builder, baked.clusters, baked.bounds, name);
        defer gpa.free(info.cluster_locations);
        const base: u32 = @intCast(refs.items.len);
        for (baked.clusters, info.cluster_locations) |c, loc| {
            try refs.append(gpa, .{
                .page = 0, // final index filled after writeTo
                .word_offset = loc.offset / 4,
                .tri_count = @intCast(c.tri_indices.len / 3),
                .lod_error = c.lod_error,
                .parent_lod_error = c.parent_lod_error,
                .parent = if (c.parent == ze.anunite.no_parent_cluster)
                    ze.gpu_mesh.no_parent
                else
                    base + c.parent,
            });
            try handle_pages.append(gpa, @intFromEnum(loc.page));
        }
        return .{ base, @intCast(refs.items.len) };
    }
};
