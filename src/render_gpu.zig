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

/// A second raster + export images on the SAME Vulkan device, reusing the
/// baked sphere/tube meshes — how the inspector popup gets a zengine scene of
/// its own (emissive spheres, edge tubes, HDR bloom) without a second device.
pub const View = struct {
    owner: *Gpu3d,
    raster: ze.gpu_mesh.MeshRaster,
    imgs: [2]ze.gpu.Gpu.ExportImage,
    w: u32,
    h: u32,

    pub fn destroy(self: *View) void {
        for (&self.imgs) |*im| self.owner.gpu.destroyExportImage(im);
        self.raster.deinit();
        const gpa = self.owner.gpa;
        gpa.destroy(self);
    }
};

/// The zengine device plus the baked sphere/tube meshes. Windows don't render
/// from it directly — each asks for a `View` (its own raster + export images),
/// so the main window can resize without disturbing the inspector popup.
pub const Gpu3d = struct {
    gpa: std.mem.Allocator,
    gpu: ze.gpu.Gpu,
    pages: [][]const u8,
    refs: []ze.gpu_mesh.ClusterRef,
    /// [start, end) slices of `refs` for each of the two meshes.
    sphere_range: [2]u32,
    tube_range: [2]u32,
    total_pages: u32,
    /// The archive pages, kept resident so every view can upload them.
    page_bytes: [][]u8,

    /// Destroy every `View` first.
    pub fn destroy(self: *Gpu3d) void {
        const gpa = self.gpa;
        self.gpu.deinit();
        for (self.page_bytes) |b| gpa.free(b);
        gpa.free(self.page_bytes);
        gpa.free(self.pages);
        gpa.free(self.refs);
        gpa.destroy(self);
    }

    /// An additional render target on this device (the popup's mini-scene).
    /// Destroy it BEFORE the owner.
    pub fn createView(self: *Gpu3d, w: u32, h: u32, max_instances: u32, bloom: f32) !*View {
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        v.owner = self;
        v.w = w;
        v.h = h;
        v.raster = try ze.gpu_mesh.MeshRaster.init(&self.gpu, self.gpa, self.pages, self.refs, max_instances, w, h);
        errdefer v.raster.deinit();
        for (self.page_bytes, 0..) |bytes, p| v.raster.uploadPage(@intCast(p), bytes);
        v.imgs[0] = try self.gpu.createExportImage(w, h, ze.gpu.vk.image_usage_color_attachment);
        errdefer self.gpu.destroyExportImage(&v.imgs[0]);
        v.imgs[1] = try self.gpu.createExportImage(w, h, ze.gpu.vk.image_usage_color_attachment);
        v.raster.enableBloom(.{ .intensity = bloom }) catch |e| {
            std.debug.print("bloom unavailable ({s}) — flat tonemap\n", .{@errorName(e)});
        };
        return v;
    }

    /// Heap-allocated because every `MeshRaster` keeps a pointer to the `Gpu`
    /// — the struct must never move once a view exists.
    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*Gpu3d {
        const self = try gpa.create(Gpu3d);
        errdefer gpa.destroy(self);
        self.gpa = gpa;

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

        // Page bytes stay resident: every view uploads them into its raster.
        self.page_bytes = try gpa.alloc([]u8, self.total_pages);
        errdefer gpa.free(self.page_bytes);
        for (0..self.total_pages) |p| self.page_bytes[p] = try archive.readPageAlloc(gpa, @intCast(p));
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
