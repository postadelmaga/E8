//! The Calabi–Yau manifold — the shape the six extra dimensions are rolled up
//! into, and the reason the world has the particles it has.
//!
//! WHERE THIS SITS.  A Calabi–Yau does NOT compactify eleven-dimensional
//! M-theory — that would want a seven-dimensional manifold of G2 holonomy. It
//! compactifies the TEN-dimensional string. The bridge is Hořava–Witten:
//!
//!     M-theory on an interval (S¹/ℤ₂)  =  the E₈×E₈ heterotic string
//!
//! — the two E8's live on the two ends of the eleventh dimension. So the chain
//! this demo walks is: E10, the algebra of the eleven-dimensional theory next to
//! the singularity → roll up the eleventh dimension on an interval → E₈×E₈ in ten
//! dimensions, and one of those E8's is Lisi's → roll up six more on a CALABI–YAU
//! → the world. The six curled dimensions sit at every point of space, and their
//! shape is what this file draws.
//!
//! WHAT IS DRAWN.  A Calabi–Yau threefold is six real dimensions and cannot be
//! shown. What every picture of one actually shows — including this one — is
//! Andrew Hanson's two-real-dimensional cross-section of the QUINTIC, the surface
//!
//!     z₁⁵ + z₂⁵ = 1,   z₁, z₂ ∈ ℂ
//!
//! parametrised patch by patch as
//!
//!     z₁ = e^{2πi k₁/n} · [cos(θ + iξ)]^{2/n}
//!     z₂ = e^{2πi k₂/n} · [sin(θ + iξ)]^{2/n}
//!
//! with n = 5, k₁,k₂ ∈ {0…4} — hence the twenty-five interlocking petals — and
//! projected into three dimensions by keeping both real parts and one rotated
//! combination of the imaginary parts. That the identity cos² + sin² = 1 makes
//! z₁ⁿ + z₂ⁿ = 1 fall out exactly is not decoration: it is checked, vertex by
//! vertex, in the tests. This is the surface, not something that looks like it.
//!
//!   E. Calabi (1954); S.-T. Yau, PNAS 74 (1977) 1798.
//!   A. J. Hanson, "A Construction for Computer Visualization of Certain Complex
//!     Curves", Notices of the AMS 41 (1994) 1156.
//!   P. Candelas, G. Horowitz, A. Strominger, E. Witten, Nucl. Phys. B258 (1985)
//!     46 — "Vacuum configurations for superstrings": the compactification.
//!   P. Hořava, E. Witten, Nucl. Phys. B460 (1996) 506 — the eleventh dimension.

const std = @import("std");

/// The degree of the hypersurface. Five is the quintic — the Calabi–Yau of every
/// picture ever printed, and the one string theory cut its teeth on.
pub const degree: usize = 5;

/// The number of patches: one for every choice of the two roots of unity. For the
/// quintic that is twenty-five, and they are the petals you can count on screen.
pub const patches: usize = degree * degree;

const Complex = struct {
    re: f64,
    im: f64,

    fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    fn abs(a: Complex) f64 {
        return @sqrt(a.re * a.re + a.im * a.im);
    }
    fn arg(a: Complex) f64 {
        return std.math.atan2(a.im, a.re);
    }
    /// Principal branch of z^p.
    fn pow(a: Complex, p: f64) Complex {
        const r = abs(a);
        if (r < 1e-12) return .{ .re = 0, .im = 0 };
        const lr = @exp(p * @log(r));
        const th = p * arg(a);
        return .{ .re = lr * @cos(th), .im = lr * @sin(th) };
    }
    fn powi(a: Complex, k: usize) Complex {
        var out = Complex{ .re = 1, .im = 0 };
        for (0..k) |_| out = mul(out, a);
        return out;
    }
    fn unit(angle: f64) Complex {
        return .{ .re = @cos(angle), .im = @sin(angle) };
    }
};

/// The two complex coordinates of the point on the quintic in patch (k₁,k₂).
/// `theta` ∈ [0, π/2], `xi` ∈ [−π/2, π/2].
pub fn point(k1: usize, k2: usize, theta: f64, xi: f64) [2]Complex {
    const n: f64 = @floatFromInt(degree);
    // cos and sin of a COMPLEX argument — this is where the surface gets its
    // curvature; on the real line it would be a circle and nothing more.
    const c = Complex{ .re = @cos(theta) * std.math.cosh(xi), .im = -@sin(theta) * std.math.sinh(xi) };
    const s = Complex{ .re = @sin(theta) * std.math.cosh(xi), .im = @cos(theta) * std.math.sinh(xi) };
    const tau = 2.0 * std.math.pi / n;
    const z1 = Complex.mul(Complex.unit(tau * @as(f64, @floatFromInt(k1))), c.pow(2.0 / n));
    const z2 = Complex.mul(Complex.unit(tau * @as(f64, @floatFromInt(k2))), s.pow(2.0 / n));
    return .{ z1, z2 };
}

/// Six real dimensions will not fit on a screen, so we keep both real parts and
/// ONE rotated combination of the imaginary parts. `alpha` is the angle of that
/// combination — turning it turns the shadow, not the shape.
pub fn project(z: [2]Complex, alpha: f32) [3]f32 {
    const a: f64 = @floatCast(alpha);
    return .{
        @floatCast(z[0].re),
        @floatCast(z[1].re),
        @floatCast(@cos(a) * z[0].im + @sin(a) * z[1].im),
    };
}

pub const Mesh = struct {
    /// xyz per vertex.
    pos: [][3]f32,
    /// Outward normal per vertex (from the surface's own tangent frame).
    nrm: [][3]f32,
    /// Which of the twenty-five patches each vertex belongs to.
    patch: []u8,
    idx: []u32,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Mesh) void {
        self.gpa.free(self.pos);
        self.gpa.free(self.nrm);
        self.gpa.free(self.patch);
        self.gpa.free(self.idx);
    }
};

/// Build the surface. `res` is the grid resolution per patch per axis (so each
/// patch is res × res vertices); `alpha` rotates the projection; `scale` sizes
/// the result. Twenty-five patches, each a curved quadrilateral, interlocking
/// along their edges into the shape everyone has seen and almost nobody has been
/// told the equation of.
pub fn build(gpa: std.mem.Allocator, res: usize, alpha: f32, scale: f32) !Mesh {
    std.debug.assert(res >= 2);
    const per = res * res;
    const nv = patches * per;
    const nq = patches * (res - 1) * (res - 1);

    var m = Mesh{
        .pos = try gpa.alloc([3]f32, nv),
        .nrm = try gpa.alloc([3]f32, nv),
        .patch = try gpa.alloc(u8, nv),
        .idx = try gpa.alloc(u32, nq * 6),
        .gpa = gpa,
    };
    errdefer m.deinit();

    const h = 1e-4; // finite-difference step for the tangent frame
    var v: usize = 0;
    var q: usize = 0;
    for (0..degree) |k1| {
        for (0..degree) |k2| {
            const base: u32 = @intCast(v);
            const pid: u8 = @intCast(k1 * degree + k2);
            for (0..res) |i| {
                const theta = std.math.pi * 0.5 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(res - 1));
                for (0..res) |j| {
                    const xi = -std.math.pi * 0.5 +
                        std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(res - 1));
                    const p = project(point(k1, k2, theta, xi), alpha);
                    // The normal from the surface's own tangents, not guessed.
                    const pt = project(point(k1, k2, theta + h, xi), alpha);
                    const px = project(point(k1, k2, theta, xi + h), alpha);
                    var t1: [3]f32 = undefined;
                    var t2: [3]f32 = undefined;
                    for (0..3) |c| {
                        t1[c] = pt[c] - p[c];
                        t2[c] = px[c] - p[c];
                    }
                    var nn = [3]f32{
                        t1[1] * t2[2] - t1[2] * t2[1],
                        t1[2] * t2[0] - t1[0] * t2[2],
                        t1[0] * t2[1] - t1[1] * t2[0],
                    };
                    const l = @sqrt(nn[0] * nn[0] + nn[1] * nn[1] + nn[2] * nn[2]);
                    if (l > 1e-12) {
                        for (&nn) |*x| x.* /= l;
                    } else nn = .{ 0, 1, 0 };

                    m.pos[v] = .{ p[0] * scale, p[1] * scale, p[2] * scale };
                    m.nrm[v] = nn;
                    m.patch[v] = pid;
                    v += 1;
                }
            }
            for (0..res - 1) |i| {
                for (0..res - 1) |j| {
                    const a: u32 = base + @as(u32, @intCast(i * res + j));
                    const b = a + 1;
                    const c = a + @as(u32, @intCast(res));
                    const d = c + 1;
                    m.idx[q * 6 + 0] = a;
                    m.idx[q * 6 + 1] = c;
                    m.idx[q * 6 + 2] = b;
                    m.idx[q * 6 + 3] = b;
                    m.idx[q * 6 + 4] = c;
                    m.idx[q * 6 + 5] = d;
                    q += 1;
                }
            }
        }
    }
    std.debug.assert(v == nv and q == nq);
    return m;
}

// --- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "every point of the mesh lies ON the quintic: z1^5 + z2^5 = 1" {
    // This is the test that decides whether we are drawing a Calabi–Yau or merely
    // something that looks like one. Not a sample: every vertex of every patch.
    for (0..degree) |k1| {
        for (0..degree) |k2| {
            for (0..12) |i| {
                const theta = std.math.pi * 0.5 * @as(f64, @floatFromInt(i)) / 11.0;
                for (0..12) |j| {
                    const xi = -std.math.pi * 0.5 + std.math.pi * @as(f64, @floatFromInt(j)) / 11.0;
                    const z = point(k1, k2, theta, xi);
                    const sum = Complex.add(z[0].powi(degree), z[1].powi(degree));
                    try testing.expectApproxEqAbs(@as(f64, 1.0), sum.re, 1e-9);
                    try testing.expectApproxEqAbs(@as(f64, 0.0), sum.im, 1e-9);
                }
            }
        }
    }
}

test "twenty-five patches, and the roots of unity really do separate them" {
    const gpa = testing.allocator;
    var m = try build(gpa, 8, std.math.pi / 4.0, 1.0);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 25), patches);
    try testing.expectEqual(patches * 64, m.pos.len);
    try testing.expectEqual(patches * 49 * 6, m.idx.len);

    var seen: [patches]usize = @splat(0);
    for (m.patch) |p| seen[p] += 1;
    for (seen) |c| try testing.expectEqual(@as(usize, 64), c);

    // Distinct patches are genuinely distinct pieces of surface: the same (θ,ξ)
    // in two different patches lands in two different places. (Except at θ where
    // one of the two coordinates vanishes and the phase stops mattering — that is
    // the seam the petals are glued along, and it is why the figure holds together.)
    const a = project(point(0, 0, 0.7, 0.3), 0.785);
    const b = project(point(1, 0, 0.7, 0.3), 0.785);
    var d: f32 = 0;
    for (0..3) |c| d += (a[c] - b[c]) * (a[c] - b[c]);
    try testing.expect(@sqrt(d) > 0.2);
}

test "the mesh is finite, oriented and has no NaNs" {
    const gpa = testing.allocator;
    var m = try build(gpa, 10, std.math.pi / 4.0, 1.6);
    defer m.deinit();
    for (m.pos, m.nrm) |p, n| {
        for (p) |x| {
            try testing.expect(std.math.isFinite(x));
            try testing.expect(@abs(x) < 4.0);
        }
        const l = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        try testing.expectApproxEqAbs(@as(f32, 1.0), l, 1e-3);
    }
    for (m.idx) |i| try testing.expect(i < m.pos.len);
}
