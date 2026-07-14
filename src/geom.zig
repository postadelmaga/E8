//! Dimension-generic projection math for the presenter framework: the domain
//! fixes `dim` (8 for E8, 4 for polytopes, 3 for molecules) and everything
//! here works on `[dim]f32` vectors and 3×dim view bases.

const std = @import("std");
const domain = @import("domain.zig");

pub const dim = domain.dim;
pub const Vec = [dim]f32;

/// Three orthonormal rows u,v,w of a dim-D → 3D projection.
pub const Basis = [3]Vec;

pub fn dot(a: Vec, b: Vec) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

pub fn project(b: *const Basis, v: Vec) [3]f32 {
    return .{ dot(b[0], v), dot(b[1], v), dot(b[2], v) };
}

pub fn orthonormalize(b: *Basis) void {
    for (0..3) |i| {
        for (0..i) |j| {
            const d = dot(b[i], b[j]);
            for (0..dim) |k| b[i][k] -= d * b[j][k];
        }
        const l = @max(@sqrt(dot(b[i], b[i])), 1e-12);
        for (0..dim) |k| b[i][k] /= l;
    }
}

/// Rotate the view basis within the coordinate plane (a,c) by `th` radians —
/// mixes hidden dimensions into the visible three.
pub fn rotateBasis(b: *Basis, a: usize, c: usize, th: f32) void {
    const co = @cos(th);
    const si = @sin(th);
    for (b) |*row| {
        const xa = row[a];
        const xc = row[c];
        row[a] = co * xa - si * xc;
        row[c] = si * xa + co * xc;
    }
}

/// The coordinate planes the ←/→ rotation walks through (Tab cycles):
/// offset pairs first (they mix hidden dimensions in fastest), then adjacent.
pub const planes = blk: {
    const half = @max(dim / 2, 1);
    var out: [dim][2]usize = undefined;
    var n: usize = 0;
    for (0..half) |i| {
        if (i + half < dim) {
            out[n] = .{ i, i + half };
            n += 1;
        }
    }
    var i: usize = 0;
    while (i + 1 < dim and n < out.len) : (i += 2) {
        out[n] = .{ i, i + 1 };
        n += 1;
    }
    const frozen = out[0..n].*;
    break :blk frozen;
};

/// Plain first-three-coordinates view — every domain's fallback preset.
pub fn coordBasis(_: f32) Basis {
    var b: Basis = @splat(@splat(0));
    // One axis per row while the dimensions last. A dim < 3 domain leaves the
    // spare screen axes ZERO (stable through orthonormalize: 0/eps = 0) — a
    // duplicated row would be Gram-Schmidt-collapsed into noise instead.
    for (0..@min(dim, 3)) |i| b[i][i] = 1;
    return b;
}
