//! The E8 root system, exactly — plus the physics bookkeeping of Garrett Lisi's
//! "An Exceptionally Simple Theory of Everything" (arXiv:0711.0770, Table 9)
//! and its triality extension "C, P, T, and Triality" (arXiv:2407.02497).
//!
//! The 240 roots of E8 in the even-coordinate lattice convention:
//!   * 112 integer roots  ±eᵢ±eⱼ (i<j)          — the adjoint of so(16) ⊃ D8
//!   * 128 spinor roots   (±½,…,±½), even # of − — the 16⁺ chiral spinor of so(16)
//!
//! Lisi's assignment rests on the chain  so(8)⊕so(8) ⊂ so(16) ⊂ E8: the FIRST
//! so(8) (coords 1..4) is the graviweak so(7,1) (spacetime spin + electroweak +
//! frame-Higgs), the SECOND so(8) (coords 5..8) contains su(3) color acting on
//! coords 6,7,8, with coord 5 Lisi's generation-related w u(1) and B−L read off
//! the trace ⅔(x6+x7+x8). The split is exact Lie theory; the particle *names*
//! follow Lisi's Table 9 and are labels, not derivations:
//!
//!   integer, i,j ∈ 1..2            →  4  gravity ω (so(3,1) spin connection)
//!   integer, i,j ∈ 3..4            →  4  electroweak W±, B1±
//!   integer, one of 1..2 + 3..4    → 16  frame-Higgs eφ ∈ 4×(2+2̄)
//!   integer, both in 5..8          → 24  color: 6 gluons ±(eᵢ−eⱼ) i,j∈6..8
//!                                        + 18 colored xΦ ∈ 3×(3+3̄) "X" bosons
//!   integer, one index each side   → 64  (8v,8v') = GENERATION III (ντ τ t b)
//!   spinor, even # of − in 1..4    → 64  (8s+,8s+') = generation I  (νe e u d)
//!   spinor, odd  # of − in 1..4    → 64  (8s−,8s−') = generation II (νμ μ c s)
//!
//! Within each 64-fermion generation the su(3) weight decides lepton (singlet)
//! vs quark (3/3̄) — generation II/III weights are physical only via the triality
//! rotation T (arXiv:0711.0770 §2.4.2), provided here in lattice coordinates:
//! T cycles I → II → III, leaves W³ and color invariant, and groups the 192
//! fermion roots into the 8 disjoint 24-cells of the 2024 CPTt paper.
//!
//! Everything here is exact in f32 (all coordinates are multiples of ½, all
//! inner products multiples of ¼), so equality tests on dot products are safe.

const std = @import("std");

pub const n_roots = 240;
pub const n_edges = 6720; // pairs at 60° (dot = 1): 240·56/2

pub const Class = enum(u8) {
    gravity,
    electroweak,
    frame_higgs,
    gluon,
    color_x,
    lepton,
    quark,

    pub fn name(c: Class) []const u8 {
        return switch (c) {
            .gravity => "gravity ω",
            .electroweak => "electroweak W/B",
            .frame_higgs => "frame-Higgs eφ",
            .gluon => "gluon",
            .color_x => "colored xΦ boson",
            .lepton => "lepton",
            .quark => "quark",
        };
    }
};

/// Fermion generation: 0 for bosons, 1..3 per Lisi's triality-related blocks
/// (I = 8s+⊗8s+', II = 8s−⊗8s−', III = 8v⊗8v').
pub fn genName(g: u8) []const u8 {
    return switch (g) {
        1 => "gen I",
        2 => "gen II",
        3 => "gen III",
        else => "boson",
    };
}

/// State under su(3) color, read off the (λ3, λ8) weight.
pub const ColorState = enum(u8) {
    singlet,
    red,
    green,
    blue,
    anti_red,
    anti_green,
    anti_blue,
    adjoint, // gluon-type octet weight

    pub fn name(cs: ColorState) []const u8 {
        return switch (cs) {
            .singlet => "singlet",
            .red => "r",
            .green => "g",
            .blue => "b",
            .anti_red => "r̄",
            .anti_green => "ḡ",
            .anti_blue => "b̄",
            .adjoint => "octet",
        };
    }
};

pub const Root = struct {
    v: [8]f32,
    class: Class,
    /// 0 = boson · 1..3 = fermion generation (Lisi's triality blocks).
    gen: u8,
    /// su(3) color weight (λ3, λ8 axes), from coords 6,7,8.
    t3: f32,
    t8: f32,
    /// Lisi's w u(1) charge (coordinate 5) and B−L = ⅔(x6+x7+x8).
    w: f32,
    bl: f32,
    color: ColorState,
    /// True for the 112 integer (so(16) adjoint) roots.
    integer: bool,
};

// --- generation --------------------------------------------------------------------

fn classify(v: [8]f32, integer: bool) Root {
    const t3 = (v[5] - v[6]) / 2.0;
    const t8 = (v[5] + v[6] - 2.0 * v[7]) / (2.0 * @sqrt(3.0));
    const w3: f32 = 0.5;
    const w8: f32 = 1.0 / (2.0 * @sqrt(3.0));
    const eps: f32 = 1e-4;
    const cs: ColorState = blk: {
        if (@abs(t3) < eps and @abs(t8) < eps) break :blk .singlet;
        const fund = [3][2]f32{ .{ w3, w8 }, .{ -w3, w8 }, .{ 0, -2.0 * w8 } };
        for (fund, 0..) |f, i| {
            if (@abs(t3 - f[0]) < eps and @abs(t8 - f[1]) < eps)
                break :blk @enumFromInt(@intFromEnum(ColorState.red) + i);
            if (@abs(t3 + f[0]) < eps and @abs(t8 + f[1]) < eps)
                break :blk @enumFromInt(@intFromEnum(ColorState.anti_red) + i);
        }
        break :blk .adjoint;
    };

    var class: Class = undefined;
    var gen: u8 = 0;
    if (integer) {
        var i: usize = 8;
        var j: usize = 8;
        for (v, 0..) |x, k| {
            if (x != 0) {
                if (i == 8) i = k else j = k;
            }
        }
        if (j < 4) {
            // Graviweak so(7,1), split per Lisi Table 9: ω on coords 1,2 ·
            // W±/B1± on coords 3,4 · frame-Higgs eφ across the two pairs.
            class = if (j <= 1) .gravity else if (i >= 2) .electroweak else .frame_higgs;
        } else if (i >= 4) {
            // Color so(8) block: gluons are ±(eᵢ−eⱼ) inside the su(3) coords 6,7,8.
            class = if (i >= 5 and v[i] * v[j] == -1.0) .gluon else .color_x;
        } else {
            // One index graviweak, one color: the (8v,8v') block — Lisi's THIRD
            // generation (ντ τ t b), triality partner of the two spinor blocks.
            gen = 3;
            class = if (cs == .singlet) .lepton else .quark;
        }
    } else {
        // so(16) spinor 128 = (8s+,8s+') ⊕ (8s−,8s−'): generations I and II,
        // split by the minus-sign parity of the graviweak (first four) half.
        var neg: u8 = 0;
        for (v[0..4]) |x| neg += @intFromBool(x < 0);
        gen = if (neg % 2 == 0) 1 else 2;
        class = if (cs == .singlet) .lepton else .quark;
    }
    return .{
        .v = v,
        .class = class,
        .gen = gen,
        .t3 = t3,
        .t8 = t8,
        .w = v[4],
        .bl = 2.0 / 3.0 * (v[5] + v[6] + v[7]),
        .color = cs,
        .integer = integer,
    };
}

/// All 240 roots, deterministically ordered: 112 integer then 128 spinor.
pub fn generate() [n_roots]Root {
    var roots: [n_roots]Root = undefined;
    var n: usize = 0;
    // Integer roots ±eᵢ±eⱼ.
    for (0..8) |i| {
        for (i + 1..8) |j| {
            for ([2]f32{ 1, -1 }) |si| {
                for ([2]f32{ 1, -1 }) |sj| {
                    var v = [_]f32{0} ** 8;
                    v[i] = si;
                    v[j] = sj;
                    roots[n] = classify(v, true);
                    n += 1;
                }
            }
        }
    }
    // Spinor roots (±½)⁸ with an even number of minus signs.
    var bits: u32 = 0;
    while (bits < 256) : (bits += 1) {
        if (@popCount(bits) % 2 != 0) continue;
        var v: [8]f32 = undefined;
        for (0..8) |k| {
            v[k] = if (bits >> @intCast(k) & 1 == 1) -0.5 else 0.5;
        }
        roots[n] = classify(v, false);
        n += 1;
    }
    std.debug.assert(n == n_roots);
    return roots;
}

pub fn dot8(a: [8]f32, b: [8]f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// The 6720 nearest-neighbor pairs (angle 60°, inner product exactly 1).
pub fn buildEdges(gpa: std.mem.Allocator, roots: []const Root) ![]const [2]u16 {
    var edges = try std.ArrayList([2]u16).initCapacity(gpa, n_edges);
    errdefer edges.deinit(gpa);
    for (0..roots.len) |i| {
        for (i + 1..roots.len) |j| {
            if (dot8(roots[i].v, roots[j].v) == 1.0)
                try edges.append(gpa, .{ @intCast(i), @intCast(j) });
        }
    }
    return edges.toOwnedSlice(gpa);
}

// --- triality ------------------------------------------------------------------------

/// Lisi's triality rotation T (arXiv:0711.0770 §2.4.2) transported to lattice
/// coordinates: T = Rᵀ·T_paper·R, where R rotates the lattice basis into the
/// paper's Cartan axes {½ωL³, ½ωR³, W³, B1³, w, B2, g³, g⁸} (p. 18). Orthogonal,
/// order 3, maps roots to roots; cycles the fermion generations I → II → III,
/// leaves W³ and su(3) color invariant (W±, 4 eφ, and the 6 gluons are fixed).
/// This is the t that extends CPT to the CPTt Group of arXiv:2407.02497.
pub fn trialityMatrix() [8][8]f32 {
    const s2 = 1.0 / @sqrt(2.0);
    const s3 = 1.0 / @sqrt(3.0);
    const s6 = 1.0 / @sqrt(6.0);
    // Rows = Lisi's Cartan axes in lattice coordinates.
    const r = [8][8]f32{
        .{ s2, s2, 0, 0, 0, 0, 0, 0 },
        .{ -s2, s2, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, s2, s2, 0, 0, 0, 0 },
        .{ 0, 0, -s2, s2, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 1, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, -s3, -s3, -s3 },
        .{ 0, 0, 0, 0, 0, -s2, s2, 0 },
        .{ 0, 0, 0, 0, 0, -s6, -s6, 2.0 * s6 },
    };
    // T in the paper frame: the 3-cycle ½ωL³ → ½ωR³ → B1³ (W³ fixed), a 2π/3
    // rotation of the (w, B2) plane, and the gluon axes g³, g⁸ fixed.
    var t: [8][8]f32 = @splat(@splat(0));
    t[0][3] = 1;
    t[1][0] = 1;
    t[2][2] = 1;
    t[3][1] = 1;
    t[4][4] = -0.5;
    t[4][5] = -0.5 * @sqrt(3.0);
    t[5][4] = 0.5 * @sqrt(3.0);
    t[5][5] = -0.5;
    t[6][6] = 1;
    t[7][7] = 1;
    var tr: [8][8]f32 = undefined; // T_paper · R
    for (0..8) |i| {
        for (0..8) |j| {
            var s: f32 = 0;
            for (0..8) |k| s += t[i][k] * r[k][j];
            tr[i][j] = s;
        }
    }
    var out: [8][8]f32 = undefined; // Rᵀ · (T_paper · R)
    for (0..8) |i| {
        for (0..8) |j| {
            var s: f32 = 0;
            for (0..8) |k| s += r[k][i] * tr[k][j];
            out[i][j] = s;
        }
    }
    return out;
}

pub fn trialityApply(t: *const [8][8]f32, v: [8]f32) [8]f32 {
    var out = [_]f32{0} ** 8;
    for (0..8) |i| {
        for (0..8) |j| out[i] += t[i][j] * v[j];
    }
    return out;
}

/// For each root, the index of its triality partner (T maps roots to roots).
pub fn buildTriality(roots: []const Root) [n_roots]u16 {
    const t = trialityMatrix();
    var map: [n_roots]u16 = undefined;
    for (roots, 0..) |*r, i| {
        const tv = trialityApply(&t, r.v);
        var found: u16 = n_roots;
        for (roots, 0..) |*s, j| {
            var d: f32 = 0;
            for (s.v, tv) |a, b| d += (a - b) * (a - b);
            if (d < 1e-4) {
                found = @intCast(j);
                break;
            }
        }
        std.debug.assert(found < n_roots);
        map[i] = found;
    }
    return map;
}

// --- projections ---------------------------------------------------------------------

/// Three orthonormal rows u,v,w of an 8D→3D projection.
pub const Basis = [3][8]f32;

pub fn project(b: *const Basis, v: [8]f32) [3]f32 {
    return .{ dot8(b[0], v), dot8(b[1], v), dot8(b[2], v) };
}

pub fn orthonormalize(b: *Basis) void {
    for (0..3) |i| {
        for (0..i) |j| {
            const d = dot8(b[i], b[j]);
            for (0..8) |k| b[i][k] -= d * b[j][k];
        }
        const l = @max(@sqrt(dot8(b[i], b[i])), 1e-12);
        for (0..8) |k| b[i][k] /= l;
    }
}

/// Rotate the view basis within the 8D coordinate plane (a,c) by `th` radians —
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

/// Bourbaki simple roots of E8 (rows), all of norm² 2.
pub const simple_roots = [8][8]f32{
    .{ 0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, 0.5 },
    .{ 1, 1, 0, 0, 0, 0, 0, 0 },
    .{ -1, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, -1, 1, 0, 0, 0, 0, 0 },
    .{ 0, 0, -1, 1, 0, 0, 0, 0 },
    .{ 0, 0, 0, -1, 1, 0, 0, 0 },
    .{ 0, 0, 0, 0, -1, 1, 0, 0 },
    .{ 0, 0, 0, 0, 0, -1, 1, 0 },
};

const Mat8 = [8][8]f32; // column-major: m[c] is column c

fn matIdentity() Mat8 {
    var m: Mat8 = @splat(@splat(0));
    for (0..8) |i| m[i][i] = 1;
    return m;
}

fn matApplyReflection(m: *Mat8, alpha: [8]f32) void {
    // S_α x = x − (x·α) α   (α² = 2), applied to every column.
    for (m) |*col| {
        const d = dot8(col.*, alpha);
        for (0..8) |k| col[k] -= d * alpha[k];
    }
}

fn matVec(m: *const Mat8, v: [8]f32) [8]f32 {
    var r = [_]f32{0} ** 8;
    for (0..8) |c| {
        for (0..8) |r_i| r[r_i] += m[c][r_i] * v[c];
    }
    return r;
}

/// A Coxeter element of E8: the product of the 8 simple reflections. Order 30.
pub fn coxeterElement() Mat8 {
    var m = matIdentity();
    for (simple_roots) |alpha| matApplyReflection(&m, alpha);
    return m;
}

/// The Coxeter (Petrie) plane of E8 — the eigenplane of the Coxeter element with
/// rotation angle 2π/30, on which the 240 roots project to the iconic 30-fold
/// symmetric figure — plus a third orthonormal axis from the next eigenplane
/// (rotation angle 2π·7/30), so the 3D view keeps the 30-gon in the xy plane.
///
/// Found by orthogonal iteration on the symmetric matrix C + Cᵀ (+2I shift):
/// its dominant 2D eigenspace (eigenvalue 2cos(2π/30)) IS the Coxeter plane.
pub fn coxeterBasis() Basis {
    const c = coxeterElement();
    // A = C + Cᵀ + 2I, symmetric, dominant eigenvalue 2 + 2cos(12°).
    var a: Mat8 = undefined;
    for (0..8) |col| {
        for (0..8) |row| a[col][row] = c[col][row] + c[row][col];
        a[col][col] += 2.0;
    }
    var b = Basis{
        .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 1, 0, 0, 0, 0, 0 },
    };
    for (0..600) |_| {
        for (&b) |*row| row.* = matVec(&a, row.*);
        orthonormalize(&b);
    }
    return b;
}

// --- Lisi paper views ----------------------------------------------------------------

/// Simple roots of the graviweak F4 ⊂ E8 in coords 1..4 (Bourbaki: two long,
/// two short). Its 48 roots are the 24 first-d4 roots plus the projections of
/// the 8v+8s+8c fermion weights — the root system of Tables 5–6 (0711.0770).
const f4_simple = [4][4]f32{
    .{ 0, 1, -1, 0 },
    .{ 0, 0, 1, -1 },
    .{ 0, 0, 0, 1 },
    .{ 0.5, -0.5, -0.5, -0.5 },
};

fn dot4(a: [4]f32, b: [4]f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// Coxeter element of the graviweak F4 (order 12), columns of a 4×4 matrix.
fn f4Coxeter() [4][4]f32 {
    var m: [4][4]f32 = @splat(@splat(0));
    for (0..4) |i| m[i][i] = 1;
    for (f4_simple) |alpha| {
        const n2 = dot4(alpha, alpha); // F4 has short roots: use the full formula
        for (&m) |*col| {
            const d = 2.0 * dot4(col.*, alpha) / n2;
            for (0..4) |k| col[k] -= d * alpha[k];
        }
    }
    return m;
}

/// The Coxeter (Petrie) plane of the graviweak F4 — rotation angle 2π/12 — as
/// two orthonormal 8D rows supported on coords 1..4. Found the same way as the
/// E8 Coxeter plane: orthogonal iteration on C + Cᵀ + 2I in the 4D block.
pub fn f4Petrie() [2][8]f32 {
    const c = f4Coxeter();
    var a: [4][4]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| a[col][row] = c[col][row] + c[row][col];
        a[col][col] += 2.0;
    }
    var u = [4]f32{ 1, 0, 0, 0 };
    var v = [4]f32{ 0, 1, 0, 0 };
    for (0..400) |_| {
        var nu = [_]f32{0} ** 4;
        var nv = [_]f32{0} ** 4;
        for (0..4) |col| {
            for (0..4) |row| {
                nu[row] += a[col][row] * u[col];
                nv[row] += a[col][row] * v[col];
            }
        }
        const lu = @max(@sqrt(dot4(nu, nu)), 1e-12);
        for (&nu) |*x| x.* /= lu;
        const d = dot4(nv, nu);
        for (0..4) |k| nv[k] -= d * nu[k];
        const lv = @max(@sqrt(dot4(nv, nv)), 1e-12);
        for (&nv) |*x| x.* /= lv;
        u = nu;
        v = nv;
    }
    var out: [2][8]f32 = @splat(@splat(0));
    for (0..4) |k| {
        out[0][k] = u[k];
        out[1][k] = v[k];
    }
    return out;
}

/// The strong-charge view of 0711.0770 §2.1 (Table 2): x = g³, y = g⁸ — the
/// gluon hexagon with quark/antiquark triangles and leptons at the center —
/// and z = Lisi's w u(1) (coordinate 5), so the three xΦ generations and the
/// fermion generations separate in depth.
pub fn g2Basis() Basis {
    const s2 = 1.0 / @sqrt(2.0);
    const s6 = 1.0 / @sqrt(6.0);
    return .{
        .{ 0, 0, 0, 0, 0, -s2, s2, 0 },
        .{ 0, 0, 0, 0, 0, -s6, -s6, 2.0 * s6 },
        .{ 0, 0, 0, 0, 1, 0, 0, 0 },
    };
}

/// The graviweak view of 0711.0770 Tables 5–6: xy = the F4 Petrie plane
/// (12-fold figure of the 48 graviweak+fermion weights), z = the color λ8 axis
/// g⁸ so color multiplets separate in depth.
pub fn f4Basis() Basis {
    const p = f4Petrie();
    const s6 = 1.0 / @sqrt(6.0);
    return .{ p[0], p[1], .{ 0, 0, 0, 0, 0, -s6, -s6, 2.0 * s6 } };
}

/// The F4 ↔ G2 rotation of 0711.0770 Figs 3–4 (Lisi's e8rotation.mov): θ = 0
/// shows the F4 plane, θ = π/2 the G2 plane — near the G2 end the central 72
/// roots are the E6 subsystem (Fig 4). z stays on Lisi's w axis.
pub fn lisiRotationBasis(theta: f32) Basis {
    const p = f4Petrie();
    const g = g2Basis();
    const co = @cos(theta);
    const si = @sin(theta);
    var b: Basis = undefined;
    b[2] = .{ 0, 0, 0, 0, 1, 0, 0, 0 };
    for (0..8) |k| {
        b[0][k] = co * p[0][k] + si * g[0][k];
        b[1][k] = co * p[1][k] + si * g[1][k];
    }
    return b;
}

/// Charge axes in the spirit of Lisi's Elementary Particle Explorer: x = the
/// weak-isospin-like axis e3, y = the e4 axis of the graviweak so(8), z = the
/// color λ8 direction (quarks and leptons separate in depth, the gluon hexagon
/// stays flat). A pinch of λ3 is mixed into x so color multiplets don't overlap
/// exactly; the triple is then orthonormalized.
pub fn physicsBasis() Basis {
    var b = Basis{
        .{ 0, 0, 1, 0, 0, 0.15, -0.15, 0 },
        .{ 0, 0, 0, 1, 0.15, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 1, 1, -2 },
    };
    orthonormalize(&b);
    return b;
}

/// The first three lattice coordinates, unvarnished.
pub fn coordBasis() Basis {
    return .{
        .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 1, 0, 0, 0, 0, 0 },
    };
}

// --- display -----------------------------------------------------------------------

pub const ColorMode = enum(u8) {
    /// Physics classes; quarks/X bosons tinted by their actual su(3) color state.
    physics,
    /// Fermion generations I/II/III (Lisi's triality blocks) vs bosons.
    generation,
    /// so(16) split: integer (adjoint 120) vs spinor (128) roots.
    so16,
    /// Depth in the hidden dimensions: |component orthogonal to the view basis|.
    hidden,

    pub fn name(m: ColorMode) []const u8 {
        return switch (m) {
            .physics => "physics classes",
            .generation => "generations (triality)",
            .so16 => "so(16): 120 ⊕ 128",
            .hidden => "hidden-coordinate depth",
        };
    }
};

/// Base RGB (0..1) for a root under a color mode. `hidden_t` is the normalized
/// magnitude of the root's component outside the view basis (0 = fully visible).
pub fn rootRgb(r: *const Root, mode: ColorMode, hidden_t: f32) [3]f32 {
    switch (mode) {
        // On BLACK, and told apart at a glance. Two rules hold the palette together:
        // no class sits below ~0.45 in its brightest channel (a dark point on a dark
        // background is a point nobody sees), and neighbouring classes are separated
        // by HUE, not by shade — the eye reads a hue difference across a scene and a
        // shade difference only side by side.
        .physics => {
            const tint: [3]f32 = switch (r.color) {
                .red => .{ 1.00, 0.32, 0.30 }, // r
                .green => .{ 0.36, 1.00, 0.42 }, // g
                .blue => .{ 0.46, 0.64, 1.00 }, // b — lifted: pure blue disappears on black
                .anti_red => .{ 0.35, 1.00, 0.98 }, // cyan
                .anti_green => .{ 1.00, 0.46, 1.00 }, // magenta
                .anti_blue => .{ 1.00, 0.96, 0.45 }, // yellow
                else => .{ 1, 1, 1 },
            };
            return switch (r.class) {
                .gravity => .{ 0.42, 0.82, 1.00 }, // sky
                .electroweak => .{ 1.00, 0.93, 0.36 }, // yellow
                .frame_higgs => .{ 0.76, 0.60, 1.00 }, // violet (was a muted grey-purple)
                .gluon => .{ 1.00, 0.60, 0.18 }, // orange
                // The xΦ keeps the color charge of its Higgs, but as a PINK family:
                // brown-orange put it right on top of the gluons.
                .color_x => .{ 0.55 + 0.45 * tint[0], 0.30 + 0.30 * tint[1], 0.62 + 0.38 * tint[2] },
                .lepton => .{ 0.58, 1.00, 0.68 }, // mint
                .quark => tint,
            };
        },
        .generation => return switch (r.gen) {
            1 => .{ 0.36, 1.00, 0.52 }, // spring green
            2 => .{ 1.00, 0.76, 0.26 }, // amber
            3 => .{ 0.94, 0.50, 1.00 }, // magenta
            else => .{ 0.66, 0.74, 0.86 }, // bosons: a bright slate, not a dark one
        },
        .so16 => return if (r.integer) .{ 0.46, 0.76, 1.00 } else .{ 1.00, 0.66, 0.40 },
        .hidden => {
            const t = std.math.clamp(hidden_t, 0, 1);
            // Cyan (in the plane) → warm orange (hidden), both fully lit.
            return .{ 0.30 + 0.70 * t, 0.80 - 0.30 * t, 1.00 - 0.75 * t };
        },
    }
}

// --- export --------------------------------------------------------------------------

/// CSV of the whole system under the current projection — one row per root:
/// index, so(16) family, class, generation, color, the 8 lattice coordinates,
/// (λ3, λ8), Lisi's w and B−L charges, the projected 3D position, and the
/// index of the triality partner. Ready for numpy/pandas/Mathematica.
pub fn buildCsv(gpa: std.mem.Allocator, roots: []const Root, basis: *const Basis) ![]u8 {
    const tri = buildTriality(roots);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "index,family,class,gen,color,x1,x2,x3,x4,x5,x6,x7,x8,lambda3,lambda8,w,b_minus_l,px,py,pz,triality\n");
    var buf: [320]u8 = undefined;
    for (roots, 0..) |*r, i| {
        const p = project(basis, r.v);
        const line = try std.fmt.bufPrint(&buf, "{d},{s},{s},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d:.6},{d}\n", .{
            i,
            if (r.integer) "adjoint(120)" else "spinor(128)",
            r.class.name(),
            genName(r.gen),
            r.color.name(),
            r.v[0], r.v[1], r.v[2], r.v[3], r.v[4], r.v[5], r.v[6], r.v[7],
            r.t3,   r.t8,   r.w,    r.bl,
            p[0],   p[1],   p[2],
            tri[i],
        });
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

// --- tests ---------------------------------------------------------------------------

const testing = std.testing;

test "240 roots, all of norm² 2, all distinct" {
    const roots = generate();
    for (roots) |r| try testing.expectEqual(@as(f32, 2.0), dot8(r.v, r.v));
    for (0..n_roots) |i| {
        for (i + 1..n_roots) |j| {
            try testing.expect(!std.meta.eql(roots[i].v, roots[j].v));
        }
    }
}

test "class census matches Lisi's Table 9" {
    const roots = generate();
    var counts = [_]u32{0} ** 7;
    for (roots) |r| counts[@intFromEnum(r.class)] += 1;
    try testing.expectEqual(@as(u32, 4), counts[@intFromEnum(Class.gravity)]);
    try testing.expectEqual(@as(u32, 4), counts[@intFromEnum(Class.electroweak)]);
    try testing.expectEqual(@as(u32, 16), counts[@intFromEnum(Class.frame_higgs)]);
    try testing.expectEqual(@as(u32, 6), counts[@intFromEnum(Class.gluon)]);
    try testing.expectEqual(@as(u32, 18), counts[@intFromEnum(Class.color_x)]);
    try testing.expectEqual(@as(u32, 48), counts[@intFromEnum(Class.lepton)]);
    try testing.expectEqual(@as(u32, 144), counts[@intFromEnum(Class.quark)]);
}

test "three 64-root generations, each 16 leptons + 48 quarks (8 disjoint 24-cells)" {
    const roots = generate();
    var by_gen = [_]u32{0} ** 4;
    var leptons = [_]u32{0} ** 4;
    var quarks = [_]u32{0} ** 4;
    for (roots) |r| {
        by_gen[r.gen] += 1;
        if (r.class == .lepton) leptons[r.gen] += 1;
        if (r.class == .quark) quarks[r.gen] += 1;
    }
    try testing.expectEqual(@as(u32, 48), by_gen[0]); // bosons
    for (1..4) |g| {
        try testing.expectEqual(@as(u32, 64), by_gen[g]);
        try testing.expectEqual(@as(u32, 16), leptons[g]);
        try testing.expectEqual(@as(u32, 48), quarks[g]);
    }
    // Generation III is the integer (8v,8v') block; I and II are spinor.
    for (roots) |r| {
        if (r.gen == 3) try testing.expect(r.integer);
        if (r.gen == 1 or r.gen == 2) try testing.expect(!r.integer);
    }
}

test "every root has 56 nearest neighbors; 6720 edges" {
    const roots = generate();
    const edges = try buildEdges(testing.allocator, &roots);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, n_edges), edges.len);
    var deg = [_]u32{0} ** n_roots;
    for (edges) |e| {
        deg[e[0]] += 1;
        deg[e[1]] += 1;
    }
    for (deg) |d| try testing.expectEqual(@as(u32, 56), d);
}

test "gluons form the su(3) root hexagon; quarks carry fundamental weights" {
    const roots = generate();
    for (roots) |r| switch (r.class) {
        .gluon => try testing.expect(r.color == .adjoint),
        .quark => try testing.expect(r.color != .singlet and r.color != .adjoint),
        .lepton => try testing.expect(r.color == .singlet),
        .gravity, .electroweak, .frame_higgs => try testing.expect(r.color == .singlet),
        else => {},
    };
}

test "triality: order 3, cycles I→II→III, fixes W± + 4 eφ + 6 gluons" {
    const roots = generate();
    const t = trialityMatrix();
    // Orthogonal, order 3 on the whole space.
    for (0..8) |i| {
        for (0..8) |j| {
            var dot: f32 = 0;
            var cube: f32 = 0;
            for (0..8) |k| {
                dot += t[k][i] * t[k][j];
                for (0..8) |l| cube += t[i][k] * t[k][l] * t[l][j];
            }
            const id: f32 = if (i == j) 1 else 0;
            try testing.expectApproxEqAbs(id, dot, 1e-5);
            try testing.expectApproxEqAbs(id, cube, 1e-5);
        }
    }
    const tri = buildTriality(&roots);
    var fixed: u32 = 0;
    for (0..n_roots) |i| {
        const j = tri[i];
        try testing.expectEqual(@as(u16, @intCast(i)), tri[tri[j]]); // T³ = 1
        const a = &roots[i];
        const b = &roots[j];
        // W³ and color are invariant: λ3, λ8 (and so the color state) survive.
        try testing.expectApproxEqAbs(a.t3, b.t3, 1e-3);
        try testing.expectApproxEqAbs(a.t8, b.t8, 1e-3);
        try testing.expectEqual(a.color, b.color);
        if (a.gen != 0) {
            // Fermions cycle through the generations keeping their type.
            try testing.expectEqual(a.gen % 3 + 1, b.gen);
            try testing.expectEqual(a.class, b.class);
        }
        if (a.class == .gluon) try testing.expectEqual(@as(u16, @intCast(i)), j);
        if (i == j) fixed += 1;
    }
    try testing.expectEqual(@as(u32, 12), fixed);
}

test "Coxeter element has order 30" {
    const c = coxeterElement();
    // Power by repeated application to the basis columns.
    var p = matIdentity();
    for (0..30) |_| {
        var next: Mat8 = undefined;
        for (0..8) |col| next[col] = matVec(&c, p[col]);
        p = next;
    }
    const id = matIdentity();
    for (0..8) |col| {
        for (0..8) |row| try testing.expectApproxEqAbs(id[col][row], p[col][row], 1e-4);
    }
}

test "Coxeter basis: orthonormal, invariant plane, 2π/30 rotation" {
    const b = coxeterBasis();
    for (0..3) |i| {
        for (0..3) |j| {
            const expect: f32 = if (i == j) 1 else 0;
            try testing.expectApproxEqAbs(expect, dot8(b[i], b[j]), 1e-4);
        }
    }
    const c = coxeterElement();
    // C·u stays in span(u,v) and rotates by 12°.
    const cu = matVec(&c, b[0]);
    const du = dot8(cu, b[0]);
    const dv = dot8(cu, b[1]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), du * du + dv * dv, 1e-3);
    try testing.expectApproxEqAbs(@cos(2.0 * std.math.pi / 30.0), @abs(du), 1e-3);
}

test "graviweak F4: Coxeter element order 12, Petrie plane rotation 30°" {
    const c = f4Coxeter();
    var p: [4][4]f32 = @splat(@splat(0));
    for (0..4) |i| p[i][i] = 1;
    for (0..12) |_| {
        var next: [4][4]f32 = @splat(@splat(0));
        for (0..4) |col| {
            for (0..4) |row| {
                for (0..4) |k| next[col][row] += c[k][row] * p[col][k];
            }
        }
        p = next;
    }
    for (0..4) |col| {
        for (0..4) |row| {
            const id: f32 = if (col == row) 1 else 0;
            try testing.expectApproxEqAbs(id, p[col][row], 1e-4);
        }
    }
    const petrie = f4Petrie();
    try testing.expectApproxEqAbs(@as(f32, 1.0), dot8(petrie[0], petrie[0]), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), dot8(petrie[0], petrie[1]), 1e-4);
    // C·u stays in the plane and rotates by 2π/12.
    var cu = [_]f32{0} ** 4;
    for (0..4) |col| {
        for (0..4) |row| cu[row] += c[col][row] * petrie[0][col];
    }
    var cu8 = [_]f32{0} ** 8;
    for (0..4) |k| cu8[k] = cu[k];
    const du = dot8(cu8, petrie[0]);
    const dv = dot8(cu8, petrie[1]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), du * du + dv * dv, 1e-3);
    try testing.expectApproxEqAbs(@cos(2.0 * std.math.pi / 12.0), @abs(du), 1e-3);
}

test "paper bases are orthonormal; G2 view puts gluons on the flat hexagon" {
    const roots = generate();
    for ([_]Basis{ g2Basis(), f4Basis(), lisiRotationBasis(0.4) }) |b| {
        for (0..3) |i| {
            for (0..3) |j| {
                const id: f32 = if (i == j) 1 else 0;
                try testing.expectApproxEqAbs(id, dot8(b[i], b[j]), 1e-4);
            }
        }
    }
    const g2 = g2Basis();
    for (roots) |r| {
        const p = project(&g2, r.v);
        if (r.class == .gluon) {
            // The root hexagon (radius √2) in the (g³, g⁸) plane, at depth w = 0.
            try testing.expectApproxEqAbs(@as(f32, 2.0), p[0] * p[0] + p[1] * p[1], 1e-4);
            try testing.expectApproxEqAbs(@as(f32, 0.0), p[2], 1e-5);
        }
        if (r.class == .lepton and r.gen != 0) {
            // Leptons are color singlets: they sit on the hexagon's axis.
            try testing.expectApproxEqAbs(@as(f32, 0.0), p[0], 1e-4);
            try testing.expectApproxEqAbs(@as(f32, 0.0), p[1], 1e-4);
        }
    }
}

test "CSV export covers every root" {
    const roots = generate();
    var basis = coxeterBasis();
    const csv = try buildCsv(testing.allocator, &roots, &basis);
    defer testing.allocator.free(csv);
    var lines: usize = 0;
    for (csv) |ch| lines += @intFromBool(ch == '\n');
    try testing.expectEqual(@as(usize, n_roots + 1), lines);
}
