//! E10 — the hyperbolic Kac–Moody algebra of M-theory, in the chart where it
//! says something.
//!
//! E10 = E8^{++}: adjoin two nodes to Lisi's E8 and the algebra stops being a
//! compact 248-dimensional group and becomes infinite-dimensional and
//! HYPERBOLIC. This file builds its real roots, finds Lisi's E8 sitting inside
//! it, and runs the cosmological billiard — all in ONE set of coordinates, the
//! ten logarithmic scale factors βᵃ of eleven-dimensional supergravity.
//!
//! THE COORDINATES.  A root is a linear form on β-space, so it is a row of ten
//! integers wₐ, and the metric is the inverse DeWitt supermetric
//!
//!     ⟨w, w'⟩ = Σ wₐw'ₐ − (Σwₐ)(Σw'ₐ) / 9
//!
//! which is LORENTZIAN — it has a light cone, and that is the whole difference
//! from E8. The root lattice is { w ∈ ℤ¹⁰ : Σwₐ ≡ 0 mod 3 }, and the REAL ROOTS
//! are exactly its vectors of norm 2. There are infinitely many.
//!
//! THE LEVEL.  Grade a root by ℓ = Σwₐ / 3 — the number of times the tenth
//! simple root appears in it. This is the gl(10) level decomposition, and it is
//! the reason E10 is a theory of M-theory rather than a curiosity: each level is
//! finite, and each level IS one of eleven-dimensional supergravity's fields.
//!
//!     ℓ = 0   90 roots   sl(10)             the METRIC — gravity, the graviton
//!     ℓ = ±1  120 roots  C(10,3) = A_abc    the 3-FORM — what an M2-brane carries
//!     ℓ = ±2  210 roots  C(10,6) = A_a…f    the 6-FORM — what an M5-brane carries
//!     ℓ = ±3  360 roots  h_a…h|b            the DUAL GRAVITON
//!
//! Those counts are not asserted by hand: they fall out of the enumeration, and
//! the tests check them. Raise the level slider in the demo and you are not
//! zooming in on a bigger picture — you are unveiling M-theory's field content,
//! one field at a time.
//!
//! THE E8 INSIDE.  Delete two nodes from E10's Dynkin diagram and E8 is what is
//! left. So Lisi's 240 roots are literally a sub-root-system of the 1470 here,
//! and `lisiMap` finds them: it matches the two Cartan matrices, transports the
//! particle assignments across, and the tests check that all 240 land on
//! distinct roots and that the sub-system has exactly 240 members.
//!
//! THE BILLIARD.  Near the Big Bang the ten βᵃ fly in null Kasner lines and
//! bounce off ten walls — and the walls are these same ten simple roots. Same
//! algebra, same coordinates, same file.
//!
//!   A. Lisi, arXiv:0711.0770.
//!   T. Damour, M. Henneaux, H. Nicolai, "Cosmological Billiards",
//!     Class. Quantum Grav. 20 (2003) R145 (hep-th/0212256).
//!   T. Damour, H. Nicolai, "Symmetries, Singularities and the De-emergence of
//!     Space", arXiv:0705.2643.
//!   T. Damour, M. Henneaux, H. Nicolai, PRL 89 (2002) 221601 — the level
//!     decomposition, and the correspondence with eleven-dimensional supergravity.

const std = @import("std");
const e8 = @import("../lisi/e8.zig");

pub const dim = 10;
pub const rank = 10;

/// How many levels the demo builds. Level 3 is where the dual graviton lives —
/// the first field with no counterpart in the supergravity Lagrangian, and the
/// first hint that E10 knows more than eleven-dimensional supergravity does.
pub const max_level: i32 = 3;

/// The metric on roots: the INVERSE DeWitt supermetric. Lorentzian.
/// Exact in integers, because Σw is a multiple of 3 for every lattice vector.
pub fn ip(a: [10]i32, b: [10]i32) i32 {
    var s: i32 = 0;
    var sa: i32 = 0;
    var sb: i32 = 0;
    for (a, b) |x, y| {
        s += x * y;
        sa += x;
        sb += y;
    }
    return s - @divExact(sa, 3) * @divExact(sb, 3);
}

/// The same form on the rendered (float) coordinates — what the color modes read.
pub fn ipf(a: [10]f32, b: [10]f32) f32 {
    var s: f32 = 0;
    var sa: f32 = 0;
    var sb: f32 = 0;
    for (a, b) |x, y| {
        s += x * y;
        sa += x;
        sb += y;
    }
    return s - sa * sb / 9.0;
}

/// Euclidean length² of the coordinates — the length the EYE sees, as opposed to
/// the length the algebra sees. In E8 the two agree; here they part company.
pub fn euclid2(a: [10]f32) f32 {
    var s: f32 = 0;
    for (a) |x| s += x * x;
    return s;
}

/// The ten simple roots. Nine of them are the SYMMETRY walls αᵢ = β^{i+1} − βⁱ,
/// pure gravity; the tenth is the ELECTRIC wall α₁₀ = β¹+β²+β³ of the M-theory
/// 3-form. In the billiard these are the walls; in the algebra they are the
/// nodes of the Dynkin diagram. Same objects.
pub const simple: [rank][10]i32 = blk: {
    var a: [rank][10]i32 = @splat(@splat(0));
    for (0..9) |i| {
        a[i][i] = -1;
        a[i][i + 1] = 1;
    }
    a[9] = .{ 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
    break :blk a;
};

/// Deleting these two nodes from E10's diagram leaves E8 — Lisi's E8. The E10
/// diagram is a chain of nine with the tenth node hanging off the third; drop the
/// two nodes at the far end of the long arm and the arms become 1, 2, 4 — which is
/// E8's diagram exactly.
pub const deleted_nodes = [2]usize{ 7, 8 };
pub const e8_nodes = [8]usize{ 0, 1, 2, 3, 4, 5, 6, 9 };

/// The gl(10) level: which FIELD of eleven-dimensional supergravity a root belongs
/// to. Everything the demo's slider does is gate on this.
pub fn levelOf(w: [10]i32) i32 {
    var s: i32 = 0;
    for (w) |x| s += x;
    return @divExact(s, 3);
}

/// The field a level names. This is the physics content of E10, and it is why the
/// algebra is worth caring about.
pub const Field = enum(u8) {
    metric,
    three_form,
    six_form,
    dual_graviton,

    pub fn of(level: i32) Field {
        return switch (@abs(level)) {
            0 => .metric,
            1 => .three_form,
            2 => .six_form,
            else => .dual_graviton,
        };
    }

    pub fn label(f: Field) []const u8 {
        return switch (f) {
            .metric => "metric — gravity (sl(10))",
            .three_form => "3-form — the M2-brane",
            .six_form => "6-form — the M5-brane",
            .dual_graviton => "dual graviton",
        };
    }
};

pub const Root = struct {
    /// The rendered coordinates: the root's ten integers, as floats. No rescaling
    /// and no compression — at these levels the coordinates are already small.
    v: [10]f32,
    /// The root itself, exactly.
    w: [10]i32,
    /// gl(10) level: the field this root belongs to.
    level: i8,
    /// Height: the sum of its coefficients on the simple roots. How deep into E10.
    height: i16,
    field: Field,
    /// True if the root lies in the E8 sub-algebra — i.e. it is one of Lisi's.
    in_e8: bool,
    /// Index into Lisi's 240 roots, −1 if this root is not one of them.
    core: i16,
    /// Lisi's particle assignment, meaningful only when `core >= 0`.
    class: e8.Class,
    gen: u8,
};

// --- linear algebra we need once -----------------------------------------------------

fn invert(comptime N: usize, m_in: [N][N]f64) [N][N]f64 {
    var m = m_in;
    var inv: [N][N]f64 = @splat(@splat(0));
    for (0..N) |i| inv[i][i] = 1;
    for (0..N) |c| {
        var piv = c;
        for (c..N) |r| {
            if (@abs(m[r][c]) > @abs(m[piv][c])) piv = r;
        }
        std.mem.swap([N]f64, &m[c], &m[piv]);
        std.mem.swap([N]f64, &inv[c], &inv[piv]);
        const d = m[c][c];
        for (0..N) |k| {
            m[c][k] /= d;
            inv[c][k] /= d;
        }
        for (0..N) |r| {
            if (r == c) continue;
            const f = m[r][c];
            if (f == 0) continue;
            for (0..N) |k| {
                m[r][k] -= f * m[c][k];
                inv[r][k] -= f * inv[c][k];
            }
        }
    }
    return inv;
}

/// `coef[a][j]`: the coefficient of simple root j in a root w is Σₐ wₐ·coef[a][j].
/// (w = Σⱼ cⱼ·αⱼ, so c = w·A⁻¹ with A the matrix whose rows are the simple roots.)
var coef: [10][10]f64 = undefined;

/// The Coxeter plane of Lisi's E8, transported into these coordinates — so the
/// E8 sub-system still draws the iconic 30-fold figure, and every new root of E10
/// lands somewhere definite around it.
var cox_rows: [3][10]f32 = undefined;

var prepared = false;

fn simpleMatrix() [10][10]f64 {
    var a: [10][10]f64 = undefined;
    for (0..10) |j| {
        for (0..10) |k| a[j][k] = @floatFromInt(simple[j][k]);
    }
    return a;
}

/// Match E10's E8 sub-diagram to Lisi's own labelling of E8's simple roots, by
/// brute-force search over the 8! relabellings for one that makes the two Cartan
/// matrices agree. There is nothing clever here and nothing to get wrong: either
/// a matching exists — which is the statement that this really is E8 — or the
/// function fails.
///
/// Returns `pi`, with `pi[i]` = the index into `e8_nodes` of the E10 simple root
/// that plays the role of Lisi's simple root i.
pub fn matchE8() [8]usize {
    var cl: [8][8]i32 = undefined; // Lisi's Cartan matrix
    for (0..8) |i| {
        for (0..8) |j| {
            cl[i][j] = @intFromFloat(@round(e8.dot8(e8.simple_roots[i], e8.simple_roots[j])));
        }
    }
    var cb: [8][8]i32 = undefined; // the sub-diagram's
    for (0..8) |i| {
        for (0..8) |j| cb[i][j] = ip(simple[e8_nodes[i]], simple[e8_nodes[j]]);
    }

    var pi: [8]usize = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var used: [8]bool = @splat(false);
    if (search(&cl, &cb, &pi, &used, 0)) return pi;
    @panic("the E10 sub-diagram is not E8 — the construction is wrong");
}

fn search(cl: *const [8][8]i32, cb: *const [8][8]i32, pi: *[8]usize, used: *[8]bool, i: usize) bool {
    if (i == 8) return true;
    for (0..8) |cand| {
        if (used[cand]) continue;
        var ok = true;
        for (0..i) |j| {
            if (cb[cand][pi[j]] != cl[i][j]) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        if (cb[cand][cand] != cl[i][i]) continue;
        pi[i] = cand;
        used[cand] = true;
        if (search(cl, cb, pi, used, i + 1)) return true;
        used[cand] = false;
    }
    return false;
}

/// Every one of Lisi's 240 roots, as a root of E10. Expand it on Lisi's simple
/// roots, then rebuild it on the matched E10 simple roots: same coefficients,
/// same algebra, new coordinates.
pub fn lisiMap() [240][10]i32 {
    const pi = matchE8();
    var l: [8][8]f64 = undefined;
    for (0..8) |i| {
        for (0..8) |k| l[i][k] = e8.simple_roots[i][k];
    }
    const linv = invert(8, l);

    const roots = e8.generate();
    var out: [240][10]i32 = undefined;
    for (roots, 0..) |r, idx| {
        var w: [10]i32 = @splat(0);
        for (0..8) |i| { // cᵢ = Σₖ v[k]·linv[k][i]
            var c: f64 = 0;
            for (0..8) |k| c += @as(f64, r.v[k]) * linv[k][i];
            const ci: i32 = @intFromFloat(@round(c));
            const node = simple[e8_nodes[pi[i]]];
            for (0..10) |k| w[k] += ci * node[k];
        }
        out[idx] = w;
    }
    return out;
}

// --- enumerating the real roots --------------------------------------------------------
//
// A real root is a lattice vector of norm 2. At level ℓ that pins both moments:
//
//     Σwₐ = 3ℓ     and     Σwₐ² = 2 + ℓ²
//
// (the second from ⟨w,w⟩ = Σw² − (Σw)²/9 = 2). So the real roots at a level are
// exactly the integer solutions of those two equations — a small, finite, exactly
// enumerable set. No sampling, no Weyl-orbit search that might miss a corner, no
// arbitrary truncation: for each level we produce ALL of them.
//
// The nine symmetry walls generate the permutations of the ten βᵃ, so the
// solutions come in orbits of one multiset. We enumerate the multisets, then
// permute.

fn enumerateLevel(gpa: std.mem.Allocator, level: i32, out: *std.ArrayList([10]i32)) !void {
    const want_sum: i32 = 3 * level;
    const want_sq: i32 = 2 + level * level;
    const bound: i32 = @intFromFloat(@floor(@sqrt(@as(f64, @floatFromInt(want_sq)))));
    var vals: [10]i32 = @splat(0);
    try multisets(gpa, out, &vals, 0, -bound, bound, want_sum, want_sq);
}

/// Non-decreasing integer sequences with the required sum and sum-of-squares.
fn multisets(
    gpa: std.mem.Allocator,
    out: *std.ArrayList([10]i32),
    vals: *[10]i32,
    i: usize,
    lo: i32,
    hi: i32,
    rem_sum: i32,
    rem_sq: i32,
) !void {
    const left: i32 = @intCast(10 - i);
    if (i == 10) {
        if (rem_sum == 0 and rem_sq == 0) try permutations(gpa, out, vals.*);
        return;
    }
    // Nothing can be reached if even the extremes cannot: prune hard.
    if (rem_sq < 0) return;
    if (rem_sum > hi * left or rem_sum < lo * left) return;
    var x = lo;
    while (x <= hi) : (x += 1) {
        if (x * x > rem_sq) {
            if (x >= 0) return; // squares only grow from here
            continue;
        }
        vals[i] = x;
        try multisets(gpa, out, vals, i + 1, x, hi, rem_sum - x, rem_sq - x * x);
    }
}

/// Every distinct permutation of a multiset (the A9 Weyl orbit of one root).
fn permutations(gpa: std.mem.Allocator, out: *std.ArrayList([10]i32), sorted: [10]i32) !void {
    var w = sorted; // already non-decreasing
    while (true) {
        try out.append(gpa, w);
        // next lexicographic permutation
        var i: usize = 9;
        while (i > 0 and w[i - 1] >= w[i]) i -= 1;
        if (i == 0) return;
        var j: usize = 9;
        while (w[j] <= w[i - 1]) j -= 1;
        std.mem.swap(i32, &w[i - 1], &w[j]);
        std.mem.reverse(i32, w[i..]);
    }
}

/// All the real roots of E10 up to `max_level`, with Lisi's E8 found inside them.
/// Caller owns the slice.
pub fn generateAlloc(gpa: std.mem.Allocator) ![]Root {
    coef = invert(10, simpleMatrix());

    // Where Lisi's roots land, so we can hand each one its particle back.
    const lisi = lisiMap();
    const lisi_roots = e8.generate();
    var by_root = std.AutoHashMap([10]i32, u16).init(gpa);
    defer by_root.deinit();
    for (lisi, 0..) |w, i| try by_root.put(w, @intCast(i));

    var raw: std.ArrayList([10]i32) = .empty;
    defer raw.deinit(gpa);
    var level: i32 = -max_level;
    while (level <= max_level) : (level += 1) {
        try enumerateLevel(gpa, level, &raw);
    }

    var out = try gpa.alloc(Root, raw.items.len);
    errdefer gpa.free(out);
    for (raw.items, 0..) |w, i| {
        var v: [10]f32 = undefined;
        for (&v, w) |*x, c| x.* = @floatFromInt(c);

        // Coefficients on the simple roots: the height, and whether the two
        // deleted nodes are used at all — which is exactly "is this one of Lisi's".
        var height: f64 = 0;
        var outside: f64 = 0;
        for (0..10) |j| {
            var c: f64 = 0;
            for (0..10) |a| c += @as(f64, @floatFromInt(w[a])) * coef[a][j];
            height += c;
            for (deleted_nodes) |d| {
                if (j == d) outside += @abs(c);
            }
        }
        const lv = levelOf(w);
        const core: i16 = if (by_root.get(w)) |k| @intCast(k) else -1;
        out[i] = .{
            .v = v,
            .w = w,
            .level = @intCast(lv),
            .height = @intFromFloat(@round(height)),
            .field = Field.of(lv),
            .in_e8 = outside < 0.5,
            .core = core,
            .class = if (core >= 0) lisi_roots[@intCast(core)].class else .gravity,
            .gen = if (core >= 0) lisi_roots[@intCast(core)].gen else 0,
        };
    }

    prepareView();
    return out;
}

/// Transport Lisi's Coxeter projection into these coordinates. For a root of the
/// E8 sub-system this reproduces his figure EXACTLY — same 30-fold picture, same
/// roots, same positions. Every other root of E10 then lands wherever the same
/// linear map sends it, which is the honest thing to do: they are not in E8, and
/// they are not pretending to be.
fn prepareView() void {
    const pi = matchE8();
    const cox = e8.coxeterBasis(); // three rows in Lisi's R⁸
    for (0..3) |r| {
        for (0..10) |a| {
            var s: f64 = 0;
            for (0..8) |i| {
                // Row · (Lisi's simple root i), weighted by that root's coefficient.
                var dot: f64 = 0;
                for (0..8) |k| dot += @as(f64, cox[r][k]) * @as(f64, e8.simple_roots[i][k]);
                s += coef[a][e8_nodes[pi[i]]] * dot;
            }
            cox_rows[r][a] = @floatCast(s);
        }
    }
    prepared = true;
}

/// The E8 Coxeter plane (rows 0,1) and its third axis (row 2), in β coordinates.
pub fn coxeterRow(r: usize) [10]f32 {
    if (!prepared) prepareView();
    return cox_rows[r];
}

/// The LEVEL as a projection axis: point the third axis along it and the fields of
/// M-theory stack up as layers — gravity in the middle plane, the M2's 3-form one
/// above and below, the M5's 6-form beyond that, the dual graviton at the edge.
pub fn levelRow(scale: f32) [10]f32 {
    return @splat(scale / 3.0); // ℓ = Σw/3
}

/// The timelike direction of the Lorentzian metric — the one E8 does not have.
/// Rotating it into view is what a light cone looks like.
pub fn timeRow(scale: f32) [10]f32 {
    var out: [10]f32 = @splat(0);
    out[0] = scale;
    out[9] = -scale;
    return out;
}

// --- the cosmological billiard ---------------------------------------------------------
//
// Same algebra, same coordinates — but now on β itself rather than on forms. Near
// the singularity the ten scale factors fly in straight NULL lines (Kasner epochs)
// and bounce off the walls, which are the ten simple roots above. The chamber has
// finite volume, so the bouncing never stops: BKL chaos.

pub const Beta = [10]f32;

/// The DeWitt supermetric on β itself: ⟨u,v⟩ = Σuᵃvᵃ − (Σuᵃ)(Σvᵃ). Lorentzian —
/// the volume of space is the timelike direction.
pub fn dewitt(u: Beta, v: Beta) f32 {
    var s: f32 = 0;
    var su: f32 = 0;
    var sv: f32 = 0;
    for (u, v) |a, b| {
        s += a * b;
        su += a;
        sv += b;
    }
    return s - su * sv;
}

pub const WallKind = enum { symmetry, electric };

pub fn wallKind(i: usize) WallKind {
    return if (i < 9) .symmetry else .electric;
}

pub const Billiard = struct {
    beta: Beta,
    vel: Beta,
    bounces: u32 = 0,
    last_wall: i32 = -1,
    just_bounced: bool = false,
    rng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Billiard {
        var b = Billiard{ .beta = undefined, .vel = @splat(0), .rng = .init(seed) };
        // Strictly inside the Weyl chamber: β increasing (every symmetry wall
        // positive) and β¹+β²+β³ > 0 (the electric wall).
        for (&b.beta, 0..) |*x, i| x.* = 0.4 * (@as(f32, @floatFromInt(i)) + 1.0);
        b.kick();
        return b;
    }

    /// A fresh Kasner epoch: a random null velocity aimed at the singularity.
    pub fn kick(self: *Billiard) void {
        const r = self.rng.random();
        while (true) {
            var v: Beta = undefined;
            for (&v) |*x| x.* = r.floatNorm(f32);
            // Slide along (1,…,1) onto the null cone, using ⟨1,1⟩ = 10 − 100 = −90
            // and ⟨v,1⟩ = −9·Σv.
            var sv: f32 = 0;
            var vv: f32 = 0;
            for (v) |x| {
                sv += x;
                vv += x * x;
            }
            const disc = (18.0 * sv) * (18.0 * sv) + 360.0 * (vv - sv * sv);
            if (disc < 0) continue;
            const s = (18.0 * sv - @sqrt(disc)) / -180.0;
            for (&v) |*x| x.* += s;
            var fwd: f32 = 0;
            for (v) |x| fwd += x;
            if (fwd < 0) for (&v) |*x| {
                x.* = -x.*;
            };
            var l: f32 = 0;
            for (v) |x| l += x * x;
            l = @sqrt(l);
            if (l < 1e-4) continue;
            for (&v) |*x| x.* /= l;
            self.vel = v;
            return;
        }
    }

    /// The Kasner exponents: gᵃᵃ ~ t^{2pᵃ}, with Σpᵃ = Σ(pᵃ)² = 1 — so one is
    /// always NEGATIVE. Some axis of space is always being crushed.
    pub fn kasner(self: *const Billiard) Beta {
        var sum: f32 = 0;
        for (self.vel) |x| sum += x;
        if (@abs(sum) < 1e-6) return @splat(0.1);
        var p: Beta = undefined;
        for (&p, self.vel) |*x, v| x.* = v / sum;
        return p;
    }

    fn wallAt(self: *const Billiard, i: usize) f32 {
        var s: f32 = 0;
        for (simple[i], self.beta) |c, b| s += @as(f32, @floatFromInt(c)) * b;
        return s;
    }

    /// Free Kasner flight, then a WEYL REFLECTION of E10 when a wall is crossed.
    pub fn step(self: *Billiard, dt: f32) void {
        self.just_bounced = false;
        var before: [10]f32 = undefined;
        for (0..10) |i| before[i] = self.wallAt(i);
        for (&self.beta, self.vel) |*b, v| b.* += v * dt;

        var hit: i32 = -1;
        var depth: f32 = 0;
        for (0..10) |i| {
            const after = self.wallAt(i);
            if (before[i] > 0 and after <= 0 and after < depth) {
                depth = after;
                hit = @intCast(i);
            }
        }
        if (hit < 0) return;

        // x → x − 2⟨α,x⟩/⟨α,α⟩ · α♯, with (α♯)ᵃ = αₐ − (Σα)/9. Every simple root
        // has ⟨α,α⟩ = 2, so the factor of 2 cancels.
        const w = simple[@intCast(hit)];
        var sw: f32 = 0;
        for (w) |c| sw += @floatFromInt(c);
        var sharp: Beta = undefined;
        for (&sharp, w) |*x, c| x.* = @as(f32, @floatFromInt(c)) - sw / 9.0;
        var wv: f32 = 0;
        for (w, self.vel) |c, v| wv += @as(f32, @floatFromInt(c)) * v;
        for (&self.vel, sharp) |*v, s| v.* -= wv * s;
        for (&self.beta, sharp) |*b, s| b.* -= depth * s;
        self.bounces += 1;
        self.last_wall = hit;
        self.just_bounced = true;
    }

    /// 0 = isotropic space, 1 = torn along one axis and crushed along another.
    pub fn anisotropy(self: *const Billiard) f32 {
        const p = self.kasner();
        var s: f32 = 0;
        for (p) |x| {
            const d = x - 0.1;
            s += d * d;
        }
        return std.math.clamp(@sqrt(s / 10.0) * 3.0, 0, 1);
    }
};

// --- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "the ten simple roots have the Cartan matrix of E10" {
    var m: [10][10]i32 = undefined;
    for (0..10) |i| {
        for (0..10) |j| m[i][j] = ip(simple[i], simple[j]);
    }
    for (0..10) |i| {
        try testing.expectEqual(@as(i32, 2), m[i][i]);
        for (0..10) |j| {
            try testing.expectEqual(m[i][j], m[j][i]);
            try testing.expect(m[i][j] == 2 or m[i][j] == 0 or m[i][j] == -1);
        }
    }
    // A tree on ten nodes, one branch node, arms of 1, 2 and 6: T₂,₃,₇ = E10.
    var deg: [10]usize = @splat(0);
    var edges: usize = 0;
    for (0..10) |i| {
        for (i + 1..10) |j| {
            if (m[i][j] == -1) {
                deg[i] += 1;
                deg[j] += 1;
                edges += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 9), edges);
    var branch: usize = 99;
    for (deg, 0..) |d, i| {
        if (d == 3) {
            try testing.expectEqual(@as(usize, 99), branch); // only one
            branch = i;
        }
    }
    try testing.expectEqual(@as(usize, 2), branch); // the 3-form hangs off node 3
}

test "the level decomposition IS eleven-dimensional supergravity's field content" {
    const gpa = testing.allocator;
    const roots = try generateAlloc(gpa);
    defer gpa.free(roots);

    var count = [_]usize{0} ** 7; // levels −3 … +3
    for (roots) |r| {
        // Every root is real: norm exactly 2, no exceptions.
        try testing.expectEqual(@as(i32, 2), ip(r.w, r.w));
        count[@intCast(r.level + 3)] += 1;
    }

    // These numbers are the whole point. They are not put in by hand — they come
    // out of solving Σw = 3ℓ, Σw² = 2 + ℓ² — and they are the fields of M-theory:
    try testing.expectEqual(@as(usize, 90), count[3]); // ℓ=0  sl(10): the METRIC
    try testing.expectEqual(@as(usize, 120), count[4]); // ℓ=1  C(10,3): the 3-FORM (M2)
    try testing.expectEqual(@as(usize, 210), count[5]); // ℓ=2  C(10,6): the 6-FORM (M5)
    try testing.expectEqual(@as(usize, 360), count[6]); // ℓ=3  the DUAL GRAVITON
    // and the negative levels mirror them exactly.
    try testing.expectEqual(count[4], count[2]);
    try testing.expectEqual(count[5], count[1]);
    try testing.expectEqual(count[6], count[0]);
    try testing.expectEqual(@as(usize, 1470), roots.len);
}

test "Lisi's E8 really is inside E10, all 240 roots of it" {
    const gpa = testing.allocator;
    const roots = try generateAlloc(gpa);
    defer gpa.free(roots);

    // The sub-system spanned by the eight surviving nodes has exactly 240 roots —
    // E8's count, on the nose.
    var in_e8: usize = 0;
    var labelled: usize = 0;
    var seen: [240]bool = @splat(false);
    for (roots) |r| {
        if (r.in_e8) in_e8 += 1;
        if (r.core >= 0) {
            labelled += 1;
            const k: usize = @intCast(r.core);
            try testing.expect(!seen[k]); // each of Lisi's roots lands exactly once
            seen[k] = true;
            // …and a root that carries one of Lisi's particles had better BE in E8.
            try testing.expect(r.in_e8);
        }
    }
    try testing.expectEqual(@as(usize, 240), in_e8);
    try testing.expectEqual(@as(usize, 240), labelled);
    for (seen) |s| try testing.expect(s);
}

test "the mapping preserves the algebra: angles between Lisi's roots survive" {
    const lisi = lisiMap();
    const roots = e8.generate();
    // Lisi's E8 and its image in E10 are the same root system: every inner product
    // between every pair of the 240 is unchanged. That is what "E8 ⊂ E10" means, and
    // it is checked here 57 360 times rather than asserted.
    for (0..240) |i| {
        for (0..240) |j| {
            const a: i32 = @intFromFloat(@round(e8.dot8(roots[i].v, roots[j].v)));
            try testing.expectEqual(a, ip(lisi[i], lisi[j]));
        }
    }
}

test "the billiard: null velocity, Kasner conditions, and it never stops bouncing" {
    var b = Billiard.init(20_031_145);
    for (0..30_000) |_| {
        b.step(0.002);
        try testing.expectApproxEqAbs(@as(f32, 0), dewitt(b.vel, b.vel), 5e-3);
    }
    const p = b.kasner();
    var s1: f32 = 0;
    var s2: f32 = 0;
    var min: f32 = 1;
    for (p) |x| {
        s1 += x;
        s2 += x * x;
        min = @min(min, x);
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0), s1, 1e-2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s2, 1e-2);
    try testing.expect(min < 0);
    try testing.expect(b.bounces > 3);
}
