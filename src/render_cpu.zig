//! Software renderer for the E8 figure — additive luminous edges + shaded discs,
//! presented as an RGBA frame through `Window.presentRgba`. This is the path that
//! always works (no Vulkan, no dmabuf), in the spirit of the classic 2D E8 plots:
//! points on top, light accumulating where edge bundles cross.
//!
//! Both heavy passes render on all cores: the frame is split into horizontal
//! bands, every worker walks the full job list but touches only the rows of its
//! own band — no per-worker buffers to merge, no write races, work split ~evenly.
//! Painter's order survives the split because each worker walks the same sorted
//! list: within a band the draw order is the serial order, and bands are disjoint
//! pixels. The workers are spawned ONCE (`startPool`) and parked on a condition
//! variable between jobs — spawning threads per frame cost more than the raster.

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

/// One point of the back-to-front pass: an optional additive halo, the shaded
/// disc, an optional ring — drawn in that order, like the serial path always did.
pub const Dot = struct {
    x: f32,
    y: f32,
    rad: f32,
    rgb: [3]f32,
    bright: f32,
    halo_r: f32 = 0, // 0 = no halo
    halo_rgb: [3]f32 = .{ 0, 0, 0 },
    halo_k: f32 = 0,
    ring_r: f32 = 0, // 0 = no ring
    ring_rgb: [3]f32 = .{ 0, 0, 0 },
};

const Job = union(enum) {
    edges: []const Edge,
    dots: []const Dot,
};

pub const Cpu = struct {
    gpa: std.mem.Allocator,
    fb: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,

    // The persistent band workers (empty = serial, the inspector's mini-scene).
    // The sync primitives are std.Io's (0.16 moved them there) — `io` is only
    // consulted while a pool exists.
    io: ?std.Io = null,
    threads: []std.Thread = &.{},
    mutex: std.Io.Mutex = .init,
    work_cv: std.Io.Condition = .init,
    done_cv: std.Io.Condition = .init,
    job: Job = .{ .edges = &.{} },
    gen: u64 = 0,
    pending: usize = 0,
    quit: bool = false,

    pub fn deinit(self: *Cpu) void {
        if (self.threads.len > 0) {
            const io = self.io.?;
            self.mutex.lockUncancelable(io);
            self.quit = true;
            self.mutex.unlock(io);
            self.work_cv.broadcast(io);
            for (self.threads) |t| t.join();
            self.gpa.free(self.threads);
            self.threads = &.{};
        }
        if (self.fb.len > 0) self.gpa.free(self.fb);
    }

    /// Spawn `n` parked band workers (the caller keeps one band for itself, so
    /// pass cores − 1). Without a pool every draw call runs serial.
    pub fn startPool(self: *Cpu, io: std.Io, n: usize) !void {
        if (n == 0 or self.threads.len > 0) return;
        self.io = io;
        self.threads = try self.gpa.alloc(std.Thread, n);
        for (self.threads, 0..) |*t, i| {
            t.* = std.Thread.spawn(.{}, poolWorker, .{ self, i }) catch {
                // Roll back: a partial pool would mis-split the bands (workers
                // size theirs off `threads.len`). Serial is always correct.
                self.mutex.lockUncancelable(io);
                self.quit = true;
                self.mutex.unlock(io);
                self.work_cv.broadcast(io);
                for (self.threads[0..i]) |st| st.join();
                self.gpa.free(self.threads);
                self.threads = &.{};
                self.quit = false;
                return;
            };
        }
    }

    fn poolWorker(self: *Cpu, idx: usize) void {
        const io = self.io.?;
        var seen: u64 = 0;
        self.mutex.lockUncancelable(io);
        while (true) {
            while (!self.quit and self.gen == seen) self.work_cv.waitUncancelable(io, &self.mutex);
            if (self.quit) break;
            seen = self.gen;
            const job = self.job;
            self.mutex.unlock(io);
            self.runBand(job, idx, self.threads.len + 1);
            self.mutex.lockUncancelable(io);
            self.pending -= 1;
            if (self.pending == 0) self.done_cv.signal(io);
        }
        self.mutex.unlock(io);
    }

    /// Run one job across the pool (the calling thread takes the last band) and
    /// wait for every band to finish.
    fn runJob(self: *Cpu, job: Job) void {
        const n = self.threads.len;
        if (n == 0) return self.runBand(job, 0, 1);
        const io = self.io.?;
        self.mutex.lockUncancelable(io);
        self.job = job;
        self.gen +%= 1;
        self.pending = n;
        self.mutex.unlock(io);
        self.work_cv.broadcast(io);
        self.runBand(job, n, n + 1);
        self.mutex.lockUncancelable(io);
        while (self.pending != 0) self.done_cv.waitUncancelable(io, &self.mutex);
        self.mutex.unlock(io);
    }

    fn runBand(self: *Cpu, job: Job, idx: usize, total: usize) void {
        // Integer row split: exact partition, no row painted twice.
        const row_lo: i32 = @intCast(idx * self.h / total);
        const row_hi: i32 = @intCast((idx + 1) * self.h / total);
        switch (job) {
            .edges => |es| for (es) |*e| self.edgeInBand(e, row_lo, row_hi),
            .dots => |ds| for (ds) |*d| {
                if (d.halo_r > 0) self.haloBand(d.x, d.y, d.halo_r, d.halo_rgb, d.halo_k, row_lo, row_hi);
                self.discBand(d.x, d.y, d.rad, d.rgb, d.bright, row_lo, row_hi);
                if (d.ring_r > 0) self.ringBand(d.x, d.y, d.ring_r, d.ring_rgb, row_lo, row_hi);
            },
        }
    }

    /// (Re)size the framebuffer to the requested resolution.
    pub fn ensure(self: *Cpu, w: u32, h: u32) !void {
        if (self.w == w and self.h == h and self.fb.len > 0) return;
        if (self.fb.len > 0) self.gpa.free(self.fb);
        self.fb = try self.gpa.alloc(u8, @as(usize, w) * h * 4);
        self.w = w;
        self.h = h;
    }

    /// Black, fully opaque. The old deep-space gradient was a pretty blue, and it
    /// cost contrast on every dark particle in the scene: on black nothing competes
    /// with the points.
    pub fn clear(self: *Cpu) void {
        // One u32 store per pixel: RGBA bytes {0,0,0,255} little-endian.
        const px = std.mem.bytesAsSlice(u32, self.fb);
        @memset(px, 0xFF00_0000);
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

    /// Draw the parametric slice of one edge that falls in rows [row_lo, row_hi).
    fn edgeInBand(self: *Cpu, e: *const Edge, row_lo: i32, row_hi: i32) void {
        const y_lo: f32 = @floatFromInt(row_lo);
        const y_hi: f32 = @floatFromInt(row_hi);
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
            if (y < row_lo or y >= row_hi) continue;
            if (x < 0 or x >= @as(i32, @intCast(self.w))) continue;
            const k = e.k0 + (e.k1 - e.k0) * t;
            const o = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
            const p = self.fb[o..][0..4];
            p[0] = @intCast(@min(255, @as(u32, p[0]) + @as(u32, @intFromFloat(e.rgb[0] * k))));
            p[1] = @intCast(@min(255, @as(u32, p[1]) + @as(u32, @intFromFloat(e.rgb[1] * k))));
            p[2] = @intCast(@min(255, @as(u32, p[2]) + @as(u32, @intFromFloat(e.rgb[2] * k))));
        }
    }

    /// Rasterize the whole edge list across the pool (call once per frame,
    /// between `clear` and the dots).
    pub fn drawEdges(self: *Cpu, edges: []const Edge) void {
        self.runJob(.{ .edges = edges });
    }

    /// Rasterize the point pass — halos, discs, rings — across the pool. The
    /// caller passes the dots in painter's (back-to-front) order.
    pub fn drawDots(self: *Cpu, dots: []const Dot) void {
        self.runJob(.{ .dots = dots });
    }

    /// Filled anti-aliased disc, shaded like a lit sphere.
    pub fn disc(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32, brightness: f32) void {
        self.discBand(cx, cy, radius, rgb, brightness, 0, @intCast(self.h));
    }

    fn discBand(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32, brightness: f32, row_lo: i32, row_hi: i32) void {
        const r = @max(radius, 1.0);
        const x_min: i32 = @intFromFloat(@floor(cx - r - 1));
        const x_max: i32 = @intFromFloat(@ceil(cx + r + 1));
        const y_min: i32 = @max(@as(i32, @intFromFloat(@floor(cy - r - 1))), row_lo);
        const y_max: i32 = @min(@as(i32, @intFromFloat(@ceil(cy + r + 1))), row_hi - 1);
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
        self.haloBand(cx, cy, radius, rgb, k, 0, @intCast(self.h));
    }

    fn haloBand(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32, k: f32, row_lo: i32, row_hi: i32) void {
        const r = @max(radius, 2.0);
        const x_min: i32 = @intFromFloat(@floor(cx - r));
        const x_max: i32 = @intFromFloat(@ceil(cx + r));
        const y_min: i32 = @max(@as(i32, @intFromFloat(@floor(cy - r))), row_lo);
        const y_max: i32 = @min(@as(i32, @intFromFloat(@ceil(cy + r))), row_hi - 1);
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
        self.ringBand(cx, cy, radius, rgb, 0, @intCast(self.h));
    }

    fn ringBand(self: *Cpu, cx: f32, cy: f32, radius: f32, rgb: [3]f32, row_lo: i32, row_hi: i32) void {
        const r = @max(radius, 2.0);
        const x_min: i32 = @intFromFloat(@floor(cx - r - 2));
        const x_max: i32 = @intFromFloat(@ceil(cx + r + 2));
        const y_min: i32 = @max(@as(i32, @intFromFloat(@floor(cy - r - 2))), row_lo);
        const y_max: i32 = @min(@as(i32, @intFromFloat(@ceil(cy + r + 2))), row_hi - 1);
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
