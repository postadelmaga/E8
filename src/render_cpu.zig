//! Software renderer for the E8 figure — additive luminous edges + shaded discs,
//! presented as an RGBA frame through `Window.presentRgba`. This is the path that
//! always works (no Vulkan, no dmabuf), in the spirit of the classic 2D E8 plots:
//! points on top, light accumulating where edge bundles cross.
//!
//! The 6720 edges dominate the frame, so they render on all cores: the frame is
//! split into horizontal bands, every worker walks the full edge list but steps
//! only the parametric range of each segment that crosses its own band — no
//! per-worker buffers to merge, no write races, work split ~evenly.

const std = @import("std");

pub const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    rgb: [3]f32,
    k0: f32, // intensity at each end, 0..255 additive scale
    k1: f32,
};

pub const Cpu = struct {
    gpa: std.mem.Allocator,
    fb: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,

    pub fn deinit(self: *Cpu) void {
        if (self.fb.len > 0) self.gpa.free(self.fb);
    }

    /// (Re)size the framebuffer to the requested resolution.
    pub fn ensure(self: *Cpu, w: u32, h: u32) !void {
        if (self.w == w and self.h == h and self.fb.len > 0) return;
        if (self.fb.len > 0) self.gpa.free(self.fb);
        self.fb = try self.gpa.alloc(u8, @as(usize, w) * h * 4);
        self.w = w;
        self.h = h;
    }

    /// Deep-space vertical gradient, fully opaque.
    pub fn clear(self: *Cpu) void {
        for (0..self.h) |y| {
            const t: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.h));
            const r: u8 = @intFromFloat(7.0 + 6.0 * t);
            const g: u8 = @intFromFloat(8.0 + 8.0 * t);
            const b: u8 = @intFromFloat(14.0 + 14.0 * t);
            const row = self.fb[y * self.w * 4 ..][0 .. self.w * 4];
            var x: usize = 0;
            while (x < row.len) : (x += 4) {
                row[x] = r;
                row[x + 1] = g;
                row[x + 2] = b;
                row[x + 3] = 255;
            }
        }
    }

    inline fn addPx(self: *Cpu, x: i32, y: i32, rgb: [3]f32, k: f32) void {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return;
        const o = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
        const p = self.fb[o..][0..4];
        p[0] = @intCast(@min(255, @as(u32, p[0]) + @as(u32, @intFromFloat(rgb[0] * k))));
        p[1] = @intCast(@min(255, @as(u32, p[1]) + @as(u32, @intFromFloat(rgb[1] * k))));
        p[2] = @intCast(@min(255, @as(u32, p[2]) + @as(u32, @intFromFloat(rgb[2] * k))));
    }

    inline fn blendPx(self: *Cpu, x: i32, y: i32, rgb: [3]f32, a: f32) void {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return;
        const o = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
        const p = self.fb[o..][0..4];
        const ia = 1.0 - a;
        p[0] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(p[0])) * ia + rgb[0] * 255.0 * a));
        p[1] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(p[1])) * ia + rgb[1] * 255.0 * a));
        p[2] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(p[2])) * ia + rgb[2] * 255.0 * a));
    }

    /// Draw the parametric slice of one edge that falls in rows [y_lo, y_hi).
    fn edgeInBand(self: *Cpu, e: *const Edge, y_lo: f32, y_hi: f32) void {
        const dx = e.x1 - e.x0;
        const dy = e.y1 - e.y0;
        const steps_f = @max(@abs(dx), @abs(dy));
        if (steps_f < 0.5) return;
        var t0: f32 = 0.0;
        var t1: f32 = 1.0;
        // Clip the parameter range to the band's rows...
        if (@abs(dy) > 1e-6) {
            var ta = (y_lo - e.y0) / dy;
            var tb = (y_hi - e.y0) / dy;
            if (ta > tb) std.mem.swap(f32, &ta, &tb);
            t0 = @max(t0, ta);
            t1 = @min(t1, tb);
        } else if (e.y0 < y_lo or e.y0 >= y_hi) return;
        // ...and to the visible columns, so off-screen spans cost nothing.
        const wf: f32 = @floatFromInt(self.w);
        if (@abs(dx) > 1e-6) {
            var ta = (0.0 - e.x0) / dx;
            var tb = (wf - e.x0) / dx;
            if (ta > tb) std.mem.swap(f32, &ta, &tb);
            t0 = @max(t0, ta);
            t1 = @min(t1, tb);
        } else if (e.x0 < 0 or e.x0 >= wf) return;
        if (t1 <= t0) return;

        const steps: u32 = @min(@as(u32, @intFromFloat(steps_f)) + 1, 4096);
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(steps));
        var i: u32 = @intFromFloat(@ceil(t0 * @as(f32, @floatFromInt(steps))));
        const i_end: u32 = @intFromFloat(@floor(t1 * @as(f32, @floatFromInt(steps))));
        while (i <= i_end) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) * inv;
            const x: i32 = @intFromFloat(e.x0 + dx * t);
            const y: i32 = @intFromFloat(e.y0 + dy * t);
            // Band + column clip already done; only the exact row edge can spill.
            if (y < @as(i32, @intFromFloat(y_lo)) or y >= @as(i32, @intFromFloat(y_hi))) continue;
            if (x < 0 or x >= @as(i32, @intCast(self.w))) continue;
            const k = e.k0 + (e.k1 - e.k0) * t;
            const o = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
            const p = self.fb[o..][0..4];
            p[0] = @intCast(@min(255, @as(u32, p[0]) + @as(u32, @intFromFloat(e.rgb[0] * k))));
            p[1] = @intCast(@min(255, @as(u32, p[1]) + @as(u32, @intFromFloat(e.rgb[1] * k))));
            p[2] = @intCast(@min(255, @as(u32, p[2]) + @as(u32, @intFromFloat(e.rgb[2] * k))));
        }
    }

    fn bandWorker(self: *Cpu, edges: []const Edge, y_lo: f32, y_hi: f32) void {
        for (edges) |*e| self.edgeInBand(e, y_lo, y_hi);
    }

    /// Rasterize the whole edge list across all cores (call once per frame,
    /// between `clear` and the discs).
    pub fn drawEdges(self: *Cpu, edges: []const Edge, threads: []std.Thread) void {
        const workers = threads.len + 1;
        const band = @as(f32, @floatFromInt(self.h)) / @as(f32, @floatFromInt(workers));
        var spawned: usize = 0;
        for (threads, 0..) |*t, i| {
            const y_lo = band * @as(f32, @floatFromInt(i));
            t.* = std.Thread.spawn(.{}, bandWorker, .{ self, edges, y_lo, y_lo + band }) catch break;
            spawned += 1;
        }
        const y_lo = band * @as(f32, @floatFromInt(spawned));
        self.bandWorker(edges, y_lo, @floatFromInt(self.h));
        for (threads[0..spawned]) |t| t.join();
    }

    /// Filled anti-aliased disc, shaded like a lit sphere.
    pub fn disc(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32, brightness: f32) void {
        const r = @max(radius, 1.0);
        const x_min: i32 = @intFromFloat(@floor(cx - r - 1));
        const x_max: i32 = @intFromFloat(@ceil(cx + r + 1));
        const y_min: i32 = @intFromFloat(@floor(cy - r - 1));
        const y_max: i32 = @intFromFloat(@ceil(cy + r + 1));
        var y = y_min;
        while (y <= y_max) : (y += 1) {
            var x = x_min;
            while (x <= x_max) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const fy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const d = @sqrt(fx * fx + fy * fy) / r;
                if (d > 1.0 + 1.5 / r) continue;
                const cover = std.math.clamp((1.0 + 1.0 / r - d) * r, 0.0, 1.0);
                // Sphere-ish shading: bright toward the upper-left rim.
                const nz = @sqrt(@max(0.0, 1.0 - d * d));
                const l = (0.42 + 0.58 * nz) * (1.0 - 0.25 * std.math.clamp((fx + fy) / r, -1, 1));
                const s = brightness * l;
                self.blendPx(x, y, .{ rgb[0] * s, rgb[1] * s, rgb[2] * s }, cover);
            }
        }
    }

    /// Additive soft glow: a radial halo with quadratic falloff, accumulating
    /// like the edge light — the software cousin of the GPU path's bloom.
    pub fn halo(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32, k: f32) void {
        const r = @max(radius, 2.0);
        const x_min: i32 = @intFromFloat(@floor(cx - r));
        const x_max: i32 = @intFromFloat(@ceil(cx + r));
        const y_min: i32 = @intFromFloat(@floor(cy - r));
        const y_max: i32 = @intFromFloat(@ceil(cy + r));
        var y = y_min;
        while (y <= y_max) : (y += 1) {
            var x = x_min;
            while (x <= x_max) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const fy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const d = @sqrt(fx * fx + fy * fy) / r;
                if (d >= 1.0) continue;
                const fall = (1.0 - d) * (1.0 - d);
                self.addPx(x, y, rgb, k * fall);
            }
        }
    }

    /// Selection ring: an unfilled anti-aliased circle.
    pub fn ring(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32) void {
        const r = @max(radius, 2.0);
        const x_min: i32 = @intFromFloat(@floor(cx - r - 2));
        const x_max: i32 = @intFromFloat(@ceil(cx + r + 2));
        const y_min: i32 = @intFromFloat(@floor(cy - r - 2));
        const y_max: i32 = @intFromFloat(@ceil(cy + r + 2));
        var y = y_min;
        while (y <= y_max) : (y += 1) {
            var x = x_min;
            while (x <= x_max) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const fy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const d = @sqrt(fx * fx + fy * fy);
                const a = std.math.clamp(1.4 - @abs(d - r), 0.0, 1.0);
                if (a > 0) self.blendPx(x, y, rgb, a);
            }
        }
    }
};
